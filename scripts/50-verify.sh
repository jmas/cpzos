#!/bin/bash
# Stage 50 — verify the produced economy image without mounting it.
set -euo pipefail
cd "$(dirname "$0")/.."
. ./config.sh
. scripts/lib.sh

NAME="cpz-arch-${CPZ_ARCH_VERSION}-cm0"
IMG="$BUILD/$NAME.img"
BOOTIMG="$BUILD/verify-boot.fat"
ROOTIMG="$BUILD/verify-root.ext4"
ROOT_PARTUUID="${DISK_ID#0x}-02"
KVER=$(kernel_version)

fail=0
ok()   { printf '  \033[1;32mok\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; fail=1; }
need() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
absent() { if eval "$2" 2>&1 | grep -q 'File not found'; then ok "$1"; else bad "$1"; fi; }
need_absent_pkg() { if pacman --root "$ROOT" -Q "$1" >/dev/null 2>&1; then bad "no $1"; else ok "no $1"; fi; }
need_pkg() { if pacman --root "$ROOT" -Q "$1" >/dev/null 2>&1; then ok "$1 installed"; else bad "$1 installed"; fi; }

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
need "config uses boot splash"    "mtype -i $BOOTIMG ::/config.txt | grep -q '^splash_screen=cpz-splash.bin'"
need "no initramfs image"         "! mdir -i $BOOTIMG ::/ | grep -qi initramfs"
need "config.txt selects overlay"  "mtype -i $BOOTIMG ::/config.txt | grep -q 'dtoverlay=cardputerzero-$BOARD-overlay'"
need "cmdline root PARTUUID"       "mtype -i $BOOTIMG ::/cmdline.txt | grep -q 'root=PARTUUID=$ROOT_PARTUUID'"
need "cmdline quiet"               "mtype -i $BOOTIMG ::/cmdline.txt | grep -q 'quiet'"
need "cmdline has no resume/initrd" "! mtype -i $BOOTIMG ::/cmdline.txt | grep -qE 'initrd=|resume='"
need "fbcon off the panel"         "mtype -i $BOOTIMG ::/cmdline.txt | grep -q 'fbcon=map:off'"
need "panic reboot enabled"        "mtype -i $BOOTIMG ::/cmdline.txt | grep -q 'panic=10'"
need "serial recovery console"     "mtype -i $BOOTIMG ::/cmdline.txt | grep -q 'console=ttyAMA0,115200'"
need "hardware watchdog on"        "mtype -i $BOOTIMG ::/config.txt | grep -q '^dtparam=watchdog=on'"
if [ "$ENABLE_HDMI" = "1" ]; then
    need "vc4 overlay enabled"     "mtype -i $BOOTIMG ::/config.txt | grep -q '^dtoverlay=vc4-kms-v3d'"
else
    need "vc4 overlay disabled"    "! mtype -i $BOOTIMG ::/config.txt | grep -q '^dtoverlay=vc4-kms-v3d'"
fi

log "root partition"
need "ext4 filesystem"       "debugfs -R 'stats' $ROOTIMG"
need "systemd present"       "debugfs -R 'stat /usr/lib/systemd/systemd' $ROOTIMG"
need "login user cpz"        "debugfs -R 'cat /etc/passwd' $ROOTIMG | grep -q '^cpz:'"
need "root account locked"   "debugfs -R 'cat /etc/shadow' $ROOTIMG | grep -qE '^root:!'"
need "wheel sudo rule"       "debugfs -R 'cat /etc/sudoers.d/10-wheel' $ROOTIMG | grep -q '%wheel'"
need "fstab root PARTUUID"   "debugfs -R 'cat /etc/fstab' $ROOTIMG | grep -q '$ROOT_PARTUUID'"

log "economy UI"
need "cpz-session installed"   "debugfs -R 'stat /usr/local/bin/cpz-session' $ROOTIMG | grep -q Inode"
need "cpz-term installed"      "debugfs -R 'stat /usr/local/bin/cpz-term' $ROOTIMG | grep -q Inode"
need "cpz-shell installed"     "debugfs -R 'stat /usr/local/bin/cpz-shell' $ROOTIMG | grep -q Inode"
need "cpz-launcher installed"  "debugfs -R 'stat /usr/local/bin/cpz-launcher' $ROOTIMG | grep -q Inode"
need "cpz-help installed"      "debugfs -R 'stat /usr/local/bin/cpz-help' $ROOTIMG | grep -q Inode"
need "cpz-settings installed"  "debugfs -R 'stat /usr/local/bin/cpz-settings' $ROOTIMG | grep -q Inode"
need "cpz-ctl installed"       "debugfs -R 'stat /usr/local/bin/cpz-ctl' $ROOTIMG | grep -q Inode"
need "cpz-tmux-start installed" "debugfs -R 'stat /usr/local/bin/cpz-tmux-start' $ROOTIMG | grep -q Inode"
need "battery provider"        "debugfs -R 'stat /usr/local/bin/cpz-battery' $ROOTIMG | grep -q Inode"
need "clock provider"          "debugfs -R 'stat /usr/local/bin/cpz-clock' $ROOTIMG | grep -q Inode"
need "network provider"        "debugfs -R 'stat /usr/local/bin/cpz-network' $ROOTIMG | grep -q Inode"
need "bluetooth provider"      "debugfs -R 'stat /usr/local/bin/cpz-bluetooth' $ROOTIMG | grep -q Inode"
need "volume provider"         "debugfs -R 'stat /usr/local/bin/cpz-volume' $ROOTIMG | grep -q Inode"
need "backlight helper"        "debugfs -R 'stat /usr/local/bin/cpz-backlight' $ROOTIMG | grep -q Inode"
need "terminal manifest"       "debugfs -R 'cat /usr/share/cpz/apps/terminal.app' $ROOTIMG | grep -q '^id=terminal'"
need "battery manifest"        "debugfs -R 'cat /usr/share/cpz/apps/battery.app' $ROOTIMG | grep -q '^provider=1'"
need "help manifest"           "debugfs -R 'cat /usr/share/cpz/apps/help.app' $ROOTIMG | grep -q '^id=help'"
need "icon map"                "debugfs -R 'cat /usr/share/cpz/icons.map' $ROOTIMG | grep -q 'terminal'"
need "terminal icon"           "debugfs -R 'stat /usr/share/cpz/icons/terminal.rgba' $ROOTIMG | grep -q Inode"
need "no JSON manifests"       "! debugfs -R 'ls /usr/share/cpz/apps' $ROOTIMG | grep -q '\\.json'"
absent "no cpz-ui"             "debugfs -R 'stat /usr/local/bin/cpz-ui' $ROOTIMG"
absent "no cpz-menud"          "debugfs -R 'stat /usr/local/bin/cpz-menud' $ROOTIMG"
absent "no cpz-menu"           "debugfs -R 'stat /usr/local/bin/cpz-menu' $ROOTIMG"
absent "no cpz-sessionctl"     "debugfs -R 'stat /usr/local/bin/cpz-sessionctl' $ROOTIMG"
absent "no cpz-sdlprobe"       "debugfs -R 'stat /usr/local/bin/cpz-sdlprobe' $ROOTIMG"
absent "no old terminal manifest" "debugfs -R 'stat /usr/share/cpz/apps/terminal/app.json' $ROOTIMG"

log "units"
need "cpz-shell unit"          "debugfs -R 'cat /etc/systemd/system/cpz-shell.service' $ROOTIMG | grep -q 'ExecStart=/usr/local/bin/cpz-shell'"
need "cpz-tmux unit"           "debugfs -R 'cat /etc/systemd/system/cpz-tmux.service' $ROOTIMG | grep -q 'RuntimeDirectory=user/1000'"
need "cpz-session unit"        "debugfs -R 'cat /etc/systemd/system/cpz-session.service' $ROOTIMG | grep -q 'ExecStart=/usr/local/bin/cpz-session --term /usr/local/bin/cpz-term'"
need "session watchdog"        "debugfs -R 'cat /etc/systemd/system/cpz-session.service' $ROOTIMG | grep -q 'WatchdogSec=10'"
need "session depends tmux"    "debugfs -R 'cat /etc/systemd/system/cpz-session.service' $ROOTIMG | grep -q 'After=.*cpz-tmux.service'"
need "session enabled"         "debugfs -R 'ls /etc/systemd/system/sysinit.target.wants' $ROOTIMG | grep -q cpz-session"
need "shell enabled"           "debugfs -R 'ls /etc/systemd/system/sysinit.target.wants' $ROOTIMG | grep -q cpz-shell"
need "tmux enabled"            "debugfs -R 'ls /etc/systemd/system/sysinit.target.wants' $ROOTIMG | grep -q cpz-tmux"
need "battery unit enabled"    "debugfs -R 'ls /etc/systemd/system/sysinit.target.wants' $ROOTIMG | grep -q cpz-battery"
need "clock unit enabled"      "debugfs -R 'ls /etc/systemd/system/sysinit.target.wants' $ROOTIMG | grep -q cpz-clock"
need "getty@tty1 not enabled"  "! debugfs -R 'ls /etc/systemd/system/getty.target.wants' $ROOTIMG 2>/dev/null | grep -q 'getty@tty1'"
need "serial recovery getty"   "debugfs -R 'ls -l /etc/systemd/system/getty.target.wants' $ROOTIMG 2>/dev/null | grep -q 'serial-getty@ttyAMA0'"
need "tmux config"             "debugfs -R 'cat /etc/tmux.conf' $ROOTIMG | grep -q 'status-interval 0'"
need "tmux keeps server"       "debugfs -R 'cat /etc/tmux.conf' $ROOTIMG | grep -q 'exit-empty off'"
need "runtime tmpfiles"        "debugfs -R 'cat /usr/lib/tmpfiles.d/cpz.conf' $ROOTIMG | grep -q '/run/cpz'"
need "shell profile"           "debugfs -R 'cat /etc/profile.d/00-cpz.sh' $ROOTIMG | grep -q 'TMUX_TMPDIR'"
need "boot report enabled"     "debugfs -R 'ls /etc/systemd/system/multi-user.target.wants' $ROOTIMG | grep -q cpz-report"
need "systemd watchdog config" "debugfs -R 'cat /etc/systemd/system.conf.d/10-cpz-watchdog.conf' $ROOTIMG | grep -q 'RuntimeWatchdogSec=15s'"

log "packages"
need_pkg libtsm
need_pkg freetype2
need_pkg ncurses
need_pkg libxkbcommon
need_pkg libevdev
need_pkg libdrm
need_pkg tmux
need_pkg ttf-dejavu
need_pkg nnn
need_pkg htop
need_pkg vim
need_pkg python
need_pkg git
need_pkg iwd
need_pkg bluez
need_pkg alsa-utils
need_absent_pkg sdl2-compat
need_absent_pkg sdl2_ttf
need_absent_pkg cairo
need_absent_pkg pango
need_absent_pkg mesa
need_absent_pkg libinput
need_absent_pkg fontconfig
need "Unicode font present" "debugfs -R 'stat /usr/share/fonts/TTF/DejaVuSansMono.ttf' $ROOTIMG | grep -q Inode"
need "no Noto CJK ballast" "! debugfs -R 'ls /usr/share/fonts/cpz' $ROOTIMG 2>/dev/null | grep -q NotoSansCJK"

log "device modules"
need "panel module autoloads" "debugfs -R 'cat /etc/modules-load.d/cpz-panel.conf' $ROOTIMG | grep -q panel-mipi-dbi-m"
need "panel loads before vc4" "debugfs -R 'cat /etc/modprobe.d/cpz-panel.conf' $ROOTIMG | grep -q 'softdep vc4 pre: panel-mipi-dbi-m'"
need "panel driver installed" "debugfs -R 'stat /usr/lib/modules/$KVER/extra/panel-mipi-dbi-m.ko' $ROOTIMG | grep -q Inode"

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

log "selftests"
if chroot "$ROOT" /usr/local/bin/cpz-term --selftest | grep -q 'UTF-8'; then
    ok "cpz-term --selftest"
else
    bad "cpz-term --selftest"
fi
if chroot "$ROOT" /usr/local/bin/cpz-shell --selftest --apps /usr/share/cpz/apps | grep -q 'selftest: ok'; then
    ok "cpz-shell --selftest"
else
    bad "cpz-shell --selftest"
fi
for bin in cpz-launcher cpz-help cpz-settings cpz-ctl cpz-battery cpz-clock cpz-network cpz-bluetooth cpz-volume; do
    if chroot "$ROOT" /usr/local/bin/$bin --selftest >/dev/null 2>&1; then
        ok "$bin --selftest"
    else
        bad "$bin --selftest"
    fi
done
if chroot "$ROOT" /usr/local/bin/cpz-session --version | grep -q 'cpz-session'; then
    ok "cpz-session --version"
else
    bad "cpz-session --version"
fi
if chroot "$ROOT" /usr/local/bin/cpz-backlight --selftest | grep -q '100%'; then
    ok "cpz-backlight selftest"
else
    bad "cpz-backlight selftest"
fi

log "session probe"
rm -rf "$ROOT/tmp/cpz-drm-test"
mkdir -p "$ROOT/tmp/cpz-drm-test/card0-SPI-1" \
         "$ROOT/tmp/cpz-drm-test/card1-HDMI-A-1"
printf 'connected\n' > "$ROOT/tmp/cpz-drm-test/card0-SPI-1/status"
printf '320x170\n'   > "$ROOT/tmp/cpz-drm-test/card0-SPI-1/modes"
printf 'connected\n' > "$ROOT/tmp/cpz-drm-test/card1-HDMI-A-1/status"
printf '1920x1080\n' > "$ROOT/tmp/cpz-drm-test/card1-HDMI-A-1/modes"
if chroot "$ROOT" env CPZ_DRM_ROOT=/tmp/cpz-drm-test \
    /usr/local/bin/cpz-session --probe | grep -q '^hdmi card1'; then
    ok "session selects HDMI when both are connected"
else
    bad "session selects HDMI when both are connected"
fi
if chroot "$ROOT" env CPZ_DRM_ROOT=/tmp/cpz-drm-test \
    /usr/local/bin/cpz-session --output panel --probe | grep -q '^panel card0'; then
    ok "session honours --output panel"
else
    bad "session honours --output panel"
fi
rm -rf "$ROOT/tmp/cpz-drm-test"

log "image size"
USED_KB=$(du -sk "$ROOT" | cut -f1)
LIMIT_KB=$((ROOT_MB * 1024 * 95 / 100))
if [ "$USED_KB" -le "$LIMIT_KB" ]; then
    ok "rootfs ${USED_KB} KiB fits ${ROOT_MB} MiB"
else
    bad "rootfs ${USED_KB} KiB exceeds ${ROOT_MB} MiB budget"
fi

if [ "$fail" = 1 ]; then
    die "verification failed"
fi
log "verification passed"
