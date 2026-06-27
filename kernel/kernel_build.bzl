"""kernel_build: the single sanctioned Bazel->make boundary for the SONiC port.

This rule is the Kleaf-equivalent typed boundary (per FR-008): it is the ONLY
place in the Bazel graph permitted to invoke `make`. It runs Kbuild against the
patched + configured source tree, producing the kernel image, vmlinux,
System.map, the .config actually used, and the installed-modules tree
(`make modules_install`).

`make` is OUR source-built GNU make (host_tools_env exports `$MAKE`), NOT a host
/usr/bin/make. Host tools (bc/depmod/cpio/pahole) and host libraries
(libelf/libdw/zlib) are injected via host_tools_env as `cfg=exec` inputs.

Toolchain split (per references/kernel.md):
  CC/LD/AR/STRIP  = sonic_rules' pinned GCC 12.5.0       (kernel TARGET objects)
  HOSTCC/HOSTLD   = Bazel exec cc toolchain (gcc/ld/ar)  (Kbuild host tools)
"""

load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cc_toolchain", "use_cc_toolchain")
load("//kernel:host_tools.bzl", "HOST_TOOL_ATTRS", "host_tools_env")
load("//kernel:providers.bzl", "KernelBuildInfo", "KernelConfigInfo")
load("//kernel:toolchain_gcc.bzl", "resolve_gcc_driver")

