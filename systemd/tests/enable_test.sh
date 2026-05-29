#!/bin/sh
# Asserts the systemd_enable tar contains the wants/ symlink that
# `deb-systemd-helper enable ssh.service` would have created in postinst.
set -e

tar_file="$1"
if [ -z "$tar_file" ]; then
    echo "FAIL: missing tar argument" >&2
    exit 1
fi

listing=$(tar -tvf "$tar_file")
echo "$listing"

# tar -tvf renders symlinks as "... link -> target".
expected="etc/systemd/system/multi-user.target.wants/ssh.service -> /lib/systemd/system/ssh.service"

if echo "$listing" | grep -qF "$expected"; then
    echo "PASS: found $expected"
    exit 0
fi

echo "FAIL: expected symlink not found: $expected" >&2
exit 1
