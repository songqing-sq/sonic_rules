"""Rule to build the ONIE installer payload zip (fs.zip).

Mirrors legacy build_debian.sh:974-975, which assembles an installer payload
zip from:
    boot/                (extracted from a boot tar)
    platform.tar.gz
    fs.squashfs
    dockerfs.tar.gz      (optional)

The on-target installer extracts this with `unzip`, so the archive must be a
standard PKZIP zip. We use the sealed bsdtar from @tar.bzl with --format=zip,
which writes standard PKZIP (readable by unzip), rather than relying on a `zip`
binary on the host PATH (not sealed/installed).
"""

load("@tar.bzl//tar:tar.bzl", tar_lib = "tar_lib")

def _installer_payload_impl(ctx):
    out = ctx.actions.declare_file(ctx.attr.out)
    bsdtar = ctx.toolchains[tar_lib.toolchain_type]

    squashfs = ctx.file.squashfs
    boot_files = ctx.files.boot_files[0]
    initrd = ctx.file.initrd
    platform_tar = ctx.file.platform_tar
    dockerfs = ctx.file.dockerfs

    inputs = [squashfs, boot_files, initrd, platform_tar]

    members = ["boot", "platform.tar.gz", "fs.squashfs"]
    dockerfs_ln = ""
    if dockerfs:
        inputs.append(dockerfs)
        members.append("dockerfs.tar.gz")
        dockerfs_ln = 'ln -s "$(pwd)/{src}" "$STAGE/dockerfs.tar.gz"'.format(src = dockerfs.path)

    command = """
set -euo pipefail
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
OUT="$(pwd)/{out}"

# boot/ is assembled straight from the kernel boot-files tree + the initrd file
# (both already boot/-rooted) -- no boot tar to pack and then unpack. The tree's
# root holds boot/, so `cp -RL <tree>/.` lands boot/ under $STAGE; the initrd
# (boot/initrd.img-<kver>) is copied alongside.
cp -RL "{boot_files}/." "$STAGE/"
# Bazel tree/genrule outputs are read-only; make boot/ writable so the initrd
# can be added (and so $STAGE cleans up).
chmod -R u+w "$STAGE/boot"
cp -L "{initrd}" "$STAGE/boot/"
# Symlink the large, already-compressed members into the staging dir under their
# payload names rather than copying them (fs.squashfs alone is ~1.3G). bsdtar -L
# below dereferences the symlinks at pack time, so the zip carries the real
# bytes. Absolute targets ($(pwd)/...) so the links resolve from $STAGE.
ln -s "$(pwd)/{platform_tar}" "$STAGE/platform.tar.gz"
ln -s "$(pwd)/{squashfs}" "$STAGE/fs.squashfs"
{dockerfs_ln}

# --options zip:compression=store: every member is already compressed (squashfs
# zstd, *.tar.gz gzip), so deflate would burn CPU for no size gain (it can even
# grow the data). -L follows the symlinks above to pack their targets' contents.
"{tar}" -c --format=zip --options zip:compression=store -L -f "$OUT" -C "$STAGE" {members}
""".format(
        tar = bsdtar.tarinfo.binary.path,
        out = out.path,
        boot_files = boot_files.path,
        initrd = initrd.path,
        platform_tar = platform_tar.path,
        squashfs = squashfs.path,
        dockerfs_ln = dockerfs_ln,
        members = " ".join(members),
    )

    ctx.actions.run_shell(
        outputs = [out],
        inputs = inputs,
        tools = bsdtar.default.files,
        command = command,
        mnemonic = "InstallerPayload",
        progress_message = "Building installer payload %s" % out.short_path,
    )
    return [DefaultInfo(files = depset([out]))]

installer_payload = rule(
    implementation = _installer_payload_impl,
    doc = "Assemble the ONIE installer payload zip (boot/, platform.tar.gz, fs.squashfs, optional dockerfs.tar.gz).",
    attrs = {
        "squashfs": attr.label(
            mandatory = True,
            allow_single_file = [".squashfs"],
            doc = "The root filesystem SquashFS image (-> fs.squashfs).",
        ),
        "boot_files": attr.label(
            mandatory = True,
            doc = "A boot/-rooted tree artifact (kernel vmlinuz/config/" +
                  "System.map under boot/), copied verbatim into the payload " +
                  "as boot/. Replaces the old boot_tar -- no pack/unpack.",
        ),
        "initrd": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "The initramfs file (boot/initrd.img-<kver>), copied into " +
                  "the payload's boot/ alongside boot_files.",
        ),
        "platform_tar": attr.label(
            mandatory = True,
            allow_single_file = [".tar.gz"],
            doc = "The platform archive (-> platform.tar.gz).",
        ),
        "dockerfs": attr.label(
            allow_single_file = [".tar.gz"],
            doc = "Optional docker filesystem archive (-> dockerfs.tar.gz).",
        ),
        "out": attr.string(
            default = "fs.zip",
            doc = "Name of the installer payload zip to produce.",
        ),
    },
    toolchains = [tar_lib.toolchain_type],
)

