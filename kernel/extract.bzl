"""Small wrapper rules that expose individual KernelBuildInfo fields as
standalone targets (so debs / boot_tar can depend on just one artifact)."""

load("//kernel:providers.bzl", "KernelBuildInfo")

def _file_impl(ctx):
    info = ctx.attr.kernel_build[KernelBuildInfo]
    f = getattr(info, ctx.attr.which)
    return [DefaultInfo(files = depset([f]))]

kernel_file = rule(
    implementation = _file_impl,
    attrs = {
        "kernel_build": attr.label(mandatory = True, providers = [KernelBuildInfo]),
        "which": attr.string(mandatory = True),
    },
)

def _tree_impl(ctx):
    info = ctx.attr.kernel_build[KernelBuildInfo]
    t = getattr(info, ctx.attr.which)
    return [DefaultInfo(files = depset([t]))]

kernel_tree = rule(
    implementation = _tree_impl,
    attrs = {
        "kernel_build": attr.label(mandatory = True, providers = [KernelBuildInfo]),
        "which": attr.string(mandatory = True),
    },
)
