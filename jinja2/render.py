"""Render a Jinja2 template to a file.

Usage:
    render.py <template_path> <out_path> [KEY=VALUE ...]

The template is loaded via a FileSystemLoader rooted at the template's
directory, so relative includes/imports resolve next to the template.
StrictUndefined makes any undefined variable a hard error, and
keep_trailing_newline preserves a template's final newline.

Any trailing KEY=VALUE arguments are passed to the template as the render
context (e.g. DOCKER_RAMFS_SIZE=3500M), so templates that reference
onie-image.conf-style variables can be rendered without a config file.
"""

import os
import sys

from jinja2 import Environment, FileSystemLoader, StrictUndefined


def main(argv):
    if len(argv) < 3:
        sys.stderr.write("usage: render.py <template_path> <out_path> [KEY=VALUE ...]\n")
        return 2

    template_path = argv[1]
    out_path = argv[2]

    context = {}
    for kv in argv[3:]:
        key, sep, value = kv.partition("=")
        if not sep:
            sys.stderr.write("render.py: expected KEY=VALUE, got %r\n" % kv)
            return 2
        context[key] = value

    template_dir = os.path.dirname(template_path) or "."
    template_name = os.path.basename(template_path)

    env = Environment(
        loader=FileSystemLoader(template_dir),
        undefined=StrictUndefined,
        keep_trailing_newline=True,
    )
    rendered = env.get_template(template_name).render(**context)

    with open(out_path, "w") as f:
        f.write(rendered)

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