def _installer_install_sh_impl(ctx):
    out = ctx.actions.declare_file(ctx.attr.name + "_install.sh")
    ctx.actions.run_shell(
        inputs = [ctx.file.template],
        outputs = [out],
        command = (
            "sed -e 's/%%DEMO_TYPE%%/{demo}/g' -e 's/%%ARCH%%/{arch}/g' " +
            "-e 's/%%IMAGE_VERSION%%/{ver}/g' -e 's/%%ONIE_IMAGE_PART_SIZE%%/{part}/' " +
            "-e 's/%%VAR_LOG_FILE_SIZE%%/{varlog}/' -e 's@%%EXTRA_CMDLINE_LINUX%%@{cmdline}@' " +
            "-e 's@%%OUTPUT_RAW_IMAGE%%@{raw}@' {tpl} > {out}"
        ).format(
            demo = ctx.attr.demo_type,
            arch = ctx.attr.arch,
            ver = ctx.attr.image_version,
            part = ctx.attr.part_size,
            varlog = ctx.attr.var_log_file_size,
            cmdline = ctx.attr.extra_cmdline,
            raw = ctx.attr.output_raw_image,
            tpl = ctx.file.template.path,
            out = out.path,
        ),
        mnemonic = "InstallShSubst",
        progress_message = "Substituting install.sh placeholders -> %s" % out.short_path,
    )
    return [DefaultInfo(files = depset([out]))]

installer_install_sh = rule(
    implementation = _installer_install_sh_impl,
    doc = "Substitute the %%...%% placeholders in the ONIE installer/install.sh " +
          "template, mirroring legacy onie-mk-demo.sh's sed pass.",
    attrs = {
        "template": attr.label(
            allow_single_file = True,
            mandatory = True,
            doc = "The install.sh template containing %%...%% placeholders.",
        ),
        "demo_type": attr.string(
            default = "OS",
            doc = "Value for %%DEMO_TYPE%% (OS or DIAG).",
        ),
        "arch": attr.string(
            mandatory = True,
            doc = "Value for %%ARCH%% (e.g. amd64, arm64).",
        ),
        "image_version": attr.string(
            mandatory = True,
            doc = "Value for %%IMAGE_VERSION%%.",
        ),
        "part_size": attr.string(
            mandatory = True,
            doc = "Value for %%ONIE_IMAGE_PART_SIZE%%.",
        ),
        "var_log_file_size": attr.string(
            mandatory = True,
            doc = "Value for %%VAR_LOG_FILE_SIZE%%.",
        ),
        "extra_cmdline": attr.string(
            default = "",
            doc = "Value for %%EXTRA_CMDLINE_LINUX%%.",
        ),
        "output_raw_image": attr.string(
            default = "target/sonic.raw",
            doc = "Value for %%OUTPUT_RAW_IMAGE%%.",
        ),
    },
)

def _onie_installer_impl(ctx):
    out = ctx.actions.declare_file(ctx.attr.out)
    gtar = ctx.executable._tar
    ctx.actions.run(
        executable = ctx.executable._onie_mk,
        # The sealed GNU tar path is passed as the trailing arg; onie_mk.sh packs
        # installer/ with `-h` (dereference) via this tar instead of the host one.
        arguments = [ctx.file.sharch_body.path, ctx.file.install_sh.path, ctx.file.payload.path,
                     ctx.attr.machine, ctx.attr.platform, ctx.file.conf.path, ctx.file.conf_arch.path, out.path,
                     gtar.path],
        inputs = [ctx.file.sharch_body, ctx.file.install_sh, ctx.file.payload, ctx.file.conf, ctx.file.conf_arch],
        tools = [gtar],
        outputs = [out],
        mnemonic = "OnieInstaller",
        progress_message = "Building ONIE self-extracting installer %s" % out.short_path,
    )
    return [DefaultInfo(files = depset([out]))]

onie_installer = rule(
    implementation = _onie_installer_impl,
    doc = "Assemble the ONIE self-extracting .bin: a substituted sharch_body.sh " +
          "header (with payload sha1 + size) followed by a tar of the installer/ " +
          "directory, mirroring the assembly half of legacy onie-mk-demo.sh (no signing).",
    attrs = {
        "sharch_body": attr.label(allow_single_file = True, mandatory = True),
        "install_sh": attr.label(allow_single_file = True, mandatory = True),
        "payload": attr.label(allow_single_file = [".zip"], mandatory = True),
        "conf": attr.label(allow_single_file = True, mandatory = True),
        "conf_arch": attr.label(allow_single_file = True, mandatory = True),
        "machine": attr.string(mandatory = True),
        "platform": attr.string(mandatory = True),
        "out": attr.string(default = "sonic.bin"),
        "_onie_mk": attr.label(default = "//onie_installer:onie_mk", executable = True, cfg = "exec"),
        "_tar": attr.label(
            default = "//tar:tar",
            executable = True,
            cfg = "exec",
            doc = "Hermetic from-source GNU tar; onie_mk.sh uses it (with -h) " +
                  "to pack installer/ instead of the host tar.",
        ),
    },
)
