"""linux-headers-common and linux-headers-<arch> deb staging.

These macros build the two headers .deb packages from the kernel build's
data-only build dir + the patched source tree, approximating Debian's
binary_headers install manifests with glob-based staging.

  common deb (arch: all): cross-arch shared headers under
      /usr/src/linux-headers-<KVERSION_SHORT>-common/
  arch deb (per-arch): arch-specific headers + kbuild output under
      /usr/src/linux-headers-<KVERSION>/  plus the build/source module symlinks.
"""

load("//sonic_deb:sonic_deb.bzl", "sonic_deb")
load("//kernel:providers.bzl", "KernelBuildInfo")

# --- staging rules: assemble a tree artifact for each headers deb ----------

def _common_stage_impl(ctx):
    info = ctx.attr.kernel_build[KernelBuildInfo]
    src = info.kernel_sources
    build_data = info.kernel_build_data_dir
    out = ctx.actions.declare_directory(ctx.label.name)
    kshort = ctx.attr.kversion_short
    kernel_src_dir = ctx.attr.kernel_src_dir

    # Derive source root.
    marker = "/" + kernel_src_dir + "/"
    first = src.to_list()[0].path
    root = first[:first.find(marker)] + "/" + kernel_src_dir

    script = ctx.actions.declare_file(ctx.label.name + "_stage.sh")
    ctx.actions.write(script, is_executable = True, content = """#!/bin/bash
set -euo pipefail
SRC="{root}"
BD="{build_data}"
DST="{out}/usr/src/linux-headers-{kshort}-common"
mkdir -p "$DST"

# Cross-arch shared content: top Makefile, Kbuild, Kconfig, scripts, the whole
# include/ tree, and per-arch Makefile/Kconfig/scripts (no .c objects).
cp -a "$SRC/Makefile" "$DST/" 2>/dev/null || true
cp -a "$SRC/Kbuild" "$DST/" 2>/dev/null || true
cp -a "$SRC/Kconfig" "$DST/" 2>/dev/null || true
mkdir -p "$DST/include"
cp -a "$SRC/include/." "$DST/include/" 2>/dev/null || true
mkdir -p "$DST/scripts"
cp -a "$SRC/scripts/." "$DST/scripts/" 2>/dev/null || true

# Generated headers from the build (override/augment the source include/).
if [ -d "$BD/include" ]; then
  cp -a "$BD/include/." "$DST/include/" 2>/dev/null || true
fi

# Strip VCS / packaging / object cruft.
rm -rf "$DST/.git" "$DST"/**/.git 2>/dev/null || true
find "$DST" -name '*.o' -delete 2>/dev/null || true
find "$DST" -name '*.cmd' -delete 2>/dev/null || true
# Drop symlinks (deb staging flattens them; dangling links would break tar).
find "$DST" -type l -delete 2>/dev/null || true
""".format(root = root, build_data = build_data.path, out = out.path, kshort = kshort))

    ctx.actions.run(
        executable = script,
        inputs = depset([build_data], transitive = [src]),
        outputs = [out],
        mnemonic = "KernelHeadersCommonStage",
        execution_requirements = {"no-sandbox": "1", "local": "1"},
        use_default_shell_env = True,
    )
    return [DefaultInfo(files = depset([out]))]

_common_stage = rule(
    implementation = _common_stage_impl,
    attrs = {
        "kernel_build": attr.label(mandatory = True, providers = [KernelBuildInfo]),
        "kversion_short": attr.string(mandatory = True),
        "kernel_src_dir": attr.string(mandatory = True),
    },
)

