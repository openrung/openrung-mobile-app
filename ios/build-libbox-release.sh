#!/usr/bin/env bash
# Builds ios/ThirdParty/Libbox.xcframework from the exact sing-box revision in
# ../SINGBOX_VERSION and grafts OpenRung's broker, punch, and WSS bindings into
# libbox's existing gomobile package. This deliberately produces one
# XCFramework and one Go runtime: do not ship any binding as a second
# gomobile framework.
#
# The transports resolve from the exact brokerapi, punchcore, and wsscore module
# versions in android/punchbridge/go.mod. BROKERAPI_SRC, PUNCHCORE_SRC, and
# WSSCORE_SRC are absolute local-development overrides only; release artifacts
# must use the pinned tags.
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

punchcore_version="$(go mod edit -json "$binding_source/go.mod" | python3 -c '
import json, sys
data = json.load(sys.stdin)
for require in data.get("Require") or []:
    if require["Path"] == "github.com/openrung/openrung/punchcore":
        print(require["Version"])
        break
')"
if [ -z "$punchcore_version" ]; then
  echo "error: $binding_source/go.mod has no punchcore module pin" >&2
  exit 1
fi

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

brokerapi_version="$(go mod edit -json "$binding_source/go.mod" | python3 -c '
import json, sys
data = json.load(sys.stdin)
for require in data.get("Require") or []:
    if require["Path"] == "github.com/openrung/openrung/brokerapi":
        print(require["Version"])
        break
')"
if [ -z "$brokerapi_version" ]; then
  echo "error: $binding_source/go.mod has no brokerapi module pin" >&2
  exit 1
fi

