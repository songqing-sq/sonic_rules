load("@rules_cc//cc:action_names.bzl", "ACTION_NAMES")
load("@rules_cc//cc:defs.bzl", "CcInfo", "cc_common")
load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cc_toolchain", "use_cc_toolchain")
load("@rules_cc//cc/common:cc_shared_library_info.bzl", "CcSharedLibraryInfo")
load("@rules_distroless//apt:defs.bzl", "dpkg_statusd")
load("@tar.bzl//:tar.bzl", "tar")
load("@tar.bzl//tar:tar.bzl", tar_lib = "tar_lib")
load("//config:arch.bzl", "DEBIAN_ARCH")
load("//shared_library:shared_library.bzl", "SymlinkInfo")

_CONTENT_BUILTIN_VARS = select({
    Label("//config:cpu_x86_64"): {
        "LIBDIR": "/usr/lib/x86_64-linux-gnu",
        # /lib/<multiarch> for core runtime libs that Debian places outside
        # /usr (libc6, libnl-3-200, libnl-genl-3-200 etc). Under trixie's
        # merged-usr layout this resolves to the same inode as ${LIBDIR},
        # but the path in the .deb metadata still matters for `dpkg -L`.
        "LIBDIR_BASE": "/lib/x86_64-linux-gnu",
    },
    Label("//config:cpu_aarch64"): {
        "LIBDIR": "/usr/lib/aarch64-linux-gnu",
        "LIBDIR_BASE": "/lib/aarch64-linux-gnu",
    },
})

def _resolvecontent_vars(key, content_vars):
    for var_name, var_value in content_vars.items():
        key = key.replace("${" + var_name + "}", var_value)
    return key

def _get_feature_configuration(ctx, cc_toolchain):
    """Create a feature configuration from the CC toolchain."""
    return cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features,
    )

# DebInfo provider for tracking which deb package a target belongs to
DebInfo = provider(
    doc = "Information about which deb package a target belongs to",
    fields = {
        "package_name": "The name of the deb package this target belongs to",
        "version": "Version of the deb package",
    },
)

# Aspect to collect transitive DebInfo from deps
_DebInfoCollector = provider(
    doc = "Collects transitive DebInfo from deps",
    fields = {
        "deb_infos": "depset of DebInfo providers from transitive deps",
    },
)

def _deb_info_collector_aspect_impl(target, ctx):
    transitive = []
    for attr_name in ["deps", "dynamic_deps"]:
        if hasattr(ctx.rule.attr, attr_name):
            for dep in getattr(ctx.rule.attr, attr_name):
                if _DebInfoCollector in dep:
                    transitive.append(dep[_DebInfoCollector].deb_infos)

    direct = []
    if DebInfo in target:
        direct.append(target[DebInfo])

    return [_DebInfoCollector(
        deb_infos = depset(direct, transitive = transitive),
    )]

_deb_info_collector_aspect = aspect(
    implementation = _deb_info_collector_aspect_impl,
    attr_aspects = ["deps", "dynamic_deps"],
)

def _normalize_path(path):
    """Normalize a path by resolving . and .. segments."""
    segments = []
    for part in path.split("/"):
        if part == "..":
            if segments:
                segments.pop()
        elif part and part != ".":
            segments.append(part)
    return "/".join(segments)

def _parse_key(key):
    """Parse a mtree key string into (package_dir, strip_prefix, mode).

    Key formats:
      /dir                  -> default mode 0644, no strip
      /dir/*                -> default mode 0644, wildcard strip (shorthand)
      /dir:strip            -> default mode 0644, explicit strip prefix
                               (use "*" for wildcard, "" for none)
      /dir:strip:mode       -> explicit mode (octal "0644"/"755")
                               strip may be "" (no strip) or "*" (wildcard)

    Mode REQUIRES the 3-part form. "/dir:0644" means strip_prefix="0644",
    NOT mode=0644. Use "/dir::0644" for the no-strip-with-mode case.

    The "/dir/*" shorthand cannot be combined with an explicit strip prefix.
    """
    parts = key.split(":")
    if len(parts) > 3:
        fail("sonic_deb content key has too many ':' segments (max 3): %r" % key)

    package_dir = parts[0]
    has_wildcard_dir = package_dir.endswith("/*")
    if has_wildcard_dir:
        package_dir = package_dir[:-2]

    explicit_strip = parts[1] if len(parts) >= 2 else None
    if has_wildcard_dir and explicit_strip != None and explicit_strip not in ("", "*"):
        fail(("sonic_deb content key combines '/*' shorthand with explicit " +
              "strip prefix %r: %r") % (explicit_strip, key))

    if has_wildcard_dir:
        strip_prefix = "*"
    elif explicit_strip:
        strip_prefix = explicit_strip
    else:
        strip_prefix = ""

    if len(parts) == 3:
        mode = parts[2]
        if not (mode.isdigit() and len(mode) in (3, 4)):
            fail(("sonic_deb content key has invalid mode %r " +
                  "(expected 3- or 4-digit octal): %r") % (mode, key))
        if len(mode) == 3:
            mode = "0" + mode
    else:
        mode = "0644"

    return package_dir, strip_prefix, mode

def _add_parents(path, seen_dirs, lines):
    """Add parent directory entries to lines if not already seen."""
    parts = path.split("/")
    current = ""
    for i in range(len(parts) - 1):
        if parts[i] == "." or parts[i] == "":
            continue
        if current:
            current += "/" + parts[i]
        else:
            current = parts[i]
        if current and current not in seen_dirs:
            lines.append("./%s type=dir mode=0755 uid=0 gid=0" % current)
            seen_dirs[current] = True

def _compute_install_path(short_path, target_package, key):
    """Compute the install path for a file based on mtree-style key."""
    package_dir, strip_prefix, _ = _parse_key(key)

    is_wildcard = (strip_prefix == "*")
    if strip_prefix and not is_wildcard and not strip_prefix.endswith("/"):
        strip_prefix += "/"
    if package_dir:
        package_dir = package_dir.strip("/")
        if package_dir:
            package_dir += "/"

    path = short_path
    if path.startswith("../"):
        first_slash = path.find("/", 3)
        if first_slash != -1:
            path = path[first_slash + 1:]
    if target_package and path.startswith(target_package + "/"):
        path = path[len(target_package) + 1:]

    if is_wildcard:
        last_slash = path.rfind("/")
        if last_slash != -1:
            path = path[last_slash + 1:]
    elif strip_prefix:
        if path.startswith(strip_prefix):
            path = path[len(strip_prefix):]

    path = package_dir + path
    return _normalize_path(path)

def _sonic_md5sums_impl(ctx):
    """Generate md5sums file from source files before tar packaging."""
    out = ctx.actions.declare_file(ctx.label.name + ".md5sums")

    keys = ctx.attr.keys
    srcs = ctx.attr.srcs

    all_inputs = []
    for src in srcs:
        all_inputs.extend(src.files.to_list())

    script_parts = []
    script_parts.append("#!/bin/bash")
    script_parts.append("set -e")
    script_parts.append("OUTPUT=" + out.path)
    script_parts.append("> $OUTPUT")
    script_parts.append("")

    content_vars = ctx.attr.content_vars
    for i, src in enumerate(srcs):
        key = _resolvecontent_vars(keys[i], content_vars)
        target_package = src.label.package

        for f in src.files.to_list():
            if f.is_symlink:
                continue
            if f.is_directory:
                package_dir, _, _ = _parse_key(key)
                dir_install = package_dir.strip("/")
                script_parts.append("find '" + f.path + "' -type f | sort | while IFS= read -r fp; do")
                script_parts.append("    rel=\"${fp#" + f.path + "/}\"")
                script_parts.append("    HASH=$(md5sum \"$fp\" | cut -d\" \" -f1)")
                script_parts.append("    printf \"%s  ./" + dir_install + "/%s\\n\" \"$HASH\" \"$rel\" >> $OUTPUT")
                script_parts.append("done")
            else:
                install_path = _compute_install_path(f.short_path, target_package, key)
                script_parts.append("if [ -f \"" + f.path + "\" ]; then")
                script_parts.append("    HASH=$(md5sum \"" + f.path + "\" | cut -d\" \" -f1)")
                script_parts.append("    printf \"%s  ./" + install_path + "\\n\" \"$HASH\" >> $OUTPUT")
                script_parts.append("fi")

    ctx.actions.run_shell(
        outputs = [out],
        inputs = all_inputs,
        command = "\n".join(script_parts),
        progress_message = "Generating md5sums for %s" % ctx.attr.name,
    )

    return [DefaultInfo(files = depset([out]))]

