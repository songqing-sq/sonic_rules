"""Hermetic host-tool resolution for the kernel config + build actions.

Adapted from the reference SONiC kernel port, but every tool is repointed at
THIS repo's hermetic sources:

  - make .............. //kernel_host_tools:make (source-built GNU make 4.4.1
                        cc_binary — a single executable, built natively from a
                        tarball, not via a foreign-build rule).
  - bc/depmod/cpio/
    pahole ............ //kernel_host_tools:{bc,depmod,cpio,pahole}
  - flex/bison/m4 ..... rules_flex / rules_bison / rules_m4 toolchains, surfaced
                        as //kernel/tools:{flex,bison,m4}_bin via the resolve_* rules.
  - perl .............. rules_perl toolchain via //kernel/tools:perl_bin.
  - libelf/libdw/zlib . //kernel_host_tools:{elf,dw,z}
                        (source-built cc_library CcInfo targets).

All tool/library attrs use `cfg = "exec"` so they are built for the execution
platform, matching HOSTCC's expectations. `host_tools_env(ctx)` returns a shell
env-setup string (PATH / MAKE / M4 / BISON_PKGDATADIR / C_INCLUDE_PATH /
LIBRARY_PATH / KBUILD_HOSTLDFLAGS) plus the list of input Files to stage.
"""

load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")

FLEX_TOOLCHAIN_TYPE = "@rules_flex//flex:toolchain_type"
BISON_TOOLCHAIN_TYPE = "@rules_bison//bison:toolchain_type"
M4_TOOLCHAIN_TYPE = "@rules_m4//m4:toolchain_type"
PERL_TOOLCHAIN_TYPE = "@rules_perl//perl:toolchain_type"

# ---------------------------------------------------------------------------
# Toolchain binary extractors (flex / bison / m4 / perl)
# ---------------------------------------------------------------------------

def _resolve_flex_impl(ctx):
    tc = ctx.toolchains[FLEX_TOOLCHAIN_TYPE].flex_toolchain
    return [DefaultInfo(
        files = depset([tc.flex_tool.executable]),
        runfiles = ctx.runfiles(transitive_files = tc.all_files),
    )]

resolve_flex = rule(
    implementation = _resolve_flex_impl,
    toolchains = [FLEX_TOOLCHAIN_TYPE],
)

def _resolve_bison_impl(ctx):
    tc = ctx.toolchains[BISON_TOOLCHAIN_TYPE].bison_toolchain
    return [DefaultInfo(
        files = depset([tc.bison_tool.executable]),
        runfiles = ctx.runfiles(transitive_files = tc.all_files),
    )]

resolve_bison = rule(
    implementation = _resolve_bison_impl,
    toolchains = [BISON_TOOLCHAIN_TYPE],
)

def _resolve_m4_impl(ctx):
    tc = ctx.toolchains[M4_TOOLCHAIN_TYPE].m4_toolchain
    return [DefaultInfo(
        files = depset([tc.m4_tool.executable]),
        runfiles = ctx.runfiles(transitive_files = tc.all_files),
    )]

resolve_m4 = rule(
    implementation = _resolve_m4_impl,
    toolchains = [M4_TOOLCHAIN_TYPE],
)

def _resolve_perl_impl(ctx):
    tc = ctx.toolchains[PERL_TOOLCHAIN_TYPE].perl_runtime
    return [DefaultInfo(
        files = depset([tc.interpreter]),
        runfiles = ctx.runfiles(transitive_files = tc.runtime),
    )]

resolve_perl = rule(
    implementation = _resolve_perl_impl,
    toolchains = [PERL_TOOLCHAIN_TYPE],
)

# ---------------------------------------------------------------------------
# Host tool attrs shared by debian_kernel_config + kernel_build
# ---------------------------------------------------------------------------

HOST_TOOL_ATTRS = {
    "_flex": attr.label(default = "//kernel/tools:flex_bin", cfg = "exec"),
    "_bison": attr.label(default = "//kernel/tools:bison_bin", cfg = "exec"),
    "_m4": attr.label(default = "//kernel/tools:m4_bin", cfg = "exec"),
    "_perl": attr.label(default = "//kernel/tools:perl_bin", cfg = "exec"),
    "_bc": attr.label(default = "//kernel_host_tools:bc", cfg = "exec"),
    "_depmod": attr.label(default = "//kernel_host_tools:depmod", cfg = "exec"),
    "_cpio": attr.label(default = "//kernel_host_tools:cpio", cfg = "exec"),
    "_pahole": attr.label(default = "//kernel_host_tools:pahole", cfg = "exec"),
    "_make": attr.label(default = "//kernel_host_tools:make", cfg = "exec", executable = True),
    "_libelf": attr.label(default = "//kernel_host_tools:elf", cfg = "exec", providers = [CcInfo]),
    "_libdw": attr.label(default = "//kernel_host_tools:dw", cfg = "exec", providers = [CcInfo]),
    "_zlib": attr.label(default = "//kernel_host_tools:z", cfg = "exec", providers = [CcInfo]),
}

