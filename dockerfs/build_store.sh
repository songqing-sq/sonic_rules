#!/usr/bin/env bash
# Sealed wrapper for the daemonless overlay2 store builder.
#
# 1. overlay2_build.py extracts each OCI layer into a temp store with parallel
#    GNU tar -xp, writes the overlay2/layerdb/imagedb metadata, and records the
#    AUFS whiteouts' store-relative paths to a temp char-list.
# 2. bsdtar packs the store into a tar (--uid 0 -> root ownership; GNU tar -xp
#    already kept setuid on the build user's own files).
# 3. overlay2_build.py --inject-into appends each whiteout as a char-dev(0,0)
#    tar member -- so the overlay2 whiteouts live INSIDE dockerfs.tar (no
#    separate manifest): the one-image install extracts them as root for free,
#    and the kvm-image build reads them back out of the tar for debugfs.
# 4. pigz compresses (parallel gzip; bsdtar's built-in zlib is single-threaded,
#    ~350s on this ~7GB store vs ~11s for pigz).
#
# No userns/root anywhere.
#
# Usage: build_store.sh PY TAR PIGZ GTAR OUT IMAGE_SPEC...
set -euo pipefail

PY="$1"; TAR="$2"; PIGZ="$3"; GTAR="$4"; OUT="$5"; shift 5

STORE="$(mktemp -d)"
CHARLIST="$(mktemp)"
TARFILE="$(mktemp --suffix=.tar)"
trap 'rm -rf "$STORE" "$CHARLIST" "$TARFILE"' EXIT

INNER='
set -euo pipefail
PY="$1"; TAR="$2"; PIGZ="$3"; GTAR="$4"; OUT="$5"; STORE="$6"; CHARLIST="$7"; TARFILE="$8"; shift 8
"$PY" --store "$STORE" --gtar "$GTAR" --char-list "$CHARLIST" "$@"
"$TAR" --create --uid 0 --gid 0 --uname root --gname root -f "$TARFILE" -C "$STORE" .
rm -rf "$STORE"
"$PY" --inject-into "$TARFILE" --char-list "$CHARLIST"
"$PIGZ" -n < "$TARFILE" > "$OUT"
'

bash -c "$INNER" _ "$PY" "$TAR" "$PIGZ" "$GTAR" "$OUT" "$STORE" "$CHARLIST" "$TARFILE" "$@"
