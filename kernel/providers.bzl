"""Providers shared across the kernel build rules."""

KernelBuildInfo = provider(
    doc = "Outputs of a kernel_build action.",
    fields = {
        "kernel_binary": "File: bzImage / Image / zImage",
        "vmlinux": "File: unstripped vmlinux ELF",
        "system_map": "File: System.map",
        "config": "File: final .config actually used",
        "kernel_release": "File: single-line KERNELRELEASE string",
        "kernel_variables": "File: .kernelvariables Makefile fragment",
        "arch": "str: architecture (amd64)",
        "kernel_build_data_dir": "File (tree): data-only build dir subset for headers debs",
        "kernel_sources": "depset[File]: patched source tree",
        "modules_install_dir": "File (tree): lib/modules/<release>/ tree",
    },
)

KernelConfigInfo = provider(
    doc = "A finalized kernel .config + kernelvariables + kernel.release.",
    fields = {
        "config": "File: .config",
        "kernel_variables": "File: .kernelvariables",
        "kernel_release": "File: single-line KERNELRELEASE string (from make kernelrelease)",
    },
)
