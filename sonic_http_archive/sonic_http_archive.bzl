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

    # 2. Apply patches
    for patch in repository_ctx.attr.patches:
        repository_ctx.patch(
            repository_ctx.path(patch),
            strip = 1,
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
