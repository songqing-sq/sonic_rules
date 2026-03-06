

load("@rules_pkg//pkg:pkg.bzl", "pkg_tar", "pkg_deb")
load("@tar.bzl", "tar")

load("@sonic_rules//:shared_library.bzl", "SymlinkInfo")

def _sonic_mtree_spec_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".spec")

    seen_dirs = {}
    lines = []

    def add_parents(path):
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

    keys = ctx.attr.keys
    
    for i in range(len(keys)):
        key = keys[i]
        target = ctx.attr.srcs[i]
        files = target.files.to_list()

        symlink_dest = ""
        extra_dest = {}
        if SymlinkInfo in target:
            symlink_dest = target[SymlinkInfo].dest
            extra_dest = target[SymlinkInfo].extra_dest

        parts = key.split(":")
        package_dir = parts[0]
        strip_prefix = parts[1] if len(parts) > 1 else ""
        mode = parts[2] if len(parts) > 2 else "0644"
        if len(mode) == 3 and mode.isdigit():
            mode = "0" + mode

        is_wildcard = (strip_prefix == "*")
        
        if strip_prefix and not is_wildcard and not strip_prefix.endswith("/"):
            strip_prefix += "/"
            
        if package_dir:
            package_dir = package_dir.strip("/")
            if package_dir:
                package_dir += "/"

        for f in files:
            path = f.short_path

            if path.startswith("../"):
                first_slash = path.find("/", 3)
                if first_slash != -1:
                    path = path[first_slash + 1:]

            target_package = target.label.package
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

            segments = []
            for part in path.split("/"):
                if part == "..":
                    if len(segments) > 0:
                        segments.pop()
                elif part == "." or part == "":
                    continue
                else:
                    segments.append(part)
            path = "/".join(segments)

            add_parents(path)

            if f.is_symlink:
                symlink_mode = "0777"
                link_target = symlink_dest if symlink_dest else (extra_dest.get(f.path, f.path))
                lines.append("./%s type=link mode=%s link=%s uid=0 gid=0" % (path, symlink_mode, link_target))
            else:
                lines.append("./%s type=file mode=%s content=%s uid=0 gid=0" % (path, mode, f.path))

    ctx.actions.write(out, content = "#mtree\n" + "\n".join(lines) + "\n")
    return [DefaultInfo(files = depset([out]))]

sonic_mtree_spec = rule(
    implementation = _sonic_mtree_spec_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = True),
        "keys": attr.string_list(),
    },
)

def _sonic_deb_impl(name, visibility, content, **kwargs):
    keys = []
    flat_srcs = []
    for key, files in content.items():
        for f in files:
            keys.append(key)
            flat_srcs.append(f)

    sonic_mtree_spec(
        name = name + "_spec",
        srcs = flat_srcs,
        keys = keys,
    )
    
    tar(
        name = name + "_data",
        srcs = flat_srcs,
        mtree = ":" + name + "_spec",
        compress = "gzip",
    )

    pkg_deb(
        name = name,
        data = ":" + name + "_data",
        visibility = visibility,
        **kwargs
    )

def sonic_deb(name, content, data = None, **kwargs):
    _sonic_deb_impl(
        name = name,
        visibility = ["//visibility:public"],
        content = content,
        **kwargs
    )
