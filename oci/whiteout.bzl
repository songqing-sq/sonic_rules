"""OCI whiteout layer for replacing an apt package with a SONiC-built deb.

OCI image layers are additive: a later layer can overwrite a file at the same
path, but it CANNOT delete a file that a lower layer shipped. So simply layering
a SONiC-built deb on top of an inherited apt package of the same name does NOT
reproduce `dpkg -i`'s upgrade semantics -- any file the apt version had that the
SONiC version lacks (or ships at a different path, e.g. a gzipped vs plain man
page) survives as an orphan.

`apt_package_whiteout` derives, from a displaced apt package's `:data` tar, an
OCI whiteout layer (`.wh.<name>` markers) that deletes ALL of that apt package's
*files*. Layer it BELOW the overriding SONiC deb:

    base (ships apt <pkg>) -> [whiteout: delete apt <pkg> files] -> [SONiC <pkg> deb]

Net effect == `dpkg -i` upgrade: the old apt version is fully removed and only
the SONiC version's files remain. Only regular files are whited out (never
directories), so shared dirs like /usr/bin are left intact for other packages.
"""

def apt_package_whiteout(name, apt_data, **kwargs):
    """Generate an OCI whiteout tar removing every file of an apt package.

    Args:
      name: target name; output is <name>.tar (an OCI layer of .wh. markers).
      apt_data: label of the displaced apt package's data tar (e.g.
                "@<apt_set>//<pkg>:data", a .tar.gz).
      **kwargs: forwarded to the genrule (visibility, tags, ...).
    """
    native.genrule(
        name = name,
        srcs = [apt_data],
        outs = [name + ".tar"],
        cmd = r"""
set -eu
work=$$(mktemp -d)
# List the apt package's payload; emit a .wh. whiteout marker for each regular
# file (skip directory entries so shared dirs are not deleted).
tar tzf $(SRCS) | while IFS= read -r f; do
  case "$$f" in */) continue ;; esac
  rel=$${f#./}
  [ -n "$$rel" ] || continue
  d=$$(dirname "$$rel")
  b=$$(basename "$$rel")
  mkdir -p "$$work/$$d"
  : > "$$work/$$d/.wh.$$b"
done
tar cf $@ -C "$$work" .
rm -rf "$$work"
""",
        **kwargs
    )
