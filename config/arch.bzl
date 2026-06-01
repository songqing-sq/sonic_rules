"""Central architecture select() mappings.

All BUILD files that need architecture strings should import from here
rather than writing inline select() expressions.
"""

DEBIAN_ARCH = select({
    Label("//config:cpu_x86_64"): "amd64",
    Label("//config:cpu_aarch64"): "arm64",
})