_sonic_md5sums = rule(
    implementation = _sonic_md5sums_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = True, mandatory = True),
        "keys": attr.string_list(mandatory = True),
        "content_vars": attr.string_dict(default = {}),
    },
)

def _sonic_md5sums_from_tar_impl(ctx):
    """Generate dpkg md5sums file by STREAMING a (gzipped) data tar.

    The data tar is expected to be rooted at `./` with in-image paths like
    `./usr/share/foo`. Emits one line per regular file:
    `<md5>  <path-without-leading-./>`, sorted by path. Skips directory and
    symlink entries.

    md5sums_from_tar.py reads the tar once in-process (no on-disk extract) and
    hashes each member with hashlib (no per-file `md5sum` fork) -- the device-
    data deb alone has thousands of small files, so the old extract+fork path
    wrote+reread every file and forked md5sum thousands of times.
    """
    out = ctx.actions.declare_file(ctx.label.name + ".md5sums")
    data_tar = ctx.file.data_tar
    tool = ctx.executable._md5_tool

    ctx.actions.run(
        executable = tool,
        arguments = [data_tar.path, out.path],
        inputs = [data_tar],
        outputs = [out],
        # py_binary output is a wrapper script; its runfiles carry the
        # interpreter + md5sums_from_tar.py, so they must travel with it.
        tools = depset(
            direct = [tool],
            transitive = [ctx.attr._md5_tool[DefaultInfo].default_runfiles.files],
        ),
        mnemonic = "DebMd5sums",
        progress_message = "Computing md5sums for %s" % ctx.attr.name,
    )
    return [DefaultInfo(files = depset([out]))]

_sonic_md5sums_from_tar = rule(
    implementation = _sonic_md5sums_from_tar_impl,
    attrs = {
        "data_tar": attr.label(allow_single_file = True, mandatory = True),
        "_md5_tool": attr.label(
            default = Label("//sonic_deb:md5sums_from_tar"),
            executable = True,
            cfg = "exec",
        ),
    },
)

def _sonic_stripped_md5sums_impl(ctx):
    """Generate md5sums file from stripped binaries directory."""
    out = ctx.actions.declare_file(ctx.label.name + ".md5sums")

    stripped_dir = ctx.attr.stripped_dir
    stripped_files = stripped_dir.files.to_list()

    if not stripped_files:
        ctx.actions.write(out, content = "")
        return [DefaultInfo(files = depset([out]))]

    # stripped_dir is a declare_directory output; files.to_list() returns the directory itself
    stripped_root = stripped_files[0].path

    # Compute install paths from keys
    keys = ctx.attr.keys
    content_vars = ctx.attr.content_vars
    entries = []
    for i, key_raw in enumerate(keys):
        key = _resolvecontent_vars(key_raw, content_vars)
        target = ctx.attr.srcs[i]
        files = target.files.to_list()
        for f in files:
            if f.is_symlink:
                continue

            # Find corresponding stripped file
            stripped_file = stripped_root + "/" + _stripped_name(f)
            install_path = f.basename

            # Compute proper install path from key
            parts = key.split(":")
            package_dir = parts[0]
            if package_dir.endswith("/*"):
                package_dir = package_dir[:-2]
            package_dir = package_dir.strip("/")
            if package_dir:
                install_path = package_dir + "/" + f.basename

            # Normalize path
            segments = []
            for part in install_path.split("/"):
                if part == "..":
                    if segments:
                        segments.pop()
                elif part and part != ".":
                    segments.append(part)
            install_path = "/".join(segments)
            entries.append((stripped_file, install_path))

    script_parts = []
    script_parts.append("#!/bin/bash")
    script_parts.append("set -e")
    script_parts.append("OUTPUT=" + out.path)
    script_parts.append("> $OUTPUT")
    for stripped_file, install_path in entries:
        script_parts.append("if [ -f \"" + stripped_file + "\" ]; then")
        script_parts.append("    HASH=$(md5sum \"" + stripped_file + "\" | cut -d\" \" -f1)")
        script_parts.append("    printf \"%s  ./" + install_path + "\\n\" \"$HASH\" >> $OUTPUT")
        script_parts.append("fi")

    ctx.actions.run_shell(
        outputs = [out],
        inputs = stripped_files,
        command = "\n".join(script_parts),
        progress_message = "Generating md5sums for stripped %s" % ctx.attr.name,
    )

    return [DefaultInfo(files = depset([out]))]

_sonic_stripped_md5sums = rule(
    implementation = _sonic_stripped_md5sums_impl,
    attrs = {
        "stripped_dir": attr.label(mandatory = True),
        "srcs": attr.label_list(allow_files = True),
        "keys": attr.string_list(),
        "content_vars": attr.string_dict(default = {}),
    },
)

