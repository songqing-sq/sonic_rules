#!/bin/sh
# Faithful reimplementation of initramfs-tools 0.142 hook-functions:
# auto_add_modules() with the default category set -- i.e. MODULES=most module
# SELECTION -- for the declarative `initramfs` rule.
#
# Why reimplement instead of sourcing hook-functions: upstream manual_add_modules
# resolves deps via `/sbin/modprobe --set-version=<v>` against the HOST's
# /lib/modules/<v>, which does not exist in the hermetic Bazel sandbox (and we
# refuse chroot). So we reproduce only the SELECTION (the named-module lists +
# the copy_modules_dir directory walks, with upstream's exclusions); the caller
# resolves the dependency closure from modules.dep, exactly as for the explicit
# `modules` list. Pinned to initramfs-tools 0.142 -- if that version bumps,
# re-diff against hook-functions:auto_add_modules.
#
# Prints module BASENAMES (suffix stripped), one per line, to stdout.
#   $1 = module tree root = contents of lib/modules/<kver>/ (so kernel/... is here)
set -ef
SRC="$1"

named() { for m in "$@"; do echo "$m"; done; }

# copy_modules_dir <reldir> [exclude ...]
#   exclude: a dir name / glob pruned from the walk; a *.ko exclude becomes *.ko*
#   (matches hook-functions copy_modules_dir). set -f keeps the globs literal so
#   find -name interprets them (no shell pathname expansion).
cmd_dir() {
    d="$1"; shift
    [ -d "$SRC/$d" ] || return 0
    args=""
    for ex in "$@"; do
        case "$ex" in *.ko) ex="${ex}*";; esac
        args="$args -name $ex -prune -o"
    done
    # word-split $args intentionally; globbing already disabled via set -f.
    # shellcheck disable=SC2086
    find "$SRC/$d" $args -name '*.ko*' -printf '%f\n' | sed 's/\.ko.*$//'
}

# Default category set: base net ide scsi block ata dasd firewire mmc
# usb_storage fb (auto_add_modules with no args).

# --- base ---
named btrfs ext2 ext3 ext4 f2fs isofs jfs reiserfs udf xfs \
      nfs nfsv2 nfsv3 nfsv4 af_packet atkbd i8042 psmouse \
      virtio_pci virtio_mmio extcon-usb-gpio extcon-usbc-cros-ec \
      axp20x_usb_power onboard_usb_hub onboard_usb_dev cros_ec_spi hyperv-keyboard
cmd_dir kernel/drivers/usb/host hwa-hc.ko sl811_cs.ko sl811-hcd.ko u132-hcd.ko whci-hcd.ko
cmd_dir kernel/drivers/usb/c67x00
cmd_dir kernel/drivers/usb/chipidea
cmd_dir kernel/drivers/usb/dwc2
cmd_dir kernel/drivers/usb/dwc3
cmd_dir kernel/drivers/usb/isp1760
cmd_dir kernel/drivers/usb/musb
cmd_dir kernel/drivers/usb/renesas_usbhs
cmd_dir kernel/drivers/usb/typec/tcpm
cmd_dir kernel/drivers/input/keyboard
cmd_dir kernel/drivers/hid 'hid-*ff.ko' hid-a4tech.ko hid-cypress.ko hid-dr.ko \
    hid-elecom.ko hid-gyration.ko hid-icade.ko hid-kensington.ko hid-kye.ko \
    hid-lcpower.ko hid-magicmouse.ko hid-ntrig.ko hid-petalynx.ko hid-picolcd.ko \
    hid-pl.ko hid-ps3remote.ko hid-quanta.ko 'hid-roccat-ko*.ko' hid-roccat-pyra.ko \
    hid-saitek.ko hid-sensor-hub.ko hid-sony.ko hid-speedlink.ko hid-tivo.ko \
    hid-twinhan.ko hid-uclogic.ko hid-wacom.ko hid-waltop.ko hid-wiimote.ko \
    hid-zydacron.ko
cmd_dir kernel/drivers/bus
cmd_dir kernel/drivers/clk
cmd_dir kernel/drivers/gpio
cmd_dir kernel/drivers/i2c/busses
cmd_dir kernel/drivers/i2c/muxes
cmd_dir kernel/drivers/mfd
cmd_dir kernel/drivers/pci/controller
cmd_dir kernel/drivers/phy
cmd_dir kernel/drivers/pinctrl
cmd_dir kernel/drivers/regulator
cmd_dir kernel/drivers/reset
cmd_dir kernel/drivers/spi
cmd_dir kernel/drivers/usb/phy
cmd_dir kernel/drivers/rtc

# --- net ---
cmd_dir kernel/drivers/net appletalk arcnet bonding can cdc-phonet.ko cdc_mbim.ko \
    cdc_subset.ko cx82310_eth.ko dummy.ko gl620a.ko hamradio hippi hso.ko \
    huawei_cdc_ncm.ko ifb.ko ipheth.ko irda kalmia.ko lg-vl600.ko macvlan.ko \
    macvtap.ko net1080.ko pcmcia plusb.ko qmi_wwan.ko sb1000.ko sierra_net.ko \
    team tokenring tun.ko veth.ko wan wimax wireless xen-netback.ko zaurus.ko
named nvmem-imx-ocotp

# --- ide ---
cmd_dir kernel/drivers/ide

# --- scsi ---
cmd_dir kernel/drivers/scsi
cmd_dir kernel/drivers/ufs
named mptfc mptsas mptscsih mptspi zfcp

# --- block ---
cmd_dir kernel/drivers/block
cmd_dir kernel/drivers/nvme
named vmd

# --- ata ---
cmd_dir kernel/drivers/ata

# --- dasd ---
named dasd_diag_mod dasd_eckd_mod dasd_fba_mod

# --- firewire ---
named firewire-ohci firewire-sbp2

# --- mmc ---
cmd_dir kernel/drivers/mmc

# --- usb_storage ---
cmd_dir kernel/drivers/usb/storage

# --- fb ---
named rockchipdrm pwm-cros-ec pwm_bl pwm-rockchip panel-simple analogix-anx6345 \
      pwm-sun4i sun4i-drm sun8i-mixer panel-edp pwm_imx27 nwl-dsi ti-sn65dsi86 \
      imx-dcss mux-mmio mxsfb imx8mq-interconnect
