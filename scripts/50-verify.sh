#!/bin/bash
# Stage 50 — verify the produced image without mounting it.
#
# These are the invariants behind the SDL2/KMSDRM appliance image. If one of
# them breaks, the image is wrong even if it builds.
set -euo pipefail
cd "$(dirname "$0")/.."
. ./config.sh
. scripts/lib.sh

NAME="cpz-arch-${CPZ_ARCH_VERSION}-cm0"
IMG="$BUILD/$NAME.img"
BOOTIMG="$BUILD/verify-boot.fat"
ROOTIMG="$BUILD/verify-root.ext4"
ROOT_PARTUUID="${DISK_ID#0x}-02"

fail=0
ok()   { printf '  \033[1;32mok\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; fail=1; }
need() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
absent() { if eval "$2" 2>&1 | grep -q 'File not found'; then ok "$1"; else bad "$1"; fi; }

[ -f "$IMG" ] || die "missing $IMG (run make image first)"

log "partition table"
need "MBR disk id $DISK_ID" "sfdisk -d $IMG | grep -q 'label-id: 0x$DISK_ID'"
need "two partitions"       "[ \"\$(sfdisk -d $IMG | grep -c '^$IMG')\" = 2 ]"

rm -f "$BOOTIMG" "$ROOTIMG"
dd if="$IMG" of="$BOOTIMG" bs=1M skip=1 count="$BOOT_MB" status=none
dd if="$IMG" of="$ROOTIMG" bs=1M skip=$((1 + BOOT_MB)) count="$ROOT_MB" status=none

log "boot partition"
need "kernel8.img"                "mtype -i $BOOTIMG ::/kernel8.img"
need "CM0 device tree"            "mtype -i $BOOTIMG ::/bcm2710-rpi-cm0.dtb"
need "board overlay"              "mtype -i $BOOTIMG ::/overlays/cardputerzero-$BOARD-overlay.dtbo"
need "spidev release overlay"     "mtype -i $BOOTIMG ::/overlays/cpz-spi.dtbo"
need "config uses cpz-spi"        "mtype -i $BOOTIMG ::/config.txt | grep -q '^dtoverlay=cpz-spi'"
need "panel firmware blob"        "debugfs -R 'stat /lib/firmware/cardputerzero,st7789v_lcd.bin' $ROOTIMG | grep -q Inode"
need "start.elf"                  "mtype -i $BOOTIMG ::/start.elf"
need "fixup.dat"                  "mtype -i $BOOTIMG ::/fixup.dat"
need "boot splash asset"          "mtype -i $BOOTIMG ::/cpz-splash.bin"
need "boot splash is Splash Asm"  "( mtype -i $BOOTIMG ::/cpz-splash.bin || true ) | head -c 10 | grep 'SPLASH ASM'"
need "firmware supports Splash Asm" "( mtype -i $BOOTIMG ::/start.elf || true ) | strings | grep 'SPLASH ASM' >/dev/null"
need "config uses boot splash"    "mtype -i $BOOTIMG ::/config.txt | grep -q '^splash_screen=cpz-splash.bin'"
need "no initramfs image"         "! mdir -i $BOOTIMG ::/ | grep -qi initramfs"
need "config.txt has no initramfs" "! mtype -i $BOOTIMG ::/config.txt | grep -q '^initramfs'"
need "config.txt selects overlay"  "mtype -i $BOOTIMG ::/config.txt | grep -q 'dtoverlay=cardputerzero-$BOARD-overlay'"
need "cmdline root PARTUUID"       "mtype -i $BOOTIMG ::/cmdline.txt | grep -q 'root=PARTUUID=$ROOT_PARTUUID'"
need "cmdline quiet"               "mtype -i $BOOTIMG ::/cmdline.txt | grep -q 'quiet'"
need "cmdline has no resume/initrd" "! mtype -i $BOOTIMG ::/cmdline.txt | grep -qE 'initrd=|resume='"
need "fbcon off the panel"         "mtype -i $BOOTIMG ::/cmdline.txt | grep -q 'fbcon=map:off'"
need "HDMI not forced off"         "! mtype -i $BOOTIMG ::/cmdline.txt | grep -q 'video=HDMI-A-1:d'"
need "panic reboot enabled"        "mtype -i $BOOTIMG ::/cmdline.txt | grep -q 'panic=10'"
need "serial recovery console"     "mtype -i $BOOTIMG ::/cmdline.txt | grep -q 'console=ttyAMA0,115200'"
need "hardware watchdog on"        "mtype -i $BOOTIMG ::/config.txt | grep -q '^dtparam=watchdog=on'"
if [ "$ENABLE_HDMI" = "1" ]; then
    need "vc4 overlay enabled"     "mtype -i $BOOTIMG ::/config.txt | grep -q '^dtoverlay=vc4-kms-v3d'"
else
    need "vc4 overlay disabled"    "! mtype -i $BOOTIMG ::/config.txt | grep -q '^dtoverlay=vc4-kms-v3d'"
    need "vc4 not autoloaded"      "! debugfs -R 'cat /etc/modules-load.d/cpz-panel.conf' $ROOTIMG | grep -qx 'vc4'"
fi

log "root partition"
need "ext4 filesystem"       "debugfs -R 'stats' $ROOTIMG"
need "systemd present"       "debugfs -R 'stat /usr/lib/systemd/systemd' $ROOTIMG"
need "login user cpz"        "debugfs -R 'cat /etc/passwd' $ROOTIMG | grep -q '^cpz:'"
need "cpz password is set"   "debugfs -R 'cat /etc/shadow' $ROOTIMG | grep -qE '^cpz:\\\$'"
need "root account locked"   "debugfs -R 'cat /etc/shadow' $ROOTIMG | grep -qE '^root:!'"
need "wheel sudo rule"       "debugfs -R 'cat /etc/sudoers.d/10-wheel' $ROOTIMG | grep -q '%wheel'"
need "fstab root PARTUUID"   "debugfs -R 'cat /etc/fstab' $ROOTIMG | grep -q '$ROOT_PARTUUID'"

log "session"
need "cpz-session installed"   "debugfs -R 'stat /usr/local/bin/cpz-session' $ROOTIMG | grep -q Inode"
need "cpz-ui installed"        "debugfs -R 'stat /usr/local/bin/cpz-ui' $ROOTIMG | grep -q Inode"
need "cpz-term installed"      "debugfs -R 'stat /usr/local/bin/cpz-term' $ROOTIMG | grep -q Inode"
need "cpz-sdlprobe installed"  "debugfs -R 'stat /usr/local/bin/cpz-sdlprobe' $ROOTIMG | grep -q Inode"
need "cpz-menud installed"     "debugfs -R 'stat /usr/local/bin/cpz-menud' $ROOTIMG | grep -q Inode"
need "cpz-menu installed"      "debugfs -R 'stat /usr/local/bin/cpz-menu' $ROOTIMG | grep -q Inode"
need "cpz-sessionctl installed" "debugfs -R 'stat /usr/local/bin/cpz-sessionctl' $ROOTIMG | grep -q Inode"
need "battery provider"        "debugfs -R 'stat /usr/local/bin/cpz-battery' $ROOTIMG | grep -q Inode"
need "clock provider"          "debugfs -R 'stat /usr/local/bin/cpz-clock' $ROOTIMG | grep -q Inode"
need "network provider"        "debugfs -R 'stat /usr/local/bin/cpz-network' $ROOTIMG | grep -q Inode"
need "bluetooth provider"      "debugfs -R 'stat /usr/local/bin/cpz-bluetooth' $ROOTIMG | grep -q Inode"
need "terminal manifest"       "debugfs -R 'cat /usr/share/cpz/apps/terminal/app.json' $ROOTIMG | grep -q '\"id\": \"terminal\"'"
need "music manifest"          "debugfs -R 'cat /usr/share/cpz/apps/music/app.json' $ROOTIMG | grep -q 'music.songs'"
need "settings manifest"       "debugfs -R 'cat /usr/share/cpz/apps/settings/app.json' $ROOTIMG | grep -q 'cpz-sessionctl'"
need "about info action"       "debugfs -R 'cat /usr/share/cpz/apps/about/app.json' $ROOTIMG | grep -q '\"info\"'"
need "terminal app icon"       "debugfs -R 'stat /usr/share/cpz/apps/terminal/icon.png' $ROOTIMG | grep -q Inode"
need "settings app icon"       "debugfs -R 'stat /usr/share/cpz/apps/settings/icon.png' $ROOTIMG | grep -q Inode"
need "provider token battery"  "debugfs -R 'stat /etc/cpz/menu/battery.token' $ROOTIMG | grep -q 'Mode:  0600'"
need "provider token clock"    "debugfs -R 'stat /etc/cpz/menu/clock.token' $ROOTIMG | grep -q Inode"
need "menu daemon unit"        "debugfs -R 'cat /etc/systemd/system/cpz-menud.service' $ROOTIMG | grep -q 'Before=cpz-session.service'"
need "menu daemon enabled"     "debugfs -R 'ls /etc/systemd/system/sysinit.target.wants' $ROOTIMG | grep -q cpz-menud"
need "battery unit enabled"    "debugfs -R 'ls /etc/systemd/system/sysinit.target.wants' $ROOTIMG | grep -q cpz-battery"
need "clock unit enabled"      "debugfs -R 'ls /etc/systemd/system/sysinit.target.wants' $ROOTIMG | grep -q cpz-clock"
need "session depends on menu" "debugfs -R 'cat /etc/systemd/system/cpz-session.service' $ROOTIMG | grep -q 'Wants=cpz-menud.service'"
need "session unit enabled"    "debugfs -R 'ls /etc/systemd/system/sysinit.target.wants' $ROOTIMG | grep -q cpz-session"
need "session starts early"    "debugfs -R 'cat /etc/systemd/system/cpz-session.service' $ROOTIMG | grep -q 'Before=basic.target'"
need "session watchdog"        "debugfs -R 'cat /etc/systemd/system/cpz-session.service' $ROOTIMG | grep -q 'WatchdogSec=10'"
need "no console unit"         "! debugfs -R 'stat /etc/systemd/system/cpz-console.service' $ROOTIMG 2>/dev/null | grep -q Inode"
need "getty@tty1 not enabled"  "! debugfs -R 'ls /etc/systemd/system/getty.target.wants' $ROOTIMG 2>/dev/null | grep -q 'getty@tty1'"
need "serial recovery getty"   "debugfs -R 'ls -l /etc/systemd/system/getty.target.wants' $ROOTIMG 2>/dev/null | grep -q 'serial-getty@ttyAMA0'"
need "display modules early"   "debugfs -R 'cat /etc/modules-load.d/cpz-panel.conf' $ROOTIMG | grep -q gpio_forwarder"
need "spi clock modules"       "debugfs -R 'cat /etc/modules-load.d/cpz-panel.conf' $ROOTIMG | grep -q i2c_bcm2835"
need "boot report enabled"     "debugfs -R 'ls /etc/systemd/system/multi-user.target.wants' $ROOTIMG | grep -q cpz-report"
need "boot report script"      "debugfs -R 'stat /usr/local/bin/cpz-report' $ROOTIMG | grep -q Inode"
need "systemd watchdog config" "debugfs -R 'cat /etc/systemd/system.conf.d/10-cpz-watchdog.conf' $ROOTIMG | grep -q 'RuntimeWatchdogSec=15s'"
need "libtsm installed"        "pacman --root $ROOT -Q libtsm"
need "SDL2 installed"          "pacman --root $ROOT -Q sdl2-compat"
need "SDL2_ttf installed"      "pacman --root $ROOT -Q sdl2_ttf"
need "mesa installed"          "pacman --root $ROOT -Q mesa"
need "libinput installed"      "pacman --root $ROOT -Q libinput"
need "libxkbcommon installed"  "pacman --root $ROOT -Q libxkbcommon"
need "Unicode font installed"  "debugfs -R 'stat /usr/share/fonts/TTF/DejaVuSansMono.ttf' $ROOTIMG | grep -q Inode"
need "Noto Sans UI font"       "debugfs -R 'stat /usr/share/fonts/cpz/NotoSans-Regular.ttf' $ROOTIMG | grep -q Inode"
need "Noto Sans bold font"     "debugfs -R 'stat /usr/share/fonts/cpz/NotoSans-Bold.ttf' $ROOTIMG | grep -q Inode"
need "Noto CJK fallback"       "debugfs -R 'stat /usr/share/fonts/cpz/NotoSansCJKsc-Regular.otf' $ROOTIMG | grep -q Inode"
need "Noto license"            "debugfs -R 'stat /usr/share/licenses/noto/OFL.txt' $ROOTIMG | grep -q Inode"

need "vendor module present" "debugfs -R 'ls /usr/lib/modules' $ROOTIMG"
need "panel module autoloads" "debugfs -R 'cat /etc/modules-load.d/cpz-panel.conf' $ROOTIMG | grep -q panel-mipi-dbi-m"
need "panel loads before vc4" "debugfs -R 'cat /etc/modprobe.d/cpz-panel.conf' $ROOTIMG | grep -q 'softdep vc4 pre: panel-mipi-dbi-m'"
need "panel driver installed" "debugfs -R 'stat /usr/lib/modules/6.18.64-2-rpi/extra/panel-mipi-dbi-m.ko' $ROOTIMG | grep -q Inode"

if [ "$ENABLE_SSH" = "1" ]; then
    need "openssh installed"    "pacman --root $ROOT -Q openssh"
    need "sshd enabled"         "debugfs -R 'ls /etc/systemd/system/multi-user.target.wants' $ROOTIMG | grep -q sshd"
    need "networkd enabled"     "debugfs -R 'ls /etc/systemd/system/multi-user.target.wants' $ROOTIMG | grep -q systemd-networkd"
    need "wired DHCP network"   "debugfs -R 'cat /etc/systemd/network/20-wired.network' $ROOTIMG | grep -q 'DHCP=yes'"
fi

need "sudo is setuid"       "debugfs -R 'stat /usr/bin/sudo' $ROOTIMG | grep -q 'Mode:  0\{0,1\}4755'"
need "no initramfs in /boot" "! debugfs -R 'ls /boot' $ROOTIMG 2>/dev/null | grep -qi initramfs"
absent "no gcc"              "debugfs -R 'stat /usr/bin/gcc' $ROOTIMG"
need "no mkinitcpio preset"  "! debugfs -R 'ls /etc/mkinitcpio.d' $ROOTIMG 2>/dev/null | grep -q '\.preset'"
need "no package cache"      "! debugfs -R 'ls /var/cache/pacman/pkg' $ROOTIMG 2>/dev/null | grep -q '\.pkg\.'"
absent "no build sources"    "debugfs -R 'stat /tmp/dtoverlays' $ROOTIMG"

log "graphics lane"
need "libdrm installed"    "pacman --root $ROOT -Q libdrm"
need "backlight helper"    "debugfs -R 'stat /usr/local/bin/cpz-backlight' $ROOTIMG | grep -q Inode"
need "SDL profile"         "debugfs -R 'cat /etc/profile.d/00-sdl.sh' $ROOTIMG | grep -q 'SDL_VIDEODRIVER=kmsdrm'"
absent "no old console" "debugfs -R 'stat /usr/local/bin/cpz-console' $ROOTIMG"
absent "no old gfx"     "debugfs -R 'stat /usr/local/bin/cpz-gfx' $ROOTIMG"
absent "no old demo"    "debugfs -R 'stat /usr/local/bin/cpz-demo' $ROOTIMG"
absent "no old fbdemo"  "debugfs -R 'stat /usr/local/bin/cpz-fbdemo' $ROOTIMG"
absent "no old mirror"  "debugfs -R 'stat /usr/local/bin/cpz-mirror' $ROOTIMG"
absent "no cpz-run"        "debugfs -R 'stat /usr/local/bin/cpz-run' $ROOTIMG"
absent "no drm-active"     "debugfs -R 'stat /usr/local/bin/cpz-drm-active' $ROOTIMG"
absent "no old library" "debugfs -R 'stat /usr/local/lib/libcpz-display.a' $ROOTIMG"
absent "no old header"  "debugfs -R 'stat /usr/local/include/cpz-display.h' $ROOTIMG"
absent "no old profile"    "debugfs -R 'stat /etc/profile.d/00-drm.sh' $ROOTIMG"
absent "no old mpv conf" "debugfs -R 'stat /etc/mpv/mpv.conf' $ROOTIMG"

if chroot "$ROOT" /usr/local/bin/cpz-sdlprobe --selftest | grep -q 'fnv1a'; then
    ok "cpz-sdlprobe --selftest runs"
else
    bad "cpz-sdlprobe --selftest runs"
fi
if chroot "$ROOT" /usr/local/bin/cpz-term --selftest | grep -q 'UTF-8'; then
    ok "cpz-term --selftest runs"
else
    bad "cpz-term --selftest runs"
fi
if chroot "$ROOT" /usr/local/bin/cpz-session --version | grep -q 'cpz-session'; then
    ok "cpz-session --version runs"
else
    bad "cpz-session --version runs"
fi
if chroot "$ROOT" /usr/local/bin/cpz-menud --selftest 2>/dev/null |
   grep -q 'manifest=[0-9]'; then
    ok "cpz-menud --selftest parses all manifests"
else
    bad "cpz-menud --selftest parses all manifests"
fi
if chroot "$ROOT" /usr/local/bin/cpz-menu --version | grep -q 'cpz-menu'; then
    ok "cpz-menu --version runs"
else
    bad "cpz-menu --version runs"
fi
for prov in battery clock network bluetooth; do
    if chroot "$ROOT" /usr/local/bin/cpz-$prov --version | grep -q "cpz-$prov"; then
        ok "cpz-$prov --version runs"
    else
        bad "cpz-$prov --version runs"
    fi
done
if chroot "$ROOT" /usr/local/bin/cpz-backlight --selftest | grep -q '100%'; then
    ok "cpz-backlight selftest runs"
else
    bad "cpz-backlight selftest runs"
fi

rm -rf "$ROOT/tmp/cpz-drm-test"
mkdir -p "$ROOT/tmp/cpz-drm-test/card0-SPI-1" \
         "$ROOT/tmp/cpz-drm-test/card1-HDMI-A-1"
printf 'connected\n' > "$ROOT/tmp/cpz-drm-test/card0-SPI-1/status"
printf '320x170\n'   > "$ROOT/tmp/cpz-drm-test/card0-SPI-1/modes"
printf 'connected\n' > "$ROOT/tmp/cpz-drm-test/card1-HDMI-A-1/status"
printf '1920x1080\n' > "$ROOT/tmp/cpz-drm-test/card1-HDMI-A-1/modes"
if chroot "$ROOT" env CPZ_DRM_ROOT=/tmp/cpz-drm-test \
    /usr/local/bin/cpz-session --probe | grep -q 'output=hdmi card=card1'; then
    ok "session selects HDMI when both are connected"
else
    bad "session selects HDMI when both are connected"
fi
if chroot "$ROOT" env CPZ_DRM_ROOT=/tmp/cpz-drm-test \
    /usr/local/bin/cpz-session --output panel --probe | grep -q 'output=panel card=card0'; then
    ok "session honours --output panel"
else
    bad "session honours --output panel"
fi
rm -rf "$ROOT/tmp/cpz-drm-test"

# The battery provider is the only component that turns a sysfs reading into
# the status-bar icon. Run it against a fake gauge and check that menud pushes
# the new level to subscribers, not just the first one.
log "battery status provider"
BT=/tmp/cpz-battery-test
rm -rf "$ROOT$BT"
mkdir -p "$ROOT$BT/etc" "$ROOT$BT/run" "$ROOT$BT/supply"
printf 'test-token\n'  > "$ROOT$BT/etc/battery.token"
printf '42\n'          > "$ROOT$BT/supply/capacity"
printf 'Discharging\n' > "$ROOT$BT/supply/status"
printf 'Battery\n'     > "$ROOT$BT/supply/type"
printf '1\n'           > "$ROOT$BT/supply/present"
chroot "$ROOT" /usr/local/bin/cpz-menud --socket "$BT/menu.sock" \
    --apps /usr/share/cpz/apps --run "$BT/run" --etc "$BT/etc" \
    >/dev/null 2>&1 &
menud_pid=$!
sleep 1
chroot "$ROOT" env CPZ_POWER_SUPPLY="$BT/supply" \
    /usr/local/bin/cpz-battery --socket "$BT/menu.sock" \
    --run "$BT/run" >/dev/null 2>&1 &
batt_pid=$!
sleep 2
out=$(chroot "$ROOT" /usr/local/bin/cpz-menu --socket "$BT/menu.sock" \
      status 2>/dev/null || true)
if grep -q 'battery.*level=42 charging=0' <<<"$out"; then
    ok "battery widget registers the real charge"
else
    bad "battery widget registers the real charge"
fi
printf '37\n'          > "$ROOT$BT/supply/capacity"
printf 'Charging\n'    > "$ROOT$BT/supply/status"
sleep 3
out=$(chroot "$ROOT" /usr/local/bin/cpz-menu --socket "$BT/menu.sock" \
      status 2>/dev/null || true)
if grep -q 'battery.*level=37 charging=1' <<<"$out"; then
    ok "battery widget updates level and charging"
else
    bad "battery widget updates level and charging"
fi
printf '0\n'           > "$ROOT$BT/supply/present"
sleep 2
out=$(chroot "$ROOT" /usr/local/bin/cpz-menu --socket "$BT/menu.sock" \
      status 2>/dev/null || true)
if grep -q '^0 widget' <<<"$out"; then
    ok "battery widget disappears with the gauge"
else
    bad "battery widget disappears with the gauge"
fi
kill "$batt_pid" "$menud_pid" 2>/dev/null || true
wait "$batt_pid" 2>/dev/null || true
wait "$menud_pid" 2>/dev/null || true
rm -rf "$ROOT$BT"

log "sizes"
printf '  image      %s\n' "$(du -h "$IMG" | cut -f1)"
printf '  image.zst  %s\n' "$(du -h "$IMG.zst" | cut -f1)"
printf '  root used  %s\n' "$(du -sh "$ROOT" 2>/dev/null | cut -f1 || echo n/a)"

rm -f "$BOOTIMG" "$ROOTIMG"
[ "$fail" = 0 ] || die "verification failed"
log "verification passed"
