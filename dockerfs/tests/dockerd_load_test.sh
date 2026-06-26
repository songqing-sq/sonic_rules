#!/usr/bin/env bash
# OPTIONAL end-to-end check (tagged manual,no-sandbox): point a real dockerd at
# the synthesized store and confirm `docker images` lists docker-database. Needs
# privileges / loop devices / overlay mounts, so it is NOT run in CI.
set -euo pipefail

STORE_TGZ="$(pwd)/$1"

ROOT="$(mktemp -d)"
trap 'kill "${DOCKERD_PID:-0}" 2>/dev/null || true; rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/data" "$ROOT/exec"
tar -xf "$STORE_TGZ" -C "$ROOT/data"

dockerd --data-root "$ROOT/data" --exec-root "$ROOT/exec" \
    --host "unix://$ROOT/docker.sock" --storage-driver overlay2 \
    --iptables=false --bridge=none &
DOCKERD_PID=$!

for _ in $(seq 1 30); do
    if docker -H "unix://$ROOT/docker.sock" info >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

docker -H "unix://$ROOT/docker.sock" images
docker -H "unix://$ROOT/docker.sock" images | grep -q docker-database || {
    echo "FAIL: docker-database not listed" >&2; exit 1; }
echo "PASS: dockerd loaded the synthesized store"
