#!/usr/bin/env bash
# Verifies the installer_payload rule: the produced zip must list fs.squashfs,
# platform.tar.gz, and a boot/ directory. The on-target installer reads this
# with unzip, so we list it with unzip -l here.
set -euo pipefail

ZIP="$(pwd)/$1"

listing="$(unzip -l "$ZIP")"
echo "--- zip listing ---"
echo "$listing"
echo "-------------------"

fail=0
for entry in "fs.squashfs" "platform.tar.gz" "boot/"; do
    if ! grep -q "$entry" <<<"$listing"; then
        echo "FAIL: $entry missing from zip" >&2
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    exit 1
fi

echo "PASS: fs.squashfs, platform.tar.gz and boot/ present"
