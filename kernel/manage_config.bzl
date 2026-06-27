"""manage_config: apply the secure-upgrade kconfig overlay.

Sits between `//bazel:debian_kernel_config` (produces base `.config` +
`.kernelvariables` + kernel.release) and `kernel_build` (consumes the final
`.config`).

When `secure_upgrade_mode` is empty (the platform `vs` / no-sign case), this
rule is a pure passthrough: it symlinks `base_config`'s outputs so they are
owned by this target and re-exposes the upstream KernelConfigInfo unchanged.
The inclusion/exclusion/force overlays already ran inside the
debian_kernel_config action, so there is nothing to do.

When `secure_upgrade_mode` is non-empty, the rule stages the patched kernel
source tree into a writable workdir, drops `base_config` at
`debian/build/build_<arch>_none_<flavor>/.config`, runs the SONiC
`manage-config` script (which edits that config via `scripts/config`, reads
`../patch/kconfig-*`, and runs `make olddefconfig`), and copies the modified
`.config` back out. `source_tree` is required in this case; without it the
script cannot resolve `debian/build/...`, `scripts/config`, or the patch
overlays, so the rule fails fast. No `make` is invoked from this Starlark
file -- the only `make` lives inside `manage-config` itself.
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("//kernel:providers.bzl", "KernelConfigInfo")

# Map arch -> Debian build subdirectory the script expects (manage-config
# lines 44-58). Kept in sync here so a wrong `arch` fails at analysis time.
_CONFIG_FILE_LOC_BY_ARCH = {
    "amd64": "debian/build/build_amd64_none_amd64",
    "arm64": "debian/build/build_arm64_none_arm64",
    "armhf": "debian/build/build_armhf_none_armmp",
}

def _impl(ctx):
    base = ctx.attr.base_config[KernelConfigInfo]
    secure_upgrade_mode = ctx.attr.secure_upgrade_mode[BuildSettingInfo].value
    secure_upgrade_cert = ctx.attr.secure_upgrade_cert[BuildSettingInfo].value

    # Passthrough: empty mode -> manage-config's secure-boot branch is a
    # no-op. Symlink the upstream outputs (so this target owns them) and
    # forward KernelConfigInfo unchanged.
    if not secure_upgrade_mode:
        out_config = ctx.actions.declare_file(ctx.label.name + "/.config")
        out_kvars = ctx.actions.declare_file(ctx.label.name + "/.kernelvariables")
        ctx.actions.symlink(output = out_config, target_file = base.config)
        ctx.actions.symlink(output = out_kvars, target_file = base.kernel_variables)
        return [
            DefaultInfo(files = depset([out_config, out_kvars])),
            KernelConfigInfo(
                config = out_config,
                kernel_variables = out_kvars,
                kernel_release = base.kernel_release,
            ),
        ]

    arch = ctx.attr.arch
    if arch not in _CONFIG_FILE_LOC_BY_ARCH:
        fail("manage_config: unsupported arch %r (expected one of %s)" % (
            arch,
            sorted(_CONFIG_FILE_LOC_BY_ARCH.keys()),
        ))
    config_file_loc = _CONFIG_FILE_LOC_BY_ARCH[arch]

    source_tree = ctx.attr.source_tree
    if source_tree == None:
        fail(
            "manage_config: secure_upgrade_mode=%r requires source_tree " % secure_upgrade_mode +
            "(the patched kernel source tree from @kernel_sources). " +
            "manage-config edits debian/build/.../config, calls scripts/config, " +
            "reads ../patch/kconfig-*, and runs `make olddefconfig`; none of " +
            "that is reachable with only base_config in the sandbox.",
        )
    source_tree_files = source_tree[DefaultInfo].files
    source_tree_list = source_tree_files.to_list()

    script = ctx.file.manage_config_script
    platform = ctx.attr.platform

    out_config = ctx.actions.declare_file(ctx.label.name + "/.config")
    out_kvars = ctx.actions.declare_file(ctx.label.name + "/.kernelvariables")

    # Stage source tree + base_config into a writable workdir, run the
    # script from the repo root (so its `../patch/...` lookups resolve to
    # OUR patch/ tree), then copy the modified .config back out. The script
    # exits non-zero on verification failure; `set -e` propagates it.
    command = """
set -euo pipefail
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
cp -aL "{source_tree_marker_dir}"/. "$WORKDIR"/
mkdir -p "$WORKDIR/{config_file_loc}"
cp -L "{base_config}" "$WORKDIR/{config_file_loc}/.config"
cp -L "{script}" "$WORKDIR/manage-config"
chmod +x "$WORKDIR/manage-config"
( cd "$WORKDIR" && ./manage-config {arch} {platform} {mode} {cert} )
cp -L "$WORKDIR/{config_file_loc}/.config" "{out_config}"
""".format(
        source_tree_marker_dir = source_tree_list[0].dirname if source_tree_list else ".",
        base_config = base.config.path,
        script = script.path,
        config_file_loc = config_file_loc,
        arch = arch,
        platform = platform if platform else '""',
        mode = secure_upgrade_mode,
        cert = secure_upgrade_cert if secure_upgrade_cert else '""',
        out_config = out_config.path,
    )

    ctx.actions.run_shell(
        inputs = depset(direct = [base.config], transitive = [source_tree_files]),
        outputs = [out_config],
        tools = [script],
        command = command,
        progress_message = "manage_config %s (mode=%s arch=%s)" % (
            ctx.label,
            secure_upgrade_mode,
            arch,
        ),
        mnemonic = "ManageConfig",
    )

    # .kernelvariables is unaffected by the secure-boot overlay; forward it.
    ctx.actions.symlink(output = out_kvars, target_file = base.kernel_variables)

    return [
        DefaultInfo(files = depset([out_config, out_kvars])),
        KernelConfigInfo(
            config = out_config,
            kernel_variables = out_kvars,
            kernel_release = base.kernel_release,
        ),
    ]

manage_config = rule(
    implementation = _impl,
    attrs = {
        "base_config": attr.label(
            mandatory = True,
            providers = [KernelConfigInfo],
            doc = "debian_kernel_config target (KernelConfigInfo).",
        ),
        "manage_config_script": attr.label(
            allow_single_file = True,
            mandatory = True,
            executable = True,
            cfg = "exec",
            doc = "The SONiC `manage-config` script (component data label).",
        ),
        "arch": attr.string(
            default = "amd64",
            values = ["amd64", "arm64", "armhf"],
            doc = "Concrete arch string from define_kernel_for_arch.",
        ),
        "platform": attr.string(
            default = "",
            doc = "Concrete platform string from define_kernel_for_arch.",
        ),
        "secure_upgrade_mode": attr.label(
            default = "//kernel:secure_upgrade_mode",
            providers = [BuildSettingInfo],
            doc = "string_flag from //kernel:BUILD.bazel. Empty -> passthrough.",
        ),
        "secure_upgrade_cert": attr.label(
            default = "//kernel:secure_upgrade_cert",
            providers = [BuildSettingInfo],
            doc = "string_flag from //kernel:BUILD.bazel. Path to the signing cert.",
        ),
        "source_tree": attr.label(
            default = None,
            allow_files = False,
            doc = "Patched kernel source tree (@kernel_sources). Required " +
                  "when secure_upgrade_mode is non-empty; ignored otherwise.",
        ),
    },
    provides = [KernelConfigInfo],
    doc = "Secure-upgrade config overlay (passthrough when mode is empty).",
)
