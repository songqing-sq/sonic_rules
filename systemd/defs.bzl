"""Rule that emits the systemd enable/mask symlinks a Debian postinst would create."""

def _systemd_enable_impl(ctx):
    out = ctx.actions.declare_file(ctx.attr.name + ".tar")
    units_dir = ctx.files.units[0].dirname if ctx.files.units else "."
    ctx.actions.run(
        executable = ctx.executable._tool,
        arguments = [out.path, ",".join(ctx.attr.enable), ",".join(ctx.attr.mask), units_dir],
        inputs = ctx.files.units,
        outputs = [out],
        mnemonic = "SystemdEnable",
    )
    return [DefaultInfo(files = depset([out]))]

systemd_enable = rule(
    implementation = _systemd_enable_impl,
    attrs = {
        "units": attr.label_list(allow_files = True),
        "enable": attr.string_list(),
        "mask": attr.string_list(),
        "_tool": attr.label(default = "//systemd:enable", executable = True, cfg = "exec"),
    },
)