def _sonic_control_tar_impl(ctx):
    """Generate control.tar.gz for a debian package."""
    output_tar = ctx.actions.declare_file(ctx.label.name + "_control.tar.gz")

    # Use the sealed bsdtar from @tar.bzl instead of system tar.
    bsdtar = ctx.toolchains[tar_lib.toolchain_type]
    tar_path = bsdtar.tarinfo.binary.path

    # Collect transitive depends from DebInfo
    auto_depends = []
    seen_packages = {}
    for target in ctx.attr.content_targets:
        if _DebInfoCollector in target:
            for deb_info in target[_DebInfoCollector].deb_infos.to_list():
                pkg = deb_info.package_name
                if pkg and pkg not in seen_packages:
                    auto_depends.append(pkg)
                    seen_packages[pkg] = True

    # Merge user-provided depends with auto-detected
    user_depends = list(ctx.attr.depends)
    all_depends = list(user_depends)
    for dep in auto_depends:
        if dep not in all_depends:
            all_depends.append(dep)

    # Handle shlibs
    shlibs_content = None
    shlibs_so_files = []
    if ctx.file.shlibs:
        shlibs_content = ctx.file.shlibs
    else:
        shlibs_entries = []
        for target in ctx.attr.content_targets:
            if CcSharedLibraryInfo not in target:
                continue

            pkg_name = ctx.attr.package
            pkg_version = ctx.attr.version
            seen_libnames = {}

            for so_file in target.files.to_list():
                lib_basename = so_file.basename
                if not (lib_basename.startswith("lib") and ".so." in lib_basename):
                    continue
                if so_file.is_symlink:
                    continue

                shlibs_entries.append("__SONAME_LOOKUP__:%s:%s:%s" % (so_file.path, pkg_name, pkg_version))
                shlibs_so_files.append(so_file)

        if shlibs_entries:
            shlibs_file = ctx.actions.declare_file(ctx.attr.name + "_auto_shlibs")
            ctx.actions.write(shlibs_file, "\n".join(shlibs_entries) + "\n")
            shlibs_content = shlibs_file

    # Get objdump from the CC toolchain via tool_paths.
    cc_toolchain = find_cc_toolchain(ctx)
    objdump_path = cc_toolchain._tool_paths.get("objdump", None)
    if not objdump_path:
        fail("objdump not found in CC toolchain tool_paths")

    # Build control file content
    control_lines = []
    control_lines.append("Package: %s" % ctx.attr.package)
    control_lines.append("Version: %s" % ctx.attr.version)
    control_lines.append("Architecture: %s" % ctx.attr.architecture)
    control_lines.append("Maintainer: %s" % ctx.attr.maintainer)

    if ctx.attr.multi_arch:
        control_lines.append("Multi-Arch: %s" % ctx.attr.multi_arch)

    if ctx.attr.priority:
        control_lines.append("Priority: %s" % ctx.attr.priority)
    if ctx.attr.section:
        control_lines.append("Section: %s" % ctx.attr.section)
    if ctx.attr.homepage:
        control_lines.append("Homepage: %s" % ctx.attr.homepage)

    # installed_size placeholder; will be replaced by actual size in shell script if 0
    control_lines.append("Installed-Size: %d" % ctx.attr.installed_size)

    if ctx.attr.pre_depends:
        control_lines.append("Pre-Depends: %s" % ", ".join(ctx.attr.pre_depends))

    if all_depends:
        control_lines.append("Depends: %s" % ", ".join(all_depends))

    if ctx.attr.recommends:
        control_lines.append("Recommends: %s" % ", ".join(ctx.attr.recommends))

    if ctx.attr.suggests:
        control_lines.append("Suggests: %s" % ", ".join(ctx.attr.suggests))

    if ctx.attr.conflicts:
        control_lines.append("Conflicts: %s" % ", ".join(ctx.attr.conflicts))

    if ctx.attr.breaks:
        control_lines.append("Breaks: %s" % ", ".join(ctx.attr.breaks))

    if ctx.attr.replaces:
        control_lines.append("Replaces: %s" % ", ".join(ctx.attr.replaces))

    if ctx.attr.provides:
        control_lines.append("Provides: %s" % ", ".join(ctx.attr.provides))

    if ctx.attr.enhances:
        control_lines.append("Enhances: %s" % ", ".join(ctx.attr.enhances))

    control_lines.append("Description: %s" % ctx.attr.description)

    # Write control file content to a declared file
    control_file = ctx.actions.declare_file(ctx.attr.name + ".control")
    ctx.actions.write(control_file, "\n".join(control_lines) + "\n")

    # Write the assembly script to a file to avoid shell escaping issues
    script_file = ctx.actions.declare_file(ctx.attr.name + "_control.sh")
    inputs = [control_file]
    script_parts = []
    script_parts.append("#!/bin/bash")
    script_parts.append("set -e")
    script_parts.append("WORKDIR=$(mktemp -d)")
    script_parts.append('trap "rm -rf $WORKDIR" EXIT')
    script_parts.append("")
    script_parts.append("cp \"$CONTROL_FILE\" $WORKDIR/control")
    script_parts.append("")
    script_parts.append("# Auto-compute Installed-Size if set to 0")
    script_parts.append("if grep -q '^Installed-Size: 0$' $WORKDIR/control; then")
    script_parts.append("    TOTAL_KB=$(du -sk $WORKDIR | cut -f1)")
    script_parts.append("    sed -i \"s/^Installed-Size: 0$/Installed-Size: ${TOTAL_KB}/\" $WORKDIR/control")
    script_parts.append("fi")
    script_parts.append("")
    script_parts.append("# Write md5sums if provided")
    script_parts.append('if [ -n "$MD5SUMS_FILE" ]; then')
    script_parts.append("    cp $MD5SUMS_FILE $WORKDIR/md5sums")
    script_parts.append("fi")
    script_parts.append("")
    script_parts.append("# Process shlibs with SONAME lookup")
    script_parts.append('if [ -n "$SHLIBS_FILE" ]; then')
    script_parts.append("    OUT=$WORKDIR/shlibs")
    script_parts.append("    > $OUT")
    script_parts.append('    case "$SHLIBS_FILE" in')
    script_parts.append("        *_auto_shlibs)")
    script_parts.append("            while IFS= read -r line; do")
    script_parts.append('                case "$line" in')
    script_parts.append("                    __SONAME_LOOKUP__:*)")
    script_parts.append("                        SO_PATH=${line#*:}")
    script_parts.append("                        SO_PATH=${SO_PATH%%:*}")
    script_parts.append("                        rest=${line#*:*:}")
    script_parts.append("                        PKG_NAME=${rest%%:*}")
    script_parts.append("                        PKG_VER=${rest#*:}")
    script_parts.append("                        SONAME=$($OBJDUMP -p $SO_PATH 2>/dev/null | grep SONAME | head -1 | rev | cut -d' ' -f1 | rev || true)")
    script_parts.append('                        if [ -n "$SONAME" ]; then')
    script_parts.append("                            LIBNAME=${SONAME#lib}")
    script_parts.append("                            LIBNAME=${LIBNAME%%.so.*}")
    script_parts.append("                            SOVERSION=${SONAME#*.so.}")
    script_parts.append("                            SOVERSION=${SOVERSION%%.*}")
    script_parts.append('                            echo "lib${LIBNAME} ${SOVERSION} ${PKG_NAME} (>= ${PKG_VER})" >> $OUT')
    script_parts.append("                        fi")
    script_parts.append("                        ;;")
    script_parts.append("                    \\#*)")
    script_parts.append("                        ;;")
    script_parts.append("                    *)")
    script_parts.append('                        if [ -n "$line" ]; then')
    script_parts.append('                            echo "$line" >> $OUT')
    script_parts.append("                        fi")
    script_parts.append("                        ;;")
    script_parts.append("                esac")
    script_parts.append('            done < "$SHLIBS_FILE"')
    script_parts.append("            ;;")
    script_parts.append("        *)")
    script_parts.append("            cp $SHLIBS_FILE $WORKDIR/shlibs")
    script_parts.append("            ;;")
    script_parts.append("    esac")
    script_parts.append("fi")
    script_parts.append("")

    # Write maintainer scripts if provided
    for script_name in ["preinst", "postinst", "prerm", "postrm", "config"]:
        attr_val = getattr(ctx.file, script_name, None)
        if attr_val:
            inputs.append(attr_val)
            script_parts.append('if [ -n "$' + script_name.upper() + '" ]; then')
            script_parts.append("    cp $" + script_name.upper() + " $WORKDIR/" + script_name)
            script_parts.append("fi")

    script_parts.append("")
    script_parts.append("# Write debconf templates if provided")
    script_parts.append('if [ -n "$TEMPLATES" ]; then')
    script_parts.append("    cp $TEMPLATES $WORKDIR/templates")
    script_parts.append("fi")

    script_parts.append("")
    script_parts.append("# Write conffiles if provided")
    script_parts.append('if [ -n "$CONFFILES" ]; then')
    script_parts.append("    cp $CONFFILES $WORKDIR/conffiles")
    script_parts.append("fi")

    script_parts.append("")
    script_parts.append("# Write triggers if provided")
    script_parts.append('if [ -n "$TRIGGERS" ]; then')
    script_parts.append("    cp $TRIGGERS $WORKDIR/triggers")
    script_parts.append("fi")

    script_parts.append("")
    script_parts.append("# Pack control.tar.gz")
    script_parts.append("\"%s\" -czf $OUTPUT --uid=0 --gid=0 -C $WORKDIR ." % tar_path)

    ctx.actions.write(script_file, "\n".join(script_parts) + "\n")
    inputs.append(script_file)

    # Build env dict for the script
    env = {
        "CONTROL_FILE": control_file.path,
        "OUTPUT": output_tar.path,
        "OBJDUMP": objdump_path,
    }
    if ctx.file.md5sums_file:
        env["MD5SUMS_FILE"] = ctx.file.md5sums_file.path
        inputs.append(ctx.file.md5sums_file)
    if shlibs_content:
        env["SHLIBS_FILE"] = shlibs_content.path
        inputs.append(shlibs_content)

        # Add .so files referenced in auto_shlibs to sandbox inputs
        inputs.extend(shlibs_so_files)

    for script_name in ["preinst", "postinst", "prerm", "postrm", "config"]:
        attr_val = getattr(ctx.file, script_name, None)
        if attr_val:
            env[script_name.upper()] = attr_val.path
            inputs.append(attr_val)
    if ctx.file.templates:
        env["TEMPLATES"] = ctx.file.templates.path
        inputs.append(ctx.file.templates)
    if ctx.file.conffiles:
        env["CONFFILES"] = ctx.file.conffiles.path
        inputs.append(ctx.file.conffiles)
    if ctx.file.triggers:
        env["TRIGGERS"] = ctx.file.triggers.path
        inputs.append(ctx.file.triggers)

    ctx.actions.run_shell(
        outputs = [output_tar],
        inputs = depset(inputs, transitive = [cc_toolchain.all_files]),
        tools = bsdtar.default.files,
        command = "bash " + script_file.path,
        env = env,
        progress_message = "Creating control.tar.gz for %s" % ctx.attr.package,
    )

    return [DefaultInfo(files = depset([output_tar]))]

