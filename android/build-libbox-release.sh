#!/usr/bin/env bash
# Builds the Android sing-box/libbox AAR (android/app/libs/libbox.aar) from the
# exact sing-box revision pinned in ../SINGBOX_VERSION, with OpenRung's committed
# NAT-punch binding (android/punchbridge) injected into the same gomobile
# package/runtime on top of the shared punch core, consumed as the Go module
# github.com/openrung/openrung/punchcore at the version pinned in
# android/punchbridge/go.mod. libbox is GPL-3.0, so the sing-box pin,
# android/punchbridge, and the pinned punchcore module version together are the
# GPL §6 corresponding source for the native Go portion of any released APK
# (see ../RELEASE.md).
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
sing_box_version="$(tr -d '[:space:]' < "$repo_root/SINGBOX_VERSION")"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/openrung-sing-box-release.XXXXXX")"
punch_source="$script_dir/punchbridge"
trap 'rm -rf "$work_dir"' EXIT

export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$ANDROID_HOME/ndk/29.0.14206865}"
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home}"
export PATH="$HOME/go/bin:/opt/homebrew/bin:/opt/homebrew/opt/openjdk@17/bin:$PATH"

# Read the punchcore pin from punchbridge's go.mod without loading the module
# graph (the graph would need the tag to be fetchable, which pre-tag dev breaks).
punchcore_version="$(go mod edit -json "$punch_source/go.mod" | python3 -c '
import json, sys
data = json.load(sys.stdin)
for require in data.get("Require") or []:
    if require["Path"] == "github.com/openrung/openrung/punchcore":
        print(require["Version"])
        break
')"
if [ -z "$punchcore_version" ]; then
  echo "error: $punch_source/go.mod has no require for github.com/openrung/openrung/punchcore" >&2
  exit 1
fi

if [ -n "${PUNCHCORE_SRC:-}" ]; then
  # Dev mode resolves punchcore from a local checkout. Absolutize once, then
  # write an explicit workspace used for the test step below: tests and the
  # graft build must see the SAME punchcore tree, and an ambient developer
  # go.work (which may point at a different checkout) is never consulted.
  PUNCHCORE_SRC="$(cd "$PUNCHCORE_SRC" && pwd)"
  dev_workspace="$work_dir/punchcore-dev.work"
  cat > "$dev_workspace" <<EOF
go 1.25.0

use $punch_source

replace github.com/openrung/openrung/punchcore => $PUNCHCORE_SRC
EOF
fi

echo "Testing the OpenRung NAT-punch binding"
(
  cd "$punch_source"
  if [ -n "${PUNCHCORE_SRC:-}" ]; then
    # Dev mode: test through the explicit workspace so the tested punchcore is
    # exactly the tree the graft will build ($PUNCHCORE_SRC), regardless of
    # any ambient go.work.
    GOWORK="$dev_workspace" go test ./...
  else
    # Release mode: force workspace mode off so a stray developer go.work can
    # never make the tested code differ from the pinned punchcore module the
    # grafted build ships.
    GOWORK=off go test ./...
  fi
)

echo "Building libbox.aar from sing-box $sing_box_version with NAT punching"

cd "$script_dir"

module_cache="${GOMODCACHE:-$(go env GOMODCACHE)}"
module_source="$module_cache/github.com/sagernet/sing-box@$sing_box_version"

GOMODCACHE="$module_cache" go mod download "github.com/sagernet/sing-box@$sing_box_version"
cp -R "$module_source" "$work_dir/source"
chmod -R u+w "$work_dir/source"

# gomobile applications must use a single generated Go runtime. A standalone
# punchbridge.aar would duplicate go.Seq/go.Universe and its native runtime next
# to libbox.aar, so merge the binding (and its sagernet-QUIC session layer) into
# sing-box's existing experimental/libbox package before its normal build
# command runs. The shared punch core is NOT copied: it is resolved as the
# pinned github.com/openrung/openrung/punchcore module injected into the grafted
# go.mod below. Tests are excluded from the copy so the graft carries exactly
# the sources that ship.
cp "$punch_source/binding.go" "$work_dir/source/experimental/libbox/openrung_punch.go"
mkdir -p "$work_dir/source/experimental/libbox/internal/openrungpunch"
for source_file in "$punch_source/internal/openrungpunch/"*.go; do
  case "$source_file" in
    *_test.go) continue ;;
  esac
  cp "$source_file" "$work_dir/source/experimental/libbox/internal/openrungpunch/"
done

(
  cd "$work_dir/source"
  if [ -n "${PUNCHCORE_SRC:-}" ]; then
    # (already absolutized next to the dev workspace above)
    echo "==============================================================" >&2
    echo "WARNING: PUNCHCORE_SRC is set — building against the local" >&2
    echo "punchcore checkout at $PUNCHCORE_SRC." >&2
    echo "This is for development only. A released AAR must be built" >&2
    echo "WITHOUT PUNCHCORE_SRC so it resolves the pinned punchcore" >&2
    echo "module version (GPL §6 pins the corresponding source)." >&2
    echo "==============================================================" >&2
    GOWORK=off go mod edit \
      -require "github.com/openrung/openrung/punchcore@$punchcore_version" \
      -replace "github.com/openrung/openrung/punchcore=$PUNCHCORE_SRC"
    # No `go mod tidy`: a directory replace of a zero-dependency module needs no
    # go.sum entries, and tidy would rewrite unrelated sing-box dependencies.
  else
    GOFLAGS=-mod=mod GOMODCACHE="$module_cache" GOWORK=off \
      go get "github.com/openrung/openrung/punchcore@$punchcore_version"
  fi
  # GOWORK=off so a developer go.work can never leak into the graft build.
  GOMODCACHE="$module_cache" GOWORK=off go run ./cmd/internal/build_libbox \
    -target android \
    -platform android/arm64
)

mkdir -p "$script_dir/app/libs"
cp "$work_dir/source/libbox.aar" "$script_dir/app/libs/libbox.aar"
echo "Release libbox AAR: $script_dir/app/libs/libbox.aar"
