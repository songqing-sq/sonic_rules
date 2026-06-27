"""Kernel `.config` generation as a BUILD ACTION (ports the reference flow).

This replaces the config generation that used to run inside the
@kernel_sources repo rule (gencontrol.py + fakeroot make setup_* +
olddefconfig + manage-config). Per the hermetic-port plan, @kernel_sources is
now a pure patched tree and config is produced here by an action whose tools
are injected as `cfg=exec` host tools (see bazel/host_tools.bzl).

Pipeline (mirrors Debian's setup_meta/setup_image plus SONiC's manage-config):
  1. Read @kernel_sources in place (read-only); out-of-tree build via $MAKE O=.
  2. debian/bin/kconfig.py layers the three Debian fragments:
       debian/config/config
       debian/config/kernelarch-x86/config
       debian/config/amd64/config
     with -o SECURITY_LOCKDOWN_LSM=y -o MODULE_SIG=y.
  3. Write .kernelvariables (override ARCH / KERNELRELEASE +
     DEBIAN_KERNEL_NO_CC_VERSION_CHECK=y).  The CC_HAS_* probes run with the
     PINNED sonic GCC (the actual target compiler kernel_build uses, via CC=
     wrapper), so config-gen-time choices (INIT_STACK_*, MODULE_ALLOW_BTF_
     MISMATCH, etc.) match the shipped kernel. HOSTCC stays the host
     /usr/bin/gcc for Kbuild host tools.
  4. $MAKE listnewconfig + oldconfig (resolve new symbols).
  5. SONiC manage-config layer: kconfig-exclusions / -inclusions via
     scripts/config, then $MAKE olddefconfig.
  6. kconfig-force-inclusions: raw append (bypasses dependency resolution).
  7. Capture $MAKE -s kernelrelease into kernel.release.

`$MAKE` is OUR source-built GNU make (host_tools_env). CC is the pinned sonic
GCC (target compiler, for the CC_HAS_* probes); HOSTCC is the host /usr/bin/gcc
(Kbuild host tools). See references/kernel.md.
"""

load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cc_toolchain", "use_cc_toolchain")
load("//kernel:host_tools.bzl", "HOST_TOOL_ATTRS", "host_tools_env")
load("//kernel:providers.bzl", "KernelConfigInfo")
load("//kernel:toolchain_gcc.bzl", "resolve_gcc_driver")

_KERNEL_ARCH_BY_ARCH = {
    "amd64": "x86",
    "arm64": "arm64",
    "armhf": "arm",
}

# Debian's `kernelarch-<X>` shared kconfig fragment dir, as it actually appears
# in the `KCONFIG='...'` line emitted by debian/rules.gen for each flavor.
# This is NOT always the kernel ARCH name: amd64's flavor layers
# `kernelarch-x86/config`, armhf's layers `kernelarch-arm/config`, but arm64's
# flavor layers NO kernelarch fragment at all (only `config` + `arm64/config`).
# Mapping to "" means: skip the kernelarch fragment for that arch.
_KERNELARCH_DIR_BY_ARCH = {
    "amd64": "x86",
    "arm64": "",
    "armhf": "arm",
}

def _kernel_sources_root(files, src_subdir):
    """Return the path that *contains* `src_subdir/` shared by every file."""
    if not files:
        return "."
    marker = "/" + src_subdir + "/"
    for f in files:
        idx = f.path.find(marker)
        if idx >= 0:
            return f.path[:idx]
    return files[0].dirname

