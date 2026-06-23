"""Rule to assemble a SONiC initramfs (initrd) image declaratively.

This produces an initrd.img-<kversion> newc cpio (gzip-compressed) that is a
genuinely bootable initramfs-tools initrd, assembled WITHOUT running mkinitramfs
and WITHOUT a chroot -- the cpio is built directly from declared Bazel inputs:

  * /init + scripts/functions + scripts/<dirs>  - the (loopback-patched)
    initramfs-tools framework, taken from /usr/share/initramfs-tools/ of the
    SONiC-patched initramfs-tools-core data tree (initramfs_tools_data).
  * scripts/init-bottom/union-mount, varlog, ... - the SONiC boot scripts that
    loop-mount fs.squashfs and union-mount the rw overlay (union-mount.j2 must be
    rendered with the onie-image.conf values before being handed to this rule).
  * /bin/busybox + applet symlink farm          - the boot shell + coreutils.
    busybox MUST be statically linked: it is exec'd at build time to enumerate
    its applets (`busybox --list-full`), so it has to run in the build sandbox
    with no dynamic loader; a static busybox also needs no libc in the initrd.
  * the boot userspace closure                  - apt-closure flatten tars for
    the binaries the SONiC hooks need at runtime (e2fsprogs: mke2fs/e2fsck/
    resize2fs/mkfs.ext4/fsck.ext4; acl: setfacl; util-linux: losetup/fdisk;
    kmod: modprobe), with their shared libs pulled in by the apt dep closure.
    This is the declarative stand-in for mkinitramfs's copy_exec.
  * lib/modules/<kversion>/...                   - the boot kernel-module closure
    (squashfs, overlay, loop, virtio_blk, virtio_pci and everything they depend
    on, resolved from the full modules.dep of the modules tree), plus a freshly
    regenerated modules.dep via the sealed depmod.

All host tools are sealed: the newc cpio + gzip stream is written by the
@tar.bzl bsdtar and modules.dep by the sealed depmod
(//kernel_host_tools:depmod -> @kmod_src), never a host-PATH tool. No
unshare/chroot/userns is used.
"""

load("@tar.bzl//tar:tar.bzl", tar_lib = "tar_lib")