_sonic_control_tar = rule(
    implementation = _sonic_control_tar_impl,
    attrs = {
        "package": attr.string(mandatory = True),
        "version": attr.string(mandatory = True),
        "architecture": attr.string(default = "amd64"),
        "maintainer": attr.string(mandatory = True),
        "multi_arch": attr.string(default = ""),
        "description": attr.string(mandatory = True),
        "section": attr.string(),
        "priority": attr.string(),
        "homepage": attr.string(),
        "installed_size": attr.int(default = 0),
        "depends": attr.string_list(default = []),
        "pre_depends": attr.string_list(default = []),
        "recommends": attr.string_list(default = []),
        "suggests": attr.string_list(default = []),
        "conflicts": attr.string_list(default = []),
        "breaks": attr.string_list(default = []),
        "replaces": attr.string_list(default = []),
        "provides": attr.string_list(default = []),
        "enhances": attr.string_list(default = []),
        "md5sums_file": attr.label(allow_single_file = True),
        "shlibs": attr.label(allow_single_file = True),
        "conffiles": attr.label(allow_single_file = True),
        "preinst": attr.label(allow_single_file = True),
        "postinst": attr.label(allow_single_file = True),
        "prerm": attr.label(allow_single_file = True),
        "postrm": attr.label(allow_single_file = True),
        "config": attr.label(allow_single_file = True),
        "templates": attr.label(allow_single_file = True),
        "triggers": attr.label(allow_single_file = True),
        "content_targets": attr.label_list(
            default = [],
            allow_files = True,
            aspects = [_deb_info_collector_aspect],
        ),
    },
    fragments = ["cpp"],
    toolchains = use_cc_toolchain() + [tar_lib.toolchain_type],
)

def _sonic_deb_assemble_impl(ctx):
    """Assemble a .deb file from debian-binary, control.tar.gz and data.tar.gz."""
    package_file_name = ctx.attr.package_file_name
    if not package_file_name:
        # Debian filename convention: the version in the .deb filename omits the
        # epoch ("N:") prefix, even though the control Version field keeps it.
        file_version = ctx.attr.version.split(":")[-1]
        package_file_name = "%s_%s_%s.deb" % (
            ctx.attr.package,
            file_version,
            ctx.attr.architecture,
        )

    output_deb = ctx.actions.declare_file(package_file_name)
    changes_file = ctx.actions.declare_file(package_file_name.rsplit(".", 1)[0] + ".changes")

    # Get ar from the CC toolchain via cc_common API.
    cc_toolchain = find_cc_toolchain(ctx)
    feature_configuration = _get_feature_configuration(ctx, cc_toolchain)
    ar_path = cc_common.get_tool_for_action(
        feature_configuration = feature_configuration,
        action_name = ACTION_NAMES.cpp_link_static_library,
    )

    script_parts = []
    script_parts.append("#!/bin/bash")
    script_parts.append("set -e")
    script_parts.append("WORKDIR=$(mktemp -d)")
    script_parts.append("trap \"rm -rf $WORKDIR\" EXIT")
    script_parts.append("")
    script_parts.append("echo \"2.0\" > $WORKDIR/debian-binary")
    script_parts.append("cp \"" + ctx.file.control_tar.path + "\" $WORKDIR/control.tar.gz")
    script_parts.append("cp \"" + ctx.file.data_tar.path + "\" $WORKDIR/data.tar.gz")
    script_parts.append("\"" + ar_path + "\" rcs \"" + output_deb.path + "\" $WORKDIR/debian-binary $WORKDIR/control.tar.gz $WORKDIR/data.tar.gz")
    script_parts.append("")

    # Generate .changes file with complete Files: section
    deb_filename = package_file_name
    section = ctx.attr.section
    priority = ctx.attr.priority
    script_parts.append("DEB_MD5=$(md5sum \"" + output_deb.path + "\" | cut -d' ' -f1)")
    script_parts.append("DEB_SIZE=$(stat -c%s \"" + output_deb.path + "\")")
    script_parts.append("cat > \"" + changes_file.path + "\" <<CHANGESEOF")
    script_parts.append("Format: 1.8")
    script_parts.append("Date: $(date -R)")
    script_parts.append("Source: %s" % ctx.attr.package)
    script_parts.append("Binary: %s" % ctx.attr.package)
    script_parts.append("Architecture: %s" % ctx.attr.architecture)
    script_parts.append("Version: %s" % ctx.attr.version)
    script_parts.append("Distribution: %s" % ctx.attr.distribution)
    script_parts.append("Urgency: %s" % ctx.attr.urgency)
    script_parts.append("Changes:")
    script_parts.append(" %s (%s) %s; urgency=%s" % (ctx.attr.package, ctx.attr.version, ctx.attr.distribution, ctx.attr.urgency))
    script_parts.append("CHANGESEOF")
    script_parts.append("printf 'Files:\\n $DEB_MD5 $DEB_SIZE %s %s %s\\n' >> \"%s\"" % (section, priority, deb_filename, changes_file.path))

    ctx.actions.run_shell(
        outputs = [output_deb, changes_file],
        inputs = depset(
            [ctx.file.control_tar, ctx.file.data_tar],
            transitive = [cc_toolchain.all_files],
        ),
        command = "\n".join(script_parts),
        progress_message = "Assembling deb package %s" % ctx.attr.package,
        env = {
            "LANG": "en_US.UTF-8",
            "LC_CTYPE": "UTF-8",
        },
    )

    return [
        DefaultInfo(
            files = depset([output_deb]),
            runfiles = ctx.runfiles(files = [output_deb, changes_file]),
        ),
        OutputGroupInfo(
            out = [output_deb],
            deb = [output_deb],
            changes = [changes_file],
        ),
    ]

