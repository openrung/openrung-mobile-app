#!/usr/bin/env bash
# Builds ios/ThirdParty/Libbox.xcframework from the exact sing-box revision in
# ../SINGBOX_VERSION and grafts OpenRung's WSS binding into libbox's existing
# gomobile package. This deliberately produces one XCFramework and one Go
# runtime: do not ship the binding as a second gomobile framework.
#
# The WSS transport itself is resolved from the exact wsscore module version in
# android/punchbridge/go.mod. Set WSSCORE_SRC=/path/to/wsscore only for local
# development; release artifacts must use the pinned module tag.
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
binding_source="$repo_root/android/punchbridge"
sing_box_version="$(tr -d '[:space:]' < "$repo_root/SINGBOX_VERSION")"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/openrung-sing-box-apple.XXXXXX")"
incoming_artifact="$script_dir/ThirdParty/.Libbox.xcframework.new.$$"
trap 'rm -rf "$work_dir" "$incoming_artifact"' EXIT

go_bin="$(go env GOPATH)/bin"
export PATH="$go_bin:/opt/homebrew/bin:$PATH"

for required_tool in go python3 xcodebuild; do
  if ! command -v "$required_tool" >/dev/null 2>&1; then
    echo "error: required tool '$required_tool' was not found in PATH" >&2
    exit 1
  fi
done

# sing-box's build helper loads gomobile from GOPATH/bin. Require the documented
# tool version instead of silently accepting a different generator from PATH.
for mobile_tool in gomobile gobind; do
  mobile_path="$go_bin/$mobile_tool"
  if [ ! -x "$mobile_path" ] || \
    ! go version -m "$mobile_path" | grep -Fq $'mod\tgithub.com/sagernet/gomobile\tv0.1.12'; then
    echo "error: $mobile_path must be github.com/sagernet/gomobile v0.1.12" >&2
    echo "install it with: go install github.com/sagernet/gomobile/cmd/$mobile_tool@v0.1.12" >&2
    exit 1
  fi
done

wsscore_version="$(go mod edit -json "$binding_source/go.mod" | python3 -c '
import json, sys
data = json.load(sys.stdin)
for require in data.get("Require") or []:
    if require["Path"] == "github.com/openrung/openrung/wsscore":
        print(require["Version"])
        break
')"
if [ -z "$wsscore_version" ]; then
  echo "error: $binding_source/go.mod has no wsscore module pin" >&2
  exit 1
fi

dev_workspace=""
if [ -n "${WSSCORE_SRC:-}" ]; then
  WSSCORE_SRC="$(cd "$WSSCORE_SRC" && pwd)"
  dev_workspace="$work_dir/openrung-wsscore-dev.work"
  {
    echo "go 1.25.0"
    echo
    echo "use $binding_source"
    echo
    echo "replace github.com/openrung/openrung/wsscore => $WSSCORE_SRC"
  } > "$dev_workspace"
fi

echo "Testing the OpenRung native bindings"
(
  cd "$binding_source"
  if [ -n "$dev_workspace" ]; then
    GOWORK="$dev_workspace" go test ./...
  else
    GOWORK=off go test ./...
  fi
)

echo "Building Libbox.xcframework from sing-box $sing_box_version with wsscore $wsscore_version"

module_cache="${GOMODCACHE:-$(go env GOMODCACHE)}"
module_source="$module_cache/github.com/sagernet/sing-box@$sing_box_version"
GOMODCACHE="$module_cache" GOWORK=off go mod download \
  "github.com/sagernet/sing-box@$sing_box_version"
cp -R "$module_source" "$work_dir/source"
chmod -R u+w "$work_dir/source"

# The gomobile-generated Objective-C API, wsscore client, and sing-box engine
# must share libbox's Go runtime. Only the thin binding is copied; WebSocket,
# TLS, yamux, stream copying, and transport bounds remain in the tagged module.
cp "$binding_source/wss_binding.go" \
  "$work_dir/source/experimental/libbox/openrung_wss.go"

(
  cd "$work_dir/source"
  go_mod_edits=(
    -require "github.com/openrung/openrung/wsscore@$wsscore_version"
  )
  if [ -n "${WSSCORE_SRC:-}" ]; then
    go_mod_edits+=(
      -replace "github.com/openrung/openrung/wsscore=$WSSCORE_SRC"
    )
    echo "==============================================================" >&2
    echo "WARNING: building with local WSSCORE_SRC: $WSSCORE_SRC" >&2
    echo "This is for development only; releases must use $wsscore_version." >&2
    echo "==============================================================" >&2
  fi

  GOWORK=off go mod edit "${go_mod_edits[@]}"
  GOFLAGS=-mod=mod GOMODCACHE="$module_cache" GOWORK=off \
    go get "github.com/openrung/openrung/wsscore@$wsscore_version"
  GOMODCACHE="$module_cache" GOWORK=off \
    go run ./cmd/internal/build_libbox \
      -target apple \
      -platform ios,iossimulator
)

artifact="$work_dir/source/Libbox.xcframework"
for slice in ios-arm64 ios-arm64_x86_64-simulator; do
  header="$artifact/$slice/Libbox.framework/Headers/Libbox.objc.h"
  binary="$artifact/$slice/Libbox.framework/Libbox"
  if [ ! -f "$header" ] || [ ! -f "$binary" ]; then
    echo "error: Apple build is missing required $slice framework files" >&2
    exit 1
  fi
  if ! grep -q 'LibboxNewOpenRungWSSClientForIOS' "$header"; then
    echo "error: Apple build is missing the OpenRung iOS WSS API in $slice" >&2
    exit 1
  fi
done

mkdir -p "$script_dir/ThirdParty"
cp -R "$artifact" "$incoming_artifact"
rm -rf "$script_dir/ThirdParty/Libbox.xcframework"
mv "$incoming_artifact" "$script_dir/ThirdParty/Libbox.xcframework"
echo "Release XCFramework: $script_dir/ThirdParty/Libbox.xcframework"
