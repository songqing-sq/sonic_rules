"""Locate the real GCC driver File inside a resolved cc_toolchain's all_files."""

def resolve_gcc_driver(cc_toolchain):
    for f in cc_toolchain.all_files.to_list():
        if f.basename.endswith("-gcc") and f.dirname.endswith("/bin"):
            return f
    fail("resolve_gcc_driver: no bin/<triple>-gcc driver in cc_toolchain.all_files")