def _arch_stage_impl(ctx):
    info = ctx.attr.kernel_build[KernelBuildInfo]
    src = info.kernel_sources
    build_data = info.kernel_build_data_dir
    out = ctx.actions.declare_directory(ctx.label.name)
    kshort = ctx.attr.kversion_short
    kversion = ctx.attr.kversion
    karch = {"amd64": "x86", "arm64": "arm64", "armhf": "arm"}[info.arch]
    kernel_src_dir = ctx.attr.kernel_src_dir

    marker = "/" + kernel_src_dir + "/"
    first = src.to_list()[0].path
    root = first[:first.find(marker)] + "/" + kernel_src_dir

    script = ctx.actions.declare_file(ctx.label.name + "_stage.sh")
    ctx.actions.write(script, is_executable = True, content = """#!/bin/bash
set -euo pipefail
SRC="{root}"
BD="{build_data}"
DST="{out}/usr/src/linux-headers-{kversion}"
mkdir -p "$DST"

# Arch-specific source headers + Makefile.
mkdir -p "$DST/arch/{karch}"
cp -a "$SRC/arch/{karch}/include" "$DST/arch/{karch}/" 2>/dev/null || true
cp -a "$SRC/arch/{karch}/Makefile" "$DST/arch/{karch}/" 2>/dev/null || true

# Build-output generated headers, .config, Module.symvers, kbuild scripts.
cp -a "$BD/.config" "$DST/.config" 2>/dev/null || true
cp -a "$BD/Module.symvers" "$DST/Module.symvers" 2>/dev/null || true
if [ -d "$BD/arch/{karch}/include" ]; then
  mkdir -p "$DST/arch/{karch}/include"
  cp -a "$BD/arch/{karch}/include/." "$DST/arch/{karch}/include/" 2>/dev/null || true
fi
if [ -d "$BD/include" ]; then
  mkdir -p "$DST/include"
  cp -a "$BD/include/." "$DST/include/" 2>/dev/null || true
fi
if [ -d "$BD/scripts" ]; then
  mkdir -p "$DST/scripts"
  cp -a "$BD/scripts/." "$DST/scripts/" 2>/dev/null || true
fi

# 1-line Makefile redirector to the common headers tree (Debian convention).
cat > "$DST/Makefile" <<EOF
include /usr/src/linux-headers-{kshort}-common/Makefile
EOF

# Note: the /lib/modules/<kversion>/{{build,source}} symlinks are created by the
# package's postinst in Debian; they are not shipped as static deb content (the
# deb staging flattens symlinks), so they are intentionally omitted here.

find "$DST" -name '*.o' -delete 2>/dev/null || true
find "$DST" -name '*.cmd' -delete 2>/dev/null || true
# Drop symlinks (deb staging flattens them; dangling links would break tar).
find "{out}" -type l -delete 2>/dev/null || true
""".format(root = root, build_data = build_data.path, out = out.path, kshort = kshort, kversion = kversion, karch = karch))

    ctx.actions.run(
        executable = script,
        inputs = depset([build_data], transitive = [src]),
        outputs = [out],
        mnemonic = "KernelHeadersArchStage",
        execution_requirements = {"no-sandbox": "1", "local": "1"},
        use_default_shell_env = True,
    )
    return [DefaultInfo(files = depset([out]))]

_arch_stage = rule(
    implementation = _arch_stage_impl,
    attrs = {
        "kernel_build": attr.label(mandatory = True, providers = [KernelBuildInfo]),
        "kversion_short": attr.string(mandatory = True),
        "kversion": attr.string(mandatory = True),
        "kernel_src_dir": attr.string(mandatory = True),
    },
)

# --- public macros --------------------------------------------------------

def linux_headers_common_deb(
        name,
        kernel_build,
        kversion_short,
        kernel_version,
        kernel_subversion,
        kernel_src_dir,
        section = "kernel",
        source = "linux",
        depends = None,
        **kwargs):
    _common_stage(
        name = name + "_stage",
        kernel_build = kernel_build,
        kversion_short = kversion_short,
        kernel_src_dir = kernel_src_dir,
    )
    sonic_deb(
        name = name,
        package = "linux-headers-" + kversion_short + "-common",
        version = kernel_version + "-" + kernel_subversion,
        architecture = "all",
        package_file_name = "linux-headers-%s-common_%s-%s_all.deb" % (kversion_short, kernel_version, kernel_subversion),
        content = {"/": [name + "_stage"]},
        depends = depends or [],
        section = section,
        source = source,
        maintainer = "Debian Kernel Team <debian-kernel@lists.debian.org>",
        description = "Common header files for Linux " + kversion_short,
        **kwargs
    )

def linux_headers_arch_deb(
        name,
        kernel_build,
        arch,
        kversion,
        kversion_short,
        kernel_version,
        kernel_subversion,
        kernel_src_dir,
        section = "kernel",
        source = "linux",
        depends = None,
        **kwargs):
    _arch_stage(
        name = name + "_stage",
        kernel_build = kernel_build,
        kversion_short = kversion_short,
        kversion = kversion,
        kernel_src_dir = kernel_src_dir,
    )
    sonic_deb(
        name = name,
        package = "linux-headers-" + kversion,
        version = kernel_version + "-" + kernel_subversion,
        architecture = arch,
        package_file_name = "linux-headers-%s_%s-%s_%s.deb" % (kversion, kernel_version, kernel_subversion, arch),
        content = {"/": [name + "_stage"]},
        depends = depends or [],
        section = section,
        source = source,
        maintainer = "Debian Kernel Team <debian-kernel@lists.debian.org>",
        description = "Header files for Linux " + kversion,
        **kwargs
    )
