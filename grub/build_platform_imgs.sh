#!/bin/bash
#
# Build GRUB 2.06 i386-pc platform images from source.
#
# Produces four images used by grub-mkimage and grub-bios-setup:
#   boot.img           512 B  raw binary  (MBR boot sector)
#   diskboot.img       512 B  raw binary  (first sector of core.img)
#   lzma_decompress.img ~2.8K raw binary  (LZMA decompressor stub)
#   kernel.img         ~31K   stripped ELF (GRUB kernel)
#
# Usage:
#   build_platform_imgs.sh <grub_src_root> <config_dir> \
#       <boot_img_out> <diskboot_img_out> <lzma_img_out> <kernel_img_out>
#
# Arguments:
#   grub_src_root   Root of the extracted GRUB 2.06 source tree.
#   config_dir      Directory containing config.h and symlist.c.
#   boot_img_out    Output path for boot.img.
#   diskboot_img_out Output path for diskboot.img.
#   lzma_img_out    Output path for lzma_decompress.img.
#   kernel_img_out  Output path for kernel.img.

set -euo pipefail

if [ "$#" -ne 6 ]; then
    echo "usage: $0 <grub_src> <config_dir> <boot.img> <diskboot.img> <lzma.img> <kernel.img>" >&2
    exit 2
fi

SRC="$(cd "$1" && pwd)"     # @grub_src root (absolute)
CFG="$(cd "$2" && pwd)"     # directory with config.h, symlist.c (absolute)
BOOT_OUT="$3"
DISKBOOT_OUT="$4"
LZMA_OUT="$5"
KERNEL_OUT="$6"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

GCC_ISYSTEM=$(gcc -m32 -print-file-name=include)

# ---------------------------------------------------------------------------
# Create include/grub/machine -> include/grub/i386/pc symlink so that
# #include <grub/machine/boot.h> resolves to include/grub/i386/pc/boot.h.
# We do this in a staging overlay to avoid modifying the source tree.
# ---------------------------------------------------------------------------
mkdir -p "$T/inc/grub"
ln -s "$SRC/include/grub/i386/pc" "$T/inc/grub/machine"
ln -s "$SRC/include/grub/i386"    "$T/inc/grub/cpu"

# Common -I flags for both assembly and C targets.
INCS=(
    -I"$CFG"                    # config.h
    -I"$T/inc"                  # grub/machine -> grub/i386/pc
    -I"$SRC/include"            # grub/*.h
    -I"$SRC"                    # top-level (multiboot.h etc.)
    -I"$SRC/grub-core"          # grub-core internal headers
    -I"$SRC/grub-core/lib/libgcrypt-grub/src"
)

# ============================= boot.img ====================================
# Source: boot/i386/pc/boot.S (pure assembly, 512 B MBR sector)
# ---------------------------------------------------------------------------
gcc -m32 -DHAVE_CONFIG_H -DASM_FILE=1 \
    -DGRUB_MACHINE_PCBIOS=1 -DGRUB_MACHINE=I386_PC \
    -nostdinc -isystem "$GCC_ISYSTEM" \
    "${INCS[@]}" \
    -c "$SRC/grub-core/boot/i386/pc/boot.S" -o "$T/boot.o"

gcc -m32 -nostdlib -Wl,-N -Wl,-S -Wl,--build-id=none \
    -Wl,-melf_i386 -no-pie -Wl,-Ttext,0x7C00 \
    -o "$T/boot.exec" "$T/boot.o"

objcopy -O binary --strip-unneeded \
    -R .note -R .comment -R .note.gnu.build-id \
    -R .MIPS.abiflags -R .reginfo -R .rel.dyn \
    -R .note.gnu.gold-version -R .note.gnu.property -R .ARM.exidx \
    "$T/boot.exec" "$BOOT_OUT"

