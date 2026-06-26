#!/usr/bin/env bash
# End-to-end smoke test for @e2fsprogs_src//:mke2fs.
#
# (1) Verifies `mke2fs -V` prints the expected version banner.
# (2) Creates a small ext4 image and checks the ext4 magic (0xEF53) at the
#     well-known superblock offset (0x438..0x439 == byte 0x438-0x439 in LE).
# (3) Exercises the -E offset= and -d <dir> options (used by the sonic-vs.img
#     static assembly pipeline).
set -euo pipefail

MKE2FS="$(pwd)/$1"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# (1) -V banner.
banner="$("$MKE2FS" -V 2>&1 | head -1)"
case "$banner" in
    "mke2fs 1.47.0"*) ;;
    *) echo "FAIL: unexpected mke2fs -V banner: $banner" >&2; exit 1 ;;
esac

# (2) Create a 10 MiB ext4 image, verify the ext4 superblock magic at byte
#     1080 (0x438). Magic is 0x53EF little-endian.
img="$work/test.img"
truncate -s 10M "$img"
"$MKE2FS" -t ext4 -F "$img" >/dev/null
magic="$(dd if="$img" bs=1 skip=1080 count=2 status=none | od -An -tx1 | tr -d ' ')"
if [ "$magic" != "53ef" ]; then
    echo "FAIL: bad ext4 superblock magic: got $magic, want 53ef" >&2
    exit 1
fi

# (3) -E offset= + -d <empty dir>. Mirrors how the sonic-vs.img pipeline
#     drops a populated ext4 inside a partition at a fixed offset.
mkdir -p "$work/seed"
echo "from bazel mke2fs" > "$work/seed/hello.txt"
big="$work/big.img"
"$MKE2FS" -E offset=1048576 -t ext4 -d "$work/seed" -F "$big" 5M >/dev/null
# Verify magic landed at offset 1048576 + 1080 = 1049656 (still 0x53EF).
magic="$(dd if="$big" bs=1 skip=1049656 count=2 status=none | od -An -tx1 | tr -d ' ')"
if [ "$magic" != "53ef" ]; then
    echo "FAIL: bad ext4 magic after -E offset: got $magic, want 53ef" >&2
    exit 1
fi

echo "PASS: mke2fs banner + ext4 magic + -E offset/-d options verified"
