"""Sync Python version from version.bzl to all pyproject.toml and MODULE.bazel files.

Usage:
    bazel run //python:sync_python_version
"""

import os
import re
import sys


def parse_version_bzl(path):
    versions = {}
    with open(path) as f:
        for line in f:
            m = re.match(r'(\w+)\s*=\s*"(.+?)"', line)
            if m:
                versions[m.group(1)] = m.group(2)
    return versions


def find_files(root, filename):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames
                       if not d.startswith(".") and not d.startswith("bazel-")]
        if filename in filenames:
            yield os.path.join(dirpath, filename)


def update_pyproject(path, python_version):
    with open(path) as f:
        content = f.read()
    new_content = re.sub(
        r'(requires-python\s*=\s*)"[^"]*"',
        r'\g<1>"==' + python_version + '"',
        content,
    )
    if new_content == content:
        return False
    with open(path, "w") as f:
        f.write(new_content)
    return True


def update_module_bazel(path, toolchain_version):
    with open(path) as f:
        content = f.read()
    new_content = re.sub(
        r'(python_version\s*=\s*)"[^"]*"',
        r'\g<1>"' + toolchain_version + '"',
        content,
    )
    repo_name = "python_" + toolchain_version.replace(".", "_")
    new_content = re.sub(
        r'(use_repo\(python,\s*)"python_[\d_]+"',
        r'\g<1>"' + repo_name + '"',
        new_content,
    )
    if new_content == content:
        return False
    with open(path, "w") as f:
        f.write(new_content)
    return True


def main():
    workspace = os.environ.get("BUILD_WORKSPACE_DIRECTORY")
    if not workspace:
        sys.stderr.write(
            "error: BUILD_WORKSPACE_DIRECTORY not set.\n"
            "Run this tool via: bazel run //python:sync_python_version\n"
        )
        return 1

    bzl_path = os.path.join(workspace, "sonic_rules", "python", "version.bzl")
    if not os.path.exists(bzl_path):
        sys.stderr.write("error: %s not found\n" % bzl_path)
        return 1

    versions = parse_version_bzl(bzl_path)
    py_version = versions.get("PYTHON_VERSION")
    tc_version = versions.get("PYTHON_TOOLCHAIN_VERSION")

    if not py_version or not tc_version:
        sys.stderr.write("error: missing PYTHON_VERSION or PYTHON_TOOLCHAIN_VERSION in %s\n" % bzl_path)
        return 1

    print("Source of truth: %s" % bzl_path)
    print("  PYTHON_VERSION = %s" % py_version)
    print("  PYTHON_TOOLCHAIN_VERSION = %s" % tc_version)
    print()

    changed = []
    unchanged = []
    uv_lock_dirs = []

    for path in sorted(find_files(workspace, "pyproject.toml")):
        if update_pyproject(path, py_version):
            rel = os.path.relpath(path, workspace)
            changed.append(rel)
            lock = os.path.join(os.path.dirname(path), "uv.lock")
            if os.path.exists(lock):
                uv_lock_dirs.append(os.path.relpath(os.path.dirname(path), workspace))
        else:
            unchanged.append(os.path.relpath(path, workspace))

    for path in sorted(find_files(workspace, "MODULE.bazel")):
        try:
            with open(path) as f:
                if "python_version" not in f.read():
                    continue
        except FileNotFoundError:
            continue
        if update_module_bazel(path, tc_version):
            changed.append(os.path.relpath(path, workspace))
        else:
            unchanged.append(os.path.relpath(path, workspace))

    if changed:
        print("Updated %d files:" % len(changed))
        for f in changed:
            print("  %s" % f)
    else:
        print("All files already up to date.")

    if unchanged:
        print("\nAlready correct: %d files" % len(unchanged))

    if uv_lock_dirs:
        print("\nReminder: re-run 'uv lock' in these directories:")
        for d in sorted(set(uv_lock_dirs)):
            print("  cd %s && uv lock" % d)

    return 0


if __name__ == "__main__":
    sys.exit(main())
