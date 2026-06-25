#!/usr/bin/env bash
# Replicates sharch_body.sh's own self-verification against the produced .bin:
# reads payload_image_size + payload_sha1 from the header, recomputes the sha1
# of the first N bytes after the exit_marker line, asserts equality, then untars
# that slice and checks installer/install.sh and installer/fs.zip are present.
set -euo pipefail

BIN="$(pwd)/$1"

header="$(sed -e '/^exit_marker$/q' "$BIN")"
size="$(printf '%s\n' "$header" | grep -m1 '^payload_image_size=' | cut -d= -f2)"
sha1_expected="$(printf '%s\n' "$header" | grep -m1 '^payload_sha1=' | cut -d= -f2)"

sha1_actual="$(sed -e '1,/^exit_marker$/d' "$BIN" | head -c "$size" | sha1sum | awk '{print $1}')"

echo "payload_image_size=$size"
echo "expected_sha1=$sha1_expected"
echo "actual_sha1=$sha1_actual"

if [ "$sha1_actual" != "$sha1_expected" ]; then
    echo "FAIL: sha1 mismatch" >&2
    exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
sed -e '1,/^exit_marker$/d' "$BIN" | head -c "$size" | tar -C "$work" -xf -

fail=0
for entry in "installer/install.sh" "installer/fs.zip"; do
    if [ ! -f "$work/$entry" ]; then
        echo "FAIL: $entry missing from extracted payload" >&2
        fail=1
    fi
done
[ "$fail" -eq 0 ] || exit 1

echo "PASS: sha1 match and installer/install.sh + installer/fs.zip present"