dev_workspace=""
if [ -n "${PUNCHCORE_SRC:-}" ] || [ -n "${WSSCORE_SRC:-}" ] || [ -n "${BROKERAPI_SRC:-}" ]; then
  if [ -n "${PUNCHCORE_SRC:-}" ]; then
    PUNCHCORE_SRC="$(cd "$PUNCHCORE_SRC" && pwd)"
  fi
  if [ -n "${WSSCORE_SRC:-}" ]; then
    WSSCORE_SRC="$(cd "$WSSCORE_SRC" && pwd)"
  fi
  if [ -n "${BROKERAPI_SRC:-}" ]; then
    BROKERAPI_SRC="$(cd "$BROKERAPI_SRC" && pwd)"
  fi
  dev_workspace="$work_dir/openrung-core-dev.work"
  {
    echo "go 1.25.0"
    echo
    echo "use $binding_source"
    if [ -n "${PUNCHCORE_SRC:-}" ]; then
      echo
      echo "replace github.com/openrung/openrung/punchcore => $PUNCHCORE_SRC"
    fi
    if [ -n "${WSSCORE_SRC:-}" ]; then
      echo
      echo "replace github.com/openrung/openrung/wsscore => $WSSCORE_SRC"
    fi
    if [ -n "${BROKERAPI_SRC:-}" ]; then
      echo
      echo "replace github.com/openrung/openrung/brokerapi => $BROKERAPI_SRC"
    fi
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

echo "Building Libbox.xcframework from sing-box $sing_box_version with brokerapi $brokerapi_version, punchcore $punchcore_version, and wsscore $wsscore_version"

module_cache="${GOMODCACHE:-$(go env GOMODCACHE)}"
module_source="$module_cache/github.com/sagernet/sing-box@$sing_box_version"
GOMODCACHE="$module_cache" GOWORK=off go mod download \
  "github.com/sagernet/sing-box@$sing_box_version"
cp -R "$module_source" "$work_dir/source"
chmod -R u+w "$work_dir/source"

# --- OpenRung app-size trim -------------------------------------------------
# Drop sing-box features OpenRung never uses (Tailscale, WireGuard, naiveproxy)
# from the libbox build so their Go trees are not statically linked into the
# shipped framework. OpenRung emits only vless/direct/block outbounds (see
# Shared/SingBoxConfiguration.swift), and each dropped feature has a
# //go:build !<tag> stub in sing-box include/, so the build still compiles and
# the protocol just reports "not included" at runtime. This patches ONLY the tag
# literals in sing-box's own build helper, leaving every other flag it sets
# (-trimpath, -ldflags "-s -w ... constant.Version=…", -libname, -iosversion)
# byte-for-byte identical. Assert-then-replace: if a SINGBOX_VERSION bump
# reshuffles these exact tag literals the build fails here, forcing the tag set
# to be re-reviewed rather than silently reverting. Keeps with_gvisor and
# with_quic for now (see RELEASE.md §2 / the size-trim plan).
python3 - "$work_dir/source/cmd/internal/build_libbox/main.go" <<'PATCH_TAGS'
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as handle:
    lines = handle.readlines()

patched_shared = False
removed_tailscale = False
out = []
for line in lines:
    stripped = line.strip()
    if stripped.startswith('sharedTags = append(sharedTags, "with_gvisor"'):
        if '"with_wireguard"' not in stripped or '"with_naive_outbound"' not in stripped:
            sys.exit(
                "error: build_libbox sharedTags line changed for this "
                "SINGBOX_VERSION; re-review OpenRung's libbox tag trim.\nsaw: "
                + stripped
            )
        line = line.replace('"with_wireguard", ', "").replace(
            '"with_naive_outbound", ', ""
        )
        patched_shared = True
    elif stripped.startswith('sharedTags = append(sharedTags, "with_tailscale"'):
        removed_tailscale = True
        continue  # drop the whole Tailscale append line
    out.append(line)

if not patched_shared or not removed_tailscale:
    sys.exit(
        "error: build_libbox tag lines not found for this SINGBOX_VERSION "
        "(shared=%s tailscale=%s); re-review OpenRung's libbox tag trim."
        % (patched_shared, removed_tailscale)
    )

with open(path, "w", encoding="utf-8") as handle:
    handle.writelines(out)

print(
    "openrung: trimmed libbox build tags "
    "(dropped with_tailscale, with_wireguard, with_naive_outbound)"
)
PATCH_TAGS
# ---------------------------------------------------------------------------

# --- OpenRung app-size trim (part 2): unlink the Tailscale closure -----------
# The tag trim above is not enough to drop tailscale.com from the binary:
# libbox's native_shell_session.go is gated only by OS (linux||android||darwin
# ||ios) and imports protocol/tailscale/tailssh, whose files build under
# with_gvisor — NOT with_tailscale. Keeping with_gvisor therefore re-links the
# entire Tailscale module (magicsock, DERP, gliderssh, embedded wireguard-go),
# measured ~12 MB per binary. OpenRung never exposes NativeShellSession (no
# Kotlin/Swift callers), and sing-box already ships a stub
# (native_shell_session_stub.go) whose methods report "not supported". Swap the
# two files' build tags so the stub always compiles and the tailssh importer
# never does — the datapath tags (with_gvisor, with_quic) stay untouched.
# Assert-then-replace, same tripwire contract as the tag patch above.
python3 - "$work_dir/source/experimental/libbox" <<'PATCH_SHELL_SESSION'
import os
import sys

root = sys.argv[1]
swaps = [
    (
        "native_shell_session.go",
        "//go:build linux || android || darwin || ios",
        "//go:build openrung_never",
    ),
    (
        "native_shell_session_stub.go",
        "//go:build !linux && !android && !darwin && !ios",
        "//go:build !openrung_never",
    ),
]
for name, old, new in swaps:
    path = os.path.join(root, name)
    with open(path, "r", encoding="utf-8") as handle:
        text = handle.read()
    if old + "\n" not in text:
        sys.exit(
            "error: %s build tag changed for this SINGBOX_VERSION; re-review "
            "OpenRung's Tailscale shell-session stub swap.\nexpected: %s"
            % (name, old)
        )
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text.replace(old + "\n", new + "\n", 1))

print(
    "openrung: stubbed libbox native shell session "
    "(unlinks tailscale.com/tailssh from the with_gvisor build)"
)
PATCH_SHELL_SESSION
# ---------------------------------------------------------------------------

