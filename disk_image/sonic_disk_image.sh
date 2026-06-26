#!/bin/bash
#
# Assemble a raw SONiC disk image (GPT: BIOS-BOOT + ONIE-BOOT + SONiC-OS) in a
# single action and install the GRUB BIOS boot stage, then pigz-compress to the
# rule output. Driven by sonic_rules/disk_image/disk_image.bzl
# (sonic_disk_image rule).
#
# This action ALSO assembles the SONiC-OS partition inline (in a tmpdir):
#   - The SMALL staging tree (boot_files+initrd, platform_tar, machine.conf ->
#     image-<ver>/{boot,platform} + machine.conf) is built on disk.
#   - The ~7G dockerfs.tar.gz is NOT extracted to disk. tar_reprefix.py streams
#     it (pigz -dc) re-rooted under image-<ver>/docker and merges it with the
#     staging tree into ONE tar piped straight to `mke2fs -d -`. mke2fs's
#     libarchive reader builds the ext4 inodes directly -- including the overlay2
#     whiteouts (char-dev(0,0) tar members) with no root and no debugfs mknod.
#     This drops the old "bsdtar -x store to tmpdir + mke2fs -d <dir>" round-trip
#     (~14G of redundant disk I/O).
#   - fs.squashfs (~1.3G) is NOT in the tar: debugfs writes it straight into the
#     ext4 after mke2fs, avoiding a staging copy that would be read twice.
#
# Mount-free / root-free for the partition build (mke2fs -E offset= -d
# writes ext4 directly inside the disk file at a partition offset);
# GRUB install is delegated to host grub-mkimage + grub-bios-setup
# (source-built from GRUB 2.06; boot.img checked into //grub/generated/).
#
# Usage:
#   sonic_disk_image.sh \
#     <squashfs> <boot_files> <platform_tar> <dockerfs_or_empty> \
#     <image_version> <machine> <platform> \
#     <onie_tar> <out> \
#     <disk_mb> <bios_mb> <onie_offset_mb> <onie_mb> \
#     <sonic_offset_mb> <sonic_size_mb> \
#     <bsdtar> <mke2fs> <sgdisk> <pigz> \
#     <grub_boot_img> <grub_mkimage> <grub_bios_setup> \
#     <grub_prefix> <debugfs> <initrd> <tar_reprefix> \
#     <grub_platform_img...>

set -euo pipefail

if [ "$#" -lt 26 ]; then
    echo "usage: $0 <26+ args; see header>" >&2
    exit 2
fi

# Absolutise inputs that the action passes as workspace-relative bazel-out
# paths so they resolve correctly regardless of the working directory.
SQUASHFS="$(realpath "$1")"
BOOT_FILES="$(realpath "$2")"
PLATFORM_TAR="$(realpath "$3")"
DOCKERFS="$4"
[ -n "$DOCKERFS" ] && DOCKERFS="$(realpath "$DOCKERFS")"
IMAGE_VERSION="$5"
MACHINE="$6"
PLATFORM="$7"
ONIE_TAR="$(realpath "$8")"
OUT="$(realpath -m "$9")"
DISK_MB="${10}"
BIOS_MB="${11}"
ONIE_OFFSET_MB="${12}"
ONIE_MB="${13}"
SONIC_OFFSET_MB="${14}"
SONIC_MB="${15}"
BSDTAR="$(realpath "${16}")"
MKE2FS="$(realpath "${17}")"
SGDISK="$(realpath "${18}")"
PIGZ="$(realpath "${19}")"
GRUB_BOOT_IMG="$(realpath "${20}")"
GRUB_MKIMAGE="$(realpath "${21}")"
GRUB_BIOS_SETUP="$(realpath "${22}")"
GRUB_PREFIX="${23}"
DEBUGFS="$(realpath "${24}")"
# initrd file (boot/initrd.img-<kver>), copied into image-<ver>/boot/ next to
# the boot_files tree's kernel.
INITRD="$(realpath "${25}")"
# tar_reprefix.py (py_binary): streams the dockerfs store re-rooted under
# image-<ver>/docker and merges it with the staging tree into the mke2fs stdin tar.
REPREFIX="$(realpath "${26}")"
# Remaining args (27+) are platform .img files (kernel.img, diskboot.img,
# lzma_decompress.img, boot.img) to copy into the grub-mkimage --directory.
shift 26
GRUB_PLATFORM_IMGS=("$@")

