"""Test rule to verify CC toolchain tool access via cc_common API."""

load("@rules_cc//cc:action_names.bzl", "ACTION_NAMES")
load("@rules_cc//cc:defs.bzl", "cc_common")
load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cc_toolchain", "use_cc_toolchain")

def _test_toolchain_access_impl(ctx):
    cc_toolchain = find_cc_toolchain(ctx)
    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features,
    )

    out = ctx.actions.declare_file(ctx.label.name + ".txt")

    info_parts = []

    # Get ar via cc_common API
    ar_path = cc_common.get_tool_for_action(
        feature_configuration = feature_configuration,
        action_name = ACTION_NAMES.cpp_link_static_library,
    )
    info_parts.append("ar path: " + ar_path)

    # Get objcopy via cc_common API
    objcopy_path = cc_common.get_tool_for_action(
        feature_configuration = feature_configuration,
        action_name = ACTION_NAMES.objcopy_embed_data,
    )
    info_parts.append("objcopy path: " + objcopy_path)

    # Get objdump via tool_paths
    objdump_path = cc_toolchain._tool_paths.get("objdump", "NOT FOUND")
    info_parts.append("objdump path: " + objdump_path)

    ctx.actions.write(out, "\n".join(info_parts) + "\n")
    return [DefaultInfo(files = depset([out]))]

test_toolchain_access = rule(
    implementation = _test_toolchain_access_impl,
    attrs = {},
    fragments = ["cpp"],
    toolchains = use_cc_toolchain(),
)
