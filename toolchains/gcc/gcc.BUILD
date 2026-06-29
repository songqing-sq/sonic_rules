load("@bazel_skylib//rules/directory:directory.bzl", "directory")

package(default_visibility = ["//visibility:public"])

licenses(["notice"])

exports_files(glob(["bin/**"]))

directory(
    name = "toolchain_root",
    srcs = glob(["lib/**", "include/**", "*/include/**"], allow_empty = True),
)

directory(
    name = "builtin_headers",
    srcs = glob(
        [
            "include/**",
            "*/include/**",
            "lib/gcc/*/*/include/**",
            "lib/gcc/*/*/include-fixed/**",
        ],
        allow_empty = True,
    ),
)

filegroup(
    name = "linker_builtins",
    data = glob(
        [
            "bin/*ld*",
            # GCC's internal linker (collect2 resolves bare `ld` to
            # <gcc>/<target>/bin/ld). The native cc rules reach it via the gcc
            # driver's hard-coded search, but tools that invoke the driver
            # outside Bazel's link action (e.g. autotools ./configure under
            # rules_foreign_cc) need it explicitly staged, or collect2 fails
            # with "cannot find 'ld'" when cross-compiling.
            "*/bin/ld*",
            "bin/*-as",
            "bin/as",
            "*/bin/as",
            # GCC runtime libs (libgcc_s, libatomic, ...) live under various
            # lib/lib64 dirs depending on the toolchain layout: top-level lib/
            # and lib64/, and <target>/lib*/. Needed by tools that link via the
            # bare driver (rules_foreign_cc autotools builds) where Bazel does
            # not inject them through the link action.
            "lib*/**/*.a",
            "lib*/**/*.so*",
            "lib*/**/*.o",
            "*/lib*/**/*.a",
            "*/lib*/**/*.so*",
            "*/lib*/**/*.o",
        ],
        allow_empty = True,
    ),
)

filegroup(
    name = "multicall_support_files",
    srcs = glob(["libexec/**/*"]),
)

# Everything in the distribution (driver wrappers + real binaries, cc1/cc1plus,
# all libs/headers/binutils). Used by the kernel_build action which invokes the
# gcc driver outside Bazel's cc link action and therefore needs the full tree.
filegroup(
    name = "all_files",
    srcs = glob(
        [
            "bin/**",
            "libexec/**",
            "lib/**",
            "lib64/**",
            "include/**",
            "*/**",
        ],
        allow_empty = True,
    ),
)