def _initramfs_impl(ctx):
    out = ctx.actions.declare_file(ctx.attr.out)
    bsdtar = ctx.toolchains[tar_lib.toolchain_type]
    tar = bsdtar.tarinfo.binary.path

    itdata = ctx.file.initramfs_tools_data
    modules_tree = ctx.file.modules_tree
    depmod = ctx.executable.depmod
    kver = ctx.attr.kversion

    # scripts: label (file) -> destination path under the cpio root.
    script_files = []
    copy_script_cmds = []
    for src, dest in ctx.attr.scripts.items():
        f = src.files.to_list()[0]
        script_files.append(f)
        copy_script_cmds.append(
            'install -D -m0755 "%s" "$TREE/%s"' % (f.path, dest),
        )
    copy_scripts = "\n".join(copy_script_cmds)

    modules = " ".join(ctx.attr.modules)

    # NOTE: built with str.replace (not .format) because the embedded awk
    # program uses literal { } braces that would collide with format fields.
    command = """
set -euo pipefail
TREE=$(mktemp -d)
ITROOT=$(mktemp -d)
BINDIR=$(mktemp -d)
FULL=""
# Copied module trees inherit Bazel's read-only (0444/0555) modes, so cleanup
# must restore write permission before rm can unlink them.
cleanup() {
    chmod -R u+w "$TREE" "$ITROOT" "$BINDIR" "${FULL:-/nonexistent}" 2>/dev/null || true
    rm -rf "$TREE" "$ITROOT" "$BINDIR" "${FULL:-}" 2>/dev/null || true
}
trap cleanup EXIT

# The sealed depmod is the kmod multicall binary; it only acts as depmod when
# invoked through an argv0 named "depmod" (`kmod depmod` is rejected).
ln -s "$(readlink -f "@@DEPMOD@@")" "$BINDIR/depmod"
DEPMOD="$BINDIR/depmod"

# 1. Unpack the (loopback-patched) initramfs-tools data tree.
"@@TAR@@" -xf "@@ITDATA@@" -C "$ITROOT"
ITSHARE="$ITROOT/usr/share/initramfs-tools"

# 2. /init + the FULL upstream scripts subtree. scripts/local performs the real
#    root mount (loopback-patched for `loop=`/`loopoffset=`, the SONiC squashfs
#    boot model) and scripts/functions/init-bottom/* are run by /init in order,
#    so the whole tree must ship -- not just functions.
install -D -m0755 "$ITSHARE/init" "$TREE/init"
cp -a "$ITSHARE/scripts" "$TREE/scripts"
# Safety: guarantee the run-parts dirs exist even if upstream ships some empty.
mkdir -p "$TREE/scripts/init-top" "$TREE/scripts/init-premount" \\
         "$TREE/scripts/init-bottom" "$TREE/scripts/local-top" \\
         "$TREE/scripts/local-premount" "$TREE/scripts/local-bottom"
# /init sources /conf/initramfs.conf, /conf/conf.d/*, and /conf/arch.conf, and
# mounts a tmpfs on /run -- emit all of them (mkinitramfs scaffolding). arch.conf
# carries DPKG_ARCH (mkinitramfs writes it as DPKG_ARCH=<arch>); derive it from
# the kversion suffix (...-amd64 -> amd64).
mkdir -p "$TREE/conf/conf.d" "$TREE/run"
printf 'MODULES=most\\nBUSYBOX=y\\nCOMPRESS=gzip\\nDEVICE=\\nNFSROOT=auto\\nRUNSIZE=10%%\\n' \\
    > "$TREE/conf/initramfs.conf"
KARCH="@@KVER@@"; echo "DPKG_ARCH=${KARCH##*-}" > "$TREE/conf/arch.conf"

# 3. SONiC boot scripts (union-mount rendered, varlog, ...) overlaid on top.
@@COPY_SCRIPTS@@

# 3a. Per-stage ORDER files. /init's run_scripts sources scripts/<stage>/ORDER;
#     mkinitramfs's cache_run_scripts generates it by tsort-ing each script's
#     `prereqs` output (with a self-edge so prereq-less scripts survive tsort).
#     Reproduce that exactly for every stage dir (after all framework + SONiC
#     scripts are in place).
for SD in "$TREE"/scripts/*/; do
    [ -d "$SD" ] || continue
    stage=$(basename "$SD")
    : > "$BINDIR/pairs"
    for f in "$SD"*; do
        [ -f "$f" ] || continue
        b=$(basename "$f")
        [ "$b" = ORDER ] && continue
        echo "$b $b" >> "$BINDIR/pairs"
        for p in $(sh "$f" prereqs 2>/dev/null || true); do
            echo "$p $b" >> "$BINDIR/pairs"
        done
    done
    : > "$SD/ORDER"
    for x in $(tsort "$BINDIR/pairs"); do
        [ -f "$SD/$x" ] || continue
        echo "/scripts/$stage/$x \\"\\$@\\"" >> "$SD/ORDER"
        echo "[ -e /conf/param.conf ] && . /conf/param.conf" >> "$SD/ORDER"
    done
done

# 3b. Boot userspace. Extract the apt-closure flatten tars (e2fsprogs, acl,
#     util-linux, kmod -- libs come along via the apt dep closure) straight into
#     the cpio root; this is the declarative stand-in for mkinitramfs copy_exec.
#     Then install the static busybox and build its applet symlink farm so the
#     framework /init (#!/bin/sh) and the SONiC scripts have a shell + coreutils.
USP="@@USERSPACE_LAYERS@@"
for L in $USP; do
    "@@TAR@@" -xf "$L" -C "$TREE"
done
install -D -m0755 "@@BUSYBOX@@" "$TREE/bin/busybox"
# Enumerate applets via the EXEC-arch lister (busybox_lister, default = the
# target busybox itself). The applet set is a busybox compile-time config, so
# the exec-arch static busybox lists the same paths as the target one -- this is
# what lets an arm64 initrd be built on an amd64 host (the target busybox cannot
# be exec'd cross-arch). --list-full prints each applet's install path
# (e.g. bin/sh, usr/bin/[); point them all at the one (target) binary.
"@@BUSYBOX_LISTER@@" --list-full | while read -r ap; do
    [ "$ap" = "bin/busybox" ] && continue
    mkdir -p "$TREE/$(dirname "$ap")"
    ln -sf /bin/busybox "$TREE/$ap"
done

# 4. Boot kernel-module closure. The modules_tree artifact is the
#    `make modules_install` PREFIX (it contains lib/modules/<kver>/kernel/...),
#    so point MODROOT at the actual module dir (fall back to treating the root as
#    already-contents-of-lib/modules for other producers). `make modules_install`
#    did not run depmod, so there is no modules.dep yet: stage the module dir
#    into a writable base and run the sealed depmod to produce one, then resolve
#    the dependency closure of the requested modules and copy just those .ko
#    files into the initrd.
SRC="@@MODULES_TREE@@"
if [ -d "$SRC/lib/modules/@@KVER@@" ]; then
    MODROOT="$SRC/lib/modules/@@KVER@@"
else
    MODROOT="$SRC"
fi
FULL=$(mktemp -d)
mkdir -p "$FULL/lib/modules/@@KVER@@"
cp -rL "$MODROOT/." "$FULL/lib/modules/@@KVER@@/"
"$DEPMOD" -b "$FULL" "@@KVER@@"
FULLDEP="$FULL/lib/modules/@@KVER@@/modules.dep"

DEST="$TREE/lib/modules/@@KVER@@"
mkdir -p "$DEST"
for f in modules.order modules.builtin modules.builtin.modinfo; do
    [ -e "$MODROOT/$f" ] && cp "$MODROOT/$f" "$DEST/$f" || true
done

# Module want-list: the explicit `modules` plus, when modules_most is set, the
# faithful MODULES=most recipe expanded against the source tree (the awk below
# resolves the dep closure of the whole list from modules.dep -- the same path
# the explicit list takes, so "most" needs no modprobe and no chroot).
NAMES="@@MODULES@@"
if [ "@@MOST@@" = "y" ]; then
    sh "@@MOST_SH@@" "$MODROOT" > "$BINDIR/most.list"
    NAMES="$NAMES $(tr '\\n' ' ' < "$BINDIR/most.list")"
fi

"@@GAWK@@" -v names="$NAMES" '
BEGIN { n = split(names, want, " ") }
{
    ci = index($0, ":")
    key = substr($0, 1, ci - 1)
    deps = substr($0, ci + 1)
    depmap[key] = deps
    bn = key
    sub(/.*\\//, "", bn)
    sub(/\\.ko.*/, "", bn)
    byname[bn] = key
}
END {
    qn = 0
    for (i = 1; i <= n; i++) {
        k = byname[want[i]]
        if (k != "") { queue[++qn] = k }
        else { print "WARN: module not found: " want[i] > "/dev/stderr" }
    }
    qi = 0
    while (qi < qn) {
        k = queue[++qi]
        if (seen[k]) continue
        seen[k] = 1
        print k
        nd = split(depmap[k], d, " ")
        for (j = 1; j <= nd; j++) {
            if (d[j] != "" && !seen[d[j]]) queue[++qn] = d[j]
        }
    }
}' "$FULLDEP" | while read -r rel; do
    mkdir -p "$DEST/$(dirname "$rel")"
    cp "$MODROOT/$rel" "$DEST/$rel"
done

# 5. Regenerate modules.dep/alias for just the staged closure.
"$DEPMOD" -b "$TREE" "@@KVER@@"

# 6. Pack as a gzip-compressed newc cpio. Touch every entry to a fixed epoch
#    and force root:0 ownership so the image is reproducible.
find "$TREE" -exec touch -h -d @"${SOURCE_DATE_EPOCH:-0}" {} +
# NB: pass -C "$TREE" rather than `cd "$TREE"` so the execroot-relative tar
# path stays valid.
"@@TAR@@" -cf "@@OUT@@" --format=newc --gzip \\
    --uid 0 --gid 0 --uname root --gname root --numeric-owner -C "$TREE" .
"""
    gawk = ctx.executable._gawk
    busybox = ctx.file.busybox
    userspace_layers = " ".join([f.path for f in ctx.files.userspace_layers])
    most_sh = ctx.file._most_modules
    lister = ctx.file.busybox_lister
    lister_path = lister.path if lister else "$TREE/bin/busybox"

    for token, value in [
        ("@@TAR@@", tar),
        ("@@GAWK@@", gawk.path),
        ("@@ITDATA@@", itdata.path),
        ("@@MODULES_TREE@@", modules_tree.path),
        ("@@DEPMOD@@", depmod.path),
        ("@@KVER@@", kver),
        ("@@MODULES@@", modules),
        ("@@MOST@@", "y" if ctx.attr.modules_most else "n"),
        ("@@MOST_SH@@", most_sh.path),
        ("@@COPY_SCRIPTS@@", copy_scripts),
        ("@@BUSYBOX@@", busybox.path),
        ("@@BUSYBOX_LISTER@@", lister_path),
        ("@@USERSPACE_LAYERS@@", userspace_layers),
        ("@@OUT@@", out.path),
    ]:
        command = command.replace(token, value)

    ctx.actions.run_shell(
        outputs = [out],
        inputs = depset(
            [itdata, modules_tree, busybox, most_sh] +
            script_files + ctx.files.userspace_layers,
        ),
        tools = depset(
            [depmod, gawk] + ([lister] if lister else []),
            transitive = [bsdtar.default.files],
        ),
        command = command,
        mnemonic = "Initramfs",
        progress_message = "Building initramfs %s" % out.short_path,
        env = {"SOURCE_DATE_EPOCH": "0"},
    )
    return [DefaultInfo(files = depset([out]))]

