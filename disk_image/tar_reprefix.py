#!/usr/bin/env python3
"""Stream-assemble the SONiC-OS partition tar for `mke2fs -d -`.

Emits ONE uncompressed tar on stdout, combining:

  1. the small on-disk staging tree (image-<ver>/boot, image-<ver>/platform,
     machine.conf) -- already laid out with the exact partition-root paths;
  2. the docker overlay2 store read (uncompressed) from stdin, with every
     member re-rooted under <docker_prefix> (e.g. image-<ver>/docker).

This replaces the old "bsdtar -x the store to a tmpdir, then mke2fs -d <dir>"
round-trip: the ~7 GiB store is never written to disk, it streams
dockerfs.tar.gz -> pigz -> here -> mke2fs straight into the ext4.

overlay2 whiteouts ride along as char-dev(0,0) members; tarfile copies their
type + devmajor/devminor verbatim, so mke2fs's libarchive reader recreates them
as char-dev inodes directly in the ext4 -- no root, no separate debugfs mknod
pass. (bsdtar's -s path-rewrite does NOT apply to entries copied from an
existing archive, which is why this re-prefix is done here, not in bsdtar.)

Usage: tar_reprefix.py <stage_dir> <docker_prefix>   (docker tar on stdin)
"""
import os
import sys
import tarfile


def main():
    stage_dir = sys.argv[1]
    docker_prefix = sys.argv[2].strip("/")

    out = tarfile.open(fileobj=sys.stdout.buffer, mode="w|",
                       format=tarfile.GNU_FORMAT)

    # 1) Staging tree: add each top-level entry so arcnames stay exactly as laid
    #    out on disk (image-<ver>/boot/..., image-<ver>/platform/...,
    #    machine.conf). tarfile.add recurses, parents first.
    for name in sorted(os.listdir(stage_dir)):
        out.add(os.path.join(stage_dir, name), arcname=name, recursive=True)

    # 2) Docker store from stdin, re-rooted under docker_prefix.
    #
    # mke2fs's tar reader does an ext2_lookup of each member's parent dir; it
    # does NOT mkdir -p. The store tar's first real member is ./overlay2/, whose
    # re-rooted parent image-<ver>/docker has no entry of its own (the store root
    # "." is dropped below, and the staging tree carries no docker dir), so emit
    # the docker_prefix directory explicitly first.
    ddir = tarfile.TarInfo(docker_prefix)
    ddir.type = tarfile.DIRTYPE
    ddir.mode = 0o755
    out.addfile(ddir)

    src = tarfile.open(fileobj=sys.stdin.buffer, mode="r|")
    for m in src:
        rel = m.name
        if rel.startswith("./"):
            rel = rel[2:]
        if rel in ("", "."):
            continue
        m.name = docker_prefix + "/" + rel
        # A hardlink's target is an archive-relative path, so it must be
        # re-rooted too. A symlink's target is resolved at runtime in the
        # filesystem, so it is left untouched.
        if m.type == tarfile.LNKTYPE:
            ln = m.linkname
            if ln.startswith("./"):
                ln = ln[2:]
            m.linkname = docker_prefix + "/" + ln
        if m.isreg():
            out.addfile(m, src.extractfile(m))
        else:
            out.addfile(m)
    src.close()
    out.close()


if __name__ == "__main__":
    main()
