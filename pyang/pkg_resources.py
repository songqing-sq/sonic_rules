"""Minimal pkg_resources shim for the hermetic pyang runner.

The aspect_rules_py uv hub treats setuptools as a build-only tool and does not
install it into the runtime venv, so the real ``pkg_resources`` is unavailable.
pyang 2.4.0's only use of pkg_resources is::

    pkg_resources.iter_entry_points(group='pyang.plugin')

to discover entry-point-registered plugins. This runner loads its plugin
(yin_cvl) via ``--plugindir`` instead, so no entry-point plugins exist; an empty
iterator is the correct and complete behavior.
"""


def iter_entry_points(group, name=None):
    return iter(())
