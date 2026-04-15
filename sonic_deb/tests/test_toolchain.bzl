load("@rules_cc//cc/toolchains:tool_info.bzl", "ToolInfo")

def _test_toolchain_impl(ctx):
    out = ctx.actions.declare_file(ctx.attr.name + "_out.txt")

    tools = ctx.attr._tools[ToolInfo]

    script_file = ctx.actions.declare_file(ctx.attr.name + "_check.sh")
    script_content = """#!/bin/bash
echo "=== ar ===" > $OUTPUT
echo "path: $AR" >> $OUTPUT
$AR --version 2>&1 | head -1 >> $OUTPUT
echo "" >> $OUTPUT
echo "=== objdump ===" >> $OUTPUT
echo "path: $OBJDUMP" >> $OUTPUT
$OBJDUMP --version 2>&1 | head -1 >> $OUTPUT
echo "" >> $OUTPUT
echo "=== objcopy ===" >> $OUTPUT
echo "path: $OBJCOPY" >> $OUTPUT
$OBJCOPY --version 2>&1 | head -1 >> $OUTPUT
"""
    ctx.actions.write(script_file, script_content)

    ctx.actions.run_shell(
        outputs = [out],
        inputs = [script_file, tools.path],
        command = "bash " + script_file.path,
        env = {
            "AR": tools.path,
            "OUTPUT": out.path,
        },
    )

    return [DefaultInfo(files = depset([out]))]

test_toolchain = rule(
    implementation = _test_toolchain_impl,
    attrs = {
        "_tools": attr.label(default = "//toolchains/gcc/tools:ar"),
    },
)
