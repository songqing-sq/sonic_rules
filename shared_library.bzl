
load("@rules_cc//cc:cc_library.bzl", "cc_library")
load("@rules_cc//cc:cc_shared_library.bzl", "cc_shared_library")
load("@rules_cc//cc/private/rules_impl:cc_library.bzl", _cc_library_rule = "cc_library")

SymlinkInfo = provider(
    fields = {
        "dest": "Destination of the symlink",
        "extra_dest": "A dict mapping file path to symlink destination",
    },
)

def _symlink_to_path_impl(ctx):

    symlink = ctx.actions.declare_symlink(ctx.attr.output)

    ctx.actions.symlink(
        output = symlink,
        target_path = ctx.attr.target_path,
    )

    return [
        DefaultInfo(files = depset([symlink])),
        SymlinkInfo(dest = ctx.attr.target_path, extra_dest = {}),
    ]

def _shared_lib_files_impl(ctx):
    files = []
    symlink_dest = {}
    for src in ctx.attr.srcs:
        files.extend(src.files.to_list())
        if SymlinkInfo in src:
            for f in src.files.to_list():
                 symlink_dest[f.path] = src[SymlinkInfo].dest
    
    return [
        DefaultInfo(files = depset(files)),
        SymlinkInfo(dest = "", extra_dest = symlink_dest) # 借用 SymlinkInfo 传递
    ]

shared_lib_files_rule = rule(
    implementation = _shared_lib_files_impl,
    attrs = {
        "srcs": attr.label_list(),
    },
)

symlink_to_path = rule(
    implementation = _symlink_to_path_impl,
    attrs = {
        "target_path": attr.string(mandatory = True),
        "output": attr.string(mandatory = True),
    },
)


def _sonic_shared_library_impl(name, visibility, dynamic_deps, deps, srcs, output_name, exports_filter, **kwargs):
    if not output_name:
        output_name = "lib" + name

    cc_library(
        name = name + "_objs",
        srcs = srcs,
        deps = deps,
        visibility = visibility,
        **kwargs
    )

    cc_library(
        name = name + "_hdrs",
        hdrs = kwargs.get("hdrs", []),
        includes = kwargs.get("includes", []),
        visibility = visibility,
    )

    cc_shared_library(
        name = name,
        deps = [":" + name + "_objs"],
        dynamic_deps = dynamic_deps,
        exports_filter = exports_filter,
        user_link_flags = select({
            "@platforms//os:linux": [
                "-Wl,-soname," + output_name + ".so",
                "-Wl,-z,defs",
            ],
            "//conditions:default": [],
        }),
        shared_lib_name = output_name + ".so",
        visibility = visibility,
    )

def _sonic_shared_library_versioned_impl(name, visibility, dynamic_deps, deps, srcs, soversion, version, output_name, exports_filter, **kwargs):

    if not output_name:
        output_name = "lib" + name

    cc_library(
        name = name + "_objs",
        srcs = srcs,
        deps = deps,
        visibility = visibility,
        **kwargs
    )

    cc_shared_library(
        name = name,
        deps = [":" + name + "_objs"],
        dynamic_deps = dynamic_deps,
        exports_filter = exports_filter,
        user_link_flags = select({
            "@platforms//os:linux": [
                "-Wl,-soname," + output_name + ".so." + soversion,
                "-Wl,-z,defs",
            ],
            "//conditions:default": [],
        }),
        shared_lib_name = output_name + ".so." + version,
        visibility = visibility,
    )

    cc_library(
        name = name + "_hdrs",
        hdrs = kwargs.get("hdrs", []),
        includes = kwargs.get("includes", []),
        visibility = visibility,
    )
    native.filegroup(
        name = name + "_hdr_files",
        srcs = kwargs.get("hdrs", []),
        visibility = visibility,
    )
    symlink_to_path(
        name = name + "_version_link",
        output = output_name + ".so." + soversion,
        target_path = output_name + ".so." + version,
    )
    symlink_to_path(
        name = name + "_dev_link",
        output = output_name + ".so",
        target_path = output_name + ".so." + soversion,
        visibility = visibility,
    )
    shared_lib_files_rule(
        name = name + "_files",
        srcs = [name, name + "_version_link"],
        visibility = visibility,
    )

sonic_shared_library = macro(
    inherit_attrs = _cc_library_rule,
    attrs = {
        "dynamic_deps": attr.label_list(),
        "exports_filter": attr.string_list(),
        "srcs": attr.label_list(),
        "deps": attr.label_list(),
        "output_name": attr.string(configurable = False),
    },
    implementation = _sonic_shared_library_impl,
)

sonic_shared_library_versioned = macro(
    inherit_attrs = _cc_library_rule,
    attrs = {
        "dynamic_deps": attr.label_list(),
        "exports_filter": attr.string_list(),
        "srcs": attr.label_list(),
        "deps": attr.label_list(),
        "soversion": attr.string(configurable = False),
        "version": attr.string(configurable = False),
        "output_name": attr.string(configurable = False),
    },
    implementation = _sonic_shared_library_versioned_impl,
)