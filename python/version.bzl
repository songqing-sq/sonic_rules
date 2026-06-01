# Runtime Python version — must match @bookworm//python3.11 (apt).
PYTHON_VERSION = "3.11.2"
PYTHON_MAJOR_MINOR = "3.11"

# Host build toolchain version for rules_python hermetic interpreter.
# Must be available in rules_python; 3.11.2 is not, so use closest.
PYTHON_TOOLCHAIN_VERSION = "3.11.3"