# The gomobile-generated Objective-C APIs, native transports, and sing-box
# engine must share libbox's Go runtime. A standalone punch framework would
# duplicate go.Seq/go.Universe and the native Go runtime. Only the thin bindings
# and sagernet-QUIC session layer are copied; broker policy, punch protocol,
# ECH/TLS, WebSocket, yamux, and transport bounds remain in the tagged modules.
cp "$binding_source/binding.go" \
  "$work_dir/source/experimental/libbox/openrung_punch.go"
cp "$binding_source/wss_binding.go" \
  "$work_dir/source/experimental/libbox/openrung_wss.go"
cp "$binding_source/broker_binding.go" \
  "$work_dir/source/experimental/libbox/openrung_broker.go"
mkdir -p "$work_dir/source/experimental/libbox/internal/openrungpunch"
for source_file in "$binding_source/internal/openrungpunch/"*.go; do
  case "$source_file" in
    *_test.go) continue ;;
  esac
  cp "$source_file" "$work_dir/source/experimental/libbox/internal/openrungpunch/"
done

(
  cd "$work_dir/source"
  go_mod_edits=(
    -require "github.com/openrung/openrung/brokerapi@$brokerapi_version"
    -require "github.com/openrung/openrung/punchcore@$punchcore_version"
    -require "github.com/openrung/openrung/wsscore@$wsscore_version"
  )
  if [ -n "${BROKERAPI_SRC:-}" ]; then
    go_mod_edits+=(
      -replace "github.com/openrung/openrung/brokerapi=$BROKERAPI_SRC"
    )
  fi
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
    if [ -n "${BROKERAPI_SRC:-}" ]; then
      echo "BROKERAPI_SRC: $BROKERAPI_SRC" >&2
    fi
    if [ -n "${PUNCHCORE_SRC:-}" ]; then
      echo "PUNCHCORE_SRC: $PUNCHCORE_SRC" >&2
    fi
    if [ -n "${WSSCORE_SRC:-}" ]; then
      echo "WSSCORE_SRC: $WSSCORE_SRC" >&2
    fi
    echo "This is for development only. Release XCFrameworks must" >&2
    echo "resolve all versions pinned in android/punchbridge/go.mod." >&2
    echo "==============================================================" >&2
  fi

  GOWORK=off go mod edit "${go_mod_edits[@]}"
  GOFLAGS=-mod=mod GOMODCACHE="$module_cache" GOWORK=off \
    go get \
      "github.com/openrung/openrung/brokerapi@$brokerapi_version" \
      "github.com/openrung/openrung/punchcore@$punchcore_version" \
      "github.com/openrung/openrung/wsscore@$wsscore_version"
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
  if ! grep -Fq 'LibboxNewOpenRungWSSClientForIOS' "$header"; then
    echo "error: Apple build is missing the OpenRung iOS WSS API in $slice" >&2
    exit 1
  fi
  if ! grep -Fq 'LibboxNewOpenRungPunchClientForIOS(NSString* _Nullable baseURL, NSString* _Nullable relayID, BOOL insecureTLS, NSString* _Nullable certSHA256, id<LibboxOpenRungPunchListener> _Nullable listener);' "$header"; then
    echo "error: Apple build is missing the nil-protector OpenRung iOS punch constructor in $slice" >&2
    exit 1
  fi
  for punch_symbol in \
    '@protocol LibboxOpenRungPunchListener <NSObject>' \
    '@interface LibboxOpenRungPunchClient : NSObject' \
    '@interface LibboxOpenRungPunchResult : NSObject' \
    ')close;' \
    ')establish;' \
    ')bridgeHost;' \
    ')bridgePort;' \
    ')errorText;' \
    ')natClass;' \
    ')peerIP;' \
    ')rttMillis;' \
    ')reason;' \
    ')sessionID;' \
    ')succeeded;'; do
    if ! grep -Fq "$punch_symbol" "$header"; then
      echo "error: Apple build is missing generated punch symbol in $slice: $punch_symbol" >&2
      exit 1
    fi
  done
  if ! grep -Fq 'LibboxNewOpenRungBrokerOperationForIOS' "$header"; then
    echo "error: Apple build is missing the OpenRung iOS broker constructor in $slice" >&2
    exit 1
  fi
  if ! grep -Fq 'LibboxNewOpenRungBrokerOperationForReactNative' "$header"; then
    echo "error: Apple build is missing the OpenRung React Native broker constructor in $slice" >&2
    exit 1
  fi
  if ! grep -Fq 'LibboxOpenRungBrokerRelayResult' "$header"; then
    echo "error: Apple build is missing the OpenRung broker relay result in $slice" >&2
    exit 1
  fi
  for broker_symbol in \
    'sendTelemetryBatchJSON:' \
    'runSpeedTest:' \
    'fetchManifestCandidate:' \
    'requestWSSTicket:' \
    'LibboxOpenRungBrokerSpeedTestResult' \
    'LibboxOpenRungBrokerManifestResult' \
    'LibboxOpenRungBrokerWSSTicketResult' \
    ')bytes;' \
    ')ttfbMillis;' \
    ')downloadDurationMillis;' \
    ')totalDurationMillis;' \
    ')mbps;' \
    ')bodyJSON;' \
    ')sourceURL;' \
    ')ticket;' \
    ')url;' \
    ')expiresAtMillis;' \
    ')errorKind;' \
    ')httpStatus;' \
    ')retryAfterMillis;'; do
    if ! grep -Fq "$broker_symbol" "$header"; then
      echo "error: Apple build is missing generated broker symbol in $slice: $broker_symbol" >&2
      exit 1
    fi
  done
done

# The app and extension are separate executables, so project.yml must give the
# OpenRung host its own resolver linkage. A normal host build can otherwise pass
# until a native call site first pulls Libbox's static Go archive into the link.
python3 - "$script_dir/project.yml" <<'CHECK_HOST_LINKAGE'
from pathlib import Path
import re
import sys

project = Path(sys.argv[1]).read_text(encoding="utf-8")
match = re.search(
    r"(?ms)^  OpenRung:\n(?P<body>.*?)(?=^  [A-Za-z0-9_]+:\n|\Z)",
    project,
)
if match is None:
    sys.exit("error: ios/project.yml has no OpenRung target")

target = match.group("body")
for dependency in (
    "- framework: ThirdParty/Libbox.xcframework",
    "- sdk: libresolv.tbd",
):
    if dependency not in target:
        sys.exit("error: the OpenRung target must link " + dependency[2:])
CHECK_HOST_LINKAGE

# Exercise native constructors in both generated slices. This deliberately
# links the static archive (rather than only checking its headers), surfacing
# unresolved resolver symbols before a later native call-site migration.
link_smoke_source="$script_dir/scripts/libbox-broker-link-smoke.m"
link_smoke() {
  local sdk="$1"
  local arch="$2"
  local deployment_flag="$3"
  local slice="$4"
  local module_cache="$work_dir/clang-modules-$sdk"

  xcrun --sdk "$sdk" clang \
    -arch "$arch" \
    "$deployment_flag" \
    -fobjc-arc \
    -fmodules \
    -fmodules-cache-path="$module_cache" \
    -F "$artifact/$slice" \
    -framework Libbox \
    -framework Foundation \
    -framework Network \
    -lresolv \
    "$link_smoke_source" \
    -o "$work_dir/libbox-broker-link-smoke-$sdk"
}

link_smoke iphoneos arm64 -miphoneos-version-min=16.0 ios-arm64
link_smoke iphonesimulator arm64 -mios-simulator-version-min=16.0 ios-arm64_x86_64-simulator

mkdir -p "$script_dir/ThirdParty"
cp -R "$artifact" "$incoming_artifact"
rm -rf "$script_dir/ThirdParty/Libbox.xcframework"
mv "$incoming_artifact" "$script_dir/ThirdParty/Libbox.xcframework"
echo "Release XCFramework: $script_dir/ThirdParty/Libbox.xcframework"