_sonic_deb_assemble = rule(
    implementation = _sonic_deb_assemble_impl,
    attrs = {
        "data_tar": attr.label(mandatory = True, allow_single_file = True),
        "control_tar": attr.label(mandatory = True, allow_single_file = True),
        "package": attr.string(mandatory = True),
        "version": attr.string(mandatory = True),
        "architecture": attr.string(default = "amd64"),
        "distribution": attr.string(default = "unstable"),
        "urgency": attr.string(default = "medium"),
        "section": attr.string(default = "misc"),
        "priority": attr.string(default = "optional"),
        "package_file_name": attr.string(),
    },
    fragments = ["cpp"],
    toolchains = use_cc_toolchain(),
)

# --- mtree spec rules ---

def _sonic_mtree_spec_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".spec")
    seen_dirs = {}
    lines = []
    tree_artifacts = []
    all_inputs = []

    content_vars = ctx.attr.content_vars
    keys = ctx.attr.keys
    for i in range(len(keys)):
        key = _resolvecontent_vars(keys[i], content_vars)
        target = ctx.attr.srcs[i]
        files = target.files.to_list()
        symlink_dest = ""
        extra_dest = {}
        if SymlinkInfo in target:
            symlink_dest = target[SymlinkInfo].dest
            extra_dest = target[SymlinkInfo].extra_dest

        _, _, mode = _parse_key(key)
        target_package = target.label.package

        for f in files:
            all_inputs.append(f)
            if f.is_directory:
                package_dir, _, _ = _parse_key(key)
                install_prefix = package_dir.strip("/")
                tree_artifacts.append((f, install_prefix, mode))
            elif f.is_symlink:
                path = _compute_install_path(f.short_path, target_package, key)
                _add_parents(path, seen_dirs, lines)
                link_target = symlink_dest if symlink_dest else (extra_dest.get(f.path, f.path))
                lines.append("./%s type=link mode=0777 link=%s uid=0 gid=0" % (path, link_target))
            else:
                path = _compute_install_path(f.short_path, target_package, key)
                _add_parents(path, seen_dirs, lines)
                lines.append("./%s type=file mode=%s content=%s uid=0 gid=0" % (path, mode, f.path))

    # Empty directories: install paths that carry no files (e.g. Debian
    # *.dirs entries like /var/lib/dhcp). Emit each (and its parents) as a
    # type=dir entry so the resulting deb ships the empty directory.
    for d in ctx.attr.empty_dirs:
        d = _resolvecontent_vars(d, content_vars)
        d = d.strip("/")
        if not d:
            continue
        _add_parents(d + "/.", seen_dirs, lines)
        if d not in seen_dirs:
            lines.append("./%s type=dir mode=0755 uid=0 gid=0" % d)
            seen_dirs[d] = True

    if not tree_artifacts:
        ctx.actions.write(out, content = "#mtree\n" + "\n".join(lines) + "\n")
    else:
        static_content = "#mtree\n" + "\n".join(lines) + "\n"
        script_parts = ["cat > '{out}' << 'STATIC_MTREE_EOF'\n{static}\nSTATIC_MTREE_EOF".format(
            out = out.path,
            static = static_content,
        )]
        for tree_f, install_prefix, mode in tree_artifacts:
            script_parts.append(
                """# Emit parent dirs then files for tree artifact
declare -A __seen_dirs
emit_parents() {{
  local p="$1"; local d=""
  IFS='/' read -ra parts <<< "$p"
  for ((i=0; i<${{#parts[@]}}-1; i++)); do
    [ -z "${{parts[i]}}" ] && continue
    if [ -n "$d" ]; then d="$d/${{parts[i]}}"; else d="${{parts[i]}}"; fi
    if [ -z "${{__seen_dirs[$d]:-}}" ]; then
      __seen_dirs[$d]=1
      printf './%s type=dir mode=0755 uid=0 gid=0\\n' "$d" >> '{out}'
    fi
  done
}}
PREFIX='{prefix}'
find '{tree}' -type f -o -type l | sort | while IFS= read -r fp; do
  rel="${{fp#{tree}/}}"
  if [ -n "$PREFIX" ]; then full="$PREFIX/$rel"; else full="$rel"; fi
  emit_parents "$full"
  printf './%s type=file mode={mode} content=%s uid=0 gid=0\\n' "$full" "$fp"
done >> '{out}'""".format(
                    tree = tree_f.path,
                    prefix = install_prefix.rstrip("/"),
                    mode = mode,
                    out = out.path,
                ),
            )
        ctx.actions.run_shell(
            inputs = all_inputs,
            outputs = [out],
            command = "\n".join(script_parts),
            mnemonic = "MtreeSpec",
        )
    return [DefaultInfo(files = depset([out]))]

sonic_mtree_spec = rule(
    implementation = _sonic_mtree_spec_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = True),
        "keys": attr.string_list(),
        "content_vars": attr.string_dict(default = {}),
        "empty_dirs": attr.string_list(default = []),
    },
)

# --- strip_binaries and debug_symbols_pkg ---

def _stripped_name(f):
    """Collision-free name for a file inside the stripped output directory.

    Using f.basename alone corrupts debs that ship two content files with the
    same basename but different install paths (e.g. a binary `redis-cli` and a
    bash-completion `redis-cli`): both would map to the same stripped file and
    the last writer wins. f.short_path is unique per file, so flattening it
    yields a stable, collision-free name shared by the strip action, the mtree
    spec, and the md5sums generation.
    """
    return f.short_path.replace("../", "").replace("/", "_")

