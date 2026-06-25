#!/usr/bin/env bash
# Verifies the sonic_rootfs stub: the produced tar must CONTAIN ./etc/os-release
# (injected when no layer provides one).
set -euo pipefail

TAR="$(pwd)/$1"

listing="$(tar -tf "$TAR")"
echo "--- rootfs tar listing ---"
echo "$listing"
echo "--------------------------"

if ! grep -qE '(^|/)etc/os-release$' <<<"$listing"; then
    echo "FAIL: etc/os-release should be present in the rootfs tar" >&2
    exit 1
fi

echo "PASS: etc/os-release present in rootfs tar"
