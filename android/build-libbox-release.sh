#!/usr/bin/env bash
# Builds the Android sing-box/libbox AAR (android/app/libs/libbox.aar) from the
# exact sing-box revision pinned in ../SINGBOX_VERSION, with OpenRung's committed
# native bindings (android/punchbridge) injected into the same gomobile
# package/runtime on top of the pinned shared punchcore and wsscore modules.
# libbox is GPL-3.0, so the sing-box pin, android/punchbridge, and both OpenRung
# module pins together are the GPL §6 corresponding source for the native Go
# portion of any released APK (see ../RELEASE.md).
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

# Read the shared-module pins from punchbridge's go.mod without loading the
# graph (the graph would need each tag to be fetchable, which pre-tag dev
# breaks).
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

wsscore_version="$(go mod edit -json "$punch_source/go.mod" | python3 -c '
import json, sys
data = json.load(sys.stdin)
for require in data.get("Require") or []:
    if require["Path"] == "github.com/openrung/openrung/wsscore":
        print(require["Version"])
        break
')"
if [ -z "$wsscore_version" ]; then
  echo "error: $punch_source/go.mod has no require for github.com/openrung/openrung/wsscore" >&2
  exit 1
fi

dev_workspace=""
if [ -n "${PUNCHCORE_SRC:-}" ] || [ -n "${WSSCORE_SRC:-}" ]; then
  # Dev mode resolves either shared module from a local checkout. Tests and
  # the graft use this explicit workspace so an ambient go.work can never make
  # the tested trees differ from the trees shipped in the AAR.
  if [ -n "${PUNCHCORE_SRC:-}" ]; then
    PUNCHCORE_SRC="$(cd "$PUNCHCORE_SRC" && pwd)"
  fi
  if [ -n "${WSSCORE_SRC:-}" ]; then
    WSSCORE_SRC="$(cd "$WSSCORE_SRC" && pwd)"
  fi
  dev_workspace="$work_dir/openrung-core-dev.work"
  {
    echo "go 1.25.0"
    echo
    echo "use $punch_source"
    if [ -n "${PUNCHCORE_SRC:-}" ]; then
      echo
      echo "replace github.com/openrung/openrung/punchcore => $PUNCHCORE_SRC"
    fi
    if [ -n "${WSSCORE_SRC:-}" ]; then
      echo
      echo "replace github.com/openrung/openrung/wsscore => $WSSCORE_SRC"
    fi
  } > "$dev_workspace"
fi

echo "Testing the OpenRung native bindings"
(
  cd "$punch_source"
  if [ -n "$dev_workspace" ]; then
    # Dev mode: test through the explicit workspace so the tested shared
    # modules exactly match the trees the graft will build.
    GOWORK="$dev_workspace" go test ./...
  else
    # Release mode: force workspace mode off so a stray developer go.work can
    # never make tested code differ from either pinned shared module.
    GOWORK=off go test ./...
  fi
)

echo "Building libbox.aar from sing-box $sing_box_version with OpenRung native transports"

cd "$script_dir"

module_cache="${GOMODCACHE:-$(go env GOMODCACHE)}"
module_source="$module_cache/github.com/sagernet/sing-box@$sing_box_version"

GOMODCACHE="$module_cache" go mod download "github.com/sagernet/sing-box@$sing_box_version"
cp -R "$module_source" "$work_dir/source"
chmod -R u+w "$work_dir/source"

# gomobile applications must use a single generated Go runtime. A standalone
# punchbridge.aar would duplicate go.Seq/go.Universe and its native runtime next
# to libbox.aar, so merge the bindings (and the sagernet-QUIC session layer)
# into sing-box's existing experimental/libbox package before its normal build
# command runs. Shared transport implementations are NOT copied: punchcore and
# wsscore resolve from their pinned modules. Tests are excluded from the graft.
cp "$punch_source/binding.go" "$work_dir/source/experimental/libbox/openrung_punch.go"
cp "$punch_source/wss_binding.go" "$work_dir/source/experimental/libbox/openrung_wss.go"
mkdir -p "$work_dir/source/experimental/libbox/internal/openrungpunch"
for source_file in "$punch_source/internal/openrungpunch/"*.go; do
  case "$source_file" in
    *_test.go) continue ;;
  esac
  cp "$source_file" "$work_dir/source/experimental/libbox/internal/openrungpunch/"
done

(
  cd "$work_dir/source"
  go_mod_edits=(
    -require "github.com/openrung/openrung/punchcore@$punchcore_version"
    -require "github.com/openrung/openrung/wsscore@$wsscore_version"
  )
  if [ -n "${PUNCHCORE_SRC:-}" ]; then
    go_mod_edits+=(
      -replace "github.com/openrung/openrung/punchcore=$PUNCHCORE_SRC"
    )
  fi
  if [ -n "${WSSCORE_SRC:-}" ]; then
    go_mod_edits+=(
      -replace "github.com/openrung/openrung/wsscore=$WSSCORE_SRC"
    )
  fi

  if [ -n "$dev_workspace" ]; then
    echo "==============================================================" >&2
    echo "WARNING: building with local OpenRung shared-module source." >&2
    if [ -n "${PUNCHCORE_SRC:-}" ]; then
      echo "PUNCHCORE_SRC: $PUNCHCORE_SRC" >&2
    fi
    if [ -n "${WSSCORE_SRC:-}" ]; then
      echo "WSSCORE_SRC: $WSSCORE_SRC" >&2
    fi
    echo "This is for development only. Release AARs must resolve" >&2
    echo "both versions pinned in android/punchbridge/go.mod." >&2
    echo "==============================================================" >&2
  fi

  GOWORK=off go mod edit "${go_mod_edits[@]}"
  # Resolve both exact pins without `go mod tidy`, which would rewrite
  # unrelated sing-box requirements. go get also records the full module sums
  # required by gomobile's read-only build; any directory replaces above remain
  # authoritative for development builds.
  GOFLAGS=-mod=mod GOMODCACHE="$module_cache" GOWORK=off \
    go get \
      "github.com/openrung/openrung/punchcore@$punchcore_version" \
      "github.com/openrung/openrung/wsscore@$wsscore_version"
  # GOWORK=off so a developer go.work can never leak into the graft build.
  # Build one AAR with all four React Native release ABIs: armeabi-v7a,
  # arm64-v8a, x86, and x86_64. The previous arm64-only target was too narrow
  # for the app's declared reactNativeArchitectures set.
  GOMODCACHE="$module_cache" GOWORK=off go run ./cmd/internal/build_libbox \
    -target android \
    -platform android
)

mkdir -p "$script_dir/app/libs"
cp "$work_dir/source/libbox.aar" "$script_dir/app/libs/libbox.aar"
echo "Release libbox AAR: $script_dir/app/libs/libbox.aar"