def _strip_binaries_impl(ctx):
    """Strip binaries and prepare debug symbols using CC toolchain tools."""
    output_dir = ctx.actions.declare_directory(ctx.attr.name + "_stripped")

    # Get objcopy from the CC toolchain via cc_common API.
    cc_toolchain = find_cc_toolchain(ctx)
    feature_configuration = _get_feature_configuration(ctx, cc_toolchain)
    objcopy_path = cc_common.get_tool_for_action(
        feature_configuration = feature_configuration,
        action_name = ACTION_NAMES.objcopy_embed_data,
    )

    all_inputs = []
    for target in ctx.attr.srcs:
        all_inputs.extend(target.files.to_list())

    input_paths = [f.path for f in all_inputs]
    input_files = all_inputs

    cc_targets = {}
    for i, target in enumerate(ctx.attr.srcs):
        if CcInfo in target or CcSharedLibraryInfo in target:
            for f in target.files.to_list():
                cc_targets[f.path] = True
        target_name = target.label.name
        if "_files" in target_name or "_libs" in target_name:
            for f in target.files.to_list():
                if (f.basename.endswith(".so") or ".so." in f.basename or
                    f.basename.endswith(".dll") or f.basename.endswith(".dylib") or
                    f.basename.endswith(".exe") or f.basename.endswith("_objs")):
                    cc_targets[f.path] = True

    script_parts = []
    script_parts.append("#!/bin/bash")
    script_parts.append("set -e")
    script_parts.append("OUTPUT_DIR=" + output_dir.path)
    script_parts.append("mkdir -p $OUTPUT_DIR")
    script_parts.append("OBJCOPY=" + objcopy_path)
    script_parts.append("")

    # strip_or_copy <src> <dst> <force_strip>: --strip-debug if the source is an
    # ELF object, otherwise copy it verbatim. force_strip=1 short-circuits the
    # ELF probe for files already known to be cc binaries (CcInfo / *.so name).
    # The runtime ELF probe (\x7fELF magic) additionally catches
    # rules_foreign_cc binaries, which carry no CcInfo and so are not in
    # cc_targets, ensuring gen_dbg debs ship stripped binaries regardless of how
    # the binary was produced. Non-ELF data files (configs, scripts, man pages)
    # are always copied unchanged.
    script_parts.append("strip_or_copy() {")
    script_parts.append("    local src=\"$1\" dst=\"$2\" force=\"$3\"")
    script_parts.append("    if [ \"$force\" = \"1\" ] || [ \"$(head -c 4 \"$src\" 2>/dev/null | od -An -tx1 | tr -d ' \\n')\" = \"7f454c46\" ]; then")
    script_parts.append("        $OBJCOPY --strip-debug \"$src\" \"$dst\"")
    script_parts.append("    else")
    script_parts.append("        cp \"$src\" \"$dst\" 2>/dev/null || true")
    script_parts.append("    fi")
    script_parts.append("}")
    script_parts.append("")

    for i, path in enumerate(input_paths):
        f = input_files[i]
        force = "1" if path in cc_targets else "0"
        out_name = _stripped_name(f)

        script_parts.append("if [ -e \"" + path + "\" ] && [[ \"" + path + "\" != *.params ]]; then")
        script_parts.append("    BASENAME=" + out_name)
        script_parts.append("    if [ -L \"" + path + "\" ]; then")
        script_parts.append("        LINK_TARGET=$(readlink \"" + path + "\")")
        script_parts.append("        if [[ \"$LINK_TARGET\" == /* ]]; then")
        script_parts.append("            if [ -f \"$LINK_TARGET\" ]; then")
        script_parts.append("                strip_or_copy \"$LINK_TARGET\" $OUTPUT_DIR/$BASENAME " + force)
        script_parts.append("            fi")
        script_parts.append("        else")
        # Relative symlink (e.g. libfoo.so.1 -> libfoo.so.1.2.3). Recreating the
        # symlink verbatim would dangle inside the stripped tree artifact (the
        # target is written under a different, mangled name), which fails
        # Bazel's tree-artifact validation. Resolve the link against its own
        # directory and copy/strip the real file instead.
        script_parts.append("            RESOLVED=\"$(dirname \"" + path + "\")/$LINK_TARGET\"")
        script_parts.append("            if [ -f \"$RESOLVED\" ]; then")
        script_parts.append("                strip_or_copy \"$RESOLVED\" $OUTPUT_DIR/$BASENAME " + force)
        script_parts.append("            fi")
        script_parts.append("        fi")
        script_parts.append("    elif [ -f \"" + path + "\" ]; then")
        script_parts.append("        strip_or_copy \"" + path + "\" $OUTPUT_DIR/$BASENAME " + force)
        script_parts.append("    fi")
        script_parts.append("fi")
        script_parts.append("")

    script_content = "\n".join(script_parts)

    ctx.actions.run_shell(
        outputs = [output_dir],
        inputs = depset(all_inputs, transitive = [cc_toolchain.all_files]),
        command = script_content,
        progress_message = "Stripping binaries for %s" % ctx.attr.name,
    )

    return [DefaultInfo(files = depset([output_dir]))]

strip_binaries = rule(
    implementation = _strip_binaries_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = True, mandatory = True),
    },
    fragments = ["cpp"],
    toolchains = use_cc_toolchain(),
)

def _debug_symbols_pkg_impl(ctx):
    """Extract debug symbols from ELF files and package them into a tar.gz."""
    output_tar = ctx.actions.declare_file(ctx.attr.name + ".tar.gz")

    # Use the sealed bsdtar from @tar.bzl instead of system tar.
    bsdtar = ctx.toolchains[tar_lib.toolchain_type]
    tar_path = bsdtar.tarinfo.binary.path

    # Get objcopy from the CC toolchain via cc_common API.
    cc_toolchain = find_cc_toolchain(ctx)
    feature_configuration = _get_feature_configuration(ctx, cc_toolchain)
    objcopy_path = cc_common.get_tool_for_action(
        feature_configuration = feature_configuration,
        action_name = ACTION_NAMES.objcopy_embed_data,
    )

    all_inputs = []
    for target in ctx.attr.srcs:
        all_inputs.extend(target.files.to_list())

    input_paths = [f.path for f in all_inputs]

    # Write script to file to avoid shell escaping issues
    script_file = ctx.actions.declare_file(ctx.attr.name + ".sh")
    script_parts = []
    script_parts.append("#!/bin/bash")
    script_parts.append("set -e")
    script_parts.append("OUTPUT_DIR=$(mktemp -d)")
    script_parts.append('trap "rm -rf $OUTPUT_DIR" EXIT')
    script_parts.append("mkdir -p $OUTPUT_DIR/usr/lib/debug/.build-id")
    script_parts.append("OBJCOPY=" + objcopy_path)
    script_parts.append("")

    for path in input_paths:
        script_parts.append("if [ -f \"" + path + "\" ] && [[ \"" + path + "\" != *.params ]]; then")
        script_parts.append("    BUILDID=$($OBJCOPY --dump-section .note.gnu.build-id=/dev/stdout \"" + path + "\" 2>/dev/null | od -An -tx1 -v | tr -d ' \\n' | tail -c +33 | head -c 40 || true)")
        script_parts.append('    if [ -n "$BUILDID" ] && [ ${#BUILDID} -ge 40 ] && echo "$BUILDID" | grep -qE "^[0-9a-fA-F]+$"; then')
        script_parts.append('        PREFIX="${BUILDID:0:2}"')
        script_parts.append('        SUFFIX="${BUILDID:2}"')
        script_parts.append("        mkdir -p $OUTPUT_DIR/usr/lib/debug/.build-id/$PREFIX")
        script_parts.append("        $OBJCOPY --only-keep-debug \"" + path + "\" $OUTPUT_DIR/usr/lib/debug/.build-id/$PREFIX/${SUFFIX}.debug 2>/dev/null || true")
        script_parts.append("    fi")
        script_parts.append("fi")
        script_parts.append("")

    script_parts.append("\"%s\" -czf $OUTPUT --uid=0 --gid=0 -C $OUTPUT_DIR ." % tar_path)

    ctx.actions.write(script_file, "\n".join(script_parts) + "\n")
    all_inputs.append(script_file)

    ctx.actions.run_shell(
        outputs = [output_tar],
        inputs = depset(all_inputs, transitive = [cc_toolchain.all_files]),
        tools = bsdtar.default.files,
        command = "bash " + script_file.path,
        env = {"OUTPUT": output_tar.path},
        progress_message = "Creating debug symbols package for %s" % ctx.attr.name,
    )

    return [DefaultInfo(files = depset([output_tar]))]

debug_symbols_pkg = rule(
    implementation = _debug_symbols_pkg_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = True, mandatory = True),
    },
    fragments = ["cpp"],
    toolchains = use_cc_toolchain() + [tar_lib.toolchain_type],
)

