#!/bin/sh
# Build a REAL Debian-mkinitramfs initrd from a staged mini-rootfs.
#
# This runs the unmodified Debian `mkinitramfs` against a faithful mini-rootfs
# assembled entirely from declared Bazel inputs (NO host /). Because mkinitramfs
# has no `--root`, we pivot into the staged tree with
# `unshare --map-root-user --mount` + `chroot` and run mkinitramfs there. As the
# userns-mapped root (uid 0) mkinitramfs records cpio entries directly; the boot
# /dev nodes are created at runtime by the kernel devtmpfs mount in
# initramfs-tools' /init, so no mknod (hence no fakeroot) is needed at build time.
#
# Args (all positional):
#   $1 TAR          - sealed bsdtar, used to unpack the input tars
#   $2 MINIROOTFS   - the assembled mini-rootfs tar (userspace + initramfs-tools
#                     + SONiC /etc/initramfs-tools config/hooks/scripts)
#   $3 MODULES_TREE - directory whose contents are lib/modules/<kver>/
#   $4 KCONFIG      - the kernel /boot/config-<kver> (mkinitramfs checks it for
#                     CONFIG_RD_<compressor> support)
#   $5 KVER         - kernel release, e.g. 6.1.0-29-2-amd64
#   $6 OUT          - output initrd path
set -eu

TAR="$1"
MINIROOTFS="$2"
MODULES_TREE="$3"
KCONFIG="$4"
KVER="$5"
OUT="$6"

TAR=$(readlink -f "$TAR")
MINIROOTFS=$(readlink -f "$MINIROOTFS")
MODULES_TREE=$(readlink -f "$MODULES_TREE")
KCONFIG=$(readlink -f "$KCONFIG")
OUT_ABS=$(readlink -f "$(dirname "$OUT")")/$(basename "$OUT")

STAGE=$(mktemp -d)
cleanup() {
    # Copied trees inherit Bazel's read-only modes; restore write before rm.
    chmod -R u+w "$STAGE" 2>/dev/null || true
    rm -rf "$STAGE" 2>/dev/null || true
}
trap cleanup EXIT

# 1. Unpack the assembled mini-rootfs (already merged-usr, with the SONiC
#    /etc/initramfs-tools overlay and the loopback-patched initramfs-tools-core).
"$TAR" -xf "$MINIROOTFS" -C "$STAGE"
chmod -R u+w "$STAGE"

# 2. Inject the kernel module tree (/lib is a merged-usr symlink to usr/lib).
mkdir -p "$STAGE/lib/modules/$KVER" "$STAGE/boot"
cp -RL "$MODULES_TREE/." "$STAGE/lib/modules/$KVER/"
cp "$KCONFIG" "$STAGE/boot/config-$KVER"
chmod -R u+w "$STAGE/usr/lib/modules" 2>/dev/null || true
chmod -R u+w "$STAGE/lib/modules" 2>/dev/null || true

# 3. Pivot into the stage and run mkinitramfs. depmod (staged kmod) builds the
#    modules.dep mkinitramfs needs; SOURCE_DATE_EPOCH makes gzip -n reproducible.
unshare --map-root-user --mount /bin/sh -e -c '
    STAGE="$1"; KVER="$2"
    chroot "$STAGE" /bin/sh -e -c "
        export PATH=/usr/bin:/usr/sbin:/sbin:/bin
        depmod $KVER
        SOURCE_DATE_EPOCH=0 mkinitramfs -d /etc/initramfs-tools -o /initrd.img $KVER
    "
' _ "$STAGE" "$KVER"

cp "$STAGE/initrd.img" "$OUT_ABS"
