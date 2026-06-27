"""define_kernel_for_arch: per-arch kernel pipeline wiring macro.

Wires, for one architecture (amd64 / platform vs):

  :<prefix>_config           debian_kernel_config (.config + .kernelvariables + kernel.release)
  :<prefix>_managed_config   manage_config (secure-upgrade passthrough)
  :<prefix>                  kernel_build  (make bzImage + modules + install)
  :<prefix>_modules_install  modules tree artifact extractor
  :<prefix>_vmlinux          unstripped vmlinux extractor
  :<prefix>_image            kernel image (bzImage) extractor
  :<prefix>_system_map       System.map extractor
  :<prefix>_build_data       data-only build dir (for headers debs)
"""

load("//kernel:debian_kernel_config.bzl", "debian_kernel_config")
load("//kernel:manage_config.bzl", "manage_config")
load("//kernel:kernel_build.bzl", "kernel_build")
load("//kernel:extract.bzl", "kernel_file", "kernel_tree")

def define_kernel_for_arch(
        name_prefix,
        arch,
        platform,
        make_goals,
        kernel_image,
        kversion,
        kernel_src_dir,
        kernel_sources,
        kconfig_exclusions,
        kconfig_inclusions,
        kconfig_force_inclusions,
        manage_config_script):
    # The kernel target is constrained to its arch's CPU so that, under any
    # given --platforms, Bazel toolchain resolution + incompatible-target
    # skipping build ONLY the matching arch: the non-matching kernel_build is
    # incompatible, `//...` skips it, and that propagates to its dependent debs.
    _target_compatible_by_arch = {
        "amd64": ["@platforms//cpu:x86_64"],
        "arm64": ["@platforms//cpu:aarch64"],
    }
    if arch not in _target_compatible_by_arch:
        fail("define_kernel_for_arch: no CPU constraint wired for arch %r " % arch +
             "(armhf has no registered cross toolchain yet).")
    target_compatible_with = _target_compatible_by_arch[arch]

    # .config + .kernelvariables + kernel.release, as a build action.
    # The Kconfig CC_HAS_* probes (e.g. -ftrivial-auto-var-init=zero, BTF/pahole,
    # asm-goto) MUST run with the pinned sonic GCC (the actual target compiler) so
    # that config-gen-time choices (INIT_STACK_*, MODULE_ALLOW_BTF_MISMATCH) match
    # the compiler kernel_build later builds with. Host /usr/bin/gcc is only used
    # for Kbuild HOSTCC (host tools).
    debian_kernel_config(
        name = name_prefix + "_config",
        arch = arch,
        platform = platform,
        kversion = kversion,
        kernel_src_dir = kernel_src_dir,
        kernel_sources = kernel_sources,
        kconfig_exclusions = kconfig_exclusions,
        kconfig_inclusions = kconfig_inclusions,
        kconfig_force_inclusions = kconfig_force_inclusions,
    )

    # Final config. Passthrough when secure_upgrade_mode is empty;
    # runs manage-config's secure-boot overlay (needs the source tree) when
    # the flag is set.
    manage_config(
        name = name_prefix + "_managed_config",
        base_config = name_prefix + "_config",
        arch = arch,
        platform = platform,
        source_tree = kernel_sources,
        manage_config_script = manage_config_script,
    )

    kernel_build(
        name = name_prefix,
        kernel_sources = kernel_sources,
        config = name_prefix + "_managed_config",
        arch = arch,
        kversion = kversion,
        kernel_src_dir = kernel_src_dir,
        kernel_image = kernel_image,
        make_goals = make_goals,
        target_compatible_with = target_compatible_with,
    )

    # Standalone artifact extractors.
    kernel_file(name = name_prefix + "_image", kernel_build = name_prefix, which = "kernel_binary")
    kernel_file(name = name_prefix + "_vmlinux", kernel_build = name_prefix, which = "vmlinux")
    kernel_file(name = name_prefix + "_system_map", kernel_build = name_prefix, which = "system_map")
    kernel_file(name = name_prefix + "_config_file", kernel_build = name_prefix, which = "config")
    kernel_tree(name = name_prefix + "_modules_install", kernel_build = name_prefix, which = "modules_install_dir")
    kernel_tree(name = name_prefix + "_build_data", kernel_build = name_prefix, which = "kernel_build_data_dir")
