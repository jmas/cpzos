#!/bin/bash -e

timezone=${TIMEZONE_DEFAULT:-UTC}
[ -n "$timezone" ] || timezone=UTC
echo "$timezone" > "${ROOTFS_DIR}/etc/timezone"
rm "${ROOTFS_DIR}/etc/localtime"

on_chroot << EOF
dpkg-reconfigure -f noninteractive tzdata
EOF