def _impl(ctx):
    src = ctx.attr.kernel_sources
    src_files = src[DefaultInfo].files
    config_info = ctx.attr.config[KernelConfigInfo]
    config = config_info.config
    kernelvariables = config_info.kernel_variables

    # Pahole is consumed via host_tools_env (PATH); the others too.
    host_env, host_tool_files = host_tools_env(ctx)

    # Pinned GCC toolchain, resolved from the target platform via Bazel toolchain
    # resolution (no per-arch dict). all_files carries the full distribution
    # (driver wrapper + real binaries, cc1/cc1plus, builtin headers, runtime libs,
    # binutils); the real driver File is located inside it.
    cc_toolchain = find_cc_toolchain(ctx)
    gcc_files = cc_toolchain.all_files
    gcc_driver = resolve_gcc_driver(cc_toolchain)

    # HOSTCC/HOSTCXX/HOSTLD/HOSTAR for Kbuild's host tools (fixdep/conf/modpost)
    # come from Bazel's exec-configuration cc toolchain — declarative and
    # replaceable, not a hardcoded /usr/bin/*. On the auto-detected host
    # (@local_config_cc) these resolve to /usr/bin/{gcc,g++,ld,ar}; whatever the
    # exec platform's registered toolchain provides is what gets used.
    exec_cc = ctx.attr._exec_cc_toolchain[cc_common.CcToolchainInfo]
    host_cc = exec_cc.compiler_executable
    host_ld = exec_cc.ld_executable
    host_ar = exec_cc.ar_executable
    # CcToolchainInfo has no c++ field; the C++ driver lives next to the C one.
    host_cxx = host_cc.rsplit("/", 1)[0] + "/g++"
    exec_cc_files = exec_cc.all_files

    arch = ctx.attr.arch  # amd64 / arm64
    # KERNEL_ARCH (linux/arch/<X>/ subdir name) derived from the Debian arch.
    _karch_by_arch = {"amd64": "x86", "arm64": "arm64", "armhf": "arm"}
    if arch not in _karch_by_arch:
        fail("kernel_build: unsupported arch %r" % arch)
    karch = _karch_by_arch[arch]

    # CROSS_COMPILE: the resolved gcc driver (CC=<driver>) handles compilation,
    # but Kbuild's LD/AS/AR/NM/OBJCOPY default to the bare host binutils unless
    # CROSS_COMPILE is set — and the host x86_64 binutils cannot link/assemble
    # arm64 objects (e.g. "ld: unrecognised emulation mode: aarch64linux").
    # The prefix is derived from the resolved driver, no per-arch dict:
    #   triple = basename(gcc_driver) minus the trailing "-gcc"
    #   prefix = <dirname(gcc_driver)>/<triple>-
    # The cross (aarch64) distro bundles <triple>-{ld,as,ar,...} alongside the
    # driver, so this prefix routes Kbuild to the target binutils. The native
    # (x86_64) distro instead ships its binutils UNPREFIXED (bare ld/as/...),
    # which the gcc driver finds via COMPILER_PATH; there is no x86_64-linux-ld,
    # so CROSS_COMPILE must stay empty. The script picks empty-vs-prefixed by
    # probing for <prefix>ld at action time — driven by the toolchain's actual
    # contents, not by arch.
    triple = gcc_driver.basename[:-len("-gcc")]
    cross_compile = gcc_driver.dirname + "/" + triple + "-"
    kversion = ctx.attr.kversion  # 6.1.0-29-2-amd64
    image = ctx.attr.kernel_image  # bzImage

    # Declared outputs.
    out_image = ctx.actions.declare_file(ctx.label.name + "/" + image)
    out_vmlinux = ctx.actions.declare_file(ctx.label.name + "/vmlinux")
    out_sysmap = ctx.actions.declare_file(ctx.label.name + "/System.map")
    out_config = ctx.actions.declare_file(ctx.label.name + "/.config.used")
    out_release = ctx.actions.declare_file(ctx.label.name + "/kernel.release")
    out_modules = ctx.actions.declare_directory(ctx.label.name + "/modules_install")
    out_builddata = ctx.actions.declare_directory(ctx.label.name + "/build_data")

    build_root = ctx.attr.kernel_src_dir

    # Derive the @kernel_sources root dir (execroot-relative) from any file.
    marker = "/" + build_root + "/"
    first = src_files.to_list()[0].path
    idx = first.find(marker)
    if idx < 0:
        fail("kernel_build: cannot locate '%s' in source path %s" % (build_root, first))
    src_root = first[:idx]

    script = ctx.actions.declare_file(ctx.label.name + "_build.sh")
    ctx.actions.write(
        output = script,
        is_executable = True,
        content = """#!/bin/bash
set -euo pipefail

EXECROOT="$(pwd)"
NPROC="$(nproc)"

# Host tool env: exports $MAKE (our source-built GNU make), PATH (bc/depmod/
# cpio/pahole), C_INCLUDE_PATH / LIBRARY_PATH (libelf/libdw/zlib) and
# KBUILD_HOSTLDFLAGS. Paths are $PWD-relative; $PWD here is the execroot.
{host_env}

# --- locate inputs (execroot-relative) ---
SRC_FG="{src_root}"
GCC="$EXECROOT/{gcc_driver}"

# Build out-of-tree from the READ-ONLY @kernel_sources tree: Kbuild supports
# `make -C <srctree> O=<objdir>` and writes only into O=, so there is no need to
# copy the ~1.4GB source tree. WSRC points straight at the read-only source;
# only the small O= dir (plus .config/.kernelvariables/CCWRAP) is writable.
# Per-target scratch (so kernel_amd64 and kernel_arm64 don't collide under a
# single `bazel build //:kernel_debs` that pulls both).
SCRATCH="$EXECROOT/_kbuild_scratch_{label}"
chmod -R u+w "$SCRATCH" 2>/dev/null || true
rm -rf "$SCRATCH"
mkdir -p "$SCRATCH"
WSRC="$SRC_FG/{build_root}"
WBUILD="$SCRATCH/_obj"
mkdir -p "$WBUILD"

# Stage the (possibly secure-upgrade-managed) final .config + .kernelvariables.
cp "$EXECROOT/{config}" "$WBUILD/.config"
cp "$EXECROOT/{kernelvariables}" "$WBUILD/.kernelvariables"

# CC wrapper: pinned gcc. Kernel objects are freestanding (-nostdinc) so no
# external sysroot is required for target compilation.
#
# COMPILER_PATH: the global export below is /usr/bin so the HOST gcc's collect2
# finds /usr/bin/ld. But the TARGET (cross) gcc must find its OWN bundled
# binutils (e.g. aarch64-linux-as), NOT the host x86_64 /usr/bin/as — otherwise
# the host assembler rejects target asm ("unknown assembler invoked" /
# "unrecognized option '-EL'"). So the wrapper overrides COMPILER_PATH to the
# cross gcc's bin dir for the target compiler only. For amd64 this points at the
# x86_64 gcc's own (equally valid) binutils; for arm64 it is what makes the
# cross-compile work at all.
GCC_BIN_DIR="$(dirname "$GCC")"
CCWRAP="$SCRATCH/_kcc"
cat > "$CCWRAP" <<WRAP
#!/bin/bash
export COMPILER_PATH="$GCC_BIN_DIR"
exec "$GCC" "\\$@"
WRAP
chmod +x "$CCWRAP"

# CROSS_COMPILE: absolute target binutils prefix derived from the resolved gcc
# driver (<gcc_bin_dir>/<triple>-, e.g. .../bin/aarch64-linux-). Absolute so
# kbuild's $(CROSS_COMPILE)ld resolves the bundled target binutils without
# relying on PATH. Used only when the distro actually ships prefixed binutils
# (<prefix>ld exists); the native x86_64 distro ships them UNPREFIXED, so leave
# CROSS_COMPILE empty there and let the gcc driver find them via COMPILER_PATH.
CROSS_COMPILE_ARG="$EXECROOT/{cross_compile}"
if [ ! -x "${{CROSS_COMPILE_ARG}}ld" ]; then
  CROSS_COMPILE_ARG=""
fi

# Hermetic build identity.
export KBUILD_BUILD_USER=sonic
export KBUILD_BUILD_HOST=sonic-build
export KBUILD_BUILD_TIMESTAMP="Thu Jan 01 00:00:00 UTC 1970"
export SOURCE_DATE_EPOCH=0
export LOCALVERSION=""
export COMPILER_PATH=/usr/bin

MAKE_ARGS=(
  -C "$WSRC"
  O="$WBUILD"
  ARCH={karch}
  CROSS_COMPILE="$CROSS_COMPILE_ARG"
  CC="$CCWRAP"
  HOSTCC={host_cc}
  HOSTCXX={host_cxx}
  HOSTLD={host_ld}
  HOSTAR={host_ar}
  KBUILD_BUILD_USER=sonic
  KBUILD_BUILD_HOST=sonic-build
  -j"$NPROC"
)

# olddefconfig reconciles the staged .config against current Kbuild.
"$MAKE" "${{MAKE_ARGS[@]}}" olddefconfig

"$MAKE" "${{MAKE_ARGS[@]}}" {image} modules

# Install modules straight into the declared output dir so it lands as
# {out_modules}/lib/modules/<rel> directly (the layout the deb expects) — no
# _root staging + flatten copy. {out_modules} is a declared_directory; ensure
# it exists for INSTALL_MOD_PATH.
mkdir -p "$EXECROOT/{out_modules}"
"$MAKE" "${{MAKE_ARGS[@]}}" INSTALL_MOD_PATH="$EXECROOT/{out_modules}" \\
     INSTALL_MOD_STRIP=1 modules_install

# make modules_install creates /lib/modules/<rel>/{{build,source}} symlinks that
# point at the ephemeral O= build dir; they are dangling outside the action and
# Bazel rejects dangling symlinks inside a tree artifact. The linux-headers deb
# supplies the real targets (and depmod regenerates them on the target), so drop
# them here — matching Debian's linux-image deb layout.
rm -f "$EXECROOT/{out_modules}/lib/modules/{kversion}/build" \\
      "$EXECROOT/{out_modules}/lib/modules/{kversion}/source"

# Collect primary outputs. The scratch is deleted at the end of this action and
# nothing else reads these files afterward, so MOVE the big single-file products
# (vmlinux ~600MB, the kernel image, System.map) instead of byte-copying. mv is
# a rename on the same filesystem (scratch & bazel-out share one output base) →
# instant; it degrades to copy+unlink across filesystems (still correct).
# .config stays a cp because it is consumed in TWO places (out_config AND
# build_data/.config below); copying a small file twice is cheap.
mkdir -p "$(dirname "$EXECROOT/{out_image}")" \\
         "$(dirname "$EXECROOT/{out_vmlinux}")" \\
         "$(dirname "$EXECROOT/{out_sysmap}")"
mv "$WBUILD/arch/{karch}/boot/{image}" "$EXECROOT/{out_image}"
mv "$WBUILD/System.map"                "$EXECROOT/{out_sysmap}"
mv "$WBUILD/vmlinux"                   "$EXECROOT/{out_vmlinux}"
cp "$WBUILD/.config"                   "$EXECROOT/{out_config}"
echo "{kversion}" > "$EXECROOT/{out_release}"

# build_data: the small, data-only subset needed by the headers debs.
BD="$EXECROOT/{out_builddata}"
mkdir -p "$BD"
cp "$WBUILD/.config" "$BD/.config"
cp "$WBUILD/.kernelvariables" "$BD/.kernelvariables" 2>/dev/null || true
cp "$WBUILD/Module.symvers" "$BD/Module.symvers" 2>/dev/null || true
# The generated-header subtrees are many small files. This is the last thing the
# action collects (scratch is removed right after), so MOVE them wholesale out of
# O= instead of copying — mv is a same-filesystem rename (instant) and degrades
# to copy+unlink across filesystems (still correct), so no cross-device concern.
for d in include "arch/{karch}/include" scripts; do
  if [ -d "$WBUILD/$d" ]; then
    mkdir -p "$(dirname "$BD/$d")"
    mv "$WBUILD/$d" "$BD/$d"
  fi
done

chmod -R u+w "$SCRATCH" 2>/dev/null || true
rm -rf "$SCRATCH"
""".format(
            host_env = host_env,
            src_root = src_root,
            build_root = build_root,
            label = ctx.label.name,
            gcc_driver = gcc_driver.path,
            config = config.path,
            kernelvariables = kernelvariables.path,
            karch = karch,
            cross_compile = cross_compile,
            host_cc = host_cc,
            host_cxx = host_cxx,
            host_ld = host_ld,
            host_ar = host_ar,
            image = image,
            kversion = kversion,
            out_image = out_image.path,
            out_vmlinux = out_vmlinux.path,
            out_sysmap = out_sysmap.path,
            out_config = out_config.path,
            out_release = out_release.path,
            out_modules = out_modules.path,
            out_builddata = out_builddata.path,
        ),
    )

    inputs = depset(
        direct = [config, kernelvariables, script] + host_tool_files,
        transitive = [src_files, gcc_files, exec_cc_files],
    )

    ctx.actions.run(
        executable = script,
        inputs = inputs,
        tools = [gcc_driver],
        outputs = [
            out_image,
            out_vmlinux,
            out_sysmap,
            out_config,
            out_release,
            out_modules,
            out_builddata,
        ],
        mnemonic = "KernelBuild",
        progress_message = "Building Linux kernel %s (make %s + modules)" % (kversion, image),
        use_default_shell_env = True,
        execution_requirements = {"no-sandbox": "1", "local": "1"},
    )

    return [
        DefaultInfo(files = depset([out_image, out_vmlinux, out_sysmap, out_config])),
        KernelBuildInfo(
            kernel_binary = out_image,
            vmlinux = out_vmlinux,
            system_map = out_sysmap,
            config = out_config,
            kernel_release = out_release,
            kernel_variables = kernelvariables,
            arch = arch,
            kernel_build_data_dir = out_builddata,
            kernel_sources = src_files,
            modules_install_dir = out_modules,
        ),
    ]

kernel_build = rule(
    implementation = _impl,
    attrs = {
        "kernel_sources": attr.label(mandatory = True, doc = "@kernel_sources source_tree filegroup."),
        "config": attr.label(mandatory = True, providers = [KernelConfigInfo], doc = "manage_config target carrying the final .config (KernelConfigInfo)."),
        "arch": attr.string(mandatory = True),
        "kversion": attr.string(mandatory = True),
        "kernel_image": attr.string(mandatory = True),
        "kernel_src_dir": attr.string(mandatory = True, doc = "Unpacked source dir name, e.g. linux-6.1.123."),
        "make_goals": attr.string_list(default = []),
        "_cc_toolchain": attr.label(
            default = Label("@bazel_tools//tools/cpp:current_cc_toolchain"),
        ),
        "_exec_cc_toolchain": attr.label(
            default = "@bazel_tools//tools/cpp:current_cc_toolchain",
            cfg = "exec",
        ),
    } | HOST_TOOL_ATTRS,
    fragments = ["cpp"],
    toolchains = use_cc_toolchain(),
)
