#!/usr/bin/env python3
"""Daemonlessly synthesize a docker `overlay2` /var/lib/docker store.

Reads one or more `oci_image` OCI-layout directories and writes a docker
overlay2 store tree (the contents of /var/lib/docker) into --store. A separate
wrapper tars that tree into dockerfs.tar.gz.

This is a faithful `docker load` into the overlay2 driver, nothing more:
  * each OCI layer is extracted, verbatim, into overlay2/<chainID>/diff/ (one
    overlay2 layer per OCI layer, so Docker's cross-image layer dedup survives);
  * the overlay2 + layerdb + imagedb metadata is computed and written;
  * the only real format conversion is the whiteout marker: OCI layers use AUFS
    whiteouts (.wh.<name> files) but the overlay2 driver wants char-dev(0,0).
    A char-dev can't be mknod-ed unprivileged on disk, but it IS just a tar
    header, so we record each whiteout's path to --char-list and a second
    --inject-into pass writes the char-dev(0,0) members straight into the
    dockerfs tar (no separate manifest, no debugfs char-dev step).

Extraction is done by parallel GNU tar (-xp, setuid-preserving) subprocesses,
NOT a Python member-by-member loop: the loop was ~13x slower (Python overhead
on 150k+ members), and GNU tar handles setuid / hardlinks / ownership natively.
We do NOT rewrite paths (no merged-/usr fixup): that is the oci_image's job --
SONiC's debian-base images already ship merged-/usr layer paths.

Stdlib only.
"""

import argparse
import base64
import gzip
import hashlib
import json
import os
import subprocess
import sys
import tarfile
from concurrent.futures import ThreadPoolExecutor


def warn(msg):
    sys.stderr.write("overlay2_build: WARNING: %s\n" % msg)


def sha256_hex(b):
    return hashlib.sha256(b).hexdigest()


def blob_path(layout_dir, digest):
    algo, hexd = digest.split(":", 1)
    return os.path.join(layout_dir, "blobs", algo, hexd)


def read_blob(layout_dir, digest):
    with open(blob_path(layout_dir, digest), "rb") as f:
        return f.read()


def is_gzip(layer, head):
    mt = layer.get("mediaType", "")
    return mt.endswith("+gzip") or head[:2] == b"\x1f\x8b"


def uncompressed_size(layout_dir, layer):
    """Byte length of the uncompressed layer tar (== layerdb `size`)."""
    p = blob_path(layout_dir, layer["digest"])
    with open(p, "rb") as f:
        head = f.read(2)
    if is_gzip(layer, head):
        total = 0
        with gzip.open(p, "rb") as g:
            while True:
                chunk = g.read(1024 * 1024)
                if not chunk:
                    break
                total += len(chunk)
        return total
    return os.path.getsize(p)


def chain_ids(diff_ids):
    """diff_ids are full 'sha256:hex'. Returns list of chainID hex strings."""
    chain = []
    for i, d in enumerate(diff_ids):
        if i == 0:
            chain.append(d.split(":", 1)[1])
        else:
            data = ("sha256:" + chain[i - 1] + " " + d).encode("ascii")
            chain.append(sha256_hex(data))
    return chain


def short_id(chain_hex):
    """26-char base32 cache-id link name, deterministic from the chainID."""
    digest = hashlib.sha256(chain_hex.encode("ascii")).digest()
    return base64.b32encode(digest).decode("ascii")[:26].upper()


def load_manifest(layout_dir):
    index = json.loads(read_blob_index(layout_dir))
    manifests = index["manifests"]
    if len(manifests) != 1:
        warn("index.json has %d manifests; using the first" % len(manifests))
    return json.loads(read_blob(layout_dir, manifests[0]["digest"]))


def read_blob_index(layout_dir):
    with open(os.path.join(layout_dir, "index.json"), "rb") as f:
        return f.read()


def write_file(path, data, mode="wb"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, mode) as f:
        f.write(data)


def add_repository(repos, repo_tag, image_id):
    repo = repo_tag.rsplit(":", 1)[0]
    repos.setdefault(repo, {})[repo_tag] = "sha256:" + image_id


