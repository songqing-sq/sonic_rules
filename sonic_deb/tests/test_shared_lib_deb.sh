#!/bin/bash
# Integration test: verify shared library deb packages (libxxx, libxxx-dbgsym, libxxx-dev).
# Checks deb structure, control fields, data content, and symlink correctness.
# Usage: test_shared_lib_deb.sh <deb_file> <test_name>
set -e

DEB="$1"
TEST_NAME="${2:-shared_lib_deb}"
RESULTS="${TEST_RESULTS_FILE:-test_results.txt}"

pass() { echo "PASS: $1" | tee -a "$RESULTS"; }
fail() { echo "FAIL: $1" | tee -a "$RESULTS"; FAILED=1; }

FAILED=0
WORKDIR=$(mktemp -d)
trap "rm -rf $WORKDIR" EXIT

echo "=== Test: $TEST_NAME ===" | tee -a "$RESULTS"
echo "CMD: $0 $*" | tee -a "$RESULTS"

# --- 1. deb structure ---
MEMBERS=$(ar t "$DEB")
echo "$MEMBERS" | grep -q "^debian-binary$" && pass "has debian-binary" || fail "missing debian-binary"
echo "$MEMBERS" | grep -q "^control.tar.gz$" && pass "has control.tar.gz" || fail "missing control.tar.gz"
echo "$MEMBERS" | grep -q "^data.tar.gz$"    && pass "has data.tar.gz"    || fail "missing data.tar.gz"

# --- 2. control fields ---
ar p "$DEB" control.tar.gz | tar -xzf - -C "$WORKDIR"
CTRL="$WORKDIR/control"

check_field() {
    local field="$1" expected="$2"
    local actual
    actual=$(grep "^${field}:" "$CTRL" | head -1 | sed "s/^${field}: //")
    [ "$actual" = "$expected" ] \
        && pass "control field $field='$expected'" \
        || fail "control field $field: expected='$expected' actual='$actual'"
}

check_field "Package"      "${EXPECTED_PACKAGE}"
check_field "Version"      "${EXPECTED_VERSION}"
check_field "Architecture" "${EXPECTED_ARCH}"
check_field "Section"      "${EXPECTED_SECTION}"

# --- 3. data.tar content: check expected paths exist ---
DATA_DIR=$(mktemp -d)
ar p "$DEB" data.tar.gz | tar -xzf - -C "$DATA_DIR"
DATA_LIST=$(ar p "$DEB" data.tar.gz | tar -tzf -)

if [ -n "${EXPECTED_DATA_PATHS}" ]; then
    for expected_path in ${EXPECTED_DATA_PATHS}; do
        echo "$DATA_LIST" | grep -qF "$expected_path" \
            && pass "data.tar contains $expected_path" \
            || fail "data.tar missing $expected_path"
    done
fi

# --- 4. symlink verification ---
# EXPECTED_SYMLINKS format: "link_path->target link_path->target ..."
if [ -n "${EXPECTED_SYMLINKS}" ]; then
    for entry in ${EXPECTED_SYMLINKS}; do
        link_path="${entry%%->*}"
        expected_target="${entry##*->}"
        full_link="$DATA_DIR/$link_path"
        if [ -L "$full_link" ]; then
            actual_target=$(readlink "$full_link")
            if [ "$actual_target" = "$expected_target" ]; then
                pass "symlink $link_path -> $expected_target"
            else
                fail "symlink $link_path: expected target='$expected_target' actual='$actual_target'"
            fi
        else
            # Check in tar listing (symlinks may appear as "link -> target" in verbose listing)
            VERBOSE_LIST=$(ar p "$DEB" data.tar.gz | tar -tzvf - 2>/dev/null || true)
            if echo "$VERBOSE_LIST" | grep -q "$link_path"; then
                # Extract the symlink target from verbose listing
                link_line=$(echo "$VERBOSE_LIST" | grep "$link_path" | head -1)
                if echo "$link_line" | grep -q "^l"; then
                    actual_target=$(echo "$link_line" | sed 's/.* -> //')
                    if [ "$actual_target" = "$expected_target" ]; then
                        pass "symlink $link_path -> $expected_target (from tar listing)"
                    else
                        fail "symlink $link_path: expected target='$expected_target' actual='$actual_target' (from tar listing)"
                    fi
                else
                    fail "symlink $link_path is not a symlink in tar (line: $link_line)"
                fi
            else
                fail "symlink $link_path not found in data.tar"
            fi
        fi
    done
fi

# --- 5. verify no symlinks where not expected ---
if [ "${EXPECT_NO_SYMLINKS}" = "1" ]; then
    SYMLINK_COUNT=$(find "$DATA_DIR" -type l 2>/dev/null | wc -l)
    if [ "$SYMLINK_COUNT" -eq 0 ]; then
        pass "no unexpected symlinks in data.tar"
    else
        FOUND_LINKS=$(find "$DATA_DIR" -type l -exec ls -la {} \;)
        fail "unexpected symlinks found: $FOUND_LINKS"
    fi
fi

# --- 6. verify files are regular (not symlinks) where expected ---
if [ -n "${EXPECTED_REGULAR_FILES}" ]; then
    for fpath in ${EXPECTED_REGULAR_FILES}; do
        full_path="$DATA_DIR/$fpath"
        if [ -f "$full_path" ] && [ ! -L "$full_path" ]; then
            pass "regular file $fpath exists"
        elif [ -L "$full_path" ]; then
            fail "$fpath is a symlink, expected regular file"
        else
            fail "regular file $fpath not found"
        fi
    done
fi

rm -rf "$DATA_DIR"

echo "=== Done: $TEST_NAME ===" | tee -a "$RESULTS"
exit $FAILED
