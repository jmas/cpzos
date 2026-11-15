#!/bin/bash -e

# Install the kmscon-based CPZ terminal session.

install -d -m 0755 "${ROOTFS_DIR}/etc/kmscon"
install -m 0644 files/kmscon.conf "${ROOTFS_DIR}/etc/kmscon/kmscon.conf"

install -d -m 0755 "${ROOTFS_DIR}/usr/local/bin"
install -m 0755 files/cpz-kmscon files/cpz-login \
	"${ROOTFS_DIR}/usr/local/bin/"

install -d -m 0755 "${ROOTFS_DIR}/etc/profile.d"
install -m 0644 files/cpz-session.sh \
	"${ROOTFS_DIR}/etc/profile.d/cpz-session.sh"

install -m 0644 files/tmux.conf "${ROOTFS_DIR}/etc/tmux.conf"

install -d -m 0755 \
	"${ROOTFS_DIR}/etc/systemd/system/kmsconvt@tty1.service.d"
install -m 0644 files/kmsconvt@tty1.service.d/10-cpz.conf \
	"${ROOTFS_DIR}/etc/systemd/system/kmsconvt@tty1.service.d/10-cpz.conf"

# userconf-pi's cancel-rename enables getty/LightDM for Raspberry Pi OS. The
# CPZ image has neither on tty1; keep only the SSH/sudoers bookkeeping so a
# rpi-preseed rename does not undo the kmscon session.
install -d -m 0755 "${ROOTFS_DIR}/usr/local/share/cpz"
install -m 0755 files/cancel-rename \
	"${ROOTFS_DIR}/usr/local/share/cpz/cancel-rename"

on_chroot << 'CHROOT'
set -e

if [ -e /usr/bin/cancel-rename ] &&
	! dpkg-divert --list /usr/bin/cancel-rename | grep -q 'cpz-os'; then
	dpkg-divert --package cpz-os --divert /usr/bin/cancel-rename.distrib \
		--rename /usr/bin/cancel-rename
fi
install -m 0755 /usr/local/share/cpz/cancel-rename /usr/bin/cancel-rename

systemctl daemon-reload || true
CHROOT
