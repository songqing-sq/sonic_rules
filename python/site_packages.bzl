load("@rules_python//python:defs.bzl", "PyInfo")
load("@tar.bzl", _mutate = "mutate", "tar")
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("//python:version.bzl", "PYTHON_MAJOR_MINOR")

_VENV_FLAG = "@aspect_rules_py//uv/private/constraints/venv:venv"
_PLATFORMS_FLAG = "//command_line_option:platforms"

def _venv_transition_impl(settings, attr):
    return {
        _VENV_FLAG: attr.venv,
        _PLATFORMS_FLAG: [str(Label("//platform:x86_64_bookworm"))],
    }

_venv_transition = transition(
    implementation = _venv_transition_impl,
    inputs = [],
    outputs = [_VENV_FLAG, _PLATFORMS_FLAG],
)

def _export_pyinfo(ctx):
    files = []
    for dep in ctx.attr.srcs:
        files.append(dep[PyInfo].transitive_sources)
    return DefaultInfo(files = depset([], transitive = files))

export_py_info = rule(
    implementation = _export_pyinfo,
    doc = "Export `PyInfo.transitive_sources` as DefaultInfo.",
    attrs = {
        "srcs": attr.label_list(
            providers = [PyInfo],
        ),
        "venv": attr.string(
            doc = "Name of the configured @aspect_rules_py virtualenv to resolve `srcs` under.",
            default = "default",
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
    cfg = _venv_transition,
)

def site_packages(name, srcs, venv = "default", mutate = None, **kwargs):
    """
    Conveninece macro to create a tar with a bunch of python dependencies.
    srcs must export the required files with `PyInfo`.

    Args:
        name: Target name (also used as the name of the tar).
        srcs: List of targets that export `PyInfo` (e.g. `py_library` targets).
        venv: Name of the @aspect_rules_py virtualenv that `srcs` (especially `@pip//...` targets) are resolved under. Must match a `uv.declare_venv(venv_name = ...)` entry.
        mutate: Not allowed. If you want to use `mutate`, chances are you're better off using `export_py_info` and `tar` directly.
        **kwargs: Additional keyword arguments forwarded to the underlying `tar` rule.
    """
    if mutate != None:
        fail("mutate is not allowed in site_packages. If you want to use `mutate`, chances are you're better off using `export_py_info` and `tar` directly.")

    export_py_info(
        name = name + "_info",
        srcs = srcs,
        venv = venv,
    )
    _pyver = PYTHON_MAJOR_MINOR
    script_name = name + "_awk"
    write_file(
        name = script_name,
        out = name + ".awk",
        content = ("""
@include "default"

# Skip directory entries inside the install/ tree -- bsdtar will recreate
# them implicitly from file entries, and keeping them in causes duplicate
# path conflicts in some versions of docker.
/[[:space:]]type=dir[[:space:]]*$/ {
  next
}

{
  # Path layout below mirrors what `pip3 install` would do on Debian system
  # Python (sysconfig with sys.prefix=/usr/local), with one SONiC-specific
  # twist: purelib/platlib goes to /usr/lib/python3/dist-packages instead of
  # /usr/local/lib/pythonX.Y/dist-packages, so dpkg-managed and
  # bazel-installed Python modules share the same directory.

  if (sub("install/bin/", "./usr/local/bin/")) {
    # entry-point scripts (sysconfig['scripts'])
  } else if (sub("install/lib/python""" + _pyver + """/site-packages/", "")) {
    # purelib / platlib -- strip prefix, prepend dist-packages target
    sub(/^/, "./usr/lib/python3/dist-packages/")
  } else if (sub("install/include/python""" + _pyver + """/", "./usr/local/include/python""" + _pyver + """/")) {
    # C extension headers (sysconfig['include'])
  } else if (match($0, /^install\\/(usr|etc|var|opt|srv|run|tmp|root|home|boot|dev|proc|sys|mnt|media)\\//)) {
    # data_files declared with absolute paths in setup.py (e.g.
    #   data_files=[('/usr/share/sonic/templates', [...])]
    # ). The wheel format strips the leading slash so the wheel ships them
    # at <dist>.data/data/usr/share/sonic/templates/..., and pip --target
    # install/ unpacks to install/usr/share/sonic/templates/... The first
    # path component matches a system root directory; restore the leading /.
    sub("install/", "./")
  } else if (sub("install/", "./usr/local/")) {
    # data_files declared with relative paths in setup.py (e.g.
    #   data_files=[('yang-models', [...])]
    # ). pip places them at <sys.prefix>/yang-models/, which on Debian
    # system Python (sys.prefix=/usr/local) is /usr/local/yang-models/.
  } else {
    # Source files coming from a hand-written py_library (`:sources`) that
    # never went through pip install -- no install/ prefix to strip. Drop
    # them straight into dist-packages.
    sub(/^/, "./usr/lib/python3/dist-packages/")
  }
}
""").split("\n")
    )
    tar(
        name = name,
        srcs = [":" + name + "_info"],
        mutate = _mutate(
            awk_script = script_name,
        ),
        **kwargs
    )
