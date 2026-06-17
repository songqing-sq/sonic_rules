"""Public API for rules_thrift.

  * thrift(name, src, language, thrift_deps, thrift_options) -- a rule that runs
    the thrift compiler and returns a TreeArtifact directory of generated
    sources (all files, for any language). Use with py_library / go_library.

  * thrift_cc_library(name, src, outs, deps, thrift_options) -- a macro that
    expands to {name}_gen (genrule running the compiler via the $(THRIFT) make
    var) + {name} (cc_library over the generated C++). `outs` lists the
    generated files explicitly.
"""

load("@rules_thrift//:thrift_toolchain.bzl", "THRIFT_TOOLCHAIN_TYPE")
load("@rules_cc//cc:defs.bzl", "cc_library")

# === thrift rule (TreeArtifact) ===========================================

def _thrift_impl(ctx):
    toolchain = ctx.toolchains[THRIFT_TOOLCHAIN_TYPE].thrift_toolchain

    out_dir = ctx.actions.declare_directory(ctx.attr.name)

    args = ctx.actions.args()
    args.add("--gen", ctx.attr.language)
    args.add("-out", out_dir.path)

    # Include paths for `include`d .thrift files (thrift_deps): add the dir of
    # each included file via -I.
    inputs = [ctx.file.src]
    include_dirs = {}
    for dep in ctx.files.thrift_deps:
        inputs.append(dep)
        include_dirs[dep.dirname] = True
    for d in include_dirs.keys():
        args.add("-I", d)

    args.add_all(ctx.attr.thrift_options)
    args.add(ctx.file.src.path)

    ctx.actions.run(
        executable = toolchain.compiler,
        arguments = [args],
        inputs = depset(direct = inputs, transitive = [toolchain.files]),
        outputs = [out_dir],
        mnemonic = "ThriftGen",
        progress_message = "Thrift (%s) %s" % (ctx.attr.language, ctx.label),
    )
    return [DefaultInfo(files = depset([out_dir]))]

thrift = rule(
    implementation = _thrift_impl,
    doc = "Generate thrift bindings; returns a TreeArtifact dir of all outputs.",
    attrs = {
        "src": attr.label(
            doc = "The .thrift source file.",
            mandatory = True,
            allow_single_file = [".thrift"],
        ),
        "language": attr.string(
            doc = "Target language: cpp (default), py, or go.",
            default = "cpp",
            values = ["cpp", "py", "go"],
        ),
        "thrift_deps": attr.label_list(
            doc = "Other .thrift files referenced via `include`.",
            allow_files = [".thrift"],
        ),
        "thrift_options": attr.string_list(
            doc = "Extra thrift compiler options (e.g. ['-r']).",
        ),
    },
    toolchains = [THRIFT_TOOLCHAIN_TYPE],
)

# === thrift_cc_library macro ==============================================

def thrift_cc_library(
        name,
        src,
        outs,
        deps = [],
        thrift_options = [],
        thrift_deps = [],
        **kwargs):
    """Generate C++ from a .thrift file and compile it as a cc_library.

    Expands to:
      * {name}_gen : a genrule that runs the thrift compiler (via $(THRIFT))
        emitting the explicitly-listed `outs`.
      * {name}     : a cc_library over the generated C++ (outs) + deps.

    Args:
      name: target name (the cc_library uses this).
      src: the .thrift source file.
      outs: list of generated files (must be listed explicitly; determine with
        `thrift --gen cpp <file> && find gen-cpp -type f`).
      deps: cc_library deps (libthrift-dev + libboost-dev).
      thrift_options: extra thrift compiler options.
      thrift_deps: other .thrift files referenced via `include`.
      **kwargs: forwarded to the cc_library (e.g. copts, visibility).
    """
    opts = " ".join(thrift_options)
    inc_flags = " ".join(["-I $$(dirname $(location %s))" % d for d in thrift_deps])

    genrule_srcs = [src] + thrift_deps

    native.genrule(
        name = name + "_gen",
        srcs = genrule_srcs,
        outs = outs,
        # $(THRIFT) is the compiler path (TemplateVariableInfo from the toolchain
        # target listed in `toolchains`); `tools` brings the compiler binary into
        # the action's inputs. $(@D) is the genrule output dir; thrift writes cpp
        # output flat there.
        cmd = "$(THRIFT) --gen cpp %s %s -out $(@D) $(location %s)" % (
            opts,
            inc_flags,
            src,
        ),
        tools = ["@rules_thrift//:thrift_compiler"],
        toolchains = ["@rules_thrift//:thrift_toolchain_for_make_var"],
    )

    # *_server.skeleton.cpp is a generated example server stub (it ships a main()
    # and is meant to be copied + edited, not compiled into a library), so it is
    # listed in `outs` (the genrule emits it) but excluded from the cc_library
    # srcs. Everything else (.cpp/.cc) is library content.
    cc_library(
        name = name,
        srcs = [
            f
            for f in outs
            if (f.endswith(".cpp") or f.endswith(".cc")) and not f.endswith(".skeleton.cpp")
        ],
        hdrs = [f for f in outs if f.endswith(".h") or f.endswith(".hh")],
        deps = deps,
        **kwargs
    )
