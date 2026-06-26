#!/usr/bin/env bash
# Structural validation of a daemonless overlay2 store (dockerfs.tar.gz).
#
# Asserts (no dockerd required):
#   * image/overlay2/repositories.json exists and names docker-database:latest
#   * an imagedb config exists whose filename == sha256sum of its content
#   * every layerdb/sha256/<chainID>/ has diff + cache-id, the matching
#     overlay2/<cache-id>/diff dir exists, and an overlay2/l/<link> symlink
#     points at it.
set -euo pipefail

STORE_TGZ="$(pwd)/$1"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
tar -xf "$STORE_TGZ" -C "$WORK"

OV2="$WORK/image/overlay2"

# 1) repositories.json mentions docker-database:latest
REPO="$OV2/repositories.json"
[ -f "$REPO" ] || { echo "FAIL: missing $REPO" >&2; exit 1; }
grep -q "docker-database:latest" "$REPO" || {
    echo "FAIL: repositories.json lacks docker-database:latest" >&2
    cat "$REPO" >&2; exit 1; }
echo "OK: repositories.json present with docker-database:latest"

# 2) imagedb config filename == sha256sum(content)
IMAGEDB="$OV2/imagedb/content/sha256"
[ -d "$IMAGEDB" ] || { echo "FAIL: missing $IMAGEDB" >&2; exit 1; }
found_config=0
for f in "$IMAGEDB"/*; do
    [ -f "$f" ] || continue
    found_config=1
    name="$(basename "$f")"
    sum="$(sha256sum "$f" | cut -d' ' -f1)"
    if [ "$name" != "$sum" ]; then
        echo "FAIL: imageID $name != sha256(config) $sum" >&2; exit 1
    fi
    echo "OK: imageID == sha256(config): $name"
done
[ "$found_config" = 1 ] || { echo "FAIL: no imagedb config" >&2; exit 1; }

# 3) every layerdb entry is internally consistent
LAYERDB="$OV2/layerdb/sha256"
[ -d "$LAYERDB" ] || { echo "FAIL: missing $LAYERDB" >&2; exit 1; }
count=0
for d in "$LAYERDB"/*/; do
    [ -d "$d" ] || continue
    count=$((count + 1))
    [ -f "$d/diff" ] || { echo "FAIL: $d missing diff" >&2; exit 1; }
    [ -f "$d/cache-id" ] || { echo "FAIL: $d missing cache-id" >&2; exit 1; }
    cid="$(cat "$d/cache-id")"
    diffdir="$WORK/overlay2/$cid/diff"
    [ -d "$diffdir" ] || { echo "FAIL: missing $diffdir" >&2; exit 1; }
    link="$(cat "$WORK/overlay2/$cid/link")"
    lsym="$WORK/overlay2/l/$link"
    [ -L "$lsym" ] || { echo "FAIL: missing symlink $lsym" >&2; exit 1; }
done
[ "$count" -gt 0 ] || { echo "FAIL: no layerdb entries" >&2; exit 1; }
echo "OK: $count layerdb entries consistent (diff/cache-id/diffdir/l-symlink)"

echo "PASS: overlay2 store is structurally valid"
