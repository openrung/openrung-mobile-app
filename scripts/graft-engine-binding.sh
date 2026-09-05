#!/usr/bin/env bash
# Grafts the ADR-003 B1 engine binding into a sing-box libbox source tree.
# Shared by android/build-libbox-release.sh and ios/build-libbox-release.sh so
# the Android AAR and the Apple xcframework can never ship different engine
# surfaces: the file list, the build-constraint guard, and the app-version
# generator live here once.
#
# usage: graft-engine-binding.sh <binding_source> <libbox_dest> <package_json>
#   binding_source  android/punchbridge checkout holding engine_*.go
#   libbox_dest     <sing-box>/experimental/libbox inside the release work dir
#   package_json    the app's package.json; its "version" becomes the engine's
#                   process-wide app version
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: $0 <binding_source> <libbox_dest> <package_json>" >&2
  exit 2
fi
binding_source="$1"
libbox_dest="$2"
package_json="$3"

# Engine lifecycle and in-process runtime share the existing libbox package.
for engine_source in engine_binding.go engine_runtime.go; do
  cp "$binding_source/$engine_source" "$libbox_dest/openrung_$engine_source"
done
# The build constraint excludes these files from the standalone binding module.
# The graft provides PlatformInterface/CommandServer and always includes them:
# strip exactly the constraint line and the blank line after it, nothing else.
for constrained in engine_libbox.go engine_libbox_test.go; do
  if [ "$(head -n 1 "$binding_source/$constrained")" != '//go:build openrung_libbox' ] ||
    [ -n "$(sed -n 2p "$binding_source/$constrained")" ]; then
    echo "error: $constrained graft constraint changed" >&2
    exit 1
  fi
  # Graft-only tests verify the concrete service adapter on the build host.
  tail -n +3 "$binding_source/$constrained" > "$libbox_dest/openrung_$constrained"
done

# Set the engine's process-wide app version during package initialization,
# before any goroutine can read it; never mutate it from a live constructor.
python3 - "$package_json" "$libbox_dest/openrung_engine_version.go" <<'ENGINE_VERSION'
import json
from pathlib import Path
import sys
version = json.loads(Path(sys.argv[1]).read_text())["version"]
Path(sys.argv[2]).write_text(
    'package libbox\nimport "github.com/openrung/openrung/connectcore/client"\n'
    'func init() { client.SetAppVersion(' + json.dumps(version) + ') }\n'
)
ENGINE_VERSION
