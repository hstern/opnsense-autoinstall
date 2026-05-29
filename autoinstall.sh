#!/bin/sh
#-
# opnsense-autoinstall — headless OPNsense installer.
#
# Runs ON the OPNsense live image (the vga .img or dvd .iso live
# system) at boot, in place of the interactive `bsdinstall opnsense`
# TUI. Drives the same non-interactive sub-commands the stock
# orchestrator uses, with the disk auto-selected and no dialogs, then
# (optionally) drops a supplied config.xml into the installed system
# so it boots fully configured.
#
# This is installed into the live image by mkimage.sh; it is not run
# by hand. Configuration comes from /etc/opnsense-autoinstall.conf
# (also placed by mkimage.sh), with safe defaults below.
#
# Mechanism notes (why this works) live in README.md. In short:
# OPNsense's installer has no scripted mode and ships no FreeBSD
# distribution sets (it clones the live filesystem via cpdup), so
# neither `bsdinstall script /etc/installerconfig` nor a preseed
# applies. The orchestrator is just a sequencer over non-interactive
# sub-commands, which this script calls directly.
#
# MIT licensed. See LICENSE.

set -eu

CONF=/etc/opnsense-autoinstall.conf
[ -r "${CONF}" ] && . "${CONF}"

# ---- defaults (override in /etc/opnsense-autoinstall.conf) ----------------
#
# TARGET_DISK: device to install onto. "auto" = the sole disk, or the
#   first of kern.disks if several. Set explicitly (e.g. "vtbd0",
#   "ada0", "nvd0") on multi-disk machines.
: "${TARGET_DISK:=auto}"
#
# SWAP_SIZE: freebsd-swap partition size (gpart size syntax, e.g. "8G"),
#   or empty for no swap.
: "${SWAP_SIZE:=}"
#
# CONFIG_XML: path (on the live image) to a config.xml to install into
#   the target as /conf/config.xml. Empty = leave the stock default
#   config (interactive first-boot setup).
: "${CONFIG_XML:=/etc/opnsense-autoinstall-config.xml}"
#
# FINAL: action when done — "reboot" or "halt".
: "${FINAL:=reboot}"
#
# CONSOLE_LOG: where to tee progress so it's visible on the console.
: "${CONSOLE_LOG:=/dev/console}"

log() { echo "opnsense-autoinstall: $*" > "${CONSOLE_LOG}" 2>/dev/null || echo "opnsense-autoinstall: $*"; }
die() { log "FATAL: $*"; exit 1; }

[ "$(id -u)" = "0" ] || die "must run as root"

# bsdinstall sub-commands read these.
export BSDINSTALL_KEYMAP_DONE=1     # skip the keymap dialog
export WORKAROUND_HYBRID=1          # GPT/UEFI hybrid boot, as the UFS path sets
export DISTRIBUTIONS=               # nothing to extract; OPNsense clones the live FS
export nonInteractive=YES

# ---- 1. select target disk ------------------------------------------------
if [ "${TARGET_DISK}" = "auto" ]; then
	TARGET_DISK=$(sysctl -n kern.disks | awk '{ print $1 }')
	[ -n "${TARGET_DISK}" ] || die "no disks found (kern.disks empty)"
	log "auto-selected target disk: ${TARGET_DISK}"
fi
[ -e "/dev/${TARGET_DISK}" ] || die "target disk /dev/${TARGET_DISK} not found"

# ---- 2. partition (mirrors /usr/libexec/bsdinstall/opnsense-ufs) ----------
# GPT: EFI system partition + freebsd-boot + freebsd-ufs root (+ optional
# swap). Sizes match opnsense.subr's constants (260M EFI, 512k boot).
log "partitioning ${TARGET_DISK} (destroying existing contents)"
gpart destroy -F "${TARGET_DISK}" >/dev/null 2>&1 || true

if [ -n "${SWAP_SIZE}" ]; then
	PARTS="{ 260M efi, 512k freebsd-boot, ${SWAP_SIZE} freebsd-swap, auto freebsd-ufs / }"
	SWAP_IDX=3
	ROOT_IDX=4
else
	PARTS="{ 260M efi, 512k freebsd-boot, auto freebsd-ufs / }"
	SWAP_IDX=
	ROOT_IDX=3
fi

bsdinstall scriptedpart "${TARGET_DISK}" gpt "${PARTS}" \
	|| die "scriptedpart failed on ${TARGET_DISK}"

gpart bootcode -b /boot/pmbr -p /boot/gptboot -i 2 "${TARGET_DISK}" >/dev/null \
	|| die "gpart bootcode failed"
gpart modify -i 1 -l efifs  "${TARGET_DISK}" >/dev/null || die "label efi failed"
gpart modify -i 2 -l bootfs "${TARGET_DISK}" >/dev/null || die "label boot failed"
gpart modify -i "${ROOT_IDX}" -l rootfs "${TARGET_DISK}" >/dev/null || die "label root failed"
[ -n "${SWAP_IDX}" ] && { gpart modify -i "${SWAP_IDX}" -l swapfs "${TARGET_DISK}" >/dev/null || die "label swap failed"; }

# Rewrite the generated fstab to use the GPT labels, as opnsense-ufs does.
if [ -f "${BSDINSTALL_TMPETC:=/tmp/bsdinstall_etc}/fstab" ]; then
	cp "${BSDINSTALL_TMPETC}/fstab" "${BSDINSTALL_TMPETC}/fstab.bak"
	SED_SWAP=""
	[ -n "${SWAP_IDX}" ] && SED_SWAP="-e s:/${TARGET_DISK}p${SWAP_IDX}:/gpt/swapfs:"
	# shellcheck disable=SC2086
	sed -e "s:/${TARGET_DISK}p${ROOT_IDX}:/gpt/rootfs:" \
	    -e "s:/${TARGET_DISK}p1:/gpt/efifs:" ${SED_SWAP} \
	    "${BSDINSTALL_TMPETC}/fstab.bak" > "${BSDINSTALL_TMPETC}/fstab"
	rm -f "${BSDINSTALL_TMPETC}/fstab.bak"
fi

# ---- 3. mount target, clone live FS, write bootloader ---------------------
log "mounting target"
bsdinstall mount || die "mount failed"

log "cloning live filesystem to target (cpdup) — this takes a few minutes"
bsdinstall opnsense-install || die "opnsense-install (cpdup) failed"

log "writing boot configuration"
bsdinstall bootconfig || die "bootconfig failed"

# ---- 4. inject supplied config.xml ----------------------------------------
# opnsense-install cloned the live system's /conf/config.xml onto the
# target. Overwriting the target's copy here makes the installed system
# boot fully configured — no interactive import, no seed media.
if [ -n "${CONFIG_XML}" ] && [ -r "${CONFIG_XML}" ]; then
	: "${BSDINSTALL_CHROOT:=/mnt}"
	log "installing supplied config.xml into target /conf/config.xml"
	mkdir -p "${BSDINSTALL_CHROOT}/conf"
	cp "${CONFIG_XML}" "${BSDINSTALL_CHROOT}/conf/config.xml"
fi

# ---- 5. finish ------------------------------------------------------------
log "finalizing (entropy, unmount)"
bsdinstall entropy || true
bsdinstall umount || true

log "installation complete; ${FINAL}"
case "${FINAL}" in
	halt) halt -p ;;
	*)    reboot ;;
esac
