"""`docker_overlay2_store`: daemonlessly synthesize a docker overlay2 store.

Reads one or more `oci_image` OCI-layout directories and produces
`dockerfs.tar.gz` containing a ready-to-use `/var/lib/docker` (overlay2 driver),
replacing the legacy "dockerd in chroot + docker load + tar /var/lib/docker".

overlay2_build.py extracts each OCI layer into the store with parallel hermetic
GNU tar (-xp) and computes the overlay2/layerdb/imagedb metadata; build_store.sh
then tars the store with the sealed bsdtar, appends the overlay2 whiteouts as
char-dev(0,0) tar members (so they live inside dockerfs.tar.gz, not a side
manifest), and compresses with hermetic pigz (parallel gzip).
"""

load("@tar.bzl//tar:tar.bzl", tar_lib = "tar_lib")

def _impl(ctx):
    out = ctx.actions.declare_file(ctx.attr.out)
    bsdtar = ctx.toolchains[tar_lib.toolchain_type]
    builder = ctx.executable._builder
    wrapper = ctx.file._wrapper
    pigz = ctx.executable._pigz
    gtar = ctx.executable._gtar

    inputs = []
    specs = []
    for target, repo_tag in ctx.attr.images.items():
        layout = target[DefaultInfo].files.to_list()[0]
        inputs.append(layout)
        specs.append("%s=%s" % (layout.path, repo_tag))

    command = 'bash "{wrapper}" "{py}" "{tar}" "{pigz}" "{gtar}" "{out}" {specs}'.format(
        wrapper = wrapper.path,
        py = builder.path,
        tar = bsdtar.tarinfo.binary.path,
        pigz = pigz.path,
        gtar = gtar.path,
        out = out.path,
        specs = " ".join(['"%s"' % s for s in specs]),
    )

    builder_runfiles = ctx.attr._builder[DefaultInfo].default_runfiles.files
    # //disk_image:pigz and //tar:tar are native_binary targets whose outputs are
    # SYMLINKS to the real binaries; each must be in the action's tools (with its
    # runfiles carrying the real binary) or the symlink dangles and bash exits 127.
    pigz_runfiles = ctx.attr._pigz[DefaultInfo].default_runfiles.files
    gtar_runfiles = ctx.attr._gtar[DefaultInfo].default_runfiles.files

    ctx.actions.run_shell(
        outputs = [out],
        inputs = depset(inputs),
        tools = depset(
            [builder, wrapper, pigz, gtar],
            transitive = [bsdtar.default.files, builder_runfiles, pigz_runfiles, gtar_runfiles],
        ),
        command = command,
        mnemonic = "DockerOverlay2Store",
        progress_message = "Building overlay2 store %s" % out.short_path,
        # Blobs in the OCI layout are relative symlinks into sibling image dirs;
        # they only resolve in the execroot, so run locally without sandboxing.
        execution_requirements = {"no-sandbox": "1", "local": "1"},
    )
    return [DefaultInfo(files = depset([out]))]

docker_overlay2_store = rule(
    implementation = _impl,
    doc = "Synthesize a docker overlay2 /var/lib/docker store as dockerfs.tar.gz.",
    attrs = {
        "images": attr.label_keyed_string_dict(
            mandatory = True,
            doc = "oci_image target -> its \"repo:tag\".",
        ),
        "out": attr.string(
            default = "dockerfs.tar.gz",
            doc = "Name of the gzipped store tarball to produce.",
        ),
        "_builder": attr.label(
            default = "//dockerfs:overlay2_build",
            executable = True,
            cfg = "exec",
        ),
        "_gtar": attr.label(
            default = "//tar:tar",
            executable = True,
            cfg = "exec",
            doc = "Hermetic GNU tar; overlay2_build extracts each OCI layer " +
                  "with it (-xp, setuid-preserving) in parallel.",
        ),
        "_wrapper": attr.label(
            default = "//dockerfs:build_store.sh",
            allow_single_file = True,
        ),
        "_pigz": attr.label(
            default = "//disk_image:pigz",
            executable = True,
            cfg = "exec",
            doc = "Hermetic parallel gzip (pigz 2.8); compresses the store tar " +
                  "across all cores instead of bsdtar's single-threaded zlib.",
        ),
    },
    toolchains = [tar_lib.toolchain_type],
)
