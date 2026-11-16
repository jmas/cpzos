#!/bin/bash -e

# Compile and install CardputerZero kernel modules + overlay
install -d -m 0755 "${ROOTFS_DIR}/opt"
# The upstream config_setup target otherwise downloads this unpinned Gist.
install -m 0755 files/rpi-config.py "${ROOTFS_DIR}/opt/rpi-config.py"

# The driver is pinned by default so rebuilding the same OS tag produces the
# same kernel modules. Set CPZ_DTOVERLAYS_REF=main to track upstream.
DTOVERLAYS_REF=${CPZ_DTOVERLAYS_REF:-4f7aeee9fc103ebb03d22cac476bb191ecfb321e}
case "$DTOVERLAYS_REF" in
    ''|*[!A-Za-z0-9._/-]*)
        echo "stage2: invalid CPZ_DTOVERLAYS_REF '$DTOVERLAYS_REF'" >&2
        exit 1
        ;;
esac
printf '%s\n' "$DTOVERLAYS_REF" > "${ROOTFS_DIR}/opt/cpz-dtoverlays.ref"

on_chroot << 'CHROOT'
set -e

# Install build dependencies
apt-get install -y --no-install-recommends \
    build-essential \
    linux-headers-rpi-v8 \
    device-tree-compiler \
    git

# Fetch the configured commit/tag/branch, then check it out detached.
DTOVERLAYS_REF=$(cat /opt/cpz-dtoverlays.ref)
rm -rf /tmp/dtoverlays
git init -q /tmp/dtoverlays
git -C /tmp/dtoverlays remote add origin \
    https://github.com/m5stack/m5stack-linux-dtoverlays.git
git -C /tmp/dtoverlays fetch --depth=1 origin "$DTOVERLAYS_REF"
git -C /tmp/dtoverlays checkout -q --detach FETCH_HEAD
git -C /tmp/dtoverlays rev-parse HEAD \
    > /etc/cardputerzero-dtoverlays.commit
rm -f /opt/cpz-dtoverlays.ref

KVER=$(basename "$(ls -d /lib/modules/*-rpi-v8 | sort -V | tail -n 1)")
export KERNELDIR="/lib/modules/${KVER}/build"
export EXTRADIR="/lib/modules/${KVER}/extra"

# make and install st7789v overlay + module
cd /tmp/dtoverlays/modules/CardputerZero
make KERNELDIR="$KERNELDIR" EXTRADIR="$EXTRADIR" CONFIG_CARDPUTERO_V0_5=y install
make KERNELDIR="$KERNELDIR" EXTRADIR="$EXTRADIR" CONFIG_CARDPUTERO_V0_5=y config_setup

# Reserve 64 MiB of contiguous memory for the KMS display driver.
DEFAULT_CONFIG="/boot/firmware/config.txt"
sed -i 's/^dtoverlay=vc4-kms-v3d$/dtoverlay=vc4-kms-v3d,cma-64/' "$DEFAULT_CONFIG"

# Update module dependencies
depmod -a "${KVER}"

# Clean up build artifacts only (keep all build tools for user driver builds)
rm -rf /tmp/dtoverlays

CHROOT