def _impl(ctx):
    arch = ctx.attr.arch
    if arch not in _KERNEL_ARCH_BY_ARCH:
        fail("debian_kernel_config: unsupported arch %r (expected one of %s)" % (
            arch,
            sorted(_KERNEL_ARCH_BY_ARCH.keys()),
        ))
    kernel_arch = _KERNEL_ARCH_BY_ARCH[arch]
    kernelarch_dir = _KERNELARCH_DIR_BY_ARCH[arch]

    # Pinned (target) GCC, resolved from the target platform via Bazel toolchain
    # resolution (no per-arch dict). The actual compiler kernel_build uses; the
    # Kconfig CC_HAS_* probes must run with it so config-gen-time choices match.
    cc_toolchain = find_cc_toolchain(ctx)
    host_env, host_tool_files = host_tools_env(ctx)
    gcc_files = cc_toolchain.all_files
    gcc_driver = resolve_gcc_driver(cc_toolchain)

    # CROSS_COMPILE prefix for the pinned-gcc config probes, derived from the
    # resolved driver: <dirname(gcc_driver)>/<triple>- where triple = basename
    # minus the trailing "-gcc" (matches kernel_build.bzl). The cross (aarch64)
    # distro ships <triple>-{ld,as,...}; the native (x86_64) distro ships them
    # UNPREFIXED, so the script falls back to empty CROSS_COMPILE when <prefix>ld
    # is absent. Config-only ops are compile-only and don't link, but we mirror
    # kernel_build to be safe.
    triple = gcc_driver.basename[:-len("-gcc")]
    cross_compile = gcc_driver.dirname + "/" + triple + "-"

    dot_config = ctx.actions.declare_file(ctx.label.name + "/.config")
    kernel_release = ctx.actions.declare_file(ctx.label.name + "/kernel.release")
    kernel_variables = ctx.actions.declare_file(ctx.label.name + "/.kernelvariables")

    kernel_sources_files = ctx.attr.kernel_sources[DefaultInfo].files
    kconfig_exclusions = ctx.file.kconfig_exclusions
    kconfig_inclusions = ctx.file.kconfig_inclusions
    kconfig_force_inclusions = ctx.file.kconfig_force_inclusions

    src_subdir = ctx.attr.kernel_src_dir

    command = """
set -euo pipefail
EXECROOT="$(pwd)"
{host_env}

# Pinned (target) gcc used as CC for the Kconfig CC_HAS_* compile probes.
# A wrapper points the cross gcc's collect2/as at its OWN bundled binutils
# (matches kernel_build.bzl's CCWRAP) so the host x86_64 binutils are not used
# for target probes. HOSTCC stays /usr/bin/gcc (Kbuild host tools).
GCC="$EXECROOT/{gcc_driver}"
GCC_BIN_DIR="$(dirname "$GCC")"
CROSS_COMPILE_ARG="$EXECROOT/{cross_compile}"
if [ ! -x "${{CROSS_COMPILE_ARG}}ld" ]; then
  CROSS_COMPILE_ARG=""
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

CCWRAP="$WORKDIR/_kcc"
cat > "$CCWRAP" <<WRAP
#!/bin/bash
export COMPILER_PATH="$GCC_BIN_DIR"
exec "$GCC" "\\$@"
WRAP
chmod +x "$CCWRAP"

# Out-of-tree build ($MAKE O=$BDIR): read the kernel source tree in place from
# the read-only bazel input. All generated output (.config, host kconfig tools,
# .config.old) goes to $BDIR; nothing is written back into the source tree, so
# the 1.5G/80k-file `cp -aL` the staging used to do is unnecessary.
KSRC="$EXECROOT/{kernel_sources_root}/{src_subdir}"
if [ ! -d "$KSRC" ]; then
  echo "debian_kernel_config: kernel source root not found at $KSRC" >&2
  ls -la "$(dirname "$KSRC")" >&2
  exit 1
fi

BDIR="$WORKDIR/build"
mkdir -p "$BDIR"

DEBIAN_CFG="$KSRC/debian/config"
if [ ! -d "$DEBIAN_CFG/{arch}" ]; then
  echo "debian_kernel_config: per-arch dir not found: $DEBIAN_CFG/{arch}" >&2
  ls -la "$DEBIAN_CFG" >&2 || true
  exit 1
fi

# --- Debian fragment layering via debian/bin/kconfig.py ---------------------
# Fragment list mirrors the `KCONFIG='...'` line debian/rules.gen emits for
# this flavor. The shared `kernelarch-<X>/config` middle fragment exists for
# amd64 (x86) and armhf (arm) but NOT for arm64 (whose flavor layers only
# `config` + `arm64/config`), so it is included only when KERNELARCH_DIR is set.
KCONFIG_FRAGS=("$DEBIAN_CFG/config")
if [ -n "{kernelarch_dir}" ]; then
  KCONFIG_FRAGS+=("$DEBIAN_CFG/kernelarch-{kernelarch_dir}/config")
fi
KCONFIG_FRAGS+=("$DEBIAN_CFG/{arch}/config")
PYTHONPATH="$KSRC/debian/lib/python" python3 "$KSRC/debian/bin/kconfig.py" \\
    "$BDIR/.config" \\
    "${{KCONFIG_FRAGS[@]}}" \\
    -o SECURITY_LOCKDOWN_LSM=y \\
    -o MODULE_SIG=y

CFG="$BDIR/.config"

# --- .kernelvariables (override ARCH/KERNELRELEASE; skip CC version check) ---
cat > "$BDIR/.kernelvariables" <<EOF
override ARCH = {kernel_arch}
override KERNELRELEASE = {kversion}
DEBIAN_KERNEL_NO_CC_VERSION_CHECK = y
EOF

# --- oldconfig (resolve new symbols to their defaults) ---------------------
# `yes '' | oldconfig` resolves every new symbol to its default and writes
# .config. The reference flow also ran `listnewconfig` first, but its output
# went to /dev/null and its exit code was ignored (|| true), so it neither
# gated nor altered .config -- it just re-parsed the whole Kconfig tree and
# re-ran the CC_HAS_* probes one extra time. Dropped; oldconfig builds the
# host kconfig tools and resolves new symbols on its own.
export COMPILER_PATH=/usr/bin
export KBUILD_BUILD_USER=sonic
export KBUILD_BUILD_HOST=sonic-build
export KBUILD_BUILD_TIMESTAMP="Thu Jan 01 00:00:00 UTC 1970"
(
  cd "$KSRC"
  set +o pipefail
  yes '' | $MAKE O="$BDIR" CROSS_COMPILE="$CROSS_COMPILE_ARG" HOSTCC=/usr/bin/gcc CC="$CCWRAP" oldconfig >/dev/null
  set -o pipefail
)

# --- SONiC manage-config layer (sections common + <arch>) ------------------
SECTIONS=(common "{arch}")

extract_section() {{
  local file="$1"; local section="$2"
  awk -v sec="[$section]" '
    $0 == sec {{ in_sec = 1; next }}
    /^\\[.*\\]$/ {{ in_sec = 0 }}
    in_sec {{ print }}
  ' "$file"
}}

apply_exclusions() {{
  local file="$1"; [ -f "$file" ] || return 0
  for s in "${{SECTIONS[@]}}"; do
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in ''|\\#*|\\;*) continue ;; esac
      opt="${{line%% *}}"
      opt="${{opt#CONFIG_}}"
      [ -n "$opt" ] && "$KSRC/scripts/config" --file "$CFG" --keep-case -d "$opt"
    done < <(extract_section "$file" "$s")
  done
}}

apply_inclusions() {{
  local file="$1"; [ -f "$file" ] || return 0
  for s in "${{SECTIONS[@]}}"; do
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in ''|\\#*|\\;*) continue ;; esac
      if [[ "$line" == *=* ]]; then
        key="${{line%%=*}}"
        val="${{line#*=}}"
        key="${{key#CONFIG_}}"
        case "$val" in
          y) "$KSRC/scripts/config" --file "$CFG" --keep-case -e "$key" ;;
          m) "$KSRC/scripts/config" --file "$CFG" --keep-case -m "$key" ;;
          n) "$KSRC/scripts/config" --file "$CFG" --keep-case -d "$key" ;;
          *) "$KSRC/scripts/config" --file "$CFG" --keep-case --set-val "$key" "$val" ;;
        esac
      else
        opt="${{line#CONFIG_}}"
        [ -n "$opt" ] && "$KSRC/scripts/config" --file "$CFG" --keep-case -e "$opt"
      fi
    done < <(extract_section "$file" "$s")
  done
}}

apply_exclusions "{exclusions}"
apply_inclusions "{inclusions}"

(
  cd "$KSRC"
  $MAKE O="$BDIR" CROSS_COMPILE="$CROSS_COMPILE_ARG" HOSTCC=/usr/bin/gcc CC="$CCWRAP" olddefconfig >/dev/null
)

# --- force-inclusions: raw append per active section -----------------------
if [ -f "{force_inclusions}" ]; then
    for s in "${{SECTIONS[@]}}"; do
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in ''|\\#*|\\;*) continue ;; esac
            printf '%s\\n' "$line" >> "$CFG"
        done < <(extract_section "{force_inclusions}" "$s")
    done
fi

# --- capture KERNELRELEASE -------------------------------------------------
(
  cd "$KSRC"
  $MAKE O="$BDIR" CROSS_COMPILE="$CROSS_COMPILE_ARG" HOSTCC=/usr/bin/gcc CC="$CCWRAP" -s kernelrelease
) > "{kernel_release_out}"

cp -L "$CFG" "{dot_config_out}"
cp -L "$BDIR/.kernelvariables" "{kernel_variables_out}"
""".format(
        host_env = host_env,
        gcc_driver = gcc_driver.path,
        cross_compile = cross_compile,
        kernel_sources_root = _kernel_sources_root(kernel_sources_files.to_list(), src_subdir),
        src_subdir = src_subdir,
        arch = arch,
        kernel_arch = kernel_arch,
        kernelarch_dir = kernelarch_dir,
        kversion = ctx.attr.kversion,
        exclusions = kconfig_exclusions.path,
        inclusions = kconfig_inclusions.path,
        force_inclusions = kconfig_force_inclusions.path,
        dot_config_out = dot_config.path,
        kernel_release_out = kernel_release.path,
        kernel_variables_out = kernel_variables.path,
    )

    ctx.actions.run_shell(
        inputs = depset(
            direct = [kconfig_exclusions, kconfig_inclusions, kconfig_force_inclusions] + host_tool_files,
            transitive = [kernel_sources_files, gcc_files],
        ),
        tools = [gcc_driver],
        outputs = [dot_config, kernel_release, kernel_variables],
        command = command,
        progress_message = "debian_kernel_config %s (arch=%s platform=%s)" % (
            ctx.label,
            arch,
            ctx.attr.platform,
        ),
        mnemonic = "DebianKernelConfig",
        use_default_shell_env = True,
    )

    return [
        KernelConfigInfo(
            config = dot_config,
            kernel_variables = kernel_variables,
            kernel_release = kernel_release,
        ),
        DefaultInfo(files = depset([dot_config, kernel_release, kernel_variables])),
    ]

