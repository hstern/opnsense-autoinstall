#!/bin/sh
#-
# mkimage-vagrant.sh — run mkimage.sh from Linux/macOS/Windows by
# borrowing a throwaway FreeBSD VM via Vagrant.
#
# mkimage.sh must run on FreeBSD (it mounts the image's UFS filesystem
# read-write, which only FreeBSD's kernel does reliably). This wrapper
# spins up a disposable FreeBSD box with Vagrant, copies the inputs in
# over SSH, runs mkimage.sh inside it, copies the finished image back,
# and destroys the box.
#
# We deliberately do NOT rely on Vagrant synced folders: FreeBSD guests
# default to rsync sync (host->guest only), so the *output* image
# couldn't come back that way. Ferrying over the box's SSH connection
# (via `vagrant ssh-config`) is provider-agnostic and bidirectional.
#
# Requires: vagrant + a provider (VirtualBox is the cross-platform
# default; note VirtualBox is unreliable on Apple Silicon — use the
# qemu/utm provider there, or just run mkimage.sh on a real FreeBSD box
# per the README).
#
# MIT licensed. See LICENSE.

set -eu

SELF_DIR=$(cd "$(dirname "$0")" && pwd)

usage() {
	cat >&2 <<EOF
Usage: $0 -i INPUT.img -o OUTPUT.img [options]

Same flags as mkimage.sh (passed through):
  -i INPUT     stock OPNsense vga .img (decompressed; not .bz2)
  -o OUTPUT    path to write the customized image (on THIS host)
  -c CONFIG    config.xml to install as the target's /conf/config.xml
  -d DISK      target install disk inside the VM (default: auto)
  -s SWAP      swap partition size, gpart syntax e.g. 8G (default: none)
  -f FINAL     reboot | halt  when the install finishes (default: reboot)

Extra:
  -B BOX       Vagrant box to use (default: freebsd/FreeBSD-14.2-RELEASE)

Boots a throwaway FreeBSD VM via Vagrant, runs mkimage.sh inside it,
and brings OUTPUT back here. Needs vagrant + a provider installed.
EOF
	exit 1
}

INPUT= OUTPUT= CONFIG= DISK=auto SWAP= FINAL=reboot
BOX="freebsd/FreeBSD-14.2-RELEASE"

while getopts "i:o:c:d:s:f:B:h" opt; do
	case "${opt}" in
	i) INPUT=${OPTARG} ;;
	o) OUTPUT=${OPTARG} ;;
	c) CONFIG=${OPTARG} ;;
	d) DISK=${OPTARG} ;;
	s) SWAP=${OPTARG} ;;
	f) FINAL=${OPTARG} ;;
	B) BOX=${OPTARG} ;;
	*) usage ;;
	esac
done

[ -n "${INPUT}" ] && [ -n "${OUTPUT}" ] || usage
command -v vagrant >/dev/null 2>&1 || { echo "ERROR: vagrant not found in PATH." >&2; exit 1; }
[ -r "${INPUT}" ] || { echo "ERROR: input image ${INPUT} not readable." >&2; exit 1; }
[ -r "${SELF_DIR}/mkimage.sh" ] || { echo "ERROR: mkimage.sh not found alongside this script." >&2; exit 1; }
[ -r "${SELF_DIR}/autoinstall.sh" ] || { echo "ERROR: autoinstall.sh not found alongside this script." >&2; exit 1; }
[ -z "${CONFIG}" ] || [ -r "${CONFIG}" ] || { echo "ERROR: config ${CONFIG} not readable." >&2; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/opnsense-autoinstall-vagrant.XXXXXX")
SSHCFG="${WORK}/ssh-config"

cleanup() {
	if [ -f "${WORK}/Vagrantfile" ]; then
		echo ">> destroying the throwaway FreeBSD VM"
		( cd "${WORK}" && vagrant destroy -f >/dev/null 2>&1 ) || true
	fi
	rm -rf "${WORK}"
}
trap cleanup EXIT INT TERM

cat > "${WORK}/Vagrantfile" <<EOF
Vagrant.configure("2") do |config|
  config.vm.box = "${BOX}"
  config.vm.synced_folder ".", "/vagrant", disabled: true
  config.vm.boot_timeout = 600
end
EOF

echo ">> booting throwaway FreeBSD VM (box: ${BOX})"
( cd "${WORK}" && vagrant up )
( cd "${WORK}" && vagrant ssh-config > "${SSHCFG}" )

scp_in()  { scp -q -F "${SSHCFG}" "$1" default:"$2"; }
ssh_run() { ssh -F "${SSHCFG}" default "$@"; }

echo ">> copying inputs into the VM"
ssh_run 'mkdir -p /tmp/oai'
scp_in "${SELF_DIR}/mkimage.sh"     /tmp/oai/mkimage.sh
scp_in "${SELF_DIR}/autoinstall.sh" /tmp/oai/autoinstall.sh
scp_in "${INPUT}"                   /tmp/oai/input.img
MKARGS="-i /tmp/oai/input.img -o /tmp/oai/output.img -a /tmp/oai/autoinstall.sh -d ${DISK} -f ${FINAL}"
[ -n "${SWAP}" ] && MKARGS="${MKARGS} -s ${SWAP}"
if [ -n "${CONFIG}" ]; then
	scp_in "${CONFIG}" /tmp/oai/config.xml
	MKARGS="${MKARGS} -c /tmp/oai/config.xml"
fi

echo ">> running mkimage.sh inside the VM"
ssh_run "cd /tmp/oai && sudo sh mkimage.sh ${MKARGS}"

echo ">> copying the finished image back to ${OUTPUT}"
scp -q -F "${SSHCFG}" default:/tmp/oai/output.img "${OUTPUT}"

echo ">> done: ${OUTPUT}"
