"""Thrift compiler toolchain.

Wraps the hermetic Thrift 0.17.0 `thrift_compiler` cc_binary as a Bazel
toolchain. The toolchain provides:

  * ThriftToolchainInfo.compiler -- the compiler executable File (used by the
    `thrift` rule's ctx.actions.run).
  * TemplateVariableInfo(vars = {"THRIFT": <compiler path>}) -- so genrule cmd
    (and the thrift_cc_library macro) can reference the compiler via $(THRIFT).
"""

ThriftToolchainInfo = provider(
    doc = "Information about the Thrift compiler toolchain.",
    fields = {
        "compiler": "The thrift compiler executable (File).",
        "files": "depset of files needed to run the compiler.",
    },
)

def _thrift_toolchain_impl(ctx):
    compiler = ctx.executable.compiler
    files = depset(
        direct = [compiler],
        transitive = [ctx.attr.compiler[DefaultInfo].default_runfiles.files],
    )
    toolchain_info = platform_common.ToolchainInfo(
        thrift_toolchain = ThriftToolchainInfo(
            compiler = compiler,
            files = files,
        ),
    )
    # Expose $(THRIFT) for genrule cmd (thrift_cc_library macro uses it).
    template_vars = platform_common.TemplateVariableInfo({
        "THRIFT": compiler.path,
    })
    return [toolchain_info, template_vars]

thrift_toolchain = rule(
    implementation = _thrift_toolchain_impl,
    attrs = {
        "compiler": attr.label(
            doc = "The thrift compiler cc_binary.",
            mandatory = True,
            executable = True,
            cfg = "exec",
        ),
    },
)

THRIFT_TOOLCHAIN_TYPE = "@rules_thrift//:toolchain_type"
