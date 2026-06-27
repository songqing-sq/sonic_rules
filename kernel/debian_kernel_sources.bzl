"""Debian kernel source acquisition + patching as `@kernel_sources`.

Repository rule that mirrors the source-acquisition flow of the top-level
Makefile (KERNEL_PROCURE_METHOD=build branch). Tarballs are unpacked by Bazel's
native fetch-phase `rctx.download_and_extract()` (no host `tar`); only `git`,
`bash` and coreutils are used afterward. **No `dpkg-source`, no `fakeroot`, no
`kernel-wedge`, no `gencontrol.py`, no `make`, no host gcc-12.**

The output `@kernel_sources` is a PURE patched source tree (no `.config`, no
`.kernelvariables`, no gencontrol output): config generation is done later by
`debian_kernel_config` as a build action.

Flow:
  1. download_and_extract orig.tar.xz         -> linux-<kv>/
  2. download_and_extract debian.tar.xz into  -> linux-<kv>/debian/
  3. apply debian/patches/series (git apply -p1), git init + commit
  4. apply SONiC patch/preconfig/series       (git apply -p1), commit
  5. apply SONiC patch/series                 (git apply -p1), commit
  6. delete Debian self-referential build symlinks (glob OOM guard)
"""

_GIT_AUTHOR_ENV = {
    "GIT_AUTHOR_NAME": "sonic",
    "GIT_AUTHOR_EMAIL": "sonic@sonic",
    "GIT_COMMITTER_NAME": "sonic",
    "GIT_COMMITTER_EMAIL": "sonic@sonic",
}

_LINUX_BASE = "https://packages.trafficmanager.net/public/debian-security/pool/updates/main/l/linux"

def _run(rctx, args, what, working_directory = None, environment = None):
    """Run a host command and fail with an actionable message on error."""
    kwargs = {}
    if working_directory != None:
        kwargs["working_directory"] = working_directory
    if environment != None:
        kwargs["environment"] = environment
    res = rctx.execute(args, **kwargs)
    if res.return_code != 0:
        fail("kernel_sources: step '{what}' failed (rc={rc}).\nargv: {argv}\nstdout:\n{out}\nstderr:\n{err}".format(
            what = what,
            rc = res.return_code,
            argv = args,
            out = res.stdout,
            err = res.stderr,
        ))
    return res

def _apply_series_script(series_path, patch_dir, kernel_dir):
    """Bash applying a quilt/stg-style series file via `git apply -p1`.

    Each non-empty / non-comment line in `series_path` names a patch file
    relative to `patch_dir`. `###->` markers and `#`/`;` comments are skipped;
    the first whitespace-delimited token of each line is the patch name.
    """
    return """
set -eu
series_file='{series}'
patch_dir='{patch_dir}'
kernel_dir='{kernel_dir}'
if [ ! -f "$series_file" ]; then
    echo "series file not found: $series_file" >&2
    exit 1
fi
cd "$kernel_dir"
while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
        ''|'#'*|';'*) continue ;;
    esac
    name=$(printf '%s' "$line" | awk '{{print $1}}')
    [ -z "$name" ] && continue
    patch_path="$patch_dir/$name"
    if [ ! -f "$patch_path" ]; then
        echo "patch missing: $patch_path" >&2
        exit 1
    fi
    if ! git apply -p1 "$patch_path"; then
        echo "git apply failed for $patch_path" >&2
        exit 1
    fi
done < "$series_file"
""".format(
        series = series_path,
        patch_dir = patch_dir,
        kernel_dir = kernel_dir,
    )

