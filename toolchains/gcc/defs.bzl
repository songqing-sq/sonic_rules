"""Parameterized GCC toolchain registration macro.

One call to `sonic_gcc_toolchain()` generates a complete cc_toolchain with:
- Tool map (gcc, g++, ld, ar, objcopy, strip)
- Include args (GCC builtins + C++ stdlib + sysroot)
- Link args (sysroot lib paths + GCC lib paths)
- Binutils path (-B for assembler discovery)
- Sysroot (--sysroot)
- toolchain() rule with exec/target constraints

Usage in BUILD.bazel:
    load(":defs.bzl", "sonic_gcc_toolchain")

    sonic_gcc_toolchain(
        name = "linux_x86_64",
        gcc_repo = "@gcc-linux-x86_64",
        sysroot_repo = "@sysroot-bookworm//:directory",
        target_arch = "amd64",
    )
"""

load("@rules_cc//cc/toolchains:args.bzl", "cc_args")
load("@rules_cc//cc/toolchains:tool.bzl", "cc_tool")
load("@rules_cc//cc/toolchains:tool_map.bzl", "cc_tool_map")
load("@rules_cc//cc/toolchains:toolchain.bzl", "cc_toolchain")
load("@rules_cc//cc/toolchains/args:sysroot.bzl", "cc_sysroot")

# Debian arch → multiarch tuple (for usr/include/<multiarch> and usr/lib/<multiarch>)
_MULTIARCH = {
    "amd64": "x86_64-linux-gnu",
    "arm64": "aarch64-linux-gnu",
    "armhf": "arm-linux-gnueabihf",
}

# Debian arch → GCC binary prefix in the toolchain tarball
_GCC_PREFIX = {
    "amd64": "x86_64-linux",
    "arm64": "aarch64-linux",
    "armhf": "arm-linux-gnueabihf",
}

# Debian arch → Bazel @platforms//cpu value
_BAZEL_CPU = {
    "amd64": "x86_64",
    "arm64": "aarch64",
    "armhf": "armv7",
}

# exec_os → Bazel @platforms//os value
_BAZEL_OS = {
    "linux": "linux",
    "macos": "macos",
}