IMG="image-${IMAGE_VERSION}"

# Sanity-check the hermetic GRUB tooling.
for f in "$GRUB_BOOT_IMG" "$GRUB_MKIMAGE" "$GRUB_BIOS_SETUP"; do
    if [ ! -x "$f" ] && [ ! -r "$f" ]; then
        echo "ERROR: required GRUB tool missing: $f" >&2
        exit 1
    fi
done

# no-sandbox actions do not get the output directory pre-created.
mkdir -p "$(dirname "$OUT")"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
DISK="$STAGE/disk.raw"

# 1) Allocate an empty raw disk (sparse).
truncate -s "${DISK_MB}M" "$DISK"

# 2) Write the GPT. -n N:start:end uses "0" as "default" (next free
#    aligned sector / end of disk). -t sets the type GUID by short code;
#    -c sets the partition label (mke2fs cannot set it in -E offset mode,
#    but sgdisk records it in the GPT entry).
"$SGDISK" -o \
    -n "1:2048:+${BIOS_MB}M"  -t 1:EF02 -c 1:BIOS-BOOT \
    -n "2:0:+${ONIE_MB}M"     -t 2:8300 -c 2:ONIE-BOOT \
    -n "3:0:0"                -t 3:8300 -c 3:SONiC-OS  \
    "$DISK" >/dev/null

# 3) Stage the ext4 source trees. bsdtar transparently handles
#    .tar / .tar.gz / .tar.xz inputs.
mkdir -p "$STAGE/onie_stage"
"$BSDTAR" -xf "$ONIE_TAR" -C "$STAGE/onie_stage"

# 3-onie) Augment the ONIE-BOOT grub.cfg in place (no pack/unpack round-trip:
#   onie_iso_extract produced a Rescue-only grub.cfg; we overwrite it here with
#   one that lists SONiC-OS first (default=0) and keeps ONIE Rescue as the
#   fallback). The embedded GRUB core.img has its prefix baked in as
#   (hd0,gpt2)/onie/grub, so /onie/grub/grub.cfg on the ONIE-BOOT partition is
#   the only menu config the firmware stack reads -- SONiC's menuentry must land
#   here. SONIC_LABEL matches the sgdisk -c 3:SONiC-OS label set below.
SONIC_LABEL="SONiC-OS"
# Derive the kernel/initrd filenames from the boot inputs instead of hardcoding
# the version: vmlinuz from the boot_files tree, initrd from $INITRD. The grub
# menuentry must match exactly what gets staged into image-<ver>/boot/, so it
# tracks kernel-version (and arch) bumps automatically.
VMLINUZ_NAME="$(basename "$(ls "$BOOT_FILES"/boot/vmlinuz-* | head -1)")"
INITRD_NAME="$(basename "$INITRD")"
mkdir -p "$STAGE/onie_stage/onie/grub"
cat > "$STAGE/onie_stage/onie/grub/grub.cfg" <<EOF
# Mirror SONiC install.sh: send GRUB UI + kernel/userspace logs to both
# the VGA console and the serial port so qemu -nographic / verify
# harnesses can capture the full boot. 115200n8 matches sonic-vs / KVM
# defaults; override per-platform if needed.
serial --speed=115200 --word=8 --parity=no --stop=1
terminal_input console serial
terminal_output console serial
set timeout=5
set default=0

menuentry 'SONiC-OS' {
    search --no-floppy --label --set=root ${SONIC_LABEL}
    echo 'Loading SONiC ...'
    insmod gzio
    insmod part_gpt
    insmod ext2
    linux /${IMG}/boot/${VMLINUZ_NAME} root=LABEL=${SONIC_LABEL} rw \\
          loop=${IMG}/fs.squashfs loopfstype=squashfs \\
          console=tty0 console=ttyS0,115200n8 \\
          systemd.unified_cgroup_hierarchy=0
    initrd /${IMG}/boot/${INITRD_NAME}
}

