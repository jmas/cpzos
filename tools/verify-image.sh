#!/bin/bash
# Verify CardputerZero image contains all required customizations.
# Usage: ./tools/verify-image.sh <image.img>
# Exit 0 = all checks pass, Exit 1 = failure (breaks CI)
# shellcheck disable=SC2016  # grep patterns intentionally contain a literal $

# debugfs streams file contents into grep -q below. grep exits at the first
# match, which sends SIGPIPE to debugfs; with pipefail that makes a successful
# check look like a failure. The checks care about grep's exit status, so keep
# errexit and nounset without pipefail here.
set -eu

IMG="${1:?Usage: $0 <image.img>}"
ERRORS=0
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

fail() { echo "  ✗ $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "  ✓ $1"; }

echo "=========================================="
echo " CardputerZero Image Verification"
echo "=========================================="
echo " Image: $IMG"
echo ""

# --- Extract partitions ---
# Get partition offsets (sectors, 512 bytes each)
BOOT_START=$(fdisk -l "$IMG" 2>/dev/null | grep "W95 FAT32\|FAT32" | awk '{print $2}')
BOOT_END=$(fdisk -l "$IMG" 2>/dev/null | grep "W95 FAT32\|FAT32" | awk '{print $3}')
ROOT_START=$(fdisk -l "$IMG" 2>/dev/null | grep "Linux" | awk '{print $2}')
ROOT_END=$(fdisk -l "$IMG" 2>/dev/null | grep "Linux" | awk '{print $3}')

BOOT_SECTORS=$((BOOT_END - BOOT_START + 1))
ROOT_SECTORS=$((ROOT_END - ROOT_START + 1))

echo "[1/6] Extracting partitions..."
dd if="$IMG" of="$TMPDIR/boot.fat" bs=512 skip="$BOOT_START" count="$BOOT_SECTORS" 2>/dev/null
dd if="$IMG" of="$TMPDIR/root.ext4" bs=512 skip="$ROOT_START" count="$ROOT_SECTORS" 2>/dev/null

# The debug image keeps the panel fbdev and fbcon so the boot log is visible.
DEBUG_IMAGE=0
if debugfs -R "stat etc/cpz-debug-boot" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "Size:"; then
    DEBUG_IMAGE=1
fi

# Release version written by export-image from VERSION.
CPZ_VERSION_IMG=$(debugfs -R "cat etc/cpz-version" "$TMPDIR/root.ext4" 2>/dev/null | tr -d '\r\n' || true)
if printf '%s\n' "$CPZ_VERSION_IMG" |
    grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'; then
    pass "CPZ version: $CPZ_VERSION_IMG"
else
    fail "etc/cpz-version MISSING or not SemVer"
fi

# --- Mount boot ---
mkdir -p "$TMPDIR/boot"
mount -o loop,ro "$TMPDIR/boot.fat" "$TMPDIR/boot" 2>/dev/null

echo ""
echo "[2/6] Boot partition (FAT32)"

for firmware_file in start.elf splash.bmp; do
    if [ -s "$TMPDIR/boot/$firmware_file" ]; then
        pass "$firmware_file exists ($(stat -c%s "$TMPDIR/boot/$firmware_file" 2>/dev/null || stat -f%z "$TMPDIR/boot/$firmware_file") bytes)"
    else
        fail "$firmware_file MISSING or empty"
    fi
done

# The initramfs is built with MODULES=list, not the default MODULES=most.
# The uncompressed module payload alone was ~4.5 MiB on the old image.
for initramfs in initramfs8 initramfs_2712; do
    if [ ! -e "$TMPDIR/boot/$initramfs" ]; then
        continue
    fi
    initramfs_size=$(stat -c%s "$TMPDIR/boot/$initramfs" 2>/dev/null || stat -f%z "$TMPDIR/boot/$initramfs")
    if [ "$initramfs_size" -le $((8 * 1024 * 1024)) ]; then
        pass "$initramfs is minimal ($initramfs_size bytes)"
    else
        fail "$initramfs is too large ($initramfs_size bytes, expected <= 8 MiB)"
    fi
done

if grep -Eq '^[[:space:]]*kernel[[:space:]]*=[[:space:]]*u-boot\.bin([[:space:]]*(#.*)?)?$' \
    "$TMPDIR/boot/config.txt" 2>/dev/null; then
    fail "config.txt: U-Boot kernel override should be removed"
else
    pass "config.txt: no U-Boot kernel override"
fi

if [ -e "$TMPDIR/boot/u-boot.bin" ]; then
    fail "u-boot.bin should be removed from boot partition"
else
    pass "u-boot.bin absent"
fi

# Check config.txt. Newer m5stack-linux-dtoverlays split the legacy
# cardputerzero-overlay into board-revision specific overlays.
CARDPUTERZERO_OVERLAYS=(
    "cardputerzero-v3-overlay"
    "cardputerzero-v5-overlay"
    "cardputerzero-overlay"
)

FOUND_CARDPUTERZERO_OVERLAY=""
for overlay in "${CARDPUTERZERO_OVERLAYS[@]}"; do
    if grep -q "dtoverlay=${overlay}" "$TMPDIR/boot/config.txt" 2>/dev/null; then
        FOUND_CARDPUTERZERO_OVERLAY="$overlay"
        break
    fi
done

if [ -n "$FOUND_CARDPUTERZERO_OVERLAY" ]; then
    pass "config.txt: dtoverlay=${FOUND_CARDPUTERZERO_OVERLAY}"
else
    fail "config.txt: missing CardputerZero dtoverlay"
fi

if grep -q "dtparam=spi=on" "$TMPDIR/boot/config.txt" 2>/dev/null; then
    pass "config.txt: dtparam=spi=on"
else
    fail "config.txt: missing dtparam=spi=on"
fi

if grep -q "dtparam=i2c_arm=on" "$TMPDIR/boot/config.txt" 2>/dev/null; then
    pass "config.txt: dtparam=i2c_arm=on"
else
    fail "config.txt: missing dtparam=i2c_arm=on"
fi

# Console-only image: gpu_mem=64 is the vc4-kms-v3d minimum. The vendor value
# (128) wasted 64 MiB of the CM0's 512 MiB on a GPU heap nothing uses.
if grep -qx "gpu_mem=64" "$TMPDIR/boot/config.txt" 2>/dev/null; then
    pass "config.txt: gpu_mem=64"
else
    fail "config.txt: expected gpu_mem=64"
fi


# Check overlay dtbo
FOUND_CARDPUTERZERO_DTBO=""
for overlay in "${CARDPUTERZERO_OVERLAYS[@]}"; do
    dtbo="$TMPDIR/boot/overlays/${overlay}.dtbo"
    if [ -f "$dtbo" ]; then
        FOUND_CARDPUTERZERO_DTBO="$dtbo"
        break
    fi
done

if [ -n "$FOUND_CARDPUTERZERO_DTBO" ]; then
    pass "overlays/$(basename "$FOUND_CARDPUTERZERO_DTBO") exists ($(stat -c%s "$FOUND_CARDPUTERZERO_DTBO" 2>/dev/null || stat -f%z "$FOUND_CARDPUTERZERO_DTBO") bytes)"
else
    fail "CardputerZero overlay dtbo MISSING"
fi

# Check cmdline.txt
if awk '
{
    for (i = 1; i <= NF; i++) {
        if ($i == "quiet") {
            ok = 1
            break
        }
    }
}
END {
    exit (ok ? 0 : 1)
}
' "$TMPDIR/boot/cmdline.txt" 2>/dev/null; then
    pass "cmdline.txt: quiet present"
else
    fail "cmdline.txt: quiet missing"
fi

if awk '
{
    for (i = 1; i <= NF; i++) {
        if ($i == "splash") {
            ok = 1
            break
        }
    }
}
END {
    exit (ok ? 0 : 1)
}
' "$TMPDIR/boot/cmdline.txt" >/dev/null 2>&1; then
    fail "cmdline.txt: splash should be removed for CardputerZero"
else
    pass "cmdline.txt: splash removed"
fi

if grep -q "plymouth.ignore-serial-consoles" "$TMPDIR/boot/cmdline.txt" 2>/dev/null; then
    fail "cmdline.txt: plymouth.ignore-serial-consoles should be removed for CardputerZero"
else
    pass "cmdline.txt: plymouth.ignore-serial-consoles removed"
fi

if grep -q "console=serial0,115200" "$TMPDIR/boot/cmdline.txt" 2>/dev/null; then
    fail "cmdline.txt: console=serial0,115200 should be removed for CardputerZero"
else
    pass "cmdline.txt: console=serial0,115200 removed"
fi

if [ "$DEBUG_IMAGE" = 1 ]; then
    if grep -q "fbcon=map:10" "$TMPDIR/boot/cmdline.txt" 2>/dev/null; then
        pass "cmdline.txt: debug image keeps fbcon on the panel"
    else
        fail "cmdline.txt: debug image lost fbcon=map:10"
    fi
    if grep -q "fbcon=map:off" "$TMPDIR/boot/cmdline.txt" 2>/dev/null; then
        fail "cmdline.txt: debug image has fbcon disabled"
    else
        pass "cmdline.txt: debug image does not disable fbcon"
    fi
else
    if grep -q "fbcon=map:off" "$TMPDIR/boot/cmdline.txt" 2>/dev/null; then
        pass "cmdline.txt: fbcon disabled (panel is DRM-only)"
    else
        fail "cmdline.txt: fbcon=map:off missing"
    fi
    if grep -q "fbcon=map:10" "$TMPDIR/boot/cmdline.txt" 2>/dev/null; then
        fail "cmdline.txt: fbcon is still mapped to the panel"
    else
        pass "cmdline.txt: fbcon is not mapped to the panel"
    fi
fi

if grep -q "vt.global_cursor_default=0" "$TMPDIR/boot/cmdline.txt" 2>/dev/null; then
    pass "cmdline.txt: VT cursor hidden"
else
    fail "cmdline.txt: vt.global_cursor_default=0 missing"
fi

umount "$TMPDIR/boot" 2>/dev/null || true

echo ""
echo "[3/6] Kernel modules (/lib/modules/*/extra/)"

REQUIRED_MODULES=(
    "bq27xxx_battery.ko"  
    "bq27xxx_battery_i2c.ko"
    "m5ioe1.ko"
    "tca8418_keypad_m5stack.ko"
    "es8389_m5stack.ko"
    "pwm_bl_m5stack.ko"
    "st7789v_m5stack.ko"
    "panel-mipi-dbi-m.ko"
)

for mod in "${REQUIRED_MODULES[@]}"; do
    if debugfs -R "ls lib/modules" "$TMPDIR/root.ext4" 2>/dev/null | grep -q .; then
        KVER=$(debugfs -R "ls lib/modules" "$TMPDIR/root.ext4" 2>/dev/null | grep -o '[0-9][^ ]*rpi-v8')
        if debugfs -R "stat lib/modules/${KVER}/extra/${mod}" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "Size:"; then
            SIZE=$(debugfs -R "stat lib/modules/${KVER}/extra/${mod}" "$TMPDIR/root.ext4" 2>/dev/null | grep -o 'Size: [0-9]*' | head -1 | cut -d' ' -f2)
            pass "$mod (${SIZE:-unknown} bytes)"
        else
            fail "$mod MISSING"
        fi
    fi
done

DTOVERLAYS_COMMIT=$(debugfs -R "cat etc/cardputerzero-dtoverlays.commit" \
    "$TMPDIR/root.ext4" 2>/dev/null | tr -d '\r\n' || true)
if [[ "$DTOVERLAYS_COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
    pass "dtoverlays source commit recorded ($DTOVERLAYS_COMMIT)"
else
    fail "dtoverlays source commit MISSING or invalid"
fi

echo ""
echo "[4/6] CPZ graphics session"

for file in usr/local/bin/cpz-first-login \
    usr/local/bin/cpz-settings usr/local/bin/cpz-status \
    usr/local/bin/cpz-apply-settings \
    usr/local/bin/cpz-cage usr/local/bin/cpz-cage-output \
    usr/local/bin/cpz-cage-session usr/local/bin/cpz-foot-reload \
    usr/local/bin/cpz-pointer usr/local/bin/cpz-i18n \
    usr/share/cpz/i18n/en.json usr/share/cpz/i18n/uk.json \
    usr/share/cpz/i18n/de.json \
    usr/local/bin/cpz-foot-config usr/local/bin/cpz-getty usr/local/bin/cpz-run \
    usr/local/bin/cpz-tmux usr/local/bin/cpz-tmux-start \
    usr/local/bin/cpz-hint usr/local/bin/cpz-help \
    usr/local/bin/cpz-keys usr/local/bin/cpz-search usr/bin/fzf \
    usr/local/bin/cpz-session-save usr/local/bin/cpz-session-restore \
    usr/local/bin/cpz-tab-close-key \
    usr/local/bin/cpz-tab-mount \
    usr/local/bin/cpz-session-save-as-user usr/local/bin/cpz-conn-status \
    usr/local/bin/cpz-brightness usr/local/bin/cpz-font \
    usr/local/bin/cpz-volume \
    usr/local/bin/cpz-keyboard-layout \
    usr/local/bin/cpz-layout-map \
    usr/local/share/cpz/xkb/cpz.template \
    usr/local/bin/cpz-layout-next usr/local/bin/cpz-display-toggle \
    usr/local/bin/cpz-automount \
    usr/local/bin/cpz-battery \
    usr/bin/cage usr/bin/foot \
    etc/systemd/system/cpz-tmux.service \
    etc/systemd/system/getty@tty1.service.d/10-cpz.conf \
    etc/udev/rules.d/99-cpz-backlight.rules \
    etc/udev/rules.d/99-cpz-keyboard.rules \
    etc/udev/rules.d/99-cpz-cage-output.rules \
    etc/udev/rules.d/99-zz-cpz-input.rules \
    etc/udev/rules.d/99-cpz-automount.rules \
    etc/systemd/system/cpz-automount@.service \
    etc/systemd/system/cpz-battery-guard.service \
    etc/cpz/battery.conf \
    etc/systemd/system/cpz-keyboard-layout.service \
    etc/systemd/system/cpz-keyboard-layout.path \
    etc/systemd/system/cardputerzero-keymap.service \
    etc/systemd/system/cpz-cage-output.service \
    etc/systemd/system/cpz-cage-output.timer \
    etc/systemd/system/cpz-cage-output.path \
    etc/systemd/system/cpz-cage-output-hotplug.service \
    etc/systemd/system/cpz-pointer.service \
    etc/systemd/system/cpz-pointer.path \
    etc/systemd/system/cpz-pointer-cursor.service \
    etc/systemd/system-sleep/cpz-cage \
    etc/systemd/system/cpz-session-save.service \
    etc/systemd/system/cpz-session-save.timer \
    etc/systemd/system/cpz-conn-status.service \
    etc/systemd/system/cpz-conn-status.timer \
    usr/bin/nmtui usr/bin/bt-agent \
    usr/share/fonts/opentype/terminus/terminus-normal.otb \
    etc/polkit-1/rules.d/50-cpz-networkmanager.rules \
    etc/systemd/system/cpz-bt-agent.service \
    etc/profile.d/cpz-session.sh etc/tmux.conf \
    etc/cpz/settings.conf etc/cpz/shadow-mtime etc/default/console-setup \
    etc/cpz/trove-index.url \
    usr/share/cpz/apt-packages.txt.gz \
    etc/cpz/themes/cpz-campbell.palette \
    etc/cpz/themes/cpz-homebrew.palette \
    etc/cpz/themes/cpz-ocean.palette \
    etc/cpz/themes/cpz-red-sands.palette \
    etc/cpz/themes/cpz-terminal-basic.palette \
    etc/cpz/themes/cpz-man-page.palette \
    etc/cpz/themes/cpz-novel.palette \
    etc/cpz/themes/cpz-papercolor-light.palette \
    etc/cpz/themes/cpz-mono.palette \
    etc/cpz/themes/cpz-light-high-contrast.palette; do
    if debugfs -R "stat $file" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "Size:"; then
        pass "$file exists"
    else
        fail "$file MISSING"
    fi
done

# The stock login-shell Wi-Fi warning points at raspi-config and duplicates
# what Settings already manages; it must not appear on the CPZ console.
if debugfs -R "stat etc/profile.d/wifi-check.sh" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -q "Size:"; then
    fail "etc/profile.d/wifi-check.sh still present"
else
    pass "stock Wi-Fi rfkill warning removed"
fi

# The first user must own ~/.config so cpz-settings can create ~/.config/cpz.
FIRST_HOME=$(debugfs -R "cat etc/passwd" "$TMPDIR/root.ext4" 2>/dev/null |
    awk -F: '$3 == 1000 { print $6; exit }' || true)
if [ -z "$FIRST_HOME" ]; then
    fail "first user (uid 1000) missing"
else
    USER_CONFIG="${FIRST_HOME#/}/.config"
    for dir in "$USER_CONFIG" "$USER_CONFIG/systemd" "$USER_CONFIG/cpz"; do
        if debugfs -R "stat /$dir" "$TMPDIR/root.ext4" 2>/dev/null |
            grep -qE 'User:[[:space:]]+1000[[:space:]]'; then
            pass "/$dir owned by uid 1000"
        else
            fail "/$dir not owned by uid 1000"
        fi
    done
fi

if debugfs -R "cat etc/polkit-1/rules.d/50-cpz-networkmanager.rules" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "netdev"; then
    pass "NetworkManager polkit rule for netdev"
else
    fail "NetworkManager polkit rule MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-settings" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "nmtui"; then
    pass "cpz-settings: Wi-Fi (nmtui)"
else
    fail "cpz-settings: Wi-Fi entry MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-settings" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "bluetoothctl"; then
    pass "cpz-settings: Bluetooth (bluetoothctl)"
else
    fail "cpz-settings: Bluetooth entry MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-settings" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "Terminal Trove"; then
    pass "cpz-settings: Applications (Terminal Trove)"
else
    fail "cpz-settings: Applications entry MISSING"
fi

if debugfs -R "stat usr/share/cpz/trove-index.json" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "Size:"; then
    pass "Terminal Trove catalog snapshot present"
else
    echo "WARN: Terminal Trove catalog snapshot missing (Applications will offer a download)"
fi

if debugfs -R "cat usr/local/bin/cpz-settings" "$TMPDIR/root.ext4" 2>/dev/null | grep -q 'run_interactive(screen, \["htop"\])'; then
    pass "cpz-settings: Resources (htop)"
else
    fail "cpz-settings: Resources entry MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-foot-config" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "background="; then
    pass "cpz-foot-config renders the theme palette"
else
    fail "cpz-foot-config palette rendering MISSING"
fi

if debugfs -R "cat etc/cpz/themes/cpz-mono.palette" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "15="; then
    pass "console theme palettes present"
else
    fail "console theme palettes MISSING"
fi

if debugfs -R "cat etc/systemd/system/cpz-bt-agent.service" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "bt-agent"; then
    pass "cpz-bt-agent uses bt-agent"
else
    fail "cpz-bt-agent service invalid or MISSING"
fi

if debugfs -R "cat etc/tmux.conf" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "status-position top"; then
    pass "tmux: status-position top"
else
    fail "tmux: status-position top MISSING"
fi

if debugfs -R "cat etc/tmux.conf" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "window-size largest"; then
    pass "tmux: window-size largest"
else
    fail "tmux: window-size largest MISSING"
fi

if debugfs -R "cat etc/tmux.conf" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "cpz-keys write"; then
    pass "tmux: generated shortcut bindings"
else
    fail "tmux: cpz-keys source line MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-keys" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "cpz-search"; then
    pass "cpz-keys: Search action present"
else
    fail "cpz-keys: Search action MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-settings" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "rebind_action"; then
    pass "cpz-settings: Input > Shortcuts present"
else
    fail "cpz-settings: shortcut rebinding MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-search" "$TMPDIR/root.ext4" 2>/dev/null | grep -q -- "--with-nth=3"; then
    pass "cpz-search: fzf providers present"
else
    fail "cpz-search: fzf providers MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-search" "$TMPDIR/root.ext4" 2>/dev/null | grep -q -- "--trove"; then
    pass "cpz-search: Terminal Trove provider present"
else
    fail "cpz-search: Terminal Trove provider MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-settings" "$TMPDIR/root.ext4" 2>/dev/null | grep -q -- "--list-tools"; then
    pass "cpz-settings: cpz-search tool list present"
else
    fail "cpz-settings: cpz-search tool list MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-settings" "$TMPDIR/root.ext4" 2>/dev/null | grep -q -- "--install-tool"; then
    pass "cpz-settings: Search install entry point present"
else
    fail "cpz-settings: Search install entry point MISSING"
fi

if debugfs -R "stat etc/systemd/system/tmp.mount" "$TMPDIR/root.ext4" 2>/dev/null | grep -q 'Fast link dest:.*/dev/null'; then
    pass "tmp.mount masked (/tmp on disk)"
else
    fail "tmp.mount NOT masked (/tmp still tmpfs)"
fi

# The CPZ panel/keyboard modules are built against the image kernel. rpi-update
# would replace that kernel and leave the device without its drivers.
if debugfs -R "stat usr/bin/rpi-update" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "Size:"; then
    fail "rpi-update is installed (would break the pinned kernel/modules)"
else
    pass "rpi-update is not installed"
fi

if debugfs -R "cat etc/apt/preferences.d/99-cpz-no-rpi-update.pref" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -q "Pin-Priority: -1"; then
    pass "rpi-update is pinned out of apt"
else
    fail "rpi-update apt pin MISSING"
fi

# The <ZENK> keycode name is added to xkb-data's evdev file; an xkb-data
# upgrade would replace it and break Sym+Shift.
if debugfs -R "cat etc/apt/preferences.d/99-cpz-xkb-data.pref" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -q "Package: xkb-data"; then
    pass "xkb-data is pinned (keeps the <ZENK> patch)"
else
    fail "xkb-data apt pin MISSING"
fi

if debugfs -R "ls etc/systemd/system/getty.target.wants" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "getty@tty1"; then
    pass "tty1 getty enabled"
else
    fail "tty1 getty NOT enabled"
fi

if debugfs -R "stat etc/systemd/system/getty@tty1.service" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -q "/dev/null"; then
    fail "getty@tty1 is masked"
else
    pass "getty@tty1 enabled for the cage login session"
fi

for vt in tty2 tty3; do
    if debugfs -R "ls etc/systemd/system/getty.target.wants" "$TMPDIR/root.ext4" 2>/dev/null |
        grep -q "getty@$vt"; then
        pass "getty@$vt fbcon recovery login enabled"
    else
        fail "getty@$vt NOT enabled"
    fi
done

if debugfs -R "ls etc/systemd/system/multi-user.target.wants" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "NetworkManager"; then
    pass "NetworkManager enabled"
else
    fail "NetworkManager NOT enabled"
fi

if debugfs -R "ls etc/systemd/system/bluetooth.target.wants" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "bluetooth.service"; then
    pass "bluetooth enabled"
else
    fail "bluetooth NOT enabled"
fi

if debugfs -R "ls etc/systemd/system/multi-user.target.wants" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "cpz-bt-agent"; then
    pass "cpz-bt-agent enabled"
else
    fail "cpz-bt-agent NOT enabled"
fi

if debugfs -R "ls etc/systemd/system/multi-user.target.wants" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "cpz-battery-guard"; then
    pass "cpz-battery-guard enabled"
else
    fail "cpz-battery-guard NOT enabled"
fi

FIRST_USER_NAME=$(debugfs -R "cat etc/passwd" "$TMPDIR/root.ext4" 2>/dev/null |
    awk -F: '$3 == 1000 { print $1; exit }' || true)
if [ -n "$FIRST_USER_NAME" ] &&
    debugfs -R "cat etc/group" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -qE "^bluetooth:.*:${FIRST_USER_NAME}(,|\$)"; then
    pass "first user in bluetooth group"
else
    fail "first user NOT in bluetooth group"
fi

if debugfs -R "cat etc/systemd/system/getty@tty1.service.d/10-cpz.conf" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -q "/usr/local/bin/cpz-getty"; then
    pass "tty1 getty starts the cage login session"
else
    fail "cpz-getty drop-in MISSING"
fi

if debugfs -R "ls etc/systemd/system/paths.target.wants" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "cpz-keyboard-layout.path"; then
    pass "cpz-keyboard-layout path unit enabled"
else
    fail "cpz-keyboard-layout path unit NOT enabled"
fi

if debugfs -R "cat etc/systemd/system/cpz-keyboard-layout.path" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "PathChanged=/dev/input"; then
    pass "keyboard removal watcher present"
else
    fail "keyboard removal watcher MISSING"
fi

if debugfs -R "cat etc/systemd/system/cardputerzero-keymap.service" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -q "CPZ_LAYOUT_SETTLE=0"; then
    pass "boot keymap load skips the redundant udev settle"
else
    fail "boot keymap load still settles udev"
fi

if [ "$DEBUG_IMAGE" = 1 ]; then
    if debugfs -R "ls etc/systemd/system/multi-user.target.wants" "$TMPDIR/root.ext4" 2>/dev/null |
        grep -q "console-setup"; then
        pass "debug image keeps console-setup"
    else
        fail "debug image lost console-setup"
    fi
else
    if debugfs -R "ls etc/systemd/system/multi-user.target.wants" "$TMPDIR/root.ext4" 2>/dev/null |
        grep -q "console-setup"; then
        fail "normal image still starts console-setup"
    else
        pass "normal image skips console-setup"
    fi
    if debugfs -R "ls etc/systemd/system/sysinit.target.wants" "$TMPDIR/root.ext4" 2>/dev/null |
        grep -q "keyboard-setup"; then
        fail "normal image still starts keyboard-setup"
    else
        pass "normal image skips keyboard-setup"
    fi
fi

if debugfs -R "ls etc/systemd/system/timers.target.wants" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "cpz-cage-output.timer"; then
    pass "cpz-cage-output timer enabled"
else
    fail "cpz-cage-output timer NOT enabled"
fi

if debugfs -R "ls etc/systemd/system/timers.target.wants" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "cpz-session-save.timer"; then
    pass "cpz-session-save timer enabled"
else
    fail "cpz-session-save timer NOT enabled"
fi

if debugfs -R "ls etc/systemd/system/timers.target.wants" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "cpz-conn-status.timer"; then
    pass "cpz-conn-status timer enabled"
else
    fail "cpz-conn-status timer NOT enabled"
fi

if debugfs -R "ls etc/systemd/system/multi-user.target.wants" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "cpz-pointer.service"; then
    pass "pointer policy applied at boot"
else
    fail "cpz-pointer.service NOT enabled"
fi

if debugfs -R "ls etc/systemd/system/paths.target.wants" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "cpz-pointer.path"; then
    pass "pointer policy follows Settings changes"
else
    fail "cpz-pointer.path NOT enabled"
fi

if debugfs -R "cat usr/local/bin/cpz-conn-status" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "E+"; then
    pass "cpz-conn-status indicators present"
else
    fail "cpz-conn-status invalid or MISSING"
fi

if debugfs -R "cat etc/cpz/settings.conf" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "show_conn=1"; then
    pass "settings: connection indicators enabled"
else
    fail "settings: show_conn MISSING"
fi

if debugfs -R "cat etc/cpz/settings.conf" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "show_eth=0"; then
    pass "settings: Ethernet indicator hidden by default"
else
    fail "settings: show_eth default MISSING"
fi

if debugfs -R "cat etc/cpz/settings.conf" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "show_volume=0"; then
    pass "settings: volume indicator hidden by default"
else
    fail "settings: show_volume default MISSING"
fi

if debugfs -R "cat etc/cpz/settings.conf" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "show_brightness=0"; then
    pass "settings: brightness indicator hidden by default"
else
    fail "settings: show_brightness default MISSING"
fi

if debugfs -R "cat etc/cpz/settings.conf" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "display=auto"; then
    pass "settings: display mode present"
else
    fail "settings: display mode MISSING"
fi

if debugfs -R "cat etc/cpz/settings.conf" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "font_size_panel=12"; then
    pass "settings: font size present"
else
    fail "settings: font size MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-foot-config" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -q "get_setting font_size"; then
    pass "cpz-foot-config reads the font size setting"
else
    fail "cpz-foot-config font size setting MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-foot-config" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -q "pixelsize="; then
    pass "cpz-foot-config renders the foot font size"
else
    fail "cpz-foot-config font size MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-settings" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "page_items"; then
    pass "cpz-settings submenus present"
else
    fail "cpz-settings submenus MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-settings" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "security_issues"; then
    pass "cpz-settings security banner present"
else
    fail "cpz-settings security banner MISSING"
fi

if debugfs -R "cat etc/cpz/shadow-mtime" "$TMPDIR/root.ext4" 2>/dev/null | grep -qE '^[0-9]+$'; then
    pass "cpz-settings factory-password stamp present"
else
    fail "cpz-settings factory-password stamp MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-settings" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "system_info_lines"; then
    pass "cpz-settings Info/System present"
else
    fail "cpz-settings Info/System MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-settings" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "Set Date & Time"; then
    pass "cpz-settings manual date/time present"
else
    fail "cpz-settings manual date/time MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-settings" "$TMPDIR/root.ext4" 2>/dev/null | grep -q 'timedatectl", "set-time"'; then
    pass "cpz-settings sets the system clock"
else
    fail "cpz-settings system clock setter MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-keyboard-layout" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "capabilities/key"; then
    pass "keyboard layout switcher present"
else
    fail "keyboard layout switcher MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-keyboard-layout" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "cardputer-zero-internal"; then
    pass "internal keyboard detection present"
else
    fail "internal keyboard detection MISSING"
fi

if debugfs -R "cat etc/udev/rules.d/99-zz-cpz-input.rules" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "cpz-pointer --udev"; then
    pass "pointer policy udev hook present"
else
    fail "pointer policy udev hook MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-pointer" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "LIBINPUT_IGNORE_DEVICE"; then
    pass "phantom pointer suppression present"
else
    fail "cpz-pointer phantom pointer suppression MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-pointer" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -q "seat-cpz-no-pointer"; then
    pass "pure pointers can be moved off the cage seat"
else
    fail "cpz-pointer hard pointer exclusion MISSING"
fi

if debugfs -R "cat etc/libinput/local-overrides.quirks" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -q "AttrEventCode=-REL_X;-REL_Y;-ABS_X;-ABS_Y;"; then
    pass "phantom keyboards/CEC cannot advertise pointer axes"
else
    fail "libinput phantom pointer quirk MISSING"
fi

if debugfs -R "cat usr/share/cpz/i18n/uk.json" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "Пошук"; then
    pass "Ukrainian interface catalog present"
else
    fail "Ukrainian interface catalog MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-keyboard-layout" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "ckbcomp"; then
    pass "console layouts generated with ckbcomp"
else
    fail "cpz-keyboard-layout does not use ckbcomp"
fi

if debugfs -R "cat usr/share/X11/xkb/symbols/cpz" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -qF 'key <HIRA> { [ period'; then
    pass "CPZ XKB layout present"
else
    fail "CPZ XKB layout MISSING"
fi

if debugfs -R "cat usr/share/X11/xkb/keycodes/evdev" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -qF '<ZENK> = 93;'; then
    pass "xkb-data <ZENK> keycode named"
else
    fail "xkb-data <ZENK> keycode MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-keyboard-layout" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -q "set-x11-keymap"; then
    pass "keyboard layout is pushed to systemd-localed"
else
    fail "systemd-localed layout update MISSING"
fi

if debugfs -R "cat usr/local/share/cpz/xkb/cpz.template" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -qF 'key <HIRA> { [ period'; then
    pass "per-language CPZ XKB template installed"
else
    fail "per-language CPZ XKB template MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-keyboard-layout" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -q "cpz-layout-map"; then
    pass "language-aware CPZ overlay generator wired"
else
    fail "cpz-layout-map not used by cpz-keyboard-layout"
fi

if debugfs -R "cat usr/local/bin/cpz-layout-map" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -q "is_letter"; then
    pass "language-aware CPZ overlay generator installed"
else
    fail "cpz-layout-map MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-keyboard-layout" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "cached_UTF-8_del.kmap.gz"; then
    pass "standard keymap fallback present"
else
    fail "cpz-keyboard-layout has no console-setup fallback"
fi

if debugfs -R "cat etc/cpz/settings.conf" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "keyboard_layouts=us"; then
    pass "settings: input layouts present"
else
    fail "settings: keyboard_layouts MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-layout-next" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "keyboard_layouts"; then
    pass "layout cycle helper present"
else
    fail "cpz-layout-next invalid or MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-display-toggle" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "display="; then
    pass "display toggle helper present"
else
    fail "cpz-display-toggle invalid or MISSING"
fi

if debugfs -R "cat etc/sudoers.d/50-cpz-layout" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "cpz-layout-apply"; then
    pass "layout reload sudoers rule present"
else
    fail "layout reload sudoers rule MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-status" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "cpz-layout.active"; then
    pass "status bar shows input layout"
else
    fail "cpz-status layout indicator MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-status" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "layout_active"; then
    pass "status bar shows language layout for the internal keyboard"
else
    fail "cpz-status language layout fallback MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-session-save" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -qF 'display-message -p -t "$id"'; then
    pass "session save queries window fields without tab delimiters"
else
    fail "session save tab-delimited fields MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-keys" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -q "cpz-layout-next"; then
    pass "cpz-keys: Alt+Space switches layout"
else
    fail "cpz-keys: layout switch action MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-session-save" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "session.tsv"; then
    pass "cpz-session-save writes session.tsv"
else
    fail "cpz-session-save invalid or MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-session-restore" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "new-window"; then
    pass "cpz-session-restore recreates tabs"
else
    fail "cpz-session-restore invalid or MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-cage-output" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -q "WLR_DRM_DEVICES"; then
    pass "cpz-cage-output writes the cage output environment"
else
    fail "cpz-cage-output output environment MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-cage-output" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -qF 'devices=$hdmi_dev'; then
    pass "HDMI runs as the primary DRM card (no secondary-GPU pixman path)"
else
    fail "HDMI is not the primary DRM card"
fi

if debugfs -R "cat usr/local/bin/cpz-cage-output" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -qF 'devices="$panel_dev:$hdmi_dev"'; then
    fail "cage still receives the panel:HDMI multi-GPU device list"
else
    pass "cage receives a single DRM card at a time"
fi

if debugfs -R "cat etc/udev/rules.d/99-cpz-display.rules" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -q "platform-3f204000.spi-cs-0"; then
    pass "panel DRM card udev rule present"
else
    fail "panel DRM card udev rule MISSING"
fi

if debugfs -R "cat etc/udev/rules.d/99-cpz-display.rules" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -q 'ENV{ID_SEAT}="seat0"'; then
    pass "panel DRM card stays on seat0"
else
    fail "panel DRM card is not explicitly assigned to seat0"
fi

if debugfs -R "cat etc/udev/rules.d/99-cpz-display.rules" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -q 'ENV{ID_SEAT}="seat-cardputer-zero"'; then
    fail "panel DRM card is still pinned to seat-cardputer-zero"
else
    pass "vendor display seat assignment removed"
fi

if debugfs -R "stat etc/udev/rules.d/99-cardputer-zero-lcd.rules" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -q "Size:"; then
    fail "vendor display rule still present"
else
    pass "vendor display rule removed"
fi

if debugfs -R "cat usr/local/bin/cpz-cage-output" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "hdmi_probe"; then
    pass "cpz-cage-output probes the HDMI connector"
else
    fail "cpz-cage-output invalid or MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-cage-output" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -q "bl_power"; then
    pass "cpz-cage-output switches the panel backlight off"
else
    fail "cpz-cage-output panel power-off MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-cage-output" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -q "hdmi_pinned"; then
    pass "cpz-cage-output honours a pinned HDMI mode without EDID"
else
    fail "cpz-cage-output pinned-mode override MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-cage-output" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -q "hdmi_debounce"; then
    pass "cpz-cage-output debounces the HDMI switch"
else
    fail "cpz-cage-output debounce MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-cage-output" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -q "hdmi_usable"; then
    pass "cpz-cage-output confirms readable-EDID hotplug quickly"
else
    fail "cpz-cage-output HDMI readiness check MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-foot-config" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -q "initial-window-mode=fullscreen"; then
    pass "cpz-foot-config renders the foot session"
else
    fail "cpz-foot-config session MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-font" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -q "font_size"; then
    pass "persistent font zoom helper installed"
else
    fail "persistent font zoom helper MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-keys" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -q "cpz-font up"; then
    pass "font zoom key bindings configured"
else
    fail "font zoom key bindings MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-hint" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -q "display-message -c"; then
    pass "attach key hint targets the client status line"
else
    fail "attach key hint client target MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-help" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -q "cpz-keys help" &&
    debugfs -R "cat usr/local/bin/cpz-keys" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -q "Font Bigger"; then
    pass "help lists the registry shortcuts (font size)"
else
    fail "help font size shortcuts MISSING"
fi

if debugfs -R "cat etc/systemd/system/cpz-tmux.service" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -q "RemainAfterExit=yes"; then
    pass "tmux server is independent of the compositor"
else
    fail "cpz-tmux service MISSING"
fi

if debugfs -R "cat etc/systemd/system-sleep/cpz-cage" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -q -- "--force"; then
    pass "cpz-cage resume hook"
else
    fail "cpz-cage resume hook MISSING"
fi

if debugfs -R "cat etc/udev/rules.d/99-cpz-cage-output.rules" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -q "cpz-cage-output-hotplug.service"; then
    pass "HDMI hotplug wakes the EDID-aware cage reconciler"
else
    fail "HDMI hotplug udev rule MISSING"
fi

if debugfs -R "ls etc/systemd/system/paths.target.wants" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -q "cpz-cage-output.path"; then
    pass "display-setting path unit enabled"
else
    fail "display-setting path unit NOT enabled"
fi

if debugfs -R "cat usr/local/bin/cpz-cage-output" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -q "CPZ_CAGE_TARGET"; then
    fail "cage output environment still contains the target"
else
    pass "HDMI target is not part of the cage environment"
fi

if debugfs -R "cat usr/local/bin/cpz-cage" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -q "cpz-cage-session"; then
    pass "cage runs the session supervisor"
else
    fail "cage session supervisor MISSING"
fi

if debugfs -R "cat etc/systemd/system/cpz-cage-output.timer" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -q "OnUnitActiveSec=5s"; then
    pass "cpz-cage-output timer is a slow 5s fallback (udev handles hotplug)"
else
    fail "cpz-cage-output timer interval is not the 5s fallback"
fi

if debugfs -R "cat etc/udev/rules.d/99-cpz-automount.rules" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -q 'ENV{SYSTEMD_WANTS}+="cpz-automount@%k.service"'; then
    pass "USB hotplug starts the automount helper"
else
    fail "USB automount udev rule MISSING"
fi

if debugfs -R "cat etc/systemd/system/cpz-automount@.service" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -q "BindsTo=dev-%i.device"; then
    pass "automount stops (and unmounts) when the disk is removed"
else
    fail "cpz-automount@.service BindsTo MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-automount" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -q "on_system_disk"; then
    pass "automount refuses the running system disk"
else
    fail "automount system-disk guard MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-automount" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -q "cpz-tab-mount"; then
    pass "automount opens a tab for the mounted disk"
else
    fail "automount disk tab hook MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-tab-mount" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -q "@cpz_mount"; then
    pass "disk tab is tagged for closing before unmount"
else
    fail "cpz-tab-mount @cpz_mount tag MISSING"
fi

if debugfs -R "stat media" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "Size:"; then
    pass "/media mount root present"
else
    fail "/media mount root MISSING"
fi


if debugfs -R "ls etc/systemd/system/multi-user.target.wants" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "rpi-preseed"; then
    pass "rpi-preseed enabled"
else
    fail "rpi-preseed NOT enabled"
fi

# The old launcher/desktop must not ship in the CPZ image.
for file in usr/share/APPLaunch/bin/M5CardputerZero-APPLaunch \
    usr/lib/systemd/system/LaunchWizard.service \
    usr/bin/fb-mirror.py usr/share/applications/fb-mirror.desktop \
    etc/systemd/system/fb_load.service \
    etc/systemd/system/sysinit.target.wants/fb_load.service \
    usr/lib/python3/dist-packages/cloudinit; do
    if debugfs -R "stat $file" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "Size:"; then
        fail "$file should not be present"
    else
        pass "$file absent"
    fi
done

echo ""
echo "[5/6] Modprobe configuration"

if debugfs -R "cat etc/modules-load.d/cardputerzero.conf" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "i2c-dev"; then
    pass "modules-load.d: i2c-dev"
else
    fail "modules-load.d: i2c-dev MISSING"
fi

if debugfs -R "cat etc/modprobe.d/blacklist-8192cu.conf" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "blacklist 8192cu"; then
    pass "modprobe.d: blacklist 8192cu"
else
    fail "modprobe.d: blacklist 8192cu MISSING"
fi

if debugfs -R "cat etc/modprobe.d/rfkill_default.conf" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "rfkill"; then
    pass "modprobe.d: rfkill default_state=0"
else
    fail "modprobe.d: rfkill MISSING"
fi

echo ""
echo "[6/6] Packages"

set +e
debugfs -R "cat var/lib/dpkg/status" "$TMPDIR/root.ext4" > "$TMPDIR/dpkg_status" 2>/dev/null
echo "  dpkg_status size: $(wc -c < "$TMPDIR/dpkg_status") bytes"

if grep -q "^Package: cage$" "$TMPDIR/dpkg_status"; then
    pass "cage installed"
else
    fail "cage package MISSING"
fi

if grep -q "^Package: foot$" "$TMPDIR/dpkg_status"; then
    pass "foot installed"
else
    fail "foot package MISSING"
fi

if grep -q "^Package: xwayland$" "$TMPDIR/dpkg_status"; then
    pass "xwayland installed"
else
    fail "xwayland package MISSING"
fi

if grep -q "^Package: fonts-terminus-otb$" "$TMPDIR/dpkg_status"; then
    pass "Terminus OTB font installed"
else
    fail "fonts-terminus-otb MISSING"
fi

if grep -q "^Package: tmux$" "$TMPDIR/dpkg_status"; then
    pass "tmux installed"
else
    fail "tmux NOT installed"
fi

if grep -q "^Package: mc$" "$TMPDIR/dpkg_status"; then
    pass "mc installed"
else
    fail "mc NOT installed"
fi

if grep -q "^Package: python3$" "$TMPDIR/dpkg_status"; then
    pass "python3 installed"
else
    fail "python3 NOT installed"
fi

# p7zip-full is transitional; the real archiver must survive its removal.
if grep -q "^Package: 7zip$" "$TMPDIR/dpkg_status"; then
    pass "7zip installed"
else
    fail "7zip NOT installed"
fi

# cpz-bt-agent runs /usr/bin/bt-agent, which ships in bluez-tools.
if grep -q "^Package: bluez-tools$" "$TMPDIR/dpkg_status"; then
    pass "bluez-tools installed (bt-agent)"
else
    fail "bluez-tools MISSING (cpz-bt-agent needs bt-agent)"
fi

# Regular CPZ image: desktop/full-stage packages must not be present.
for pkg in fastfetch cmatrix adbd pulseaudio-utils python3-cairo python3-gi-cairo; do
    if grep -q "^Package: ${pkg}$" "$TMPDIR/dpkg_status"; then
        fail "${pkg} should not be installed"
    else
        pass "${pkg} absent"
    fi
done

# stage3/03-cleanup removes build-only and duplicate packages. Only assert the
# entries that have no reverse dependencies; the cleanup keeps anything apt
# would have to take another package with. ack/net-tools are kept while
# rpi-swap/raspinfo depend on them, and bluez-tools must stay for bt-agent.
for pkg in p7zip-full vim-tiny ed wireless-tools \
    lua5.1 luajit manpages-dev fbset dmidecode ueberzug debconf-utils \
    build-essential gdb strace; do
    if grep -q "^Package: ${pkg}$" "$TMPDIR/dpkg_status"; then
        fail "${pkg} should have been removed by cpz-cleanup"
    else
        pass "${pkg} removed"
    fi
done
set -e

echo ""
echo "=========================================="
if [ $ERRORS -eq 0 ]; then
    echo " ✓ ALL CHECKS PASSED"
    echo "=========================================="
    exit 0
else
    echo " ✗ $ERRORS CHECK(S) FAILED"
    echo "=========================================="
    exit 1
fi