def _stripped_mtree_spec_impl(ctx):
    """Generate mtree spec for stripped binaries."""
    out = ctx.actions.declare_file(ctx.label.name + ".spec")
    seen_dirs = {}
    lines = []
    tree_artifacts = []

    stripped_files = ctx.attr.stripped_dir.files.to_list()
    if not stripped_files:
        ctx.actions.write(out, content = "#mtree\n")
        return [DefaultInfo(files = depset([out]))]

    stripped_dir_path = stripped_files[0].path

    content_vars = ctx.attr.content_vars
    keys = ctx.attr.keys
    for i in range(len(keys)):
        key = _resolvecontent_vars(keys[i], content_vars)
        _, _, mode = _parse_key(key)

        target = ctx.attr.srcs[i]
        files = target.files.to_list()

        symlink_dest = ""
        extra_dest = {}
        if SymlinkInfo in target:
            symlink_dest = target[SymlinkInfo].dest
            extra_dest = target[SymlinkInfo].extra_dest

        for f in files:
            if f.is_directory:
                package_dir, _, _ = _parse_key(key)
                install_prefix = package_dir.strip("/")
                tree_artifacts.append((f, install_prefix, mode))
            elif f.is_symlink:
                path = _compute_install_path(f.short_path, target.label.package, key)
                _add_parents(path, seen_dirs, lines)
                link_target = symlink_dest if symlink_dest else (extra_dest.get(f.path, f.path))
                lines.append("./%s type=link mode=0777 link=%s uid=0 gid=0" % (path, link_target))
            else:
                path = _compute_install_path(f.short_path, target.label.package, key)
                _add_parents(path, seen_dirs, lines)
                stripped_file_path = stripped_dir_path + "/" + _stripped_name(f)
                lines.append("./%s type=file mode=%s content=%s uid=0 gid=0" % (path, mode, stripped_file_path))

    # Empty directories (Debian *.dirs entries with no files). See the
    # matching block in _sonic_mtree_spec_impl.
    for d in ctx.attr.empty_dirs:
        d = _resolvecontent_vars(d, content_vars)
        d = d.strip("/")
        if not d:
            continue
        _add_parents(d + "/.", seen_dirs, lines)
        if d not in seen_dirs:
            lines.append("./%s type=dir mode=0755 uid=0 gid=0" % d)
            seen_dirs[d] = True

    if not tree_artifacts:
        ctx.actions.write(out, content = "#mtree\n" + "\n".join(lines) + "\n")
    else:
        static_content = "#mtree\n" + "\n".join(lines) + "\n"
        script_parts = ["cat > '{out}' << 'STATIC_MTREE_EOF'\n{static}\nSTATIC_MTREE_EOF".format(
            out = out.path,
            static = static_content,
        )]
        for tree_f, install_prefix, mode in tree_artifacts:
            script_parts.append(
                """# Emit parent dirs then files for tree artifact
declare -A __seen_dirs
emit_parents() {{
  local p="$1"; local d=""
  IFS='/' read -ra parts <<< "$p"
  for ((i=0; i<${{#parts[@]}}-1; i++)); do
    [ -z "${{parts[i]}}" ] && continue
    if [ -n "$d" ]; then d="$d/${{parts[i]}}"; else d="${{parts[i]}}"; fi
    if [ -z "${{__seen_dirs[$d]:-}}" ]; then
      __seen_dirs[$d]=1
      printf './%s type=dir mode=0755 uid=0 gid=0\\n' "$d" >> '{out}'
    fi
  done
}}
PREFIX='{prefix}'
find '{tree}' -type f -o -type l | sort | while IFS= read -r fp; do
  rel="${{fp#{tree}/}}"
  if [ -n "$PREFIX" ]; then full="$PREFIX/$rel"; else full="$rel"; fi
  emit_parents "$full"
  printf './%s type=file mode={mode} content=%s uid=0 gid=0\\n' "$full" "$fp"
done >> '{out}'""".format(
                    tree = tree_f.path,
                    prefix = install_prefix.rstrip("/"),
                    mode = mode,
                    out = out.path,
                ),
            )
        ctx.actions.run_shell(
            inputs = stripped_files + [f for f, _, _ in tree_artifacts],
            outputs = [out],
            command = "\n".join(script_parts),
            mnemonic = "StrippedMtreeSpec",
        )
    return [DefaultInfo(files = depset([out]))]

stripped_mtree_spec = rule(
    implementation = _stripped_mtree_spec_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = True),
        "keys": attr.string_list(),
        "stripped_dir": attr.label(mandatory = True),
        "content_vars": attr.string_dict(default = {}),
        "empty_dirs": attr.string_list(default = []),
    },
)

# --- Debug md5sums rule ---

def _sonic_dbg_md5sums_impl(ctx):
    """Generate md5sums for a debug symbols tar.gz by extracting and computing."""
    output_md5 = ctx.actions.declare_file(ctx.label.name + ".md5sums")

    # Use the sealed bsdtar from @tar.bzl instead of system tar.
    bsdtar = ctx.toolchains[tar_lib.toolchain_type]
    tar_path = bsdtar.tarinfo.binary.path

    script_file = ctx.actions.declare_file(ctx.attr.name + ".sh")
    script_parts = []
    script_parts.append("#!/bin/bash")
    script_parts.append("set -e")
    script_parts.append("SANDBOX_ROOT=$(pwd)")
    script_parts.append("WORKDIR=$(mktemp -d)")
    script_parts.append('trap "rm -rf $WORKDIR" EXIT')
    script_parts.append("\"%s\" -xzf $DEBUG_TAR -C $WORKDIR" % tar_path)
    script_parts.append("cd $WORKDIR")
    script_parts.append("find . -type f -exec md5sum {} \\; > $SANDBOX_ROOT/$OUTPUT")

    ctx.actions.write(script_file, "\n".join(script_parts) + "\n")

    ctx.actions.run_shell(
        outputs = [output_md5],
        inputs = [ctx.file.debug_tar, script_file],
        tools = bsdtar.default.files,
        command = "bash " + script_file.path,
        env = {
            "DEBUG_TAR": ctx.file.debug_tar.path,
            "OUTPUT": output_md5.path,
        },
        progress_message = "Generating md5sums for debug symbols %s" % ctx.attr.name,
    )

    return [DefaultInfo(files = depset([output_md5]))]

_sonic_dbg_md5sums = rule(
    implementation = _sonic_dbg_md5sums_impl,
    attrs = {
        "debug_tar": attr.label(mandatory = True, allow_single_file = True),
    },
    toolchains = [tar_lib.toolchain_type],
)

# --- Main sonic_deb macro ---

