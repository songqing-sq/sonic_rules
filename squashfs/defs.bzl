"""Rule to build a SquashFS image from a rootfs tree provided as a tar.

Mirrors legacy build_debian.sh:946:
    mksquashfs <tree> fs.squashfs -comp zstd -b 1M -e boot -e var/lib/docker

Uses the hermetic, from-source mksquashfs (//squashfs/tools:mksquashfs) and the
sealed bsdtar from @tar.bzl rather than any tool on the host PATH.
"""

load("@tar.bzl//tar:tar.bzl", tar_lib = "tar_lib")

def _mksquashfs_impl(ctx):
    out = ctx.actions.declare_file(ctx.attr.out)
    bsdtar = ctx.toolchains[tar_lib.toolchain_type]
    tree = ctx.file.tree
    mksq = ctx.executable._mksquashfs

    excludes = " ".join(["-e '%s'" % e for e in ctx.attr.excludes])

    command = """
set -euo pipefail
# mksquashfs -tar reads the rootfs tar on stdin and builds the image directly
# from the tar metadata -- no extraction to a work dir. This (a) drops the
# pack-then-unpack round-trip of the whole rootfs, and (b) takes setuid/setgid
# (and any special files) straight from the tar headers, instead of relying on a
# non-root re-extraction that can only set setuid on build-user-owned files.
# bsdtar -cf - @ re-streams .tar/.tar.gz as an uncompressed tar; -all-root maps
# ownership to root; -wildcards makes -e match nested paths (e.g. var/lib/docker).
"{tar}" -cf - @"{tree}" | "{mksq}" - "{out}" -tar -noappend -comp zstd -b 1M -all-root -wildcards {excludes}
""".format(
        tar = bsdtar.tarinfo.binary.path,
        tree = tree.path,
        mksq = mksq.path,
        out = out.path,
        excludes = excludes,
    )

    ctx.actions.run_shell(
        outputs = [out],
        inputs = [tree],
        tools = depset([mksq], transitive = [bsdtar.default.files]),
        command = command,
        mnemonic = "Mksquashfs",
        progress_message = "Building squashfs %s" % out.short_path,
    )
    return [DefaultInfo(files = depset([out]))]

mksquashfs = rule(
    implementation = _mksquashfs_impl,
    doc = "Turn a rootfs tree (a .tar/.tar.gz) into a SquashFS image.",
    attrs = {
        "tree": attr.label(
            mandatory = True,
            allow_single_file = [".tar", ".tar.gz"],
            doc = "A single .tar (or .tar.gz) holding the rootfs tree.",
        ),
        "out": attr.string(
            default = "fs.squashfs",
            doc = "Name of the SquashFS image to produce.",
        ),
        "excludes": attr.string_list(
            default = ["boot", "var/lib/docker"],
            doc = "Paths (relative to the tree root) to exclude from the image.",
        ),
        "_mksquashfs": attr.label(
            default = "//squashfs/tools:mksquashfs",
            executable = True,
            cfg = "exec",
        ),
    },
    toolchains = [tar_lib.toolchain_type],
)

def _sonic_squashfs_impl(ctx):
    out = ctx.actions.declare_file(ctx.attr.out)
    mksq = ctx.executable._mksquashfs
    gtar = ctx.executable._tar
    layers = ctx.files.layers

    excludes = " ".join(["-e '%s'" % e for e in ctx.attr.excludes])
    layer_paths = " ".join(['"%s"' % f.path for f in layers])

    # Assemble the rootfs tree and squash it in ONE action: the tree lives only
    # in this action's tmpdir, so there is no intermediate rootfs.tar artifact
    # (~1.3G) packed by one rule just to be re-read by another. This fuses the
    # legacy sonic_rootfs (unpack layers) and mksquashfs (tree -> squashfs)
    # steps; mksquashfs reads the tmpdir directly. merged-/usr is handled by the
    # first layer (merged_usr_skeleton) + --keep-directory-symlink, not a fixup.
    command = """
set -euo pipefail
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
# Use the hermetic from-source GNU tar (//tar:tar), NOT the sealed bsdtar:
# bsdtar -p does not restore setuid/setgid when extracting as non-root, which
# silently drops the suid bit on sudo/mount/su, and bsdtar has no
# --keep-directory-symlink. GNU tar -p keeps setuid on the build-user's own
# files; mksquashfs -all-root then maps owner to root, giving correct
# setuid-root binaries.
#
# --keep-directory-symlink: the FIRST layer (merged_usr_skeleton) lays down
# bin/sbin/lib[/lib64] -> usr/* symlinks; this flag makes tar follow those
# symlinks when later layers carry ./bin/x etc., so the content lands in /usr
# (exactly as debootstrap + dpkg do). No post-hoc merged-usr fixup needed.
for f in {layers}; do "{tar}" -xpf "$f" -C "$d" --keep-directory-symlink; done
mkdir -p "$d/etc"
[ -f "$d/etc/os-release" ] || echo 'ID=sonic' > "$d/etc/os-release"
# mksquashfs reads the assembled tree directly (directory mode); -e excludes are
# source-relative paths (no -wildcards needed, mirroring build_debian.sh:946).
"{mksq}" "$d" "{out}" -noappend -comp zstd -b 1M -all-root {excludes}
""".format(
        mksq = mksq.path,
        tar = gtar.path,
        out = out.path,
        layers = layer_paths,
        excludes = excludes,
    )

    ctx.actions.run_shell(
        outputs = [out],
        inputs = layers,
        tools = depset([mksq, gtar]),
        command = command,
        mnemonic = "SonicSquashfs",
        progress_message = "Assembling rootfs + squashfs %s" % out.short_path,
    )
    return [DefaultInfo(files = depset([out]))]

sonic_squashfs = rule(
    implementation = _sonic_squashfs_impl,
    doc = "Assemble rootfs layer tars into one tree (unpack + merged-usr fixup) " +
          "and squash it to a SquashFS image in a single action -- no " +
          "intermediate rootfs.tar artifact. Fuses sonic_rootfs + mksquashfs for " +
          "the image build path; the standalone rules remain for other uses.",
    attrs = {
        "layers": attr.label_list(
            mandatory = True,
            allow_files = [".tar", ".tar.gz"],
            doc = "Rootfs layer tars, unpacked in order into one tree.",
        ),
        "out": attr.string(
            default = "fs.squashfs",
            doc = "Name of the SquashFS image to produce.",
        ),
        "excludes": attr.string_list(
            default = ["boot", "var/lib/docker"],
            doc = "Paths (relative to the tree root) to exclude from the image.",
        ),
        "_mksquashfs": attr.label(
            default = "//squashfs/tools:mksquashfs",
            executable = True,
            cfg = "exec",
        ),
        "_tar": attr.label(
            default = "//tar:tar",
            executable = True,
            cfg = "exec",
            doc = "Hermetic from-source GNU tar (setuid-preserving -p + " +
                  "--keep-directory-symlink), replacing the host tar.",
        ),
    },
)
