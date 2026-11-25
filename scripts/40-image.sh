#!/bin/bash
# Stage 40 — assemble a bootable disk image without loop devices.
#
# Docker Desktop on macOS has no losetup, so nothing here mounts anything:
#   * the FAT32 boot partition is built with mtools on a plain file
#   * the ext4 root partition is built with `mke2fs -d` (populate from a tree)
#   * the MBR is written with sfdisk and the two parts are dd'ed in
set -euo pipefail
cd "$(dirname "$0")/.."
. ./config.sh
. scripts/lib.sh

for tool in mformat mcopy sfdisk mke2fs zstd dd truncate; do
    require "$tool"
done

UI_SUFFIX=""
[ "$UI_TEST" = "1" ] && UI_SUFFIX="-ui"
NAME="cpz-arch-${CPZ_ARCH_VERSION}-cm0${UI_SUFFIX}"
IMG="$BUILD/$NAME.img"
BOOTIMG="$BUILD/boot.fat"
ROOTIMG="$BUILD/root.ext4"
BOOTSRC="$BUILD/boot"
STAGE="$BUILD/root-stage"

# --- boot partition -------------------------------------------------------
log "collecting /boot"
rm -rf "$BOOTSRC"
cp -a "$ROOT/boot" "$BOOTSRC"

log "building FAT32 boot partition (${BOOT_MB} MiB)"
rm -f "$BOOTIMG"
mformat -i "$BOOTIMG" -C -F -T $((BOOT_MB * 2048)) -h 64 -s 32 -v BOOT ::
mcopy -i "$BOOTIMG" -s -o "$BOOTSRC"/* ::/

# --- root partition -------------------------------------------------------
log "staging the root tree (hardlinks, /boot excluded)"
rm -rf "$STAGE"
cp -al "$ROOT" "$STAGE"
rm -rf "$STAGE/boot"
mkdir -p "$STAGE/boot"

USED_KB=$(du -sk "$STAGE" | cut -f1)
LIMIT_KB=$((ROOT_MB * 1024 * 95 / 100))
if [ "$USED_KB" -gt "$LIMIT_KB" ]; then
    die "rootfs is ${USED_KB} KiB but ${ROOT_MB} MiB only fits ${LIMIT_KB} KiB; raise ROOT_MB in config.sh"
fi

log "building ext4 root partition (${ROOT_MB} MiB, ${USED_KB} KiB used)"
rm -f "$ROOTIMG"
mke2fs -q -F -t ext4 -L cpzroot -m 0 -d "$STAGE" "$ROOTIMG" "${ROOT_MB}M"

# --- disk -----------------------------------------------------------------
TOTAL_MB=$((1 + BOOT_MB + ROOT_MB))
BOOT_START=2048
BOOT_SECT=$((BOOT_MB * 2048))
ROOT_START=$((BOOT_START + BOOT_SECT))
ROOT_SECT=$((ROOT_MB * 2048))

log "writing MBR (${TOTAL_MB} MiB, disk id 0x$DISK_ID)"
rm -f "$IMG"
truncate -s "${TOTAL_MB}M" "$IMG"

sfdisk --label dos --quiet "$IMG" <<EOF
start=$BOOT_START, size=$BOOT_SECT, type=c, bootable
start=$ROOT_START, size=$ROOT_SECT, type=83
EOF
# The MBR disk signature is what the kernel turns into PARTUUID=<id>-NN.
sfdisk --disk-id "$IMG" "0x$DISK_ID" >/dev/null

dd if="$BOOTIMG" of="$IMG" bs=1M seek=$((BOOT_START / 2048)) conv=notrunc status=none
dd if="$ROOTIMG" of="$IMG" bs=1M seek=$((ROOT_START / 2048)) conv=notrunc status=none

log "compressing"
zstd -q -T0 -3 -f "$IMG" -o "$IMG.zst"

rm -rf "$STAGE" "$BOOTIMG" "$ROOTIMG"

cat > "$BUILD/$NAME.txt" <<EOF
name:        $NAME
version:     $CPZ_ARCH_VERSION
board:       $BOARD
date:        $(date -u +%Y-%m-%dT%H:%M:%SZ)
image:       $NAME.img
image.zst:   $NAME.img.zst
root:        /dev/mmcblk0p2  ext4, ${ROOT_MB} MiB
boot:        /dev/mmcblk0p1  FAT32, ${BOOT_MB} MiB
rootfs used: ${USED_KB} KiB
kernel:      $(kernel_version)
login:       $USER_NAME / $USER_PASS
EOF

# The build volume is not visible on the host; export the artifacts.
mkdir -p "${OUT_DIR:?}"
cp -f "$IMG" "$IMG.zst" "$BUILD/$NAME.txt" "${OUT_DIR:?}/"
log "image: $(du -h "$IMG" | cut -f1) raw, $(du -h "$IMG.zst" | cut -f1) zstd"
log "artifacts copied to $OUT_DIR"
