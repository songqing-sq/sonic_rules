#!/usr/bin/env bash
# Builds a squashfs image with `-comp zstd` from a fixture tree using the
# hermetic mksquashfs, then verifies: (1) the SquashFS magic ("hsqs"), and
# (2) that unsquashfs round-trips the content back.
set -euo pipefail

MKSQUASHFS="$(pwd)/$1"
UNSQUASHFS="$(pwd)/$2"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

src="$work/src"
mkdir -p "$src/sub"
echo "hello squashfs" >"$src/hello.txt"
echo "nested content" >"$src/sub/nested.txt"

img="$work/out.squashfs"
"$MKSQUASHFS" "$src" "$img" -comp zstd -b 1M -noappend

# (1) SquashFS magic: first four bytes must be "hsqs".
magic="$(head -c 4 "$img")"
if [[ "$magic" != "hsqs" ]]; then
    echo "FAIL: bad squashfs magic: got '$magic', want 'hsqs'" >&2
    exit 1
fi

# (2) Round-trip with unsquashfs.
"$UNSQUASHFS" -d "$work/extract" "$img" >/dev/null
grep -q "hello squashfs" "$work/extract/hello.txt"
grep -q "nested content" "$work/extract/sub/nested.txt"

echo "PASS: zstd squashfs created and verified"