def _sonic_deb_impl(
        name,
        visibility,
        content,
        content_targets = [],
        gen_dbg = False,
        empty_dirs = [],
        **kwargs):
    """Implementation of the sonic_deb macro.

    Generates md5sums before tar packaging, uses CC toolchain tools (ar, objdump, objcopy),
    and tar from @tar.bzl. No dependency on rules_pkg.
    """
    keys = []
    flat_srcs = []
    for key, files in content.items():
        for f in files:
            keys.append(key)
            flat_srcs.append(f)

    content_vars = {}
    if any(["${" in k for k in keys]) or any(["${" in d for d in empty_dirs]):
        content_vars = _CONTENT_BUILTIN_VARS

    all_content_targets = flat_srcs + content_targets

    package_name = kwargs.get("package", name)
    version = kwargs.get("version", "1.0.0")
    maintainer = kwargs.get("maintainer", "")
    multi_arch = kwargs.get("multi_arch", "")
    description = kwargs.get("description", "")

    # Common kwargs extracted once to avoid repetition
    architecture = kwargs.get("architecture", DEBIAN_ARCH)
    distribution = kwargs.get("distribution", "unstable")
    urgency = kwargs.get("urgency", "medium")
    section = kwargs.get("section")
    priority = kwargs.get("priority")
    homepage = kwargs.get("homepage")
    depends = kwargs.get("depends", [])
    pre_depends = kwargs.get("pre_depends", [])
    recommends = kwargs.get("recommends", [])
    suggests = kwargs.get("suggests", [])
    conflicts = kwargs.get("conflicts", [])
    breaks = kwargs.get("breaks", [])
    replaces = kwargs.get("replaces", [])
    provides = kwargs.get("provides", [])
    enhances = kwargs.get("enhances", [])
    shlibs = kwargs.get("shlibs")
    conffiles_file = kwargs.get("conffiles_file")
    preinst = kwargs.get("preinst")
    postinst = kwargs.get("postinst")
    prerm = kwargs.get("prerm")
    postrm = kwargs.get("postrm")
    config = kwargs.get("config")
    templates = kwargs.get("templates")
    triggers = kwargs.get("triggers")
    package_file_name = kwargs.get("package_file_name")

    if gen_dbg:
        # === Main package with stripped binaries ===

        strip_binaries(
            name = name + "_stripped",
            srcs = flat_srcs,
        )

        stripped_mtree_spec(
            name = name + "_spec",
            srcs = flat_srcs,
            keys = keys,
            stripped_dir = ":" + name + "_stripped",
            content_vars = content_vars,
            empty_dirs = empty_dirs,
        )

        tar(
            name = name + "_data",
            srcs = [":" + name + "_stripped"] + flat_srcs,
            mtree = ":" + name + "_spec",
            compress = "gzip",
            visibility = visibility,
        )

        _sonic_stripped_md5sums(
            name = name + "_md5sums",
            stripped_dir = ":" + name + "_stripped",
            srcs = flat_srcs,
            keys = keys,
            content_vars = content_vars,
        )

    else:
        # === Normal flow without debug symbols ===

        sonic_mtree_spec(
            name = name + "_spec",
            srcs = flat_srcs,
            keys = keys,
            content_vars = content_vars,
            empty_dirs = empty_dirs,
        )

        tar(
            name = name + "_data",
            srcs = flat_srcs,
            mtree = ":" + name + "_spec",
            compress = "gzip",
            visibility = visibility,
        )

        _sonic_md5sums(
            name = name + "_md5sums",
            srcs = flat_srcs,
            keys = keys,
            content_vars = content_vars,
        )

    # === Common: control tar and deb assembly for main package ===
    _sonic_control_tar(
        name = name + "_control",
        package = package_name,
        version = version,
        architecture = architecture,
        maintainer = maintainer,
        multi_arch = multi_arch,
        description = description,
        section = section if section else "misc",
        priority = priority if priority else "optional",
        homepage = homepage,
        depends = depends,
        pre_depends = pre_depends,
        recommends = recommends,
        suggests = suggests,
        conflicts = conflicts,
        breaks = breaks,
        replaces = replaces,
        provides = provides,
        enhances = enhances,
        md5sums_file = ":" + name + "_md5sums",
        shlibs = shlibs,
        conffiles = conffiles_file,
        preinst = preinst,
        postinst = postinst,
        prerm = prerm,
        postrm = postrm,
        config = config,
        templates = templates,
        triggers = triggers,
        content_targets = all_content_targets,
        visibility = visibility,
    )

    _sonic_deb_assemble(
        name = name,
        data_tar = ":" + name + "_data",
        control_tar = ":" + name + "_control",
        package = package_name,
        version = version,
        architecture = architecture,
        distribution = distribution,
        urgency = urgency,
        section = section if section else "misc",
        priority = priority if priority else "optional",
        package_file_name = package_file_name,
        visibility = visibility,
    )

    dpkg_statusd(
        name = name + "_statusd",
        package_name = package_name,
        control = ":" + name + "_control",
        visibility = visibility,
    )

    if gen_dbg:
        # === Debug symbols package ===
        if name.endswith(".deb"):
            base = name[:-4]  # remove .deb
            parts = base.split("_")
            dbg_name = parts[0] + "-dbgsym" + ("_" + "_".join(parts[1:]) if len(parts) > 1 else "") + ".deb"
        else:
            dbg_name = name + "_dbgsym"
        dbg_package = package_name + "-dbgsym"

        debug_symbols_pkg(
            name = dbg_name + "_symbols",
            srcs = flat_srcs,
        )

        _sonic_dbg_md5sums(
            name = dbg_name + "_md5sums",
            debug_tar = ":" + dbg_name + "_symbols",
        )

        _sonic_control_tar(
            name = dbg_name + "_control",
            package = dbg_package,
            version = version,
            architecture = architecture,
            maintainer = maintainer,
            multi_arch = multi_arch,
            description = "Debug symbols for " + package_name,
            section = "debug",
            priority = priority if priority else "optional",
            depends = depends,
            md5sums_file = ":" + dbg_name + "_md5sums",
            content_targets = all_content_targets,
            visibility = visibility,
        )

        _sonic_deb_assemble(
            name = dbg_name,
            data_tar = ":" + dbg_name + "_symbols",
            control_tar = ":" + dbg_name + "_control",
            package = dbg_package,
            version = version,
            architecture = architecture,
            distribution = distribution,
            urgency = urgency,
            section = "debug",
            priority = priority if priority else "optional",
            visibility = visibility,
        )

def sonic_deb(name, content, data = None, gen_dbg = False, visibility = ["//visibility:public"], **kwargs):
    """Create a Debian package.

    Args:
        name: Target name, also base for output .deb filename.
        content: Dict mapping "install_dir:strip_prefix:mode" to file lists.
        data: Pre-packaged tar file (optional).
        gen_dbg: Whether to also generate -dbgsym debug symbol package.
        visibility: Visibility of the generated targets.
        **kwargs: Additional attributes passed through to the deb package.
    """
    if data:
        package_name = kwargs.get("package", name)
        version = kwargs.get("version", "1.0.0")
        section = kwargs.get("section")
        priority = kwargs.get("priority")

        # If the caller didn't supply md5sums_file, compute it from the data tar.
        # The dpkg_statusd action requires `./md5sums` inside the control tar,
        # so this must always be present.
        md5sums_label = kwargs.get("md5sums_file")
        if not md5sums_label:
            _sonic_md5sums_from_tar(
                name = name + "_md5sums",
                data_tar = data,
                visibility = ["//visibility:private"],
            )
            md5sums_label = ":" + name + "_md5sums"

        _sonic_control_tar(
            name = name + "_control",
            package = package_name,
            version = version,
            architecture = kwargs.get("architecture", DEBIAN_ARCH),
            maintainer = kwargs.get("maintainer", ""),
            multi_arch = kwargs.get("multi_arch", ""),
            description = kwargs.get("description", ""),
            section = section,
            priority = priority,
            homepage = kwargs.get("homepage"),
            depends = kwargs.get("depends", []),
            pre_depends = kwargs.get("pre_depends", []),
            recommends = kwargs.get("recommends", []),
            suggests = kwargs.get("suggests", []),
            conflicts = kwargs.get("conflicts", []),
            breaks = kwargs.get("breaks", []),
            replaces = kwargs.get("replaces", []),
            provides = kwargs.get("provides", []),
            enhances = kwargs.get("enhances", []),
            shlibs = kwargs.get("shlibs"),
            md5sums_file = md5sums_label,
            conffiles = kwargs.get("conffiles_file"),
            preinst = kwargs.get("preinst"),
            postinst = kwargs.get("postinst"),
            prerm = kwargs.get("prerm"),
            postrm = kwargs.get("postrm"),
            config = kwargs.get("config"),
            templates = kwargs.get("templates"),
            triggers = kwargs.get("triggers"),
            visibility = visibility,
        )
        _sonic_deb_assemble(
            name = name,
            data_tar = data,
            control_tar = ":" + name + "_control",
            package = package_name,
            version = version,
            architecture = kwargs.get("architecture", DEBIAN_ARCH),
            distribution = kwargs.get("distribution", "unstable"),
            urgency = kwargs.get("urgency", "medium"),
            section = section if section else "misc",
            priority = priority if priority else "optional",
            package_file_name = kwargs.get("package_file_name"),
            visibility = visibility,
        )
        dpkg_statusd(
            name = name + "_statusd",
            package_name = package_name,
            control = ":" + name + "_control",
            visibility = visibility,
        )
        return

    _sonic_deb_impl(
        name = name,
        visibility = visibility,
        content = content,
        gen_dbg = gen_dbg,
        **kwargs
    )
