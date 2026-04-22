def _extract_proto_headers(ctx):
    all_headers = ctx.attr.cc_proto_target[CcInfo].compilation_context.direct_public_headers
    headers_to_move = [
        f
        for f in all_headers
        if "_virtual_includes" in f.dirname and f.path.endswith(".pb.h")
    ]

    outputs = []
    for src in headers_to_move:
        out = ctx.actions.declare_file(ctx.attr.outdir + "/" + src.basename)
        ctx.actions.run_shell(
            inputs = [src],
            outputs = [out],
            command = "cp \"$1\" \"$2\"",
            arguments = [src.path, out.path],
        )
        outputs.append(out)

    return [
        DefaultInfo(
            files = depset(outputs),
            runfiles = ctx.runfiles(outputs),
        ),
    ]

extract_proto_headers = rule(
    implementation = _extract_proto_headers,
    doc = "A rule that extracts all the pb.h headers from a CcInfo and puts them in an appropriately-named directory, returning individual files.",
    attrs = {
        "cc_proto_target": attr.label(
            mandatory = True,
            providers = [CcInfo],
        ),
        "outdir": attr.string(
            mandatory = True,
        ),
    },
)
