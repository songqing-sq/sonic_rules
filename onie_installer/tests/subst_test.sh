#!/usr/bin/env bash
# Verifies installer_install_sh substitutes every %%...%% placeholder.
set -euo pipefail

OUT="$(pwd)/$1"

echo "--- substituted install.sh ---"
cat "$OUT"
echo "------------------------------"

fail=0
for expect in "ARCH=amd64" "PART=32768" "VARLOG=4096" "VER=bazel-dev"; do
    if ! grep -q "$expect" "$OUT"; then
        echo "FAIL: '$expect' missing from output" >&2
        fail=1
    fi
done

leftover="$(grep -c '%%' "$OUT" || true)"
if [ "$leftover" -ne 0 ]; then
    echo "FAIL: $leftover leftover placeholder line(s) containing %%" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    exit 1
fi

echo "PASS: all placeholders substituted, none left"
