#!/usr/bin/env bash
# Builds the Android sing-box/libbox AAR (android/app/libs/libbox.aar) from the
# exact sing-box revision pinned in ../SINGBOX_VERSION, with OpenRung's committed
# NAT-punch client injected into the same gomobile package/runtime. libbox is
# GPL-3.0, so the pin plus android/punchbridge are the GPL §6 corresponding
# source for the native Go portion of any released APK (see ../RELEASE.md).
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

echo "Testing the OpenRung NAT-punch binding"
(
  cd "$punch_source"
  go test ./...
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
# to libbox.aar, so merge the binding and client core into sing-box's existing
# experimental/libbox package before its normal build command runs.
cp "$punch_source/binding.go" "$work_dir/source/experimental/libbox/openrung_punch.go"
mkdir -p "$work_dir/source/experimental/libbox/internal/openrungpunch"
cp "$punch_source/internal/openrungpunch/"*.go \
  "$work_dir/source/experimental/libbox/internal/openrungpunch/"

(
  cd "$work_dir/source"
  GOMODCACHE="$module_cache" go run ./cmd/internal/build_libbox \
    -target android \
    -platform android/arm64
)

mkdir -p "$script_dir/app/libs"
cp "$work_dir/source/libbox.aar" "$script_dir/app/libs/libbox.aar"
echo "Release libbox AAR: $script_dir/app/libs/libbox.aar"
