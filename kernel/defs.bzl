"""sonic_kernel: top-level macro that wires the full SONiC kernel deb pipeline.

This is the reusable equivalent of what the @sonic-linux-kernel component's
BUILD.bazel used to spell out by hand for amd64 + arm64. It loops over the
`arches` dict so there is a single description of the per-arch pipeline:

  per arch:
    debian_kernel_config -> manage_config -> kernel_build (+ extractors)
    linux-image deb        (boot files + modules_install + doc)
    linux-image-dbgsym deb (unstripped vmlinux)
    linux-headers-<arch> deb
  shared:
    linux-headers-common deb (arch: all; sourced from the selected arch via
      select() so a single-arch build pulls only one kernel compile)
    :kernel_debs           filegroup (select() on the target CPU)
    kernel_debs_dist       distribution target

Version/sha DATA and the @kernel_sources repo INSTANTIATION stay in the
component (it can load its kernel_version.bzl + pass the //patch:* + the
//:manage-config labels). This macro receives them as plain arguments, so it
never hardcodes a version.

The is_amd64/is_arm64 select keys reuse @sonic_build_infra//config:cpu_x86_64 /
:cpu_aarch64.
"""

load("//sonic_deb:sonic_deb.bzl", "sonic_deb")
load("//kernel:debian_docs.bzl", "debian_changelog_gz", "debian_copyright", "debian_news_gz")
load("//kernel:headers_deb.bzl", "linux_headers_arch_deb", "linux_headers_common_deb")
load("//kernel:image_scripts.bzl", "kernel_image_boot_files", "kernel_image_dbg_files", "render_image_scripts")
load("//kernel:kernel_debs_dist.bzl", "kernel_debs_dist")
load("//kernel:kernel_inputs.bzl", "define_kernel_for_arch")

_CPU_CONFIG = {
    "amd64": "@sonic_build_infra//config:cpu_x86_64",
    "arm64": "@sonic_build_infra//config:cpu_aarch64",
}

_MAINTAINER = "Debian Kernel Team <debian-kernel@lists.debian.org>"

