"""Boot-file staging for the linux-image deb.

Stages /boot/{vmlinuz,config,System.map}-<KVERSION> from a kernel_build, and a
separate dbgsym tree for /usr/lib/debug/boot/vmlinux-<KVERSION>.
"""

load("//kernel:providers.bzl", "KernelBuildInfo")

def _boot_impl(ctx):
    info = ctx.attr.kernel_build[KernelBuildInfo]
    kversion = ctx.attr.kversion
    out = ctx.actions.declare_directory(ctx.label.name)
    script = ctx.actions.declare_file(ctx.label.name + "_stage.sh")
    ctx.actions.write(script, is_executable = True, content = """#!/bin/bash
set -euo pipefail
DST="{out}/boot"
mkdir -p "$DST"
cp "{image}" "$DST/vmlinuz-{kversion}"
cp "{config}" "$DST/config-{kversion}"
cp "{sysmap}" "$DST/System.map-{kversion}"
chmod 0644 "$DST/config-{kversion}" "$DST/System.map-{kversion}"
chmod 0644 "$DST/vmlinuz-{kversion}"
""".format(
        out = out.path,
        image = info.kernel_binary.path,
        config = info.config.path,
        sysmap = info.system_map.path,
        kversion = kversion,
    ))
    ctx.actions.run(
        executable = script,
        inputs = [info.kernel_binary, info.config, info.system_map],
        outputs = [out],
        mnemonic = "KernelBootFiles",
        use_default_shell_env = True,
    )
    return [DefaultInfo(files = depset([out]))]

kernel_image_boot_files = rule(
    implementation = _boot_impl,
    attrs = {
        "kernel_build": attr.label(mandatory = True, providers = [KernelBuildInfo]),
        "kversion": attr.string(mandatory = True),
    },
)

def _dbg_impl(ctx):
    info = ctx.attr.kernel_build[KernelBuildInfo]
    kversion = ctx.attr.kversion
    out = ctx.actions.declare_directory(ctx.label.name)
    script = ctx.actions.declare_file(ctx.label.name + "_stage.sh")
    ctx.actions.write(script, is_executable = True, content = """#!/bin/bash
set -euo pipefail
DST="{out}/usr/lib/debug/boot"
mkdir -p "$DST"
cp "{vmlinux}" "$DST/vmlinux-{kversion}"
chmod 0644 "$DST/vmlinux-{kversion}"
""".format(out = out.path, vmlinux = info.vmlinux.path, kversion = kversion))
    ctx.actions.run(
        executable = script,
        inputs = [info.vmlinux],
        outputs = [out],
        mnemonic = "KernelDbgFiles",
        use_default_shell_env = True,
    )
    return [DefaultInfo(files = depset([out]))]

kernel_image_dbg_files = rule(
    implementation = _dbg_impl,
    attrs = {
        "kernel_build": attr.label(mandatory = True, providers = [KernelBuildInfo]),
        "kversion": attr.string(mandatory = True),
    },
)

# ---------------------------------------------------------------------------
# render_debian_template — @variable@ substitution on a template located by
# path-suffix in a file set (typically @kernel_sources//:all).
# ---------------------------------------------------------------------------

def _render_debian_template_impl(ctx):
    template_suffix = ctx.attr.template_suffix

    # Suffix is assumed unique across kernel_sources. Debian's
    # `debian/templates/` and `debian/signing_templates/` carry parallel
    # filenames, so any template_suffix should include a directory segment.
    template_file = None
    for f in ctx.files.kernel_sources:
        if f.short_path.endswith(template_suffix):
            template_file = f
            break
    if template_file == None:
        fail("render_debian_template: no file in kernel_sources ending in %r" % template_suffix)

    sed_args = []
    for var, val in ctx.attr.substitutions.items():
        # Sed metacharacters in replacement values: backslash, slash (the
        # s/.../.../ delimiter), &, and newlines. Plus `$` which the shell
        # would expand before sed sees it.
        escaped_val = (val
            .replace("\\", "\\\\")
            .replace("/", "\\/")
            .replace("&", "\\&")
            .replace("\n", "\\n")
            .replace("$", "\\$"))
        sed_args.append("-e 's/@{v}@/{val}/g'".format(v = var, val = escaped_val))
    sed_expr = " ".join(sed_args)

    out_basename = ctx.attr.output_basename if ctx.attr.output_basename else ctx.label.name
    out = ctx.actions.declare_file(out_basename)

    ctx.actions.run_shell(
        inputs = [template_file],
        outputs = [out],
        command = "sed {sed_expr} '{src}' > '{out}' && chmod 0755 '{out}'".format(
            sed_expr = sed_expr,
            src = template_file.path,
            out = out.path,
        ),
        mnemonic = "RenderDebianTemplate",
        progress_message = "Rendering Debian template %{label}",
    )
    return [DefaultInfo(files = depset([out]))]

render_debian_template = rule(
    implementation = _render_debian_template_impl,
    attrs = {
        "kernel_sources": attr.label(
            mandatory = True,
            allow_files = True,
            doc = "Target whose DefaultInfo files include the template " +
                  "(typically @kernel_sources//:all).",
        ),
        "template_suffix": attr.string(
            mandatory = True,
            doc = "Path suffix to locate the template, e.g. " +
                  "'/debian/templates/image-unsigned.preinst.in'.",
        ),
        "substitutions": attr.string_dict(
            mandatory = True,
            doc = "Map of @variable@ -> value (without the @ delimiters).",
        ),
        "output_basename": attr.string(
            default = "",
            doc = "Output file basename; defaults to the target name.",
        ),
    },
)

# ---------------------------------------------------------------------------
# render_image_scripts — macro for the four image maintainer scripts
# ---------------------------------------------------------------------------

def render_image_scripts(
        name,
        kernel_sources,
        abiname,
        localversion,
        image_stem = "vmlinuz"):
    """Renders image-unsigned.{preinst,postinst,prerm,postrm}.in.

    Emits four ``render_debian_template`` targets named
    ``<name>_preinst``, ``<name>_postinst``, ``<name>_prerm``,
    ``<name>_postrm``.

    Args:
      name: name prefix for the four generated targets.
      kernel_sources: label for the kernel sources filegroup
        (e.g. ``@kernel_sources//:all``).
      abiname: e.g. ``"6.1.0-29"`` -- the ``@abiname@`` variable.
      localversion: e.g. ``"-2-amd64"`` -- the ``@localversion@`` variable.
        Combined with ``abiname`` this yields the ``version=`` line.
      image_stem: e.g. ``"vmlinuz"`` -- the ``@image-stem@`` variable.
    """
    subs = {
        "abiname": abiname,
        "localversion": localversion,
        "image-stem": image_stem,
    }
    for kind in ["preinst", "postinst", "prerm", "postrm"]:
        render_debian_template(
            name = name + "_" + kind,
            kernel_sources = kernel_sources,
            template_suffix = "/debian/templates/image-unsigned." + kind + ".in",
            substitutions = subs,
            output_basename = name + "_" + kind,
        )
