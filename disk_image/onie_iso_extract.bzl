"""Extract an ONIE-BOOT partition staging tree from a downloaded ONIE
recovery ISO.

The output feeds the static `sonic-vs.img.gz` assembly pipeline (T8
`sonic_disk_image`): the staging tar becomes the ext4 contents of the
ONIE-BOOT partition (built in place with `mke2fs -d`), supplying both the
ONIE rescue kernel/initrd and the GRUB i386-pc modules + grub.cfg that
the on-disk core.img (built by host `grub-mkimage` at sonic_disk_image
time) loads at boot:

  * `<name>_onie_boot.tar` -> fed to mke2fs -d. Mirrors what an actual
    ONIE install lays down on its ONIE-BOOT partition:

       onie/vmlinuz
       onie/initrd.xz
       onie/grub/grub.cfg            (minimal "ONIE: Rescue" menuentry
                                      referencing /onie/vmlinuz +
                                      /onie/initrd.xz; later overwritten
                                      by onie_boot_with_sonic_grub to add
                                      a SONiC menuentry)
       onie/grub/i386-pc/*.mod       (all GRUB BIOS modules from the
       onie/grub/i386-pc/*.lst        ISO's boot/grub/i386-pc/ tree)
       onie/grub/i386-pc/*.img

Previously this rule also extracted an MBR boot sector and a "core.img"
out of the ISO's `boot/eltorito.img`. Those are not produced any more:
the ISO's MBR is an ISO9660 hybrid stub (not a usable GPT disk MBR),
and eltorito.img's core.img is built for `(cd)` prefix and El Torito
chainload, not for a BIOS Boot Partition on a GPT disk. The on-disk MBR
+ core.img are now generated at sonic_disk_image time by host
`grub-mkimage` + `grub-bios-setup` (source-built from GRUB 2.06),
matching what `grub-install --target=i386-pc` produces during a real
ONIE install.

ISO structure (probed empirically for
onie-recovery-x86_64-kvm_x86_64-r0.iso):

    /vmlinuz                      4.0M ONIE kernel
    /initrd.xz                   19.8M ONIE initrd (xz)
    /boot/grub/grub.cfg                live-ISO GRUB config
    /boot/grub/i386-pc/*.mod    271 files: GRUB BIOS modules

The actual file laydown / commands live in `onie_iso_extract.sh`; this
.bzl wires the shell script to the bsdtar toolchain and Bazel actions.
"""

load("@tar.bzl//tar:tar.bzl", tar_lib = "tar_lib")

def _onie_iso_extract_impl(ctx):
    iso = ctx.file.iso
    onie_boot = ctx.actions.declare_file(ctx.label.name + "_onie_boot.tar")
    bsdtar = ctx.toolchains[tar_lib.toolchain_type]

    # Optional override: a tar of a version-consistent i386-pc GRUB tree (modules
    # + platform .img). When set, it REPLACES the ISO's own i386-pc modules in the
    # staged ONIE-BOOT tree. The ISO ships GRUB 2.02 modules, which cannot be
    # loaded by the GRUB 2.06 core.img the disk assembly builds; real disk images
    # must pass this (see //platform/vs). Empty string = keep the ISO's modules.
    grub_i386pc = ctx.file.grub_i386pc
    grub_arg = grub_i386pc.path if grub_i386pc else ""
    inputs = [iso] + ([grub_i386pc] if grub_i386pc else [])

    ctx.actions.run(
        executable = ctx.executable._extract_sh,
        arguments = [
            bsdtar.tarinfo.binary.path,
            iso.path,
            onie_boot.path,
            grub_arg,
        ],
        inputs = inputs,
        outputs = [onie_boot],
        tools = bsdtar.default.files,
        mnemonic = "OnieIsoExtract",
        progress_message = "Extracting ONIE ISO materials from %s" % iso.short_path,
    )
    return [
        DefaultInfo(files = depset([onie_boot])),
        # Per-output group so a sibling filegroup(output_group="onie_boot")
        # can pick the file out of the rule. declare_file() outputs are not
        # addressable as bare labels, so this is the standard way to feed
        # the artifact into other rules' label attributes.
        OutputGroupInfo(
            onie_boot = depset([onie_boot]),
        ),
    ]

onie_iso_extract = rule(
    implementation = _onie_iso_extract_impl,
    doc = "Extract an ONIE-BOOT staging tar from a downloaded ONIE recovery " +
          "ISO. Produces one output: <name>_onie_boot.tar.",
    attrs = {
        "iso": attr.label(
            mandatory = True,
            allow_single_file = [".iso"],
            doc = "The ONIE recovery ISO (hybrid ISO9660 + MBR).",
        ),
        "grub_i386pc": attr.label(
            allow_single_file = True,
            doc = "Optional tar of a version-consistent i386-pc GRUB tree " +
                  "(modules + platform .img, top-level). Replaces the ISO's " +
                  "GRUB 2.02 modules in the staged ONIE-BOOT tree so they match " +
                  "the GRUB 2.06 core.img. Required for bootable disk images.",
        ),
        "_extract_sh": attr.label(
            default = "//disk_image:onie_iso_extract_sh",
            executable = True,
            cfg = "exec",
        ),
    },
    toolchains = [tar_lib.toolchain_type],
)