def _impl(rctx):
    kv = rctx.attr.kernel_version
    ksv = rctx.attr.kernel_subversion

    orig_name = "linux_{}.orig.tar.xz".format(kv)
    debian_name = "linux_{}-{}.debian.tar.xz".format(kv, ksv)

    kernel_dir = rctx.attr.kernel_src_dir

    # ---- 1. download + extract orig tarball -> linux-<kv>/ ---------------
    # Bazel natively unpacks .tar.xz during fetch (no host `tar`). The orig
    # tarball ships a single top-level `linux-<kv>/` dir, so output="." lands
    # the tree at the repo root exactly as `tar -xJf orig` did.
    rctx.report_progress("downloading + extracting {}".format(orig_name))
    rctx.download_and_extract(
        url = _LINUX_BASE + "/" + orig_name,
        output = ".",
        sha256 = rctx.attr.orig_sha,
    )

    # ---- 2. download + extract debian tarball into linux-<kv>/debian/ ----
    # The debian tarball ships a top-level `debian/` dir; extracting with
    # output=linux-<kv> merges it into the source tree (matches the old
    # `tar -xJf debian -C linux-<kv>`).
    rctx.report_progress("downloading + extracting {}".format(debian_name))
    rctx.download_and_extract(
        url = _LINUX_BASE + "/" + debian_name,
        output = kernel_dir,
        sha256 = rctx.attr.debian_sha,
    )

    # Absolute paths.
    kernel_abs = str(rctx.path(kernel_dir))

    # Locate the workspace patch/ root from the series label's dirname.
    patch_root = str(rctx.path(rctx.attr.series).dirname)  # .../patch

    # ---- 4. apply Debian's own debian/patches/series, then init git ------
    rctx.report_progress("applying debian/patches/series")
    debian_series = "{}/debian/patches/series".format(kernel_abs)
    debian_patch_dir = "{}/debian/patches".format(kernel_abs)
    _run(
        rctx,
        ["bash", "-c", _apply_series_script(debian_series, debian_patch_dir, kernel_abs)],
        what = "apply debian quilt series",
    )

    rctx.report_progress("initializing git in {}".format(kernel_dir))
    _run(rctx, ["git", "init", "-q"], what = "git init", working_directory = kernel_abs)
    _run(rctx, ["git", "add", "-f", "--", "."], what = "git add initial", working_directory = kernel_abs)
    _run(
        rctx,
        ["git", "commit", "-qm", "debian source"],
        what = "git commit (debian source)",
        working_directory = kernel_abs,
        environment = _GIT_AUTHOR_ENV,
    )

    # ---- 5. apply SONiC preconfig series --------------------------------
    rctx.report_progress("applying SONiC patch/preconfig/series")
    preconfig_series = "{}/preconfig/series".format(patch_root)
    preconfig_patch_dir = "{}/preconfig".format(patch_root)
    _run(
        rctx,
        ["bash", "-c", _apply_series_script(preconfig_series, preconfig_patch_dir, kernel_abs)],
        what = "apply preconfig series",
    )
    _run(rctx, ["git", "add", "-A"], what = "git add (preconfig)", working_directory = kernel_abs)
    _run(
        rctx,
        ["git", "commit", "-qm", "preconfig"],
        what = "git commit (preconfig)",
        working_directory = kernel_abs,
        environment = _GIT_AUTHOR_ENV,
    )

    # ---- 6. apply main SONiC series -------------------------------------
    rctx.report_progress("applying SONiC patch/series")
    main_series = "{}/series".format(patch_root)
    _run(
        rctx,
        ["bash", "-c", _apply_series_script(main_series, patch_root, kernel_abs)],
        what = "apply SONiC main series",
    )
    _run(rctx, ["git", "add", "-A"], what = "git add (sonic)", working_directory = kernel_abs)
    _run(
        rctx,
        ["git", "commit", "-qm", "sonic patches"],
        what = "git commit (sonic patches)",
        working_directory = kernel_abs,
        environment = _GIT_AUTHOR_ENV,
    )

    # ---- 7. remove Debian self-referential build symlinks ---------------
    # If any patch / debian rule created `debian/build/source_none` or
    # `debian/build/build_*/source` (symlinks back to the kernel root), the
    # glob(["**"]) that exposes the tree would follow them into a cycle and
    # exhaust Bazel's analysis heap. Drop them defensively; Kbuild recreates the
    # O= `source` symlink itself during the build.
    for ln in [
        kernel_dir + "/debian/build/source_none",
        kernel_dir + "/debian/build/build_amd64_none_amd64/source",
    ]:
        rctx.delete(ln)

    # ---- 7b. drop the .git dir used only for `git apply` layering --------
    # git is only used at fetch time to stage the patch layers; the exposed
    # tree needs no version control. Bazel marks fetched repos read-only, so a
    # left-over .git (hundreds of MB of mode-0444 objects) makes kernel_build's
    # `cp -a` + scratch cleanup choke ("Permission denied" / "Directory not
    # empty"). Remove it here so @kernel_sources is a pure, smaller source tree.
    _run(rctx, ["rm", "-rf", ".git"], what = "remove .git", working_directory = kernel_abs)

    # ---- 8. emit BUILD.bazel exposing the pure patched tree -------------
    rctx.file("WORKSPACE", "")
    rctx.template("BUILD.bazel", rctx.attr._build_tpl, substitutions = {
        "{BUILD_DIR}": kernel_dir,
    })

debian_kernel_sources = repository_rule(
    implementation = _impl,
    attrs = {
        "series": attr.label(
            mandatory = True,
            doc = "patch/series file (main SONiC patch set). Its dirname locates patch/.",
        ),
        "preconfig_series": attr.label(
            mandatory = True,
            doc = "patch/preconfig/series file.",
        ),
        "patches": attr.label_list(
            mandatory = True,
            doc = "All files under patch/ (declared so rctx re-fetches on change).",
        ),
        "kernel_version": attr.string(
            mandatory = True,
            doc = "Upstream kernel version, e.g. 6.1.123.",
        ),
        "kernel_subversion": attr.string(
            mandatory = True,
            doc = "Debian sub-version, e.g. 1.",
        ),
        "kernel_src_dir": attr.string(
            mandatory = True,
            doc = "Unpacked source dir name, e.g. linux-6.1.123.",
        ),
        "orig_sha": attr.string(
            mandatory = True,
            doc = "sha256 of the orig.tar.xz (version-coupled).",
        ),
        "debian_sha": attr.string(
            mandatory = True,
            doc = "sha256 of the debian.tar.xz (version-coupled).",
        ),
        "_build_tpl": attr.label(
            default = "//kernel:kernel_sources.BUILD.tpl",
            allow_single_file = True,
        ),
    },
    doc = "Downloads, extracts (download_and_extract) and patches (git apply) " +
          "the Debian 6.1.123 kernel source for SONiC. Pure patched tree; no config.",
)
