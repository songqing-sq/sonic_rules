"""sonic_rootfs: assemble layer tars into one fs tree (M1 stub; layers grow in M2+)."""

def sonic_rootfs(name, layers = [], visibility = None):
    native.genrule(
        name = name,
        srcs = layers,
        outs = [name + ".tar"],
        # Hermetic from-source GNU tar (//tar:tar) instead of the host `tar`:
        # GNU-specific -p (setuid) + --keep-directory-symlink are required (see
        # below); the sealed bsdtar from @tar.bzl supports neither.
        tools = ["//tar:tar"],
        cmd = """
          d=$$(mktemp -d)
          GTAR=$(location //tar:tar)
          # -p (preserve-permissions): default only for root, but the build user
          # owns its own extracted files and CAN set setuid/setgid on them, so -p
          # keeps those mode bits (sudo/su/passwd/mount/...). Without it tar drops
          # setuid for non-root -> sudo "must be owned by uid 0 and have the
          # setuid bit set". mksquashfs -all-root then maps owner to root, giving
          # the correct setuid-root binaries.
          #
          # --keep-directory-symlink: when the first layer is merged_usr_skeleton
          # (bin/sbin/lib[/lib64] -> usr/*), later layers' ./bin/x follow those
          # symlinks into /usr, debootstrap-style -- so no post-hoc merged-usr
          # fixup is needed. Callers needing merged-/usr pass merged_usr_skeleton
          # first (as the image build does); the empty-layers stub needs nothing.
          for f in $(SRCS); do "$$GTAR" -xpf $$f -C $$d --keep-directory-symlink; done
          mkdir -p $$d/etc
          [ -f $$d/etc/os-release ] || echo 'ID=sonic' > $$d/etc/os-release
          # Archive the top-level entries explicitly (not `.`) so member names
          # AND hardlink targets carry no leading `./`. mksquashfs -tar (the
          # squashfs rule) rejects `.`/`..` in tar pathnames, including hardlink
          # link targets (e.g. perl5.36.0 -> usr/bin/perl).
          "$$GTAR" -cf $@ -C $$d $$(ls -A $$d)
          rm -rf $$d
        """,
        visibility = visibility or ["//visibility:public"],
    )