# ============================= diskboot.img ================================
# Source: boot/i386/pc/diskboot.S (pure assembly, 512 B)
# ---------------------------------------------------------------------------
gcc -m32 -DHAVE_CONFIG_H -DASM_FILE=1 \
    -DGRUB_MACHINE_PCBIOS=1 -DGRUB_MACHINE=I386_PC \
    -nostdinc -isystem "$GCC_ISYSTEM" \
    "${INCS[@]}" \
    -c "$SRC/grub-core/boot/i386/pc/diskboot.S" -o "$T/diskboot.o"

gcc -m32 -nostdlib -Wl,-N -Wl,-S -Wl,--build-id=none \
    -Wl,-melf_i386 -no-pie -Wl,-Ttext,0x8000 \
    -o "$T/diskboot.exec" "$T/diskboot.o"

objcopy -O binary --strip-unneeded \
    -R .note -R .comment -R .note.gnu.build-id \
    -R .MIPS.abiflags -R .reginfo -R .rel.dyn \
    -R .note.gnu.gold-version -R .note.gnu.property -R .ARM.exidx \
    "$T/diskboot.exec" "$DISKBOOT_OUT"

# ========================= lzma_decompress.img =============================
# Source: boot/i386/pc/startup_raw.S
#   #includes: kern/i386/realmode.S, boot/i386/pc/lzma_decode.S, rs_decoder.h
# rs_decoder.h is generated from lib/reed_solomon.c compiled to assembly.
# ---------------------------------------------------------------------------

# Step 1: generate rs_decoder.h (compile reed_solomon.c to assembly output)
gcc -m32 -DHAVE_CONFIG_H -DSTANDALONE \
    -DGRUB_MACHINE_PCBIOS=1 -DGRUB_MACHINE=I386_PC \
    -nostdinc -isystem "$GCC_ISYSTEM" \
    "${INCS[@]}" \
    -Os -mregparm=3 -ffreestanding -g0 \
    -S "$SRC/grub-core/lib/reed_solomon.c" -o "$T/rs_decoder.h"

# Step 2: assemble startup_raw.S (uses -I to find rs_decoder.h, realmode.S,
# and lzma_decode.S via relative and angle-bracket includes)
gcc -m32 -DHAVE_CONFIG_H -DASM_FILE=1 \
    -DGRUB_MACHINE_PCBIOS=1 -DGRUB_MACHINE=I386_PC \
    -nostdinc -isystem "$GCC_ISYSTEM" \
    "${INCS[@]}" \
    -I"$T" \
    -c "$SRC/grub-core/boot/i386/pc/startup_raw.S" -o "$T/startup_raw.o"

gcc -m32 -nostdlib -Wl,-N -Wl,-S -Wl,--build-id=none \
    -Wl,-melf_i386 -no-pie -Wl,-Ttext,0x8200 \
    -o "$T/lzma_decompress.exec" "$T/startup_raw.o"

objcopy -O binary --strip-unneeded \
    -R .note -R .comment -R .note.gnu.build-id \
    -R .MIPS.abiflags -R .reginfo -R .rel.dyn \
    -R .note.gnu.gold-version -R .note.gnu.property -R .ARM.exidx \
    "$T/lzma_decompress.exec" "$LZMA_OUT"

# ============================== kernel.img =================================
# The i386-pc GRUB kernel: startup.S + 29 C files + symlist.c, linked as a
# static ELF at 0x9000 and stripped (NOT objcopy -O binary).
# ---------------------------------------------------------------------------