initramfs = rule(
    implementation = _initramfs_impl,
    doc = "Assemble a SONiC initrd cpio from the initramfs-tools tree, the " +
          "SONiC boot scripts, and a kernel module closure.",
    attrs = {
        "initramfs_tools_data": attr.label(
            mandatory = True,
            allow_single_file = [".tar", ".tar.gz"],
            doc = "The (loopback-patched) initramfs-tools-core data tree tar; " +
                  "supplies /init and scripts/functions.",
        ),
        "modules_tree": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "A directory artifact whose root is the contents of " +
                  "lib/modules/<kversion>/ (e.g. kernel_<arch>_modules_install).",
        ),
        "kversion": attr.string(
            mandatory = True,
            doc = "Kernel release, e.g. 6.1.0-29-2-amd64.",
        ),
        "scripts": attr.label_keyed_string_dict(
            allow_files = True,
            doc = "Map of script file -> destination path under the cpio root " +
                  "(e.g. scripts/init-bottom/union-mount). Installed mode 0755.",
        ),
        "busybox": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "A statically-linked busybox binary (target arch). Installed " +
                  "at /bin/busybox; its applet symlink farm is generated by " +
                  "exec'ing `busybox --list-full`, so it must be static to run " +
                  "in the build sandbox (this also means the initrd shell needs " +
                  "no libc). For a cross build, exec arch must equal target arch.",
        ),
        "busybox_lister": attr.label(
            cfg = "exec",
            allow_single_file = True,
            doc = "An EXEC-arch static busybox used only to enumerate applets " +
                  "(`busybox --list-full`) when building the symlink farm. " +
                  "Required for cross builds (arm64 target on an amd64 host), " +
                  "where the target `busybox` cannot be exec'd. Point it at the " +
                  "same busybox source as `busybox`; cfg=exec resolves it to the " +
                  "host arch. If unset, the target `busybox` is exec'd directly " +
                  "(correct only when exec arch == target arch).",
        ),
        "userspace_layers": attr.label_list(
            allow_files = [".tar", ".tar.gz"],
            doc = "apt-closure flatten tars supplying the boot userspace the " +
                  "SONiC hooks need at runtime (e2fsprogs, acl, util-linux, " +
                  "kmod) with their shared-lib closure. Extracted into the cpio " +
                  "root -- the declarative stand-in for mkinitramfs copy_exec.",
        ),
        "modules_most": attr.bool(
            default = True,
            doc = "Include the initramfs-tools MODULES=most module set (faithful " +
                  "to hook-functions:auto_add_modules 0.142) on top of `modules`. " +
                  "On by default to match SONiC's build_debian.sh, which sets " +
                  "MODULES=most unconditionally for every image. Set False for a " +
                  "minimal initrd carrying only the explicit `modules` list.",
        ),
        "_most_modules": attr.label(
            default = "//initramfs:most_modules.sh",
            allow_single_file = True,
        ),
        "modules": attr.string_list(
            mandatory = True,
            doc = "Kernel module base names to include (with their dep closure).",
        ),
        "out": attr.string(
            default = "initrd.img",
            doc = "Name of the initrd image to produce.",
        ),
        "depmod": attr.label(
            mandatory = True,
            executable = True,
            cfg = "exec",
            doc = "A sealed depmod binary (e.g. @sonic_linux_kernel//tools:depmod).",
        ),
        "_gawk": attr.label(
            default = "@gawk",
            executable = True,
            cfg = "exec",
        ),
    },
    toolchains = [tar_lib.toolchain_type],
)