def extract_one(gtar, blob, diff_dir):
    """Extract one OCI layer blob into diff_dir with GNU tar -xp.

    -p keeps setuid/setgid (the build user owns its own extracted files, so it
    CAN set those bits); GNU tar auto-detects gzip. The store ends up owned by
    the build user -- the final `bsdtar -c --uid 0` maps it back to root.
    """
    subprocess.run([gtar, "-xpf", blob, "-C", diff_dir],
                   check=True, stderr=subprocess.DEVNULL)


def scan_whiteouts(diff_dir, store):
    """After extraction, turn AUFS whiteout markers in this layer's diff into
    overlay2 form: record each .wh.<name> as a store-relative path (for the
    disk-image rule to inject as a char-dev via debugfs) and delete the marker
    file. .wh..wh..opq becomes a trusted.overlay.opaque xattr on its dir.
    Returns the list of store-relative whiteout target paths."""
    wh = []
    for root, _dirs, files in os.walk(diff_dir):
        for name in files:
            if name == ".wh..wh..opq":
                try:
                    os.setxattr(root, "trusted.overlay.opaque", b"y")
                except OSError as e:
                    warn("opaque xattr on %s failed (%s); skipping" % (root, e))
                os.remove(os.path.join(root, name))
            elif name.startswith(".wh."):
                target = os.path.join(root, name[4:])
                wh.append(os.path.relpath(target, store))
                os.remove(os.path.join(root, name))
    return wh


def build_per_layer(store, layout_dir, repo_tag, repos, seen_chains, tasks):
    """Write this image's overlay2/layerdb/imagedb metadata and append its
    not-yet-seen layers' (blob, diff_dir) to `tasks` for parallel extraction.
    seen_chains maps chainID -> layer size, so a chainID shared across images
    (the debian/python base) is extracted and sized exactly once."""
    manifest = load_manifest(layout_dir)
    config_bytes = read_blob(layout_dir, manifest["config"]["digest"])
    image_id = sha256_hex(config_bytes)
    config = json.loads(config_bytes)
    diff_ids = config["rootfs"]["diff_ids"]
    layers = manifest["layers"]
    if len(layers) != len(diff_ids):
        raise SystemExit("layers (%d) != diff_ids (%d)" %
                         (len(layers), len(diff_ids)))

    chains = chain_ids(diff_ids)
    shorts = [short_id(c) for c in chains]

    img_ov2 = os.path.join(store, "image", "overlay2")
    ov2 = os.path.join(store, "overlay2")
    os.makedirs(os.path.join(ov2, "l"), exist_ok=True)
    os.makedirs(os.path.join(img_ov2, "layerdb", "tmp"), exist_ok=True)

    # imagedb: config bytes verbatim, filename == sha256 of the bytes.
    write_file(os.path.join(img_ov2, "imagedb", "content", "sha256", image_id),
               config_bytes)

    for i, layer in enumerate(layers):
        chain_hex = chains[i]
        cache_id = chain_hex
        diff_dir = os.path.join(ov2, cache_id, "diff")

        # Cross-image dedup: same chainID -> same diff_dir; extract+size once.
        if cache_id in seen_chains:
            size = seen_chains[cache_id]
        else:
            os.makedirs(diff_dir, exist_ok=True)
            tasks.append((blob_path(layout_dir, layer["digest"]), diff_dir))
            size = uncompressed_size(layout_dir, layer)
            seen_chains[cache_id] = size

        # overlay2/<cache-id> metadata
        write_file(os.path.join(ov2, cache_id, "link"),
                   shorts[i].encode("ascii"))
        open(os.path.join(ov2, cache_id, "committed"), "wb").close()
        if i > 0:
            # immediate-parent-first, base last
            lower = ":".join("l/" + shorts[j] for j in range(i - 1, -1, -1))
            write_file(os.path.join(ov2, cache_id, "lower"),
                       lower.encode("ascii"))

        # overlay2/l/<SHORT_ID> -> ../<cache-id>/diff
        link_path = os.path.join(ov2, "l", shorts[i])
        if os.path.lexists(link_path):
            os.remove(link_path)
        os.symlink(os.path.join("..", cache_id, "diff"), link_path)

        # layerdb/sha256/<chainID>/{diff,cache-id,size,parent}
        ldir = os.path.join(img_ov2, "layerdb", "sha256", chain_hex)
        os.makedirs(ldir, exist_ok=True)
        write_file(os.path.join(ldir, "diff"), diff_ids[i].encode("ascii"))
        write_file(os.path.join(ldir, "cache-id"), cache_id.encode("ascii"))
        write_file(os.path.join(ldir, "size"), str(size).encode("ascii"))
        if i > 0:
            write_file(os.path.join(ldir, "parent"),
                       ("sha256:" + chains[i - 1]).encode("ascii"))

    add_repository(repos, repo_tag, image_id)
    return image_id