debian_kernel_config = rule(
    implementation = _impl,
    attrs = {
        "arch": attr.string(
            mandatory = True,
            values = ["amd64", "arm64", "armhf"],
            doc = "Target architecture: amd64 / arm64 / armhf.",
        ),
        "platform": attr.string(
            mandatory = True,
            doc = "SONiC platform string (e.g. 'vs'). Selects SONiC kconfig sections.",
        ),
        "kversion": attr.string(
            mandatory = True,
            doc = "Full Debian kernel version string (e.g. '6.1.0-29-2-amd64').",
        ),
        "kernel_src_dir": attr.string(
            mandatory = True,
            doc = "Unpacked source dir name (e.g. 'linux-6.1.123'). Matches the " +
                  "@kernel_sources layout (src/<kernel_src_dir>/).",
        ),
        "kernel_sources": attr.label(
            allow_files = True,
            mandatory = True,
            doc = "@kernel_sources patched source tree (src/<kernel_src_dir>/).",
        ),
        "kconfig_exclusions": attr.label(allow_single_file = True, mandatory = True),
        "kconfig_inclusions": attr.label(allow_single_file = True, mandatory = True),
        "kconfig_force_inclusions": attr.label(allow_single_file = True, mandatory = True),
        "_cc_toolchain": attr.label(
            default = Label("@bazel_tools//tools/cpp:current_cc_toolchain"),
        ),
    } | HOST_TOOL_ATTRS,
    fragments = ["cpp"],
    toolchains = use_cc_toolchain(),
    provides = [KernelConfigInfo],
    doc = "Generates .config + .kernelvariables + kernel.release from the " +
          "Debian fragments and SONiC kconfig overlays, as a build action.",
)
