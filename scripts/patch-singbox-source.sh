#!/usr/bin/env bash
# Applies OpenRung's sing-box source patches to a pristine sing-box tree at the
# SINGBOX_VERSION commit. Shared by android/build-libbox-release.sh and
# ios/build-libbox-release.sh so the Android AAR and the Apple xcframework are
# built from the same modified source.
#
# Patches live in scripts/singbox-patches/*.patch and apply in name order.
# Every hunk must apply exactly (no fuzz, no already-applied hunks): a
# SINGBOX_VERSION bump that moves the patched code fails the build here, so the
# patch is rebased deliberately instead of being silently dropped.
#
# usage: patch-singbox-source.sh <sing_box_source>
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <sing_box_source>" >&2
  exit 2
fi
source_dir="$1"
patch_dir="$(cd "$(dirname "$0")" && pwd)/singbox-patches"

shopt -s nullglob
patches=("$patch_dir"/*.patch)
if [ "${#patches[@]}" -eq 0 ]; then
  echo "error: no sing-box patches found in $patch_dir" >&2
  exit 1
fi

for patch_file in "${patches[@]}"; do
  patch_args=(-d "$source_dir" -p1 --forward --batch --fuzz=0 --silent)
  if ! patch "${patch_args[@]}" --dry-run < "$patch_file"; then
    echo "error: $(basename "$patch_file") does not apply to this SINGBOX_VERSION; rebase it." >&2
    exit 1
  fi
  patch "${patch_args[@]}" < "$patch_file"
  echo "openrung: applied sing-box patch $(basename "$patch_file")"
done