def sonic_kernel(
        kernel_sources,
        kernel_sources_all,
        kernel_src_dir,
        ver,
        abiname,
        abi_minor,
        kversion_short,
        kernel_version,
        kernel_subversion,
        manage_config_script,
        kconfig_exclusions,
        kconfig_inclusions,
        kconfig_force_inclusions,
        arches,
        platform = "vs",
        image_stem = "vmlinuz"):
    """Wire the per-arch kernel pipeline + debs for every arch in `arches`.

    Args:
      kernel_sources: label of the patched source tree (@kernel_sources//:source_tree).
      kernel_sources_all: label of the kernel_sources :all filegroup (templates/docs).
      kernel_src_dir: unpacked source dir name, e.g. "linux-6.1.123".
      ver: full version "kernel_version-kernel_subversion", e.g. "6.1.123-1".
      abiname: Debian ABI name, e.g. "6.1.0-29".
      abi_minor: SONiC extra ABI minor, e.g. "2".
      kversion_short: arch-independent release, e.g. "6.1.0-29-2".
      kernel_version: upstream version, e.g. "6.1.123".
      kernel_subversion: Debian sub-version, e.g. "1".
      manage_config_script: label of the SONiC manage-config script (//:manage-config).
      kconfig_exclusions: //patch:kconfig-exclusions label.
      kconfig_inclusions: //patch:kconfig-inclusions label.
      kconfig_force_inclusions: //patch:kconfig-force-inclusions label.
      arches: dict arch -> {kernel_image, make_goals, image_description}.
      platform: SONiC platform string (default "vs").
      image_stem: image file stem for the maintainer-script templates (default "vmlinuz").
    """
    common_deb = "linux_headers_common_deb"
    deb_select = {}

    for arch, spec in arches.items():
        if arch not in _CPU_CONFIG:
            fail("sonic_kernel: no CPU config_setting wired for arch %r" % arch)

        kversion = kversion_short + "-" + arch  # e.g. 6.1.0-29-2-amd64
        localversion = "-" + abi_minor + "-" + arch  # e.g. -2-amd64
        prefix = "kernel_" + arch  # kernel_amd64 / kernel_arm64

        # config -> manage_config -> kernel_build (+ extractors).
        define_kernel_for_arch(
            name_prefix = prefix,
            arch = arch,
            kernel_image = spec["kernel_image"],
            kversion = kversion,
            kernel_src_dir = kernel_src_dir,
            kernel_sources = kernel_sources,
            kconfig_exclusions = kconfig_exclusions,
            kconfig_inclusions = kconfig_inclusions,
            kconfig_force_inclusions = kconfig_force_inclusions,
            manage_config_script = manage_config_script,
            make_goals = spec["make_goals"],
            platform = platform,
        )

        # --- linux-image deb (vmlinuz + config + System.map + modules tree) ---
        kernel_image_boot_files(
            name = arch + "_image_boot_files",
            kernel_build = ":" + prefix,
            kversion = kversion,
        )

        render_image_scripts(
            name = arch + "_image",
            abiname = abiname,
            image_stem = image_stem,
            kernel_sources = kernel_sources_all,
            localversion = localversion,
        )

        debian_changelog_gz(
            name = "linux_image_" + arch + "_changelog_gz",
            kernel_sources = kernel_sources_all,
        )

        debian_copyright(
            name = "linux_image_" + arch + "_copyright",
            kernel_sources = kernel_sources_all,
        )

        debian_news_gz(
            name = "linux_image_" + arch + "_news_gz",
            kernel_sources = kernel_sources_all,
            news_file_suffix = "/debian/linux-image.NEWS",
        )

        sonic_deb(
            name = "linux_image_" + arch + "_deb",
            package = "linux-image-" + kversion + "-unsigned",
            version = ver,
            architecture = arch,
            package_file_name = "linux-image-%s-unsigned_%s_%s.deb" % (kversion, ver, arch),
            content = {
                "/": [
                    ":" + arch + "_image_boot_files",
                    ":" + prefix + "_modules_install",
                ],
                "/usr/share/doc/linux-image-" + kversion + "-unsigned/*": [
                    ":linux_image_" + arch + "_changelog_gz",
                    ":linux_image_" + arch + "_copyright",
                    ":linux_image_" + arch + "_news_gz",
                ],
            },
            depends = [
                "kmod",
                "linux-base (>= 4.3~)",
                "initramfs-tools (>= 0.120+deb8u2) | linux-initramfs-tool",
            ],
            section = "kernel",
            source = "linux",
            maintainer = _MAINTAINER,
            description = spec["image_description"],
            preinst = ":" + arch + "_image_preinst",
            postinst = ":" + arch + "_image_postinst",
            prerm = ":" + arch + "_image_prerm",
            postrm = ":" + arch + "_image_postrm",
        )

        # --- linux-image-dbgsym deb (unstripped vmlinux) ---
        kernel_image_dbg_files(
            name = arch + "_image_dbg_files",
            kernel_build = ":" + prefix,
            kversion = kversion,
        )

        sonic_deb(
            name = "linux_image_" + arch + "_dbgsym_deb",
            package = "linux-image-" + kversion + "-unsigned-dbgsym",
            version = ver,
            architecture = arch,
            package_file_name = "linux-image-%s-unsigned-dbgsym_%s_%s.deb" % (kversion, ver, arch),
            content = {
                "/": [":" + arch + "_image_dbg_files"],
            },
            depends = ["linux-image-" + kversion + "-unsigned (= " + ver + ")"],
            section = "debug",
            source = "linux",
            maintainer = _MAINTAINER,
            description = "Debug symbols for linux-image-" + kversion + "-unsigned",
        )

        # --- linux-headers-<arch> deb ---
        linux_headers_arch_deb(
            name = "linux_headers_" + arch + "_deb",
            kernel_build = ":" + prefix,
            arch = arch,
            kversion = kversion,
            kversion_short = kversion_short,
            kernel_version = kernel_version,
            kernel_subversion = kernel_subversion,
            kernel_src_dir = kernel_src_dir,
            depends = [
                "linux-headers-%s-common (= %s)" % (kversion_short, ver),
                "linux-kbuild-6.1 (>= " + ver + ")",
                "libc6",
            ],
        )

        deb_select[_CPU_CONFIG[arch]] = [
            ":linux_headers_" + arch + "_deb",
            ":linux_image_" + arch + "_deb",
            ":linux_image_" + arch + "_dbgsym_deb",
        ]

    # --- linux-headers-common deb (arch: all) ---
    # Sourced from whichever arch is being built (select on the target CPU) so a
    # single-arch build pulls only one kernel compile.
    linux_headers_common_deb(
        name = common_deb,
        kernel_build = select({
            _CPU_CONFIG[arch]: ":kernel_" + arch
            for arch in arches
        }),
        kversion_short = kversion_short,
        kernel_version = kernel_version,
        kernel_subversion = kernel_subversion,
        kernel_src_dir = kernel_src_dir,
        depends = ["linux-base"],
    )

    # --- aggregate :kernel_debs filegroup (per-arch via select on the CPU) ---
    native.filegroup(
        name = "kernel_debs",
        srcs = [":" + common_deb] + select(deb_select),
        visibility = ["//visibility:public"],
    )

    # --- distribution target ---
    kernel_debs_dist(
        name = "kernel_debs_dist",
        debs = ":kernel_debs",
    )
