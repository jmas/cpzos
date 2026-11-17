#!/bin/bash
# Verify CardputerZero image contains all required customizations.
# Usage: ./tools/verify-image.sh <image.img>
# Exit 0 = all checks pass, Exit 1 = failure (breaks CI)

set -euo pipefail

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

if grep -q "fbcon=map:10" "$TMPDIR/boot/cmdline.txt" 2>/dev/null; then
    pass "cmdline.txt: fbcon gives the panel a mode at boot"
else
    fail "cmdline.txt: fbcon=map:10 missing"
fi

if grep -q "fbcon=map:off" "$TMPDIR/boot/cmdline.txt" 2>/dev/null; then
    fail "cmdline.txt: fbcon is mapped off (panel has no mode at boot)"
else
    pass "cmdline.txt: fbcon is not mapped off"
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
echo "[4/6] CPZ kmscon session"

for file in usr/local/bin/cpz-first-login \
    usr/local/bin/cpz-settings usr/local/bin/cpz-status \
    usr/local/bin/cpz-apply-settings \
    usr/local/bin/cpz-kmscon usr/local/bin/cpz-kmscon-config \
    usr/local/bin/cpz-kmscon-output usr/local/bin/cpz-login \
    usr/local/bin/cpz-session-save usr/local/bin/cpz-session-restore \
    usr/local/bin/cpz-tab-info usr/local/bin/cpz-tab-close-key \
    usr/local/bin/cpz-session-save-as-user usr/local/bin/cpz-conn-status \
    usr/local/bin/cpz-brightness \
    usr/local/bin/cpz-keyboard-layout \
    usr/local/bin/cpz-layout-next usr/local/bin/cpz-display-toggle \
    usr/bin/kmscon \
    etc/kmscon/kmscon.conf \
    etc/systemd/system/kmsconvt@.service.d/10-cpz.conf \
    etc/udev/rules.d/99-cpz-backlight.rules \
    etc/udev/rules.d/99-cpz-keyboard.rules \
    etc/udev/rules.d/99-cpz-kmscon-output.rules \
    etc/udev/rules.d/99-cpz-kmscon-nudge.rules \
    etc/systemd/system/cpz-keyboard-layout.service \
    etc/systemd/system/cpz-keyboard-layout.path \
    etc/systemd/system/cardputerzero-keymap.service \
    etc/systemd/system/cpz-kmscon-output.service \
    etc/systemd/system/cpz-kmscon-output.timer \
    etc/systemd/system-sleep/cpz-kmscon \
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

if debugfs -R "cat usr/local/bin/cpz-settings" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "Aptitude::Delete-Unused=false"; then
    pass "cpz-settings: Applications (aptitude)"
else
    fail "cpz-settings: Applications entry MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-settings" "$TMPDIR/root.ext4" 2>/dev/null | grep -q 'run_interactive(screen, \["htop"\])'; then
    pass "cpz-settings: Resources (htop)"
else
    fail "cpz-settings: Resources entry MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-kmscon-config" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "palette-background"; then
    pass "cpz-kmscon-config renders the theme palette"
else
    fail "cpz-kmscon-config palette rendering MISSING"
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

if debugfs -R "ls etc/systemd/system/getty.target.wants" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "kmsconvt@tty1"; then
    pass "kmsconvt@tty1 enabled"
else
    fail "kmsconvt@tty1 NOT enabled"
fi

if debugfs -R "stat etc/systemd/system/getty@tty1.service" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -q "/dev/null"; then
    pass "getty@tty1 masked (kmscon owns tty1)"
else
    fail "getty@tty1 NOT masked"
fi

for vt in tty2 tty3; do
    if debugfs -R "ls etc/systemd/system/getty.target.wants" "$TMPDIR/root.ext4" 2>/dev/null |
        grep -q "getty@$vt"; then
        pass "getty@$vt fbcon recovery login enabled"
    else
        fail "getty@$vt NOT enabled"
    fi
    if debugfs -R "ls etc/systemd/system/getty.target.wants" "$TMPDIR/root.ext4" 2>/dev/null |
        grep -q "kmsconvt@$vt"; then
        fail "kmsconvt@$vt should not run a second kmscon"
    else
        pass "kmsconvt@$vt not enabled"
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

FIRST_USER_NAME=$(debugfs -R "cat etc/passwd" "$TMPDIR/root.ext4" 2>/dev/null |
    awk -F: '$3 == 1000 { print $1; exit }' || true)
if [ -n "$FIRST_USER_NAME" ] &&
    debugfs -R "cat etc/group" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -qE "^bluetooth:.*:${FIRST_USER_NAME}(,|\$)"; then
    pass "first user in bluetooth group"
else
    fail "first user NOT in bluetooth group"
fi

if debugfs -R "cat etc/systemd/system/kmsconvt@.service.d/10-cpz.conf" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "/usr/local/bin/cpz-kmscon"; then
    pass "kmscon autologin wrapper"
else
    fail "kmscon autologin wrapper MISSING"
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

