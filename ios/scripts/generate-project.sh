#!/bin/bash
# Regenerates ios/OpenRung.xcodeproj from project.yml (xcodegen is the source of truth)
# and re-runs CocoaPods so the Pods project, workspace, and [CP] build phases stay in sync.
# Run this after editing project.yml or adding/removing native source files.
set -euo pipefail

export PATH="/opt/homebrew/bin:$PATH"
export LANG="${LANG:-en_US.UTF-8}"

cd "$(dirname "$0")/.."

xcodegen generate
pod install
