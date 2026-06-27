"""Unit tests for pure helper functions in sonic_deb.bzl.

These tests exercise _normalize_path, _parse_key, and _compute_install_path
by re-implementing them locally (Starlark cannot load private symbols from
another .bzl file), and verifying their behaviour with bazel_skylib unittest.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")

# ---------------------------------------------------------------------------
# Local copies of the helpers under test (must stay in sync with sonic_deb.bzl)
# ---------------------------------------------------------------------------

def _normalize_path(path):
    segments = []
    for part in path.split("/"):
        if part == "..":
            if segments:
                segments.pop()
        elif part and part != ".":
            segments.append(part)
    return "/".join(segments)

def _parse_key(key):
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

def _compute_install_path(short_path, target_package, key):
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

# ---------------------------------------------------------------------------
# _normalize_path tests
# ---------------------------------------------------------------------------

def _normalize_path_basic_test(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "usr/bin/foo", _normalize_path("usr/bin/foo"))
    asserts.equals(env, "usr/bin/foo", _normalize_path("usr/bin/../bin/foo"))
    asserts.equals(env, "usr/bin/foo", _normalize_path("./usr/bin/foo"))
    asserts.equals(env, "usr/bin/foo", _normalize_path("usr//bin/foo"))
    asserts.equals(env, "", _normalize_path(""))
    asserts.equals(env, "", _normalize_path("."))
    asserts.equals(env, "foo", _normalize_path("a/../foo"))
    return unittest.end(env)

normalize_path_basic_test = unittest.make(_normalize_path_basic_test)

# ---------------------------------------------------------------------------
# _parse_key tests
# ---------------------------------------------------------------------------

def _parse_key_three_parts_test(ctx):
    env = unittest.begin(ctx)
    pkg_dir, strip_prefix, mode = _parse_key("/usr/bin:src/bin:0755")
    asserts.equals(env, "/usr/bin", pkg_dir)
    asserts.equals(env, "src/bin", strip_prefix)
    asserts.equals(env, "0755", mode)
    return unittest.end(env)

parse_key_three_parts_test = unittest.make(_parse_key_three_parts_test)

def _parse_key_wildcard_shorthand_test(ctx):
    env = unittest.begin(ctx)

    # /*shorthand: default mode 0644, wildcard strip
    pkg_dir, strip_prefix, mode = _parse_key("/usr/bin/*")
    asserts.equals(env, "/usr/bin", pkg_dir)
    asserts.equals(env, "*", strip_prefix)
    asserts.equals(env, "0644", mode)
    return unittest.end(env)

parse_key_wildcard_shorthand_test = unittest.make(_parse_key_wildcard_shorthand_test)

def _parse_key_wildcard_three_parts_test(ctx):
    env = unittest.begin(ctx)

    # explicit wildcard via 3-part form
    pkg_dir, strip_prefix, mode = _parse_key("/usr/bin:*:0755")
    asserts.equals(env, "/usr/bin", pkg_dir)
    asserts.equals(env, "*", strip_prefix)
    asserts.equals(env, "0755", mode)
    return unittest.end(env)

parse_key_wildcard_three_parts_test = unittest.make(_parse_key_wildcard_three_parts_test)

def _parse_key_two_parts_strip_test(ctx):
    env = unittest.begin(ctx)

    # 2-part form: second segment is the strip prefix (not mode!)
    pkg_dir, strip_prefix, mode = _parse_key("/usr/lib:src/lib")
    asserts.equals(env, "/usr/lib", pkg_dir)
    asserts.equals(env, "src/lib", strip_prefix)
    asserts.equals(env, "0644", mode)
    return unittest.end(env)

parse_key_two_parts_strip_test = unittest.make(_parse_key_two_parts_strip_test)

def _parse_key_one_part_default_mode_test(ctx):
    env = unittest.begin(ctx)
    pkg_dir, strip_prefix, mode = _parse_key("/etc/sonic")
    asserts.equals(env, "/etc/sonic", pkg_dir)
    asserts.equals(env, "", strip_prefix)
    asserts.equals(env, "0644", mode)
    return unittest.end(env)

parse_key_one_part_default_mode_test = unittest.make(_parse_key_one_part_default_mode_test)

def _parse_key_three_digit_mode_padded_test(ctx):
    env = unittest.begin(ctx)

    # 3-digit mode in 3-part form gets a leading 0
    _, _, mode = _parse_key("/usr/bin::755")
    asserts.equals(env, "0755", mode)
    return unittest.end(env)

parse_key_three_digit_mode_padded_test = unittest.make(_parse_key_three_digit_mode_padded_test)

def _parse_key_no_strip_with_mode_test(ctx):
    env = unittest.begin(ctx)

    # empty strip + explicit mode: "/dir::mode"
    pkg_dir, strip_prefix, mode = _parse_key("/usr/bin::0755")
    asserts.equals(env, "/usr/bin", pkg_dir)
    asserts.equals(env, "", strip_prefix)
    asserts.equals(env, "0755", mode)
    return unittest.end(env)

parse_key_no_strip_with_mode_test = unittest.make(_parse_key_no_strip_with_mode_test)

# ---------------------------------------------------------------------------
# _compute_install_path tests
# ---------------------------------------------------------------------------

def _compute_install_path_wildcard_test(ctx):
    env = unittest.begin(ctx)

    # wildcard: only basename is kept, placed under package_dir
    result = _compute_install_path("pkg/sub/foo.so", "pkg", "/usr/lib/*")
    asserts.equals(env, "usr/lib/foo.so", result)

    # equivalent 3-part form with explicit mode
    result3 = _compute_install_path("pkg/sub/foo.so", "pkg", "/usr/lib:*:0644")
    asserts.equals(env, "usr/lib/foo.so", result3)
    return unittest.end(env)

compute_install_path_wildcard_test = unittest.make(_compute_install_path_wildcard_test)

def _compute_install_path_strip_prefix_test(ctx):
    env = unittest.begin(ctx)

    # strip_prefix removes leading path component
    result = _compute_install_path("pkg/src/bin/tool", "pkg", "/usr/bin:src/bin:0755")
    asserts.equals(env, "usr/bin/tool", result)
    return unittest.end(env)

compute_install_path_strip_prefix_test = unittest.make(_compute_install_path_strip_prefix_test)

def _compute_install_path_no_strip_test(ctx):
    env = unittest.begin(ctx)

    # no strip: file placed directly under package_dir (short_path relative to target_package)
    # short_path="pkg/cfg.json", target_package="pkg" -> relative="cfg.json" -> "etc/sonic/cfg.json"
    result = _compute_install_path("pkg/cfg.json", "pkg", "/etc/sonic")
    asserts.equals(env, "etc/sonic/cfg.json", result)
    return unittest.end(env)

compute_install_path_no_strip_test = unittest.make(_compute_install_path_no_strip_test)

def _compute_install_path_external_repo_test(ctx):
    env = unittest.begin(ctx)

    # external repo path: ../repo_name/sub/file -> sub/file
    result = _compute_install_path("../some_repo/sub/file.so", "", "/usr/lib/*")
    asserts.equals(env, "usr/lib/file.so", result)
    return unittest.end(env)

compute_install_path_external_repo_test = unittest.make(_compute_install_path_external_repo_test)

def _compute_install_path_dotdot_normalization_test(ctx):
    env = unittest.begin(ctx)

    # path with .. should be normalized
    result = _compute_install_path("pkg/a/b/../../c/file.txt", "pkg", "/usr/share")
    asserts.equals(env, "usr/share/c/file.txt", result)
    return unittest.end(env)

compute_install_path_dotdot_normalization_test = unittest.make(_compute_install_path_dotdot_normalization_test)

# ---------------------------------------------------------------------------
# Test suite
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# _compute_dbg_name – mirrors the logic in sonic_deb.bzl _sonic_deb_impl
# ---------------------------------------------------------------------------
def _compute_dbg_name(name):
    if name.endswith(".deb"):
        base = name[:-4]
        parts = base.split("_")
        return parts[0] + "-dbgsym" + ("_" + "_".join(parts[1:]) if len(parts) > 1 else "") + ".deb"
    else:
        return name + "_dbgsym"

def _dbg_name_no_deb_suffix_test(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "mypackage_dbgsym", _compute_dbg_name("mypackage"))
    return unittest.end(env)

dbg_name_no_deb_suffix_test = unittest.make(_dbg_name_no_deb_suffix_test)

def _dbg_name_deb_suffix_full_test(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "libfoo-dbgsym_1.0.0_amd64.deb", _compute_dbg_name("libfoo_1.0.0_amd64.deb"))
    return unittest.end(env)

dbg_name_deb_suffix_full_test = unittest.make(_dbg_name_deb_suffix_full_test)

def _dbg_name_deb_suffix_no_underscore_test(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "libfoo-dbgsym.deb", _compute_dbg_name("libfoo.deb"))
    return unittest.end(env)

dbg_name_deb_suffix_no_underscore_test = unittest.make(_dbg_name_deb_suffix_no_underscore_test)

def _dbg_name_deb_suffix_two_parts_test(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "libfoo-dbgsym_1.0.0.deb", _compute_dbg_name("libfoo_1.0.0.deb"))
    return unittest.end(env)

dbg_name_deb_suffix_two_parts_test = unittest.make(_dbg_name_deb_suffix_two_parts_test)

def sonic_deb_unit_test_suite(name):
    unittest.suite(
        name,
        normalize_path_basic_test,
        parse_key_three_parts_test,
        parse_key_wildcard_shorthand_test,
        parse_key_wildcard_three_parts_test,
        parse_key_two_parts_strip_test,
        parse_key_one_part_default_mode_test,
        parse_key_three_digit_mode_padded_test,
        parse_key_no_strip_with_mode_test,
        compute_install_path_wildcard_test,
        compute_install_path_strip_prefix_test,
        compute_install_path_no_strip_test,
        compute_install_path_external_repo_test,
        compute_install_path_dotdot_normalization_test,
        dbg_name_no_deb_suffix_test,
        dbg_name_deb_suffix_full_test,
        dbg_name_deb_suffix_no_underscore_test,
        dbg_name_deb_suffix_two_parts_test,
    )
