#!/bin/bash
# Integration test: verify the content of a built .deb package.
# Usage: test_deb_content.sh <deb_file> <test_name>
# Results are written to $TEST_RESULTS_FILE (default: test_results.txt)
set -e

DEB="$1"
TEST_NAME="${2:-deb_content}"
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

check_field "Package"      "${EXPECTED_PACKAGE:-test-sonic-deb}"
check_field "Version"      "${EXPECTED_VERSION:-1.0.0}"
check_field "Architecture" "${EXPECTED_ARCH:-amd64}"
check_field "Maintainer"   "${EXPECTED_MAINTAINER:-SONiC Test <test@sonic-switch.org>}"
check_field "Section"      "${EXPECTED_SECTION:-net}"
check_field "Priority"     "${EXPECTED_PRIORITY:-optional}"

# Installed-Size must be a positive integer
ISIZE=$(grep "^Installed-Size:" "$CTRL" | head -1 | awk '{print $2}')
[[ "$ISIZE" =~ ^[0-9]+$ ]] && [ "$ISIZE" -gt 0 ] \
    && pass "Installed-Size is positive ($ISIZE)" \
    || fail "Installed-Size invalid: '$ISIZE'"

# --- 3. md5sums (optional: skip check if SKIP_MD5SUMS_CHECK=1) ---
if [ "${SKIP_MD5SUMS_CHECK:-0}" = "1" ]; then
    pass "md5sums check skipped (pre-packaged data branch)"
elif [ -f "$WORKDIR/md5sums" ] && [ -s "$WORKDIR/md5sums" ]; then
    pass "md5sums present and non-empty"
else
    fail "md5sums missing or empty"
fi

# --- 4. data.tar content ---
DATA_LIST=$(ar p "$DEB" data.tar.gz | tar -tzf -)
if [ -z "${EXPECTED_DATA_PATHS}" ]; then
    pass "data.tar content check skipped (no expected paths specified)"
else
    for expected_path in ${EXPECTED_DATA_PATHS}; do
        echo "$DATA_LIST" | grep -qF "$expected_path" \
            && pass "data.tar contains $expected_path" \
            || fail "data.tar missing $expected_path"
    done
fi

# --- 5. .changes file (sibling of deb) ---
CHANGES="${DEB%.deb}.changes"
if [ -f "$CHANGES" ]; then
    grep -q "^Format:" "$CHANGES"  && pass ".changes has Format field"  || fail ".changes missing Format"
    grep -q "^Files:"  "$CHANGES"  && pass ".changes has Files section" || fail ".changes missing Files section"
else
    fail ".changes file not found at $CHANGES"
fi

echo "=== Done: $TEST_NAME ===" | tee -a "$RESULTS"
exit $FAILED