# =============================================================================
# initramfs_real: a REAL Debian-mkinitramfs initrd.
#
# Unlike the structural `initramfs` rule above (which hand-assembles a cpio),
# this runs the unmodified `mkinitramfs` against a staged mini-rootfs, so the
# result is a genuine, bootable initramfs-tools image (busybox /bin, real
# /init + scripts/functions, the full MODULES=most kernel-module set, and the
# SONiC union-mount/fsck hooks resolved through copy_exec's ldd closure).
#
# The mini-rootfs (`minirootfs`) is assembled declaratively in BUILD from
# @bookworm package closures + the loopback-patched initramfs-tools-core +
# the SONiC /etc/initramfs-tools overlay. mkinitramfs runs under
# `unshare --map-root-user --mount` + `chroot` (local, no-sandbox) because it
# needs a writable pivot root; no fakeroot/mknod is required since the boot
# device nodes come from the kernel devtmpfs mount in /init.
# =============================================================================
def _initramfs_real_impl(ctx):
    out = ctx.actions.declare_file(ctx.attr.out)
    bsdtar = ctx.toolchains[tar_lib.toolchain_type]
    tar = bsdtar.tarinfo.binary
    builder = ctx.file._builder

    command = '/bin/sh "%s" "%s" "%s" "%s" "%s" "%s" "%s"' % (
        builder.path,
        tar.path,
        ctx.file.minirootfs.path,
        ctx.file.modules_tree.path,
        ctx.file.kernel_config.path,
        ctx.attr.kversion,
        out.path,
    )

    ctx.actions.run_shell(
        outputs = [out],
        inputs = depset(
            [ctx.file.minirootfs, ctx.file.modules_tree, ctx.file.kernel_config, builder],
        ),
        tools = depset(transitive = [bsdtar.default.files]),
        command = command,
        mnemonic = "InitramfsReal",
        progress_message = "Building real mkinitramfs initrd %s" % out.short_path,
        # mkinitramfs runs inside unshare+chroot, which the Bazel sandbox cannot
        # nest; run locally with no sandbox.
        execution_requirements = {"local": "1", "no-sandbox": "1"},
        use_default_shell_env = True,
    )
    return [DefaultInfo(files = depset([out]))]

initramfs_real = rule(
    implementation = _initramfs_real_impl,
    doc = "Build a real Debian-mkinitramfs initrd from a staged mini-rootfs tar.",
    attrs = {
        "minirootfs": attr.label(
            mandatory = True,
            allow_single_file = [".tar", ".tar.gz"],
            doc = "The assembled mini-rootfs tar (merged-usr userspace + " +
                  "loopback-patched initramfs-tools + SONiC /etc/initramfs-tools).",
        ),
        "modules_tree": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "Directory artifact whose root is the contents of " +
                  "lib/modules/<kversion>/ (e.g. kernel_<arch>_modules_install).",
        ),
        "kernel_config": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "The kernel /boot/config-<kversion> file (mkinitramfs verifies " +
                  "the chosen compressor against CONFIG_RD_*).",
        ),
        "kversion": attr.string(
            mandatory = True,
            doc = "Kernel release, e.g. 6.1.0-29-2-amd64.",
        ),
        "out": attr.string(
            default = "initrd.img",
            doc = "Name of the initrd image to produce.",
        ),
        "_builder": attr.label(
            default = "//initramfs:mkinitramfs_build.sh",
            allow_single_file = True,
        ),
    },
    toolchains = [tar_lib.toolchain_type],
)
