#!/bin/bash -e

rm -f "${ROOTFS_DIR}/etc/apt/apt.conf.d/51cache"
rm -f "${ROOTFS_DIR}/etc/apt/sources.list.d/00-temp.list"
find "${ROOTFS_DIR}/var/lib/apt/lists/" -type f -delete

# A release build upgrades every package to the archive state it will ship
# with. Local fast builds usually already have that state from the stage
# installs and should not spend a minute re-solving it (or silently change
# packages after the cleanup stage). CPZ_EXPORT_DIST_UPGRADE=0 skips it.
if [ "${CPZ_EXPORT_DIST_UPGRADE:-1}" = "0" ]; then
	echo "export-image: skipping dist-upgrade (CPZ_EXPORT_DIST_UPGRADE=0)"
else
	on_chroot << EOF
apt-get update
apt-get -y dist-upgrade --auto-remove --purge
apt-get clean
EOF
fi
