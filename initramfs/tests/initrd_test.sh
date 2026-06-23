#!/bin/sh
# Structural test for the REAL mkinitramfs initrd image.
#
# Args:
#   $1 = path to the initrd.img (gzip-compressed newc cpio)
#   $2 = path to a cpio lister (bsdtar or cpio)
#
# Asserts the image is a genuine Debian initramfs-tools / mkinitramfs initrd
# (not a hand-assembled cpio stub): the real /init + scripts/functions +
# conf/initramfs.conf, a shell (busybox or klibc), the SONiC union-mount boot
# script, and the boot kernel-module set (squashfs/overlay/loop + virtio).
set -eu

INITRD="$1"
LISTER="$2"

LIST=$(mktemp)
trap 'rm -f "$LIST"' EXIT

# Decompress then list the cpio (mirrors the real boot decompress path).
# bsdtar reads a cpio with `-tf -`; GNU cpio reads it with `-t`.
case "$(basename "$LISTER")" in
    *bsdtar* | *tar) zcat "$INITRD" | "$LISTER" -tf - > "$LIST" ;;
    *) zcat "$INITRD" | "$LISTER" -t > "$LIST" ;;
esac

fail=0

check() {
    # $1 = extended regex, $2 = human description
    if grep -Eq "$1" "$LIST"; then
        echo "OK: $2"
    else
        echo "FAIL: $2 (pattern: $1)" >&2
        fail=1
    fi
}

# --- Genuine initramfs-tools / mkinitramfs markers ----------------------------
check '(^|/)init$'                       "real initramfs-tools /init present"
check 'scripts/functions$'               "scripts/functions (boot helpers) present"
check 'conf/initramfs.conf$'             "conf/initramfs.conf present"
# A working shell: busybox (BUSYBOX=auto) or klibc utilities.
if grep -Eq '(^|/)bin/busybox$' "$LIST" || grep -Eq 'klibc' "$LIST"; then
    echo "OK: shell (busybox/klibc) present"
else
    echo "FAIL: no busybox/klibc shell in initrd" >&2
    fail=1
fi

# --- SONiC boot integration ---------------------------------------------------
check 'init-bottom/union-mount$'         "SONiC scripts/init-bottom/union-mount present"

# --- Boot kernel-module set ---------------------------------------------------
for m in squashfs overlay loop virtio_blk virtio_pci; do
    check "/${m}\.ko" "module ${m}.ko present"
done

if [ "$fail" -ne 0 ]; then
    echo "---- initrd contents (head) ----" >&2
    head -50 "$LIST" >&2
    exit 1
fi

echo "initrd real-mkinitramfs test PASSED"
