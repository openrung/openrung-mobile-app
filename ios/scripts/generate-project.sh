#!/bin/bash
# Regenerates ios/OpenRung.xcodeproj from project.yml (xcodegen is the source of truth)
# and re-runs CocoaPods so the Pods project, workspace, and [CP] build phases stay in sync.
# Run this after editing project.yml or adding/removing native source files.
set -euo pipefail

export PATH="/opt/homebrew/bin:$PATH"
export LANG="${LANG:-en_US.UTF-8}"

cd "$(dirname "$0")/.."

# The app version string is single-sourced in package.json; inject it so xcodegen bakes the
# matching MARKETING_VERSION into the project (see ../scripts/check-versions.mjs).
APP_VERSION="$(node -p "require('$(pwd)/../package.json').version")"
export APP_VERSION

xcodegen generate
pod install
