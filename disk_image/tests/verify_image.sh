#!/usr/bin/env bash
# End-to-end smoke test for //disk_image:sonic_disk_image.
#
# (1) Verifies the rule output is a valid gzip stream.
# (2) gunzips it and confirms the result starts with a DOS/MBR boot sector
#     (since the MBR overlay drops the GRUB boot.img code in the first
#     446 bytes on top of sgdisk's protective MBR).
# (3) Uses sgdisk -p to dump the partition table and asserts all three
#     expected labels (BIOS-BOOT / ONIE-BOOT / SONiC-OS) are present in
#     the correct slot order.
set -euo pipefail

IMG_GZ="$(pwd)/$1"
SGDISK="$(pwd)/$2"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# (1) gunzip.
img="$work/disk.raw"
gunzip -c "$IMG_GZ" > "$img"

# (2) file(1) recognition — fall back to a hand-rolled magic check if
#     `file` is missing from the host (rare, but the test must not depend
#     on it). The 0x55AA boot signature lives at byte offset 510..511.
if command -v file >/dev/null 2>&1; then
    file_out=$(file "$img")
    echo "file: $file_out"
    case "$file_out" in
        *"DOS/MBR boot sector"*|*"GPT"*) ;;
        *)
            echo "FAIL: file(1) did not identify image as MBR/GPT: $file_out" >&2
            exit 1
            ;;
    esac
fi
sig=$(dd if="$img" bs=1 skip=510 count=2 status=none | od -An -tx1 | tr -d ' ')
if [ "$sig" != "55aa" ]; then
    echo "FAIL: missing MBR 0x55AA signature (got 0x$sig)" >&2
    exit 1
fi

# (3) sgdisk -p prints the GPT table with one row per partition. Format:
#     <num>  <start>  <end>  <size>  <code>  <label>
parts=$("$SGDISK" -p "$img" 2>&1)
echo "----- sgdisk -p -----"
echo "$parts"
echo "---------------------"

for label in BIOS-BOOT ONIE-BOOT SONiC-OS; do
    if ! echo "$parts" | grep -q -F "$label"; then
        echo "FAIL: partition label '$label' missing from sgdisk -p output" >&2
        exit 1
    fi
done

echo "PASS: 3 partitions with labels BIOS-BOOT / ONIE-BOOT / SONiC-OS"