if debugfs -R "ls etc/systemd/system/timers.target.wants" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "cpz-kmscon-output.timer"; then
    pass "cpz-kmscon-output timer enabled"
else
    fail "cpz-kmscon-output timer NOT enabled"
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

if debugfs -R "cat etc/cpz/settings.conf" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "font_panel=6x12"; then
    pass "settings: panel font size present"
else
    fail "settings: panel font size MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-kmscon-config" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -q "get_setting font_panel"; then
    pass "cpz-kmscon-config reads the panel font setting"
else
    fail "cpz-kmscon-config panel font setting MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-kmscon-config" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -q "font-size=%s"; then
    pass "cpz-kmscon-config renders the kmscon font size"
else
    fail "cpz-kmscon-config font size MISSING"
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

if debugfs -R "cat usr/local/bin/cpz-keyboard-layout" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "ckbcomp"; then
    pass "console layouts generated with ckbcomp"
else
    fail "cpz-keyboard-layout does not use ckbcomp"
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

if debugfs -R "cat etc/tmux.conf" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "M-Space"; then
    pass "tmux: Alt+Space switches layout"
else
    fail "tmux: layout switch binding MISSING"
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

if debugfs -R "cat usr/local/bin/cpz-kmscon-output" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -q "vt_nudge"; then
    pass "cpz-kmscon-output activates the fbdev panel display"
else
    fail "cpz-kmscon-output fbdev activation MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-kmscon-output" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "hdmi_probe"; then
    pass "cpz-kmscon-output probes the HDMI connector"
else
    fail "cpz-kmscon-output invalid or MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-kmscon-output" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -q "bl_power"; then
    pass "cpz-kmscon-output switches the panel backlight off"
else
    fail "cpz-kmscon-output panel power-off MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-kmscon-output" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -q "hdmi_pinned"; then
    pass "cpz-kmscon-output honours a pinned HDMI mode without EDID"
else
    fail "cpz-kmscon-output pinned-mode override MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-kmscon-output" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -q "hdmi_debounce"; then
    pass "cpz-kmscon-output debounces the HDMI switch"
else
    fail "cpz-kmscon-output debounce MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-kmscon-config" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -q "dpms-timeout=%s"; then
    pass "cpz-kmscon-config renders the screen timeout"
else
    fail "cpz-kmscon-config dpms-timeout MISSING"
fi

if debugfs -R "cat etc/kmscon/kmscon.conf" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -q "multi-monitor=largest"; then
    pass "kmscon draws on one screen"
else
    fail "kmscon multi-monitor config MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-kmscon" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -q -- "--login -- /usr/local/bin/cpz-login"; then
    pass "cpz-kmscon starts the autologin wrapper"
else
    fail "cpz-kmscon autologin wiring MISSING"
fi

if debugfs -R "cat etc/udev/rules.d/99-cpz-kmscon-nudge.rules" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -q "HOTPLUG"; then
    pass "kmscon hotplug nudge rule present"
else
    fail "kmscon hotplug nudge rule MISSING"
fi

if debugfs -R "cat etc/systemd/system-sleep/cpz-kmscon" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -q -- "--force"; then
    pass "cpz-kmscon resume hook"
else
    fail "cpz-kmscon resume hook MISSING"
fi

if debugfs -R "cat etc/udev/rules.d/99-cpz-kmscon-output.rules" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -q "systemctl --no-block start"; then
    pass "HDMI hotplug wakes the kmscon reconciler"
else
    fail "HDMI hotplug udev rule MISSING"
fi

if debugfs -R "cat etc/systemd/system/cpz-kmscon-output.timer" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -q "AccuracySec"; then
    pass "cpz-kmscon-output timer keeps sub-second accuracy"
else
    fail "cpz-kmscon-output timer accuracy MISSING"
fi

if debugfs -R "cat usr/local/bin/cpz-login" "$TMPDIR/root.ext4" 2>/dev/null | grep -q "getent passwd 1000"; then
    pass "cpz-login: resolves uid 1000"
else
    fail "cpz-login: uid 1000 resolution MISSING"
fi

if debugfs -R "cat etc/profile.d/cpz-session.sh" "$TMPDIR/root.ext4" 2>/dev/null |
    grep -q "/run/cpz-kmscon/session.tty1.tty"; then
    pass "cpz-session.sh attaches only to the kmscon pty"
else
    fail "cpz-session.sh kmscon pty detection MISSING"
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

if grep -q "^Package: kmscon$" "$TMPDIR/dpkg_status"; then
    pass "kmscon installed"
else
    fail "kmscon package MISSING"
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

if grep -q "^Package: aptitude$" "$TMPDIR/dpkg_status"; then
    pass "aptitude installed"
else
    fail "aptitude NOT installed"
fi

# Regular CPZ image: desktop/full-stage packages must not be present.
for pkg in fastfetch cmatrix adbd pulseaudio-utils python3-cairo python3-gi-cairo; do
    if grep -q "^Package: ${pkg}$" "$TMPDIR/dpkg_status"; then
        fail "${pkg} should not be installed"
    else
        pass "${pkg} absent"
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
