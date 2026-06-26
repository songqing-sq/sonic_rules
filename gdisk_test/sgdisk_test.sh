#!/usr/bin/env bash
# End-to-end smoke test for @gdisk_src//:sgdisk.
#
# (1) Verifies `sgdisk -V` prints the expected version banner.
# (2) Creates a fresh GPT on a sparse 10 MiB image with one partition,
#     sets type code 0x8300 (Linux filesystem) and a custom partition label.
# (3) Reads the table back with `sgdisk -p` and confirms the label is present
#     (exercises both the writer and the reader, mirroring how the
#     sonic-vs.img.gz static assembly pipeline uses sgdisk).
set -euo pipefail

SGDISK="$(pwd)/$1"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# (1) -V banner.
banner="$("$SGDISK" -V 2>&1 | head -1)"
case "$banner" in
    "GPT fdisk (sgdisk) version 1.0."*) ;;
    *) echo "FAIL: unexpected sgdisk -V banner: $banner" >&2; exit 1 ;;
esac

# (2) Create + populate a fresh GPT on a 10 MiB sparse image.
img="$work/test.img"
truncate -s 10M "$img"
"$SGDISK" -o -n 1:0:0 -t 1:8300 -c 1:"TEST-LABEL" "$img" >/dev/null

# (3) Read it back and check the label round-trips.
if ! "$SGDISK" -p "$img" | grep -q "TEST-LABEL"; then
    echo "FAIL: TEST-LABEL not found in sgdisk -p output:" >&2
    "$SGDISK" -p "$img" >&2
    exit 1
fi

echo "PASS: sgdisk banner + GPT write/read round-trip verified"