menuentry 'ONIE: Rescue' {
    search --no-floppy --label --set=root ONIE-BOOT
    echo 'Loading ONIE ...'
    linux /onie/vmlinuz console=tty0 console=ttyS0,115200n8 boot_reason=rescue
    initrd /onie/initrd.xz
}
EOF

# 3a) Assemble the SMALL SONiC-OS staging tree inline (no intermediate Bazel
#     artifact). Layout under $SONIC_STAGE (= root of the SONiC-OS ext4):
#       image-<ver>/boot/...      (from <boot_files> tree + <initrd>)
#       image-<ver>/platform/...  (contents of <platform_tar>)
#       machine.conf              (onie_* identifiers at the partition root)
#     image-<ver>/docker/...      streamed from <dockerfs> straight into the ext4
#                                 (tar_reprefix.py | mke2fs -d -), not staged.
#     image-<ver>/fs.squashfs is written in later by debugfs, not staged here.
SONIC_STAGE="$STAGE/sonic_stage"
mkdir -p "$SONIC_STAGE/$IMG"
# boot/ from the kernel boot-files tree + the initrd file (both boot/-rooted) --
# copied straight in, no boot tar to unpack. The tree's root holds boot/, so
# `cp -RL <tree>/.` lands boot/ under image-<ver>/; the initrd goes alongside.
cp -RL "$BOOT_FILES/." "$SONIC_STAGE/$IMG/"
# Bazel tree/genrule outputs are read-only; make boot/ writable so the initrd
# can be added (and so the tmpdir cleans up).
chmod -R u+w "$SONIC_STAGE/$IMG/boot"
cp -L "$INITRD" "$SONIC_STAGE/$IMG/boot/"
mkdir -p "$SONIC_STAGE/$IMG/platform"
"$BSDTAR" -xf "$PLATFORM_TAR" -C "$SONIC_STAGE/$IMG/platform"
# docker/: NOT staged on disk. It is streamed straight into the ext4 by
# tar_reprefix.py | mke2fs -d - below (re-rooted to image-<ver>/docker -- the
# directory MUST be named "docker" = onie-image.conf DOCKERFS_DIR: the initrd
# union-mount binds /host/image-<ver>/docker -> /var/lib/docker). overlay2
# whiteouts ride the tar as char-dev(0,0) members and become char-dev inodes via
# mke2fs's libarchive reader -- no extract, no chmod, no debugfs mknod.
# machine.conf at the partition root. ONIE reads this on first boot to discover
# the platform/arch identifiers.
cat > "$SONIC_STAGE/machine.conf" <<EOF
onie_machine=${MACHINE}
onie_platform=${PLATFORM}
onie_arch=${PLATFORM%%-*}
EOF

# 4) mke2fs -E offset=<bytes> writes the ext4 filesystem directly into
#    the raw disk at the partition's byte offset. The trailing size
#    argument bounds the FS to the partition size so it does not spill
#    into the next partition. -L sets the volume label.
ONIE_OFFSET_BYTES=$((ONIE_OFFSET_MB * 1024 * 1024))

# ONIE-BOOT has no overlay2 whiteouts: build it in place at the partition
# offset (mount-free, root-free).
"$MKE2FS" -F -t ext4 -L ONIE-BOOT \
    -E "offset=$ONIE_OFFSET_BYTES" \
    -d "$STAGE/onie_stage" \
    "$DISK" "${ONIE_MB}M" >/dev/null

# SONiC-OS is built in place at the partition offset exactly like ONIE-BOOT.
# When a dockerfs store is present, the store streams (pigz -dc) re-rooted under
# image-<ver>/docker, merged with the staging tree by tar_reprefix.py into ONE
# tar piped to `mke2fs -d -`. mke2fs's libarchive reader writes every inode
# directly -- overlay2 whiteouts become char-dev(0,0) with no root and no debugfs
# mknod. With no dockerfs, fall back to populating from the staging dir.
SONIC_OFFSET_BYTES=$((SONIC_OFFSET_MB * 1024 * 1024))
if [ -n "$DOCKERFS" ]; then
    "$PIGZ" -dc "$DOCKERFS" \
        | "$REPREFIX" "$SONIC_STAGE" "$IMG/docker" \
        | "$MKE2FS" -F -t ext4 -L SONiC-OS \
            -E "offset=$SONIC_OFFSET_BYTES" \
            -d - \
            "$DISK" "${SONIC_MB}M" >/dev/null
