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

# The normal image drives the panel through DRM only and removes the driver's
# fbdev emulation. The debug image keeps it: fbcon on the panel is the only
# pre-kmscon console there. Pass the choice into the chroot as a marker file.
rm -f "${ROOTFS_DIR}/opt/cpz-keep-panel-fbdev"
if [ "${CPZ_DEBUG_BOOT:-0}" = "1" ]; then
    install -m 0644 /dev/null "${ROOTFS_DIR}/opt/cpz-keep-panel-fbdev"
fi

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

# CPZ: in the normal image the internal panel is a pure DRM display. The
# driver's fbdev emulation (/dev/fb1) is what made kmscon pick its fbdev
# backend: kmscon only recognises a DRM-backed fbdev node when fix.id ends in
# "drmfb", but fix.id is 16 bytes and "panel-mipi-dbi" + "drmfb" is truncated
# to "panel-mipi-dbid". Without the fbdev node there is nothing to fall back
# to. The debug image keeps the emulation for the panel fbcon.
if [ ! -e /opt/cpz-keep-panel-fbdev ]; then
    python3 - <<'PY'
from pathlib import Path

path = Path("/tmp/dtoverlays/modules/st7789v-1.0/panel-mipi-dbi-m.c")
text = path.read_text()
old = """    if (bpp == 16)
        drm_client_setup_with_fourcc(drm, DRM_FORMAT_RGB565);
    else
        drm_client_setup_with_fourcc(drm, DRM_FORMAT_RGB888);
"""
new = """    /*
     * CPZ: do not register the DRM fbdev emulation. The panel is driven
     * through KMS only; a /dev/fb1 node makes kmscon use its fbdev backend.
     */
"""
if text.count(old) != 1:
    raise SystemExit(
        "CPZ: panel-mipi-dbi-m fbdev block not found; upstream source changed"
    )
path.write_text(text.replace(old, new))
PY
fi

# The vendor FSM blocks the Shift key while the Sym layer is latched, so a
# sticky Sym tap (tap Sym, then Shift+key) can never reach level 2 of an XKB
# key. Allow Shift to activate while Sym is active; it still reports the base
# KEY_LEFTSHIFT keycode, so the uppercase level and the language-aware CPZ
# overlay work. Fn and Sym remain mutually exclusive.
python3 - <<'PY'
from pathlib import Path

path = Path("/tmp/dtoverlays/modules/tca8418-1.0/tca8418_keypad_m5stack.c")
text = path.read_text()
old = """	if (device->id == 0)
		return !keypad_data->shift_key.fsm.layer_active &&
			!keypad_data->fn_key.fsm.layer_active;

	return !keypad_data->sym_key.fsm.layer_active;
"""
new = """	if (device->id == 0)
		return !keypad_data->shift_key.fsm.layer_active &&
			!keypad_data->fn_key.fsm.layer_active;

	/* CPZ: Shift may be pressed while a sticky Sym layer is active, so
	 * Shift+Sym selects the uppercase level of the CPZ layout.
	 */
	if (device->id == 1)
		return true;

	return !keypad_data->sym_key.fsm.layer_active;
"""
if text.count(old) != 1:
    raise SystemExit(
        "CPZ: tca8418_fsm_can_activate block not found; upstream source changed"
    )
path.write_text(text.replace(old, new))
PY

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

rm -f "${ROOTFS_DIR}/opt/cpz-keep-panel-fbdev"
