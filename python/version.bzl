# Runtime Python version — must match trixie's apt python3 (3.13) and the
# default rules_python toolchain registered in the root MODULE.bazel (3.13.4).
# (Was 3.11 for bookworm; trixie ships Python 3.13.)
PYTHON_VERSION = "3.13.4"
PYTHON_MAJOR_MINOR = "3.13"

# Host build toolchain version for rules_python hermetic interpreter.
PYTHON_TOOLCHAIN_VERSION = "3.13.4"