def inject_chardev(tar_path, char_list):
    """Append each whiteout in char_list to tar_path as a char-dev(0,0) member.

    A char-dev can't be mknod-ed unprivileged on disk, but it IS just a tar
    header (typeflag '3', dev 0,0) -- so the overlay2 whiteouts travel inside
    dockerfs.tar itself. The one-image install path (target extracts as root)
    then creates them for free; the kvm-image path injects them via debugfs
    (it extracts unprivileged, where the char-dev members are skipped)."""
    tf = tarfile.open(tar_path, "a", format=tarfile.GNU_FORMAT)
    with open(char_list) as f:
        for line in f:
            p = line.strip()
            if not p:
                continue
            # match bsdtar -c -C <store> . member names ("./overlay2/...")
            ti = tarfile.TarInfo("./" + p)
            ti.type = tarfile.CHRTYPE
            ti.mode = 0
            ti.uid = 0
            ti.gid = 0
            ti.uname = "root"
            ti.gname = "root"
            ti.devmajor = 0
            ti.devminor = 0
            tf.addfile(ti)
    tf.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--store",
                    help="build mode: output store dir (becomes /var/lib/docker)")
    ap.add_argument("--gtar",
                    help="build mode: GNU tar binary to extract layers (-xp).")
    ap.add_argument("--char-list", required=True,
                    help="build mode: write store-relative whiteout paths here; "
                         "inject mode: read them from here.")
    ap.add_argument("--inject-into",
                    help="inject mode: append char-dev(0,0) members (from "
                         "--char-list) to this tar instead of building a store.")
    ap.add_argument("images", nargs="*",
                    help="build mode: OCI-layout-dir=repo:tag specs")
    args = ap.parse_args()

    if args.inject_into:
        inject_chardev(args.inject_into, args.char_list)
        return

    if not args.store or not args.gtar or not args.images:
        ap.error("--store, --gtar and image specs are required to build a store")

    os.makedirs(args.store, exist_ok=True)
    repos = {}
    seen_chains = {}
    tasks = []  # (blob, diff_dir) for each unique chainID, extracted in parallel
    for spec in args.images:
        layout_dir, repo_tag = spec.split("=", 1)
        iid = build_per_layer(args.store, layout_dir, repo_tag, repos,
                              seen_chains, tasks)
        sys.stderr.write("overlay2_build: %s -> imageID sha256:%s\n" %
                         (repo_tag, iid))

    # Extract all unique layers in parallel -- GNU tar subprocesses, so the GIL
    # does not serialize them; this is the heavy step (~150k files, ~7GB).
    with ThreadPoolExecutor(max_workers=os.cpu_count()) as ex:
        list(ex.map(lambda t: extract_one(args.gtar, t[0], t[1]), tasks))

    # Record AUFS whiteouts (after extraction the markers are plain files in the
    # diff dirs); build_store.sh re-invokes us with --inject-into to write them
    # into the final tar as char-dev(0,0) members.
    wh_list = []
    for _blob, diff_dir in tasks:
        wh_list.extend(scan_whiteouts(diff_dir, args.store))

    write_file(os.path.join(args.store, "image", "overlay2",
                            "repositories.json"),
               json.dumps({"Repositories": repos}).encode("utf-8"))

    os.makedirs(os.path.dirname(os.path.abspath(args.char_list)),
                exist_ok=True)
    with open(args.char_list, "w") as f:
        for p in sorted(wh_list):
            f.write(p + "\n")


if __name__ == "__main__":
    main()
