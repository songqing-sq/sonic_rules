#!/usr/bin/env bash
# Faithful port of the assembly half of onie-mk-demo.sh (no signing).
# Args: $1 sharch_body template, $2 install.sh (substituted), $3 payload zip,
#       $4 machine, $5 platform, $6 onie-image.conf, $7 onie-image-<arch>.conf,
#       $8 output .bin, $9 hermetic GNU tar binary
set -euo pipefail
sharch_body="$1"; install_sh="$2"; payload="$3"; machine="$4"; platform="$5"
conf="$6"; conf_arch="$7"; out="$8"; gtar="$9"
tmp=$(mktemp -d); inst="$tmp/installer"; mkdir -p "$inst"
cp "$install_sh" "$inst/install.sh"
cp "$sharch_body" "$inst/sharch_body.sh"
cp "$conf" "$inst/onie-image.conf"
cp "$conf_arch" "$inst/"
# Symlink (not copy) the payload zip (~1.3G) into installer/; tar -h below
# dereferences it so the sharch tarball carries the real bytes.
ln -s "$(readlink -f "$payload")" "$inst/$(basename "$payload")"
printf 'machine=%s\nplatform=%s\n' "$machine" "$platform" > "$inst/machine.conf"
sharch="$tmp/sharch.tar"
# Hermetic from-source GNU tar (passed as $gtar), not the host tar; -h
# dereferences the payload symlink so the real bytes land in the tarball.
"$gtar" -C "$tmp" -chf "$sharch" installer
sha1=$(sha1sum < "$sharch" | awk '{print $1}')
tar_size=$(wc -c < "$sharch")
out=$(readlink -f "$out")
cp "$sharch_body" "$out"
chmod u+w "$out"
sed -i -e "s/%%IMAGE_SHA1%%/$sha1/" -e "s|%%PAYLOAD_IMAGE_SIZE%%|$tar_size|" "$out"
cat "$sharch" >> "$out"
chmod +x "$out"
rm -rf "$tmp"