else
    "$MKE2FS" -F -t ext4 -L SONiC-OS \
        -E "offset=$SONIC_OFFSET_BYTES" \
        -d "$SONIC_STAGE" \
        "$DISK" "${SONIC_MB}M" >/dev/null
fi

# Write fs.squashfs straight into the SONiC-OS ext4 with debugfs (no ~1.3G copy
# staged for mke2fs -d to re-read). Absolute host path + absolute ext4 path; the
# parent image-<ver>/ already exists (mke2fs created it from boot/...).
# `$DISK?offset=N` makes libext2fs operate on the partition embedded in the disk;
# writes land at the offset and leave the rest of the disk intact (verified).
# overlay2 whiteouts are no longer injected here -- mke2fs's libarchive reader
# created them as char-dev(0,0) inodes from the dockerfs tar above.
DBG_SCRIPT="$STAGE/debugfs.cmds"
printf 'write %s /%s/fs.squashfs\n' "$SQUASHFS" "$IMG" > "$DBG_SCRIPT"
"$DEBUGFS" -w -f "$DBG_SCRIPT" "$DISK?offset=$SONIC_OFFSET_BYTES" >/dev/null

# 5) Build the GRUB i386-pc core.img with the prefix pointed at
#    ONIE-BOOT's /onie/grub directory. The module list is the minimum
#    required to: read GPT (part_gpt), read ext2/3/4 (ext2 + gzio for
#    compressed inodes), search for the partition by label (search,
#    search_label), echo progress, load the SONiC kernel (linux), and
#    re-exec grub.cfg (configfile, loadenv for boot counters).
GRUB_STAGE="$STAGE/grub_stage"
mkdir -p "$GRUB_STAGE"
# *.mod come from the ONIE-BOOT staging tar (extracted from the ONIE
# recovery ISO by onie_iso_extract). They are already unpacked at
# $STAGE/onie_stage/onie/grub/i386-pc/ and match the ONIE GRUB version
# that would be used in a real grub-install during ONIE installation.
# The checked-in platform .img files (kernel.img, diskboot.img,
# lzma_decompress.img, boot.img) are copied alongside the *.mod so
# grub-mkimage can find them in one --directory.
GRUB_MODULES_DIR="$STAGE/onie_stage/onie/grub/i386-pc"
for img in "${GRUB_PLATFORM_IMGS[@]}"; do
    cp "$(realpath "$img")" "$GRUB_MODULES_DIR/"
done

cp "$GRUB_BOOT_IMG" "$GRUB_STAGE/boot.img"
"$GRUB_MKIMAGE" \
    --format=i386-pc \
    --directory="$GRUB_MODULES_DIR" \
    --prefix="$GRUB_PREFIX" \
    --output="$GRUB_STAGE/core.img" \
    biosdisk part_gpt ext2 normal search search_label echo linux configfile loadenv

# 6) grub-bios-setup installs boot.img + core.img:
#    - writes boot.img (446 bytes) into the MBR boot code area
#    - writes core.img into the BIOS Boot Partition (GPT type EF02)
#    - patches boot.img's kernel_sector field (offset 0x5c) with the
#      actual LBA grub-bios-setup chose for core.img
#    - patches core.img's diskboot blocklist
#
#    grub-bios-setup is patched (//grub:grub-bios-setup-no-mountinfo.patch)
#    so that when its --directory has no real backing block device
#    (overlayfs/tmpfs under the Bazel sandbox) it falls back to the
#    destination disk image as the root device instead of aborting on
#    /proc/self/mountinfo. No CWD `overlay` symlink workaround is needed.
"$GRUB_BIOS_SETUP" \
    --directory="$GRUB_STAGE" \
    --skip-fs-probe \
    --device-map=/dev/null \
    "$DISK" >/dev/null

# 7) Compress to the rule output. pigz -c streams the gzipped bytes to
#    stdout so we never materialise a second copy of the raw image.
"$PIGZ" -c "$DISK" > "$OUT"
