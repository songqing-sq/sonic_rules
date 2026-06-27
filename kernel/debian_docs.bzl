"""Rules to generate /usr/share/doc/<pkg>/ content for Debian kernel debs.

Each deb (linux-image, linux-headers-amd64, linux-headers-common) ships:
  /usr/share/doc/<package>/changelog.Debian.gz  — gzip -n of debian/changelog
  /usr/share/doc/<package>/copyright            — verbatim copy of debian/copyright

Both files are sourced from the @kernel_sources filegroup (the patched
Debian kernel source tree). The changelog is compressed with `gzip -n`
(no embedded filename or mtime) for bit-reproducibility.

Exposed symbols:
  debian_changelog_gz  — rule that locates debian/changelog in kernel_sources
                         and emits a gzip-compressed output file.
  debian_copyright     — rule that locates debian/copyright in kernel_sources
                         and emits a plain-copy output file.
  debian_news_gz       — rule that locates debian/<news_file> in kernel_sources
                         and emits a gzip-compressed NEWS.Debian.gz output.
"""

# ---------------------------------------------------------------------------
# debian_changelog_gz
# ---------------------------------------------------------------------------

def _debian_changelog_gz_impl(ctx):
    # Locate debian/changelog by suffix in the kernel_sources filegroup.
    # The suffix is unique across the tree (there is only one debian/changelog).
    changelog_file = None
    for f in ctx.files.kernel_sources:
        if f.short_path.endswith("/debian/changelog"):
            changelog_file = f
            break
    if changelog_file == None:
        fail("debian_changelog_gz: no file ending in '/debian/changelog' found in kernel_sources")

    # Output must be named "changelog.Debian.gz" so it lands under
    # /usr/share/doc/<pkg>/changelog.Debian.gz when the sonic_deb content
    # map uses the /*:mode wildcard-strip form.
    out = ctx.actions.declare_file(ctx.label.name + "/changelog.Debian.gz")

    # gzip -n: suppress embedded filename and mtime in the gzip header for
    # reproducibility (matches `gzip --no-name`). Sufficient on its own —
    # no SOURCE_DATE_EPOCH plumbing needed.
    ctx.actions.run_shell(
        inputs = [changelog_file],
        outputs = [out],
        command = "gzip -n -c '{src}' > '{out}'".format(
            src = changelog_file.path,
            out = out.path,
        ),
        mnemonic = "GzipChangelog",
        progress_message = "Compressing debian/changelog for %{label}",
    )
    return [DefaultInfo(files = depset([out]))]

debian_changelog_gz = rule(
    implementation = _debian_changelog_gz_impl,
    attrs = {
        "kernel_sources": attr.label(
            mandatory = True,
            allow_files = True,
            doc = "Target whose DefaultInfo files include debian/changelog " +
                  "(typically @kernel_sources//:all).",
        ),
    },
    doc = "Emits debian/changelog compressed with gzip -n (no name/mtime " +
          "in header) for use in /usr/share/doc/<pkg>/changelog.Debian.gz.",
)

# ---------------------------------------------------------------------------
# debian_copyright
# ---------------------------------------------------------------------------

def _debian_copyright_impl(ctx):
    # Locate debian/copyright by suffix in the kernel_sources filegroup.
    copyright_file = None
    for f in ctx.files.kernel_sources:
        if f.short_path.endswith("/debian/copyright"):
            copyright_file = f
            break
    if copyright_file == None:
        fail("debian_copyright: no file ending in '/debian/copyright' found in kernel_sources")

    # Output must be named "copyright" so it lands under
    # /usr/share/doc/<pkg>/copyright when the sonic_deb content map
    # uses the /*:mode wildcard-strip form.
    out = ctx.actions.declare_file(ctx.label.name + "/copyright")
    ctx.actions.run_shell(
        inputs = [copyright_file],
        outputs = [out],
        command = "cp -L '{src}' '{out}'".format(
            src = copyright_file.path,
            out = out.path,
        ),
        mnemonic = "CopyDebianCopyright",
        progress_message = "Copying debian/copyright for %{label}",
    )
    return [DefaultInfo(files = depset([out]))]

debian_copyright = rule(
    implementation = _debian_copyright_impl,
    attrs = {
        "kernel_sources": attr.label(
            mandatory = True,
            allow_files = True,
            doc = "Target whose DefaultInfo files include debian/copyright " +
                  "(typically @kernel_sources//:all).",
        ),
    },
    doc = "Emits a verbatim copy of debian/copyright for use in " +
          "/usr/share/doc/<pkg>/copyright.",
)

# ---------------------------------------------------------------------------
# debian_news_gz
# ---------------------------------------------------------------------------

def _debian_news_gz_impl(ctx):
    # Locate the NEWS file by suffix match. The image deb uses
    # debian/linux-image.NEWS; adjust the suffix via the news_file_suffix attr.
    news_suffix = ctx.attr.news_file_suffix
    news_file = None
    for f in ctx.files.kernel_sources:
        if f.short_path.endswith(news_suffix):
            news_file = f
            break
    if news_file == None:
        fail("debian_news_gz: no file ending in %r found in kernel_sources" % news_suffix)

    # Output must be named "NEWS.Debian.gz" so it lands under
    # /usr/share/doc/<pkg>/NEWS.Debian.gz when the sonic_deb content
    # map uses the /*:mode wildcard-strip form.
    out = ctx.actions.declare_file(ctx.label.name + "/NEWS.Debian.gz")
    ctx.actions.run_shell(
        inputs = [news_file],
        outputs = [out],
        command = "gzip -n -c '{src}' > '{out}'".format(
            src = news_file.path,
            out = out.path,
        ),
        mnemonic = "GzipNews",
        progress_message = "Compressing debian NEWS for %{label}",
    )
    return [DefaultInfo(files = depset([out]))]

debian_news_gz = rule(
    implementation = _debian_news_gz_impl,
    attrs = {
        "kernel_sources": attr.label(
            mandatory = True,
            allow_files = True,
            doc = "Target whose DefaultInfo files include the NEWS file " +
                  "(typically @kernel_sources//:all).",
        ),
        "news_file_suffix": attr.string(
            mandatory = True,
            doc = "Path suffix to locate the NEWS file, e.g. " +
                  "'/debian/linux-image.NEWS'.",
        ),
    },
    doc = "Emits a debian NEWS file compressed with gzip -n for use in " +
          "/usr/share/doc/<pkg>/NEWS.Debian.gz.",
)
