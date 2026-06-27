#!/usr/bin/env python3
"""Compute a dpkg `md5sums` control file by streaming a data tar.

Replaces the old "bsdtar -x the whole data tar to a tmpdir, then fork md5sum
per file" path: the tar is read ONCE in-process (gzip/xz/bz2 auto-detected),
each regular-file member is hashed with hashlib, and "<md5>  <path>" lines are
written sorted by path (leading "./" stripped). No on-disk extract, no
per-file subprocess -- the device-data deb alone has thousands of small files,
so the old path wrote+reread every file and forked md5sum thousands of times.

Output is byte-identical to the old `find . -type f | sort | md5sum` flow:
regular files only (hardlinks included, matching `find -type f`), two spaces
between digest and path, sorted by path.

Usage: md5sums_from_tar.py <data_tar> <out>
"""
import hashlib
import sys
import tarfile

_CHUNK = 1 << 20


def main():
    data_tar, out = sys.argv[1], sys.argv[2]
    lines = []
    with tarfile.open(data_tar, "r:*") as tf:
        for member in tf:
            # `find . -type f` counts regular files AND hardlinks (each link is
            # a real dir entry post-extract); dirs/symlinks/devices are skipped.
            if not (member.isfile() or member.islnk()):
                continue
            src = tf.extractfile(member)  # follows hardlinks to the target data
            digest = hashlib.md5()
            for chunk in iter(lambda: src.read(_CHUNK), b""):
                digest.update(chunk)
            rel = member.name[2:] if member.name.startswith("./") else member.name
            lines.append((rel, digest.hexdigest()))
    lines.sort()
    with open(out, "w") as fh:
        for rel, digest in lines:
            fh.write("%s  %s\n" % (digest, rel))


if __name__ == "__main__":
    main()
