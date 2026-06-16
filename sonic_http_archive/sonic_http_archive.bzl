"""Generic http_archive repository rule with BUILD template substitution.

Wraps download/extract/patch to also:
  - Generate a BUILD file from a template with {REPO_DIR} substitution
  - Symlink extra files into the repo for load() resolution
"""

def _sonic_http_archive_impl(repository_ctx):
    # 1. Download and extract
    repository_ctx.download_and_extract(
        url = repository_ctx.attr.urls,
        sha256 = repository_ctx.attr.sha256,
        stripPrefix = repository_ctx.attr.strip_prefix,
        type = repository_ctx.attr.type,
    )

    # 2. Apply patches.
    # Bazel's native patch implementation rejects some valid git-format patches
    # (e.g. a "\ No newline at end of file" marker on the final hunk). When
    # patch_tool is set, shell out to the system patch utility (-p1) which is
    # more lenient and matches the legacy `git apply -p1` / `patch -p1` flow.
    patch_tool = repository_ctx.attr.patch_tool
    patch_strip = repository_ctx.attr.patch_strip
    for patch in repository_ctx.attr.patches:
        if patch_tool:
            result = repository_ctx.execute(
                [patch_tool, "-p" + str(patch_strip), "--no-backup-if-mismatch", "-i", repository_ctx.path(patch)],
            )
            if result.return_code != 0:
                fail("Error applying patch {}:\n{}\n{}".format(patch, result.stdout, result.stderr))
        else:
            repository_ctx.patch(
                repository_ctx.path(patch),
                strip = patch_strip,
            )

    # 3. Generate BUILD file from template
    repo_dir = "external/" + repository_ctx.name
    substitutions = dict(repository_ctx.attr.substitutions)
    if "{REPO_DIR}" not in substitutions:
        substitutions["{REPO_DIR}"] = repo_dir

    repository_ctx.template(
        "BUILD.bazel",
        repository_ctx.attr.build_file_template,
        substitutions = substitutions,
    )

    # 4. Copy extra files (e.g. .bzl helpers, test data)
    for extra_file in repository_ctx.attr.extra_files:
        repository_ctx.symlink(
            repository_ctx.path(extra_file),
            extra_file.name,
        )

sonic_http_archive = repository_rule(
    implementation = _sonic_http_archive_impl,
    attrs = {
        "urls": attr.string_list(mandatory = True),
        "sha256": attr.string(mandatory = True),
        "strip_prefix": attr.string(),
        "type": attr.string(
            doc = "Archive type (zip, tar.gz, etc). Auto-detected if not specified.",
        ),
        "patches": attr.label_list(
            doc = "Patch files to apply after extraction.",
        ),
        "patch_tool": attr.string(
            default = "",
            doc = "If set (e.g. \"patch\"), use this system tool (-p1) to apply " +
                  "patches instead of Bazel's native patch. More lenient with " +
                  "git-format patches that have malformed newline markers.",
        ),
        "patch_strip": attr.int(
            default = 1,
            doc = "Strip level (-pN) applied to every patch, for both the " +
                  "native and patch_tool code paths. Default 1 preserves all " +
                  "existing callers; set to 2 when patch paths carry an extra " +
                  "leading component (e.g. a/<pkg-version>/...).",
        ),
        "build_file_template": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "BUILD file template. Supports {REPO_DIR} substitution.",
        ),
        "substitutions": attr.string_dict(
            doc = "Additional template substitutions beyond {REPO_DIR}.",
        ),
        "extra_files": attr.label_list(
            allow_files = True,
            doc = "Extra files to symlink into the fetched repo root.",
        ),
    },
)
