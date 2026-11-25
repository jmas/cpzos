#!/bin/bash
# Stage 20 — build the Cardputer Zero out-of-tree kernel modules and overlays.
#
# The vendor tree is pinned to the same commit the main CPZ image uses. The
# modules are compiled inside the target chroot against linux-rpi-headers, then
# the toolchain and the sources are removed again (stage 30).
set -euo pipefail
cd "$(dirname "$0")/.."
. ./config.sh
. scripts/lib.sh

require git
KVER=$(kernel_version)
log "kernel: $KVER"

# --- fetch the pinned vendor tree -------------------------------------------
SRC="$BUILD/src/dtoverlays"
if [ ! -d "$SRC/.git" ]; then
    log "fetching m5stack-linux-dtoverlays @ $DTOVERLAYS_REF"
    rm -rf "$SRC"
    git init -q "$SRC"
    git -C "$SRC" remote add origin "$DTOVERLAYS_URL"
    git -C "$SRC" fetch -q --depth=1 origin "$DTOVERLAYS_REF"
    git -C "$SRC" checkout -q --detach FETCH_HEAD
fi
[ -f "$SRC/modules/CardputerZero/Makefile" ] || die "vendor tree looks incomplete: $SRC"

# --- build inside the target ------------------------------------------------
pacman_target -Sy --needed
pacman_target -S --needed $BUILD_PACKAGES

log "copying sources into the chroot"
rm -rf "$ROOT/tmp/dtoverlays"
mkdir -p "$ROOT/tmp/dtoverlays"
cp -a "$SRC/modules" "$ROOT/tmp/dtoverlays/"

# CardputerZero carries the board overlay (keypad, audio, PMIC, battery gauge,
# IMU rails). The sub-directories build the individual drivers. Display
# bring-up is deliberately not configured here: the drivers stay available for
# whatever stack is added later.
MODULES="CardputerZero st7789v-1.0 tca8418-1.0 m5ioe1-1.0 bq27220-1.0 es8389-1.0 imu-1.0"

for dir in $MODULES; do
    log "building $dir"
    in_root "cd /tmp/dtoverlays/modules/$dir && \
        make -j\"\$(nproc)\" KERNELDIR=/usr/lib/modules/$KVER/build ARCH=arm64"
done

log "installing modules, overlays, firmware and udev rules"
mkdir -p "$ROOT/usr/lib/modules/$KVER/extra" "$ROOT/boot/overlays" \
         "$ROOT/lib/firmware" "$ROOT/etc/udev/rules.d" "$ROOT/usr/share/keymaps"

for dir in $MODULES; do
    d="$ROOT/tmp/dtoverlays/modules/$dir"
    find "$d" -maxdepth 1 -name '*.ko'  -exec cp {} "$ROOT/usr/lib/modules/$KVER/extra/" \;
    find "$d" -maxdepth 1 -name '*.dtbo' -exec cp {} "$ROOT/boot/overlays/" \;
done
find "$ROOT/tmp/dtoverlays/modules" -maxdepth 2 \( -name '*.bin' -o -name '*.fw' \) \
    -exec cp {} "$ROOT/lib/firmware/" \;
find "$ROOT/tmp/dtoverlays/modules" -maxdepth 2 -name '*.rules' \
    -exec cp {} "$ROOT/etc/udev/rules.d/" \;
[ -f "$ROOT/tmp/dtoverlays/modules/tca8418-1.0/tca8418_keypad_m5stack_keymap.map" ] && \
    cp "$ROOT/tmp/dtoverlays/modules/tca8418-1.0/tca8418_keypad_m5stack_keymap.map" \
       "$ROOT/usr/share/keymaps/"

in_root "depmod -a $KVER"
rm -rf "$ROOT/tmp/dtoverlays"

# --- sanity ----------------------------------------------------------------
[ -f "$ROOT/boot/overlays/cardputerzero-$BOARD-overlay.dtbo" ] || \
    warn "expected cardputerzero-$BOARD-overlay.dtbo not found in /boot/overlays"

log "modules installed: $(find "$ROOT/usr/lib/modules/$KVER/extra" -name '*.ko' | wc -l | tr -d ' ')"
