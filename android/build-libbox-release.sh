#!/usr/bin/env bash
# Builds the Android sing-box/libbox AAR (android/app/libs/libbox.aar) from the
# exact sing-box revision pinned in ../SINGBOX_VERSION, with the OpenRung NAT
# hole-punch client (openrung/mobile/orpunch, pinned in ../OPENRUNG_VERSION)
# bound into the SAME AAR. Both run under one Go runtime: gomobile binds the
# io.nekohasekai.libbox.* and io.nekohasekai.orpunch.* packages together, so
# there is a single go/Seq JNI bridge and a single libbox.so (a second, separate
# AAR would collide on go/Seq and run two Go runtimes — unsupported).
#
# libbox is GPL-3.0 (pinned rev = ../SINGBOX_VERSION) and openrung is GPL-3.0
# (pinned rev = ../OPENRUNG_VERSION); together they are the GPL §6 corresponding
# source for the shipped APK's native engine — keep both pins in lockstep with the
# released binary (see ../RELEASE.md).
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
sing_box_version="$(tr -d '[:space:]' < "$repo_root/SINGBOX_VERSION")"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/openrung-sing-box-release.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$ANDROID_HOME/ndk/29.0.14206865}"
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home}"
export PATH="$HOME/go/bin:/opt/homebrew/bin:/opt/homebrew/opt/openjdk@17/bin:$PATH"

# OPENRUNG_SRC is a local checkout of the openrung Go module (module path
# "openrung"). It is a private module path with no VCS host, so it can only be
# wired in via a go.mod `replace` to a local path — check it out at the
# ../OPENRUNG_VERSION commit for a reproducible, GPL-corresponding build. Default
# to a sibling of the app repo; override for worktrees or other layouts.
resolve_openrung_src() {
  if [[ -n "${OPENRUNG_SRC:-}" ]]; then
    printf '%s' "$OPENRUNG_SRC"
    return
  fi
  local candidate
  for candidate in "$repo_root/../openrung" "$repo_root/../../openrung" "/opt/projects/openrung"; do
    if [[ -f "$candidate/go.mod" ]] && grep -qx 'module openrung' "$candidate/go.mod" 2>/dev/null; then
      (cd "$candidate" && pwd)
      return
    fi
  done
  echo "error: could not locate the openrung Go module; set OPENRUNG_SRC to its checkout" >&2
  exit 1
}
openrung_src="$(resolve_openrung_src)"
echo "Building libbox.aar from sing-box $sing_box_version + openrung punch ($openrung_src)"

cd "$script_dir"

module_cache="${GOMODCACHE:-$(go env GOMODCACHE)}"
module_source="$module_cache/github.com/sagernet/sing-box@$sing_box_version"

GOMODCACHE="$module_cache" go mod download "github.com/sagernet/sing-box@$sing_box_version"
cp -R "$module_source" "$work_dir/source"
chmod -R u+w "$work_dir/source"

(
  cd "$work_dir/source"

  # Wire the openrung punch wrapper into the sing-box module's build graph. The
  # keep-file forces `go mod tidy` to retain the (otherwise unimported) require and
  # pull openrung's transitive deps (mainline quic-go v0.60.0, which coexists with
  # sagernet's fork — different module paths). The require is added explicitly so
  # tidy resolves it even before the bind arg references it.
  {
    echo ''
    echo 'require openrung v0.0.0-00010101000000-000000000000'
    echo "replace openrung => $openrung_src"
  } >> go.mod
  mkdir -p orpunchkeep
  printf 'package orpunchkeep\n\nimport _ "openrung/mobile/orpunch"\n' > orpunchkeep/keep.go
  GOFLAGS=-mod=mod GOMODCACHE="$module_cache" GOWORK=off go mod tidy

  # Append the wrapper to build_libbox's single bind package arg so both packages
  # land in one AAR / one Go runtime. Every gomobile flag, build tag, and ldflag
  # (-checklinkname=0, badlinkname, tfogo_checklinkname0, with_quic, ...) stays
  # sourced from build_libbox, so the libbox half is byte-for-byte the stock build.
  perl -0pi -e 's{args = append\(args, "\./experimental/libbox"\)}{args = append(args, "./experimental/libbox", "openrung/mobile/orpunch")}' \
    cmd/internal/build_libbox/main.go
  if ! grep -q 'openrung/mobile/orpunch' cmd/internal/build_libbox/main.go; then
    echo "error: failed to inject the orpunch bind package into build_libbox" >&2
    exit 1
  fi

  GOFLAGS=-mod=mod GOMODCACHE="$module_cache" GOWORK=off go run ./cmd/internal/build_libbox \
    -target android \
    -platform android/arm64
)

mkdir -p "$script_dir/app/libs"
cp "$work_dir/source/libbox.aar" "$script_dir/app/libs/libbox.aar"

# Sanity-check that both halves made it into the single AAR. gomobile nests the
# Java classes inside classes.jar, so extract that and inspect it, not the AAR's
# top level.
check_dir="$work_dir/aar-check"
mkdir -p "$check_dir"
unzip -o -q "$script_dir/app/libs/libbox.aar" classes.jar -d "$check_dir"
if ! unzip -l "$check_dir/classes.jar" | grep -q 'io/nekohasekai/orpunch/Session.class'; then
  echo "error: the built AAR is missing io.nekohasekai.orpunch classes" >&2
  exit 1
fi
if ! unzip -l "$check_dir/classes.jar" | grep -q 'io/nekohasekai/libbox/Libbox.class'; then
  echo "error: the built AAR is missing io.nekohasekai.libbox classes" >&2
  exit 1
fi
echo "Release libbox+punch AAR: $script_dir/app/libs/libbox.aar"