# TARGET_CFLAGS for kernel C compilation (from configure + Makefile).
KCFLAGS=(
    -std=gnu99 -Os -m32
    -DHAVE_CONFIG_H
    '-DGRUB_FILE="grub"'
    -DGRUB_MACHINE_PCBIOS=1 -DGRUB_MACHINE=I386_PC
    -nostdinc -isystem "$GCC_ISYSTEM"
    "${INCS[@]}"
    -march=i386 -mrtd -mregparm=3
    -falign-jumps=1 -falign-loops=1 -falign-functions=1
    -freg-struct-return
    -mno-mmx -mno-sse -mno-sse2 -mno-sse3 -mno-3dnow
    -msoft-float
    -fno-dwarf2-cfi-asm -mno-stack-arg-probe
    -fno-asynchronous-unwind-tables -fno-unwind-tables
    -fno-ident -fno-PIE -fno-pie -fno-stack-protector
    -ffreestanding
    -Wall -Wno-error
    -Wno-unused-parameter -Wno-sign-compare
    -Wno-implicit-fallthrough -Wno-unused-result
    -Wno-unused-but-set-variable -Wno-missing-field-initializers
    -Wno-deprecated-declarations -Wno-undef -Wno-redundant-decls
    -Wno-old-style-definition -Wno-type-limits -Wno-format
    -Wno-missing-prototypes -Wno-missing-declarations
    -Wno-cast-align -Wno-nested-externs -Wno-shadow
    -Wno-address -Wno-strict-aliasing -Wno-trampolines
    -Wno-unused-function -Wno-unused-variable -Wno-array-bounds
)

# TARGET_CCASFLAGS for kernel assembly (.S) compilation.
KASFLAGS=(
    -m32 -msoft-float -fno-PIE -fno-pie
    -DHAVE_CONFIG_H -DASM_FILE=1
    -DGRUB_MACHINE_PCBIOS=1 -DGRUB_MACHINE=I386_PC
    -nostdinc -isystem "$GCC_ISYSTEM"
    "${INCS[@]}"
)

# -- Compile startup.S (assembly entry point) --
gcc "${KASFLAGS[@]}" \
    -c "$SRC/grub-core/kern/i386/pc/startup.S" -o "$T/startup.o"

# -- Compile C source files --
KERNEL_C_SRCS=(
    kern/i386/pc/init.c
    kern/i386/pc/mmap.c
    term/i386/pc/console.c
    kern/i386/dl.c
    kern/i386/tsc.c
    kern/i386/tsc_pit.c
    kern/compiler-rt.c
    kern/mm.c
    kern/time.c
    kern/generic/millisleep.c
    kern/buffer.c
    kern/command.c
    kern/corecmd.c
    kern/device.c
    kern/disk.c
    kern/dl.c
    kern/env.c
    kern/err.c
    kern/file.c
    kern/fs.c
    kern/list.c
    kern/main.c
    kern/misc.c
    kern/parser.c
    kern/partition.c
    kern/rescue_parser.c
    kern/rescue_reader.c
    kern/term.c
    kern/verifiers.c
)

OBJS=("$T/startup.o")

for src in "${KERNEL_C_SRCS[@]}"; do
    # Create output dir to avoid basename collisions (e.g. kern/dl.c vs
    # kern/i386/dl.c).
    odir="$T/$(dirname "$src")"
    mkdir -p "$odir"
    ofile="$odir/$(basename "${src%.c}.o")"
    gcc "${KCFLAGS[@]}" \
        -c "$SRC/grub-core/$src" -o "$ofile"
    OBJS+=("$ofile")
done

# -- Compile symlist.c (checked-in generated file) --
gcc "${KCFLAGS[@]}" \
    -c "$CFG/symlist.c" -o "$T/symlist.o"
OBJS+=("$T/symlist.o")

# -- Link kernel.exec --
gcc -m32 -Wl,-melf_i386 -no-pie -Wl,--build-id=none \
    -nostdlib -Wl,-N -Wl,-Ttext,0x9000 \
    -o "$T/kernel.exec" "${OBJS[@]}"

# -- Strip to kernel.img (ELF, not raw binary) --
strip \
    -R .rel.dyn -R .reginfo -R .note -R .comment \
    -R .drectve -R .note.gnu.gold-version \
    -R .MIPS.abiflags -R .ARM.exidx \
    -o "$KERNEL_OUT" "$T/kernel.exec"
