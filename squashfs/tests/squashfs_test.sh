#!/usr/bin/env bash
# Verifies the mksquashfs rule: the image must CONTAIN etc/os-release and must
# NOT contain the excluded boot/ directory. Lists contents with the hermetic
# unsquashfs.
set -euo pipefail

IMG="$(pwd)/$1"
UNSQUASHFS="$(pwd)/$2"

listing="$("$UNSQUASHFS" -l "$IMG")"
echo "--- squashfs listing ---"
echo "$listing"
echo "------------------------"

if ! grep -q "etc/os-release" <<<"$listing"; then
    echo "FAIL: etc/os-release should be present in the image" >&2
    exit 1
fi

if grep -q "/boot" <<<"$listing"; then
    echo "FAIL: boot/ should have been excluded from the image" >&2
    exit 1
fi

echo "PASS: etc/os-release present and boot/ excluded"
