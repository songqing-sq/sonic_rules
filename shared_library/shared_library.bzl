load("@rules_cc//cc:cc_import.bzl", "cc_import")
load("@rules_cc//cc:cc_library.bzl", "cc_library")
load("@rules_cc//cc:cc_shared_library.bzl", "cc_shared_library")
load("@rules_cc//cc:defs.bzl", "CcInfo", "cc_common")
load("@rules_cc//cc:find_cc_toolchain.bzl", "CC_TOOLCHAIN_TYPE", "find_cc_toolchain", "use_cc_toolchain")
load("@rules_cc//cc/common:cc_shared_library_info.bzl", "CcSharedLibraryInfo")
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

    result = [
        DefaultInfo(files = depset(files)),
        SymlinkInfo(dest = "", extra_dest = symlink_dest),
    ]

    # Transparently forward CcSharedLibraryInfo from the dedicated cc_shared_lib attr
    if ctx.attr.cc_shared_lib and CcSharedLibraryInfo in ctx.attr.cc_shared_lib:
        result.append(ctx.attr.cc_shared_lib[CcSharedLibraryInfo])
    return result

shared_lib_files_rule = rule(
    implementation = _shared_lib_files_impl,
    attrs = {
        "srcs": attr.label_list(),
        "cc_shared_lib": attr.label(providers = [CcSharedLibraryInfo]),
    },
)

symlink_to_path = rule(
    implementation = _symlink_to_path_impl,
    attrs = {
        "target_path": attr.string(mandatory = True),
        "output": attr.string(mandatory = True),
    },
)

def _static_archive_impl(ctx):
    """Extract the (PIC) static library .a from a cc_library's CcInfo and copy it
    to a deterministically-named output (lib<output_name>.a) for -dev packaging."""
    cc_info = ctx.attr.lib[CcInfo]
    archive = None
    for li in cc_info.linking_context.linker_inputs.to_list():
        for lib in li.libraries:
            if lib.pic_static_library:
                archive = lib.pic_static_library
                break
            if lib.static_library:
                archive = lib.static_library
                break
        if archive:
            break
    if not archive:
        fail("no static archive found in {}".format(ctx.attr.lib.label))

    out = ctx.actions.declare_file(ctx.attr.output_name + ".a")
    ctx.actions.run_shell(
        inputs = [archive],
        outputs = [out],
        command = "cp \"$1\" \"$2\"",
        arguments = [archive.path, out.path],
    )
    return [DefaultInfo(files = depset([out]))]

static_archive = rule(
    implementation = _static_archive_impl,
    doc = "Extract the static .a from a cc_library and rename it lib<output_name>.a.",
    attrs = {
        "lib": attr.label(mandatory = True, providers = [CcInfo]),
        "output_name": attr.string(mandatory = True),
    },
)

def _version_script_flags(version_script):
    """Return (extra user_link_flags, additional_linker_inputs) for an optional
    linker version script. The flag uses $(location) so cc_shared_library expands
    it to the execpath of the version-script file."""
    if not version_script:
        return [], []
    return ["-Wl,--version-script=$(location {})".format(version_script)], [version_script]

def _sonic_shared_library_impl(name, visibility, dynamic_deps, deps, objects, srcs, output_name, exports_filter, version_script, allow_undefined, **kwargs):
    if not output_name:
        output_name = "lib" + name

    vscript_flags, vscript_inputs = _version_script_flags(version_script)

    # Python C extensions (and other dlopened plugins) legitimately leave
    # interpreter-provided symbols undefined; -Wl,-z,defs must be dropped there.
    defs_flags = [] if allow_undefined else ["-Wl,-z,defs"]

    cc_library(
        name = name,
        srcs = srcs,
        deps = deps + objects,
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
        name = name + "_shared",
        deps = [":" + name] + objects,
        dynamic_deps = dynamic_deps,
        exports_filter = exports_filter,
        additional_linker_inputs = vscript_inputs,
        user_link_flags = select({
            "@platforms//os:linux": [
                "-Wl,-soname," + output_name + ".so",
            ] + defs_flags + vscript_flags,
            "//conditions:default": [],
        }),
        shared_lib_name = output_name + ".so",
        visibility = visibility,
    )

def _sonic_shared_library_versioned_impl(name, visibility, dynamic_deps, deps, objects, srcs, soversion, version, output_name, exports_filter, version_script, allow_undefined, **kwargs):
    if not output_name:
        output_name = "lib" + name

    vscript_flags, vscript_inputs = _version_script_flags(version_script)

    defs_flags = [] if allow_undefined else ["-Wl,-z,defs"]

    cc_library(
        name = name,
        srcs = srcs,
        deps = deps + objects,
        visibility = visibility,
        **kwargs
    )

    cc_shared_library(
        name = name + "_shared",
        deps = [":" + name] + objects,
        dynamic_deps = dynamic_deps,
        exports_filter = exports_filter,
        additional_linker_inputs = vscript_inputs,
        user_link_flags = select({
            "@platforms//os:linux": [
                "-Wl,-soname," + output_name + ".so." + soversion,
            ] + defs_flags + vscript_flags,
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
        visibility = visibility,
    )
    symlink_to_path(
        name = name + "_dev_link",
        output = output_name + ".so",
        target_path = output_name + ".so." + soversion,
        visibility = visibility,
    )
    # `_dev_link_direct` mirrors libtool/Debian convention where the dev .so
    # symlink points directly at the real .so.<full_version> file (skipping the
    # soname hop). Downstream sonic_deb users that need byte-exact equivalence
    # to Debian's lib*-dev packages should depend on this instead of _dev_link.
    symlink_to_path(
        name = name + "_dev_link_direct",
        output = "direct/" + output_name + ".so",
        target_path = output_name + ".so." + version,
        visibility = visibility,
    )
    shared_lib_files_rule(
        name = name + "_files",
        srcs = [name + "_shared", name + "_version_link"],
        cc_shared_lib = name + "_shared",
        visibility = visibility,
    )

sonic_shared_library = macro(
    inherit_attrs = _cc_library_rule,
    attrs = {
        "dynamic_deps": attr.label_list(),
        "exports_filter": attr.string_list(),
        "srcs": attr.label_list(),
        "deps": attr.label_list(),
        "objects": attr.label_list(),
        "output_name": attr.string(configurable = False),
        "version_script": attr.label(allow_single_file = True, configurable = False),
        "allow_undefined": attr.bool(default = False, configurable = False),
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
        "objects": attr.label_list(),
        "soversion": attr.string(configurable = False),
        "version": attr.string(configurable = False),
        "output_name": attr.string(configurable = False),
        "version_script": attr.label(allow_single_file = True, configurable = False),
        "allow_undefined": attr.bool(default = False, configurable = False),
    },
    implementation = _sonic_shared_library_versioned_impl,
)