# ---------------------------------------------------------------------------
# Shell env builder
# ---------------------------------------------------------------------------

def _bin_dir(f):
    """Return the directory containing a File, for PATH injection."""
    return f.path.rsplit("/", 1)[0] if "/" in f.path else "."

def host_tools_env(ctx):
    """Build the shell env-setup string and collect input files.

    Returns:
        (env_string, input_files): the shell export commands and the list of
        File objects to add to the action inputs.
    """
    tool_files = []
    path_dirs = []

    # Executable tools (flex/bison/m4/perl/bc/depmod/cpio/pahole).
    m4_path = None
    bison_pkgdatadir = None
    for attr_name in ["_flex", "_bison", "_m4", "_perl", "_bc", "_depmod", "_cpio", "_pahole"]:
        target = getattr(ctx.attr, attr_name, None)
        if target == None:
            continue
        files = target[DefaultInfo].files.to_list()
        tool_files.extend(files)
        tool_name = attr_name.lstrip("_")
        for f in files:
            basename = f.path.rsplit("/", 1)[-1] if "/" in f.path else f.path
            if basename == tool_name or (tool_name == "depmod" and basename == "kmod"):
                path_dirs.append(_bin_dir(f))
                if attr_name == "_m4":
                    m4_path = f.path
                break
        rf = target[DefaultInfo].default_runfiles
        if rf:
            rf_files = rf.files.to_list()
            tool_files.extend(rf_files)
            if attr_name == "_bison":
                for f in rf_files:
                    if f.path.endswith("/m4sugar/m4sugar.m4"):
                        bison_pkgdatadir = f.path.rsplit("/m4sugar/", 1)[0]
                        break

    # Libraries: source-built cc_library targets (libelf, libdw, zlib).
    include_dirs = []
    lib_dirs = []
    for attr_name in ["_libelf", "_libdw", "_zlib"]:
        target = getattr(ctx.attr, attr_name, None)
        if target == None:
            continue
        files = target[DefaultInfo].files.to_list()
        tool_files.extend(files)

        cc_info = target[CcInfo]
        for d in cc_info.compilation_context.system_includes.to_list():
            if d and d not in include_dirs:
                include_dirs.append(d)
        for d in cc_info.compilation_context.includes.to_list():
            if d and d not in include_dirs:
                include_dirs.append(d)
        tool_files.extend(cc_info.compilation_context.headers.to_list())
        for li in cc_info.linking_context.linker_inputs.to_list():
            for lib in li.libraries:
                f = lib.static_library or lib.pic_static_library or lib.dynamic_library
                if f:
                    tool_files.append(f)
                    d = f.path.rsplit("/", 1)[0] if "/" in f.path else "."
                    if d not in lib_dirs:
                        lib_dirs.append(d)

    # make: our source-built single binary. ctx.executable._make is the binary.
    make_path = None
    make_exe = getattr(ctx.executable, "_make", None)
    if make_exe != None:
        make_path = make_exe.path
        tool_files.append(make_exe)
        path_dirs.append(_bin_dir(make_exe))

    # Prefix $PWD so paths resolve after `cd` into temp dirs.
    abs = lambda d: "$PWD/" + d
    path_str = ":".join([abs(d) for d in path_dirs]) if path_dirs else ""
    include_str = ":".join([abs(d) for d in include_dirs]) if include_dirs else ""
    lib_str = ":".join([abs(d) for d in lib_dirs]) if lib_dirs else ""

    env_lines = []
    if path_str:
        env_lines.append('export PATH="{}:${{PATH:-/usr/bin:/bin}}"'.format(path_str))
    else:
        env_lines.append('export PATH="/usr/bin:/bin:${PATH:-}"')
    if make_path:
        env_lines.append('export MAKE="$PWD/{}"'.format(make_path))
    else:
        env_lines.append("export MAKE=/usr/bin/make")
    if m4_path:
        env_lines.append('export M4="$PWD/{}"'.format(m4_path))
    if bison_pkgdatadir:
        env_lines.append('export BISON_PKGDATADIR="$PWD/{}"'.format(bison_pkgdatadir))
    if include_str:
        env_lines.append('export C_INCLUDE_PATH="{}"'.format(include_str))
    if lib_str:
        env_lines.append('export LIBRARY_PATH="{}"'.format(lib_str))
    env_lines.append('export KBUILD_HOSTLDFLAGS="-Wl,--whole-archive -l:liblibeu.a -Wl,--no-whole-archive -lz"')
    # Remove .so from LIBRARY_PATH dirs so the linker uses .a (avoids libeu
    # symbol issue when both are present).
    if lib_dirs:
        env_lines.append("find {} -name '*.so' -delete 2>/dev/null || true".format(
            " ".join(["$PWD/" + d for d in lib_dirs]),
        ))

    return "\n".join(env_lines), tool_files
