"""Platform-agnostic ONIE image composition. sonic-vs.bin is the validation instance.

Wires the already-built M1 rules (sonic_squashfs -> installer_payload
+ installer_install_sh -> onie_installer) into a single sonic-<machine>.bin. This
is the M1 subset: no dockerfs/initramfs orchestration yet (those args arrive in
later milestones; `dockerfs` is accepted now but optional).
"""

load("//squashfs:defs.bzl", "sonic_squashfs")
load("//onie_installer:defs.bzl", "installer_payload", "onie_installer", "installer_install_sh")
load("//dockerfs:defs.bzl", "docker_overlay2_store")

def sonic_onie_image(
        name,
        machine,
        arch,
        platform,
        image_version,
        rootfs_layers,
        boot_files,
        initrd,
        platform_tar,
        sharch_body,
        install_sh_template,
        onie_conf,
        onie_conf_arch,
        onie_image_part_size = "524288",
        var_log_file_size = "61440",
        extra_cmdline = "",
        dockerfs = None,
        dockers = {},
        visibility = None):
    """Compose a sonic-<machine>.bin ONIE self-extracting installer.

    Args:
        name: Target name; the final .bin target is `name`.
        machine: SONiC machine string (e.g. "vs"); drives the output filename.
        arch: Debian arch substituted into install.sh (e.g. "amd64").
        platform: Platform identifier written into machine.conf.
        image_version: Image version substituted into install.sh.
        rootfs_layers: Layer tars assembled by sonic_rootfs into the fs tree.
        boot_files: A boot/-rooted tree artifact (kernel vmlinuz/config/System.map).
        initrd: The initramfs file (boot/initrd.img-<kver>).
        platform_tar: The platform.tar.gz archive.
        sharch_body: sharch_body.sh header template (with sha1/size placeholders).
        install_sh_template: install.sh TEMPLATE carrying %%...%% placeholders.
        onie_conf: onie-image.conf.
        onie_conf_arch: onie-image-<arch>.conf.
        onie_image_part_size: %%ONIE_IMAGE_PART_SIZE%% value.
        var_log_file_size: %%VAR_LOG_FILE_SIZE%% value.
        extra_cmdline: %%EXTRA_CMDLINE_LINUX%% value.
        dockerfs: Optional pre-built dockerfs.tar.gz (M2+); None in M1. Ignored
            when `dockers` is non-empty (the store is synthesized instead).
        dockers: Optional dict of oci_image target -> "repo:tag". When non-empty,
            a docker overlay2 store (dockerfs.tar.gz) is synthesized from these
            images and shipped in the payload. Keys are resolved in the caller's
            package/repo. Empty (default) leaves the M1/M2 behavior unchanged.
        visibility: Visibility for the final .bin target.
    """
    sonic_squashfs(
        name = name + "_squashfs",
        layers = rootfs_layers,
        out = "fs.squashfs",
        excludes = ["boot", "var/lib/docker"],
    )
    if dockers:
        docker_overlay2_store(
            name = name + "_dockerfs",
            images = dockers,
            out = "dockerfs.tar.gz",
        )
        dockerfs = ":" + name + "_dockerfs"
    installer_payload(
        name = name + "_payload",
        squashfs = ":" + name + "_squashfs",
        boot_files = boot_files,
        initrd = initrd,
        platform_tar = platform_tar,
        dockerfs = dockerfs,
        out = "fs.zip",
    )
    installer_install_sh(
        name = name + "_install_sh",
        template = install_sh_template,
        arch = arch,
        image_version = image_version,
        part_size = onie_image_part_size,
        var_log_file_size = var_log_file_size,
        extra_cmdline = extra_cmdline,
    )
    onie_installer(
        name = name,
        sharch_body = sharch_body,
        install_sh = ":" + name + "_install_sh",
        payload = ":" + name + "_payload",
        conf = onie_conf,
        conf_arch = onie_conf_arch,
        machine = machine,
        platform = platform,
        out = "sonic-" + machine + ".bin",
        visibility = visibility,
    )