def sonic_gcc_toolchain(
        name,
        gcc_repo,
        sysroot_repo,
        target_arch,
        exec_arch = "amd64",
        exec_os = "linux",
        target_os = "linux",
        os_release_constraint = "//platform:bookworm",
        gcc_version = "12.5.0",
        binutils_have_prefix = None,
        visibility = ["//visibility:public"]):
    """Register a complete GCC cc_toolchain with one macro call.

    Args:
        name: Unique name for this toolchain. Also used as the toolchain() target name.
        gcc_repo: Label string of the fetched GCC distribution repo (e.g., "@gcc-linux-aarch64").
        sysroot_repo: Label string of the sysroot directory target
            (e.g., "@sysroot-bookworm//:directory").
        target_arch: Debian architecture of the TARGET ("amd64", "arm64", "armhf").
        exec_arch: Debian architecture of the EXEC/HOST platform (default "amd64").
        exec_os: OS of the exec platform ("linux" or "macos").
        target_os: OS of the target platform (default "linux").
        os_release_constraint: Custom constraint label for the Debian release.
            Set to None to omit.
        gcc_version: GCC version string (used for include path construction).
        visibility: Visibility of the generated toolchain() target.
    """
    prefix = _GCC_PREFIX[target_arch]
    multiarch = _MULTIARCH[target_arch]

    # In cross-compiler distributions, ALL tools have the target prefix
    # (e.g., aarch64-linux-strip). In native distributions, only gcc/g++/gcc-ar
    # have the prefix; binutils (strip, objcopy, ld) are unprefixed.
    _have_prefix = binutils_have_prefix if binutils_have_prefix != None else (target_arch != exec_arch)
    binutils_prefix = prefix + "-" if _have_prefix else ""

    # --- Tool definitions ---
    cc_tool(
        name = name + "_gcc",
        src = gcc_repo + "//:bin/" + prefix + "-gcc",
        capabilities = ["@rules_cc//cc/toolchains/capabilities:supports_pic"],
        data = [
            name + "_builtin_headers",
            name + "_binutils",
            name + "_multicall",
        ],
        tags = ["manual"],
    )

    cc_tool(
        name = name + "_g++",
        src = gcc_repo + "//:bin/" + prefix + "-g++",
        capabilities = ["@rules_cc//cc/toolchains/capabilities:supports_pic"],
        data = [
            name + "_builtin_headers",
            name + "_binutils",
            name + "_multicall",
        ],
        tags = ["manual"],
    )

    cc_tool(
        name = name + "_ld",
        src = gcc_repo + "//:bin/" + prefix + "-g++",
        data = [name + "_binutils", name + "_multicall"],
        tags = ["manual"],
    )

    cc_tool(
        name = name + "_ar",
        src = gcc_repo + "//:bin/" + prefix + "-gcc-ar",
        tags = ["manual"],
    )

    cc_tool(
        name = name + "_objcopy",
        src = gcc_repo + "//:bin/" + binutils_prefix + "objcopy",
        tags = ["manual"],
    )

    cc_tool(
        name = name + "_strip",
        src = gcc_repo + "//:bin/" + binutils_prefix + "strip",
        tags = ["manual"],
    )

    # --- Data aliases (decouple from gcc_repo label) ---
    native.alias(name = name + "_builtin_headers", actual = gcc_repo + "//:builtin_headers", tags = ["manual"])
    native.alias(name = name + "_binutils", actual = gcc_repo + "//:linker_builtins", tags = ["manual"])
    native.alias(name = name + "_multicall", actual = gcc_repo + "//:multicall_support_files", tags = ["manual"])

    # --- Tool map ---
    cc_tool_map(
        name = name + "_tool_map",
        tags = ["manual"],
        tools = {
            "@rules_cc//cc/toolchains/actions:ar_actions": name + "_ar",
            "@rules_cc//cc/toolchains/actions:assembly_actions": name + "_gcc",
            "@rules_cc//cc/toolchains/actions:c_compile": name + "_gcc",
            "@rules_cc//cc/toolchains/actions:cpp_compile_actions": name + "_g++",
            "@rules_cc//cc/toolchains/actions:link_actions": name + "_ld",
            "@rules_cc//cc/toolchains/actions:objcopy_embed_data": name + "_objcopy",
            "@rules_cc//cc/toolchains/actions:strip": name + "_strip",
        },
        visibility = ["//visibility:private"],
    )

    # --- cc_args ---
    _format_dict = {
        "gcc": gcc_repo + "//:builtin_headers",
        "sysroot": sysroot_repo,
    }

    # Binutils path: -B <gcc>/bin/<prefix>- so GCC finds its assembler/linker
    # even with -no-canonical-prefixes.
    _binutils_format = {"gcc": gcc_repo + "//:builtin_headers"}
    cc_args(
        name = name + "_binutils_path",
        actions = [
            "@rules_cc//cc/toolchains/actions:compile_actions",
            "@rules_cc//cc/toolchains/actions:link_actions",
        ],
        args = ["-B", "{gcc}/bin/" + prefix + "-"],
        data = _binutils_format.values(),
        format = _binutils_format,
        visibility = ["//visibility:private"],
    )

    # Include paths: GCC builtins + C++ stdlib + sysroot
    cc_args(
        name = name + "_includes",
        actions = ["@rules_cc//cc/toolchains/actions:compile_actions"],
        args = [
            "-isystem", "{gcc}/lib/gcc/" + prefix + "/" + gcc_version + "/include",
            "-idirafter", "{gcc}/" + prefix + "/include/c++/" + gcc_version,
            "-idirafter", "{gcc}/" + prefix + "/include/c++/" + gcc_version + "/" + prefix,
            "-idirafter", "{sysroot}/usr/include/" + multiarch,
            "-idirafter", "{sysroot}/usr/include",
        ],
        data = _format_dict.values(),
        format = _format_dict,
        visibility = ["//visibility:private"],
    )

    # Link paths: sysroot libs + GCC runtime libs.
    # Use the joined flag form (-B<path>/-L<path>/-Wl,-rpath-link,<path>) rather
    # than space-separated pairs. gcc/ld accept both, but autotools' libtool
    # (--mode=link) rejects a space between -L and its argument ("require no
    # space between '-L' and ..."), which breaks any configure_make component
    # whose shared libs link through libtool (e.g. thrift). The joined form is
    # the canonical autotools-compatible spelling and behaves identically for
    # all other (non-libtool) link actions.
    cc_args(
        name = name + "_links",
        actions = ["@rules_cc//cc/toolchains/actions:link_actions"],
        args = [
            "-B{sysroot}/usr/lib/" + multiarch,
            "-L{sysroot}/usr/lib/" + multiarch,
            "-B{sysroot}/lib/" + multiarch,
            "-L{sysroot}/lib/" + multiarch,
            "-L{gcc}/lib/gcc/" + prefix + "/" + gcc_version,
            "-L{gcc}/" + prefix + "/lib64",
            "-Wl,-rpath-link,{sysroot}/lib/" + multiarch,
            "-Wl,-rpath-link,{sysroot}/usr/lib/" + multiarch,
            "-Wl,--build-id",
        ],
        data = _format_dict.values(),
        format = _format_dict,
        visibility = ["//visibility:private"],
    )

    # Sysroot
    cc_sysroot(
        name = name + "_sysroot",
        data = [sysroot_repo],
        sysroot = sysroot_repo,
        visibility = ["//visibility:private"],
    )

    # --- cc_toolchain ---
    cc_toolchain(
        name = name + "_cc_toolchain",
        args = [
            "//toolchains/args:no_absolute_paths_for_builtins",
            "//toolchains/args:warnings",
            name + "_binutils_path",
            name + "_includes",
            name + "_links",
            name + "_sysroot",
        ],
        compiler = "gcc",
        enabled_features = [
            "@rules_cc//cc/toolchains/args:experimental_replace_legacy_action_config_features",
        ],
        known_features = [
            "@rules_cc//cc/toolchains/args:experimental_replace_legacy_action_config_features",
            "//toolchains/args:opt_compile_flags_feature",
            "//toolchains/args:dbg_compile_flags_feature",
        ],
        tags = ["manual"],
        tool_map = name + "_tool_map",
    )

    # --- toolchain() ---
    exec_constraints = [
        "@platforms//os:" + _BAZEL_OS[exec_os],
        "@platforms//cpu:" + _BAZEL_CPU[exec_arch],
    ]
    target_constraints = [
        "@platforms//os:" + _BAZEL_OS[target_os],
        "@platforms//cpu:" + _BAZEL_CPU[target_arch],
    ]
    if os_release_constraint:
        target_constraints.append(os_release_constraint)

    native.toolchain(
        name = name,
        exec_compatible_with = exec_constraints,
        target_compatible_with = target_constraints,
        toolchain = name + "_cc_toolchain",
        toolchain_type = "@bazel_tools//tools/cpp:toolchain_type",
        visibility = visibility,
    )
