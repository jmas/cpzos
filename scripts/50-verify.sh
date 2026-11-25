#!/bin/bash
# Stage 50 — verify the produced base image without mounting it.
#
# The image is a distribution base: kernel, firmware, hardware drivers,
# networking and a recovery login path. There is no display stack and no UI,
# and the checks below enforce that boundary.
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
need "start.elf"                  "mtype -i $BOOTIMG ::/start.elf"
need "fixup.dat"                  "mtype -i $BOOTIMG ::/fixup.dat"
need "no initramfs image"         "! mdir -i $BOOTIMG ::/ | grep -qi initramfs"
need "config.txt selects overlay" "mtype -i $BOOTIMG ::/config.txt | grep -q 'dtoverlay=cardputerzero-$BOARD-overlay'"
need "cmdline root PARTUUID"       "mtype -i $BOOTIMG ::/cmdline.txt | grep -q 'root=PARTUUID=$ROOT_PARTUUID'"
need "cmdline quiet"               "mtype -i $BOOTIMG ::/cmdline.txt | grep -q 'quiet'"
need "cmdline has no resume/initrd" "! mtype -i $BOOTIMG ::/cmdline.txt | grep -qE 'initrd=|resume='"
need "fbcon off"                   "mtype -i $BOOTIMG ::/cmdline.txt | grep -q 'fbcon=map:off'"
need "panic reboot enabled"        "mtype -i $BOOTIMG ::/cmdline.txt | grep -q 'panic=10'"
need "serial recovery console"     "mtype -i $BOOTIMG ::/cmdline.txt | grep -q 'console=ttyS0,115200'"
need "hardware watchdog on"        "mtype -i $BOOTIMG ::/config.txt | grep -q '^dtparam=watchdog=on'"
need "no vc4 overlay"              "! mtype -i $BOOTIMG ::/config.txt | grep -q '^dtoverlay=vc4-kms-v3d'"
need "no panel spi overlay"        "! mtype -i $BOOTIMG ::/config.txt | grep -q '^dtoverlay=cpz-spi'"
need "no boot splash"              "! mdir -i $BOOTIMG ::/ | grep -qi 'splash'"

log "root partition"
need "ext4 filesystem"       "debugfs -R 'stats' $ROOTIMG"
need "systemd present"       "debugfs -R 'stat /usr/lib/systemd/systemd' $ROOTIMG"
need "login user cpz"        "debugfs -R 'cat /etc/passwd' $ROOTIMG | grep -q '^cpz:'"
need "root account locked"   "debugfs -R 'cat /etc/shadow' $ROOTIMG | grep -qE '^root:!'"
need "wheel sudo rule"       "debugfs -R 'cat /etc/sudoers.d/10-wheel' $ROOTIMG | grep -q '%wheel'"
need "fstab root PARTUUID"   "debugfs -R 'cat /etc/fstab' $ROOTIMG | grep -q '$ROOT_PARTUUID'"

log "no UI or display stack"
absent "no cpz-session"        "debugfs -R 'stat /usr/local/bin/cpz-session' $ROOTIMG"
absent "no cpz-term"           "debugfs -R 'stat /usr/local/bin/cpz-term' $ROOTIMG"
absent "no cpz-shell"          "debugfs -R 'stat /usr/local/bin/cpz-shell' $ROOTIMG"
absent "no cpz-launcher"       "debugfs -R 'stat /usr/local/bin/cpz-launcher' $ROOTIMG"
absent "no cpz-settings"       "debugfs -R 'stat /usr/local/bin/cpz-settings' $ROOTIMG"
absent "no cpz-help"           "debugfs -R 'stat /usr/local/bin/cpz-help' $ROOTIMG"
absent "no cpz-ctl"            "debugfs -R 'stat /usr/local/bin/cpz-ctl' $ROOTIMG"
absent "no providers"          "debugfs -R 'stat /usr/local/bin/cpz-battery' $ROOTIMG"
absent "no backlight helper"   "debugfs -R 'stat /usr/local/bin/cpz-backlight' $ROOTIMG"
absent "no cpz tmux start"     "debugfs -R 'stat /usr/local/bin/cpz-tmux-start' $ROOTIMG"
absent "no cpz app directory"  "debugfs -R 'stat /usr/share/cpz' $ROOTIMG"
absent "no icon map"           "debugfs -R 'stat /usr/share/cpz/icons.map' $ROOTIMG"
absent "no tmux config"        "debugfs -R 'stat /etc/tmux.conf' $ROOTIMG"
absent "no session unit"       "debugfs -R 'stat /etc/systemd/system/cpz-session.service' $ROOTIMG"
absent "no shell unit"         "debugfs -R 'stat /etc/systemd/system/cpz-shell.service' $ROOTIMG"
absent "no tmux unit"          "debugfs -R 'stat /etc/systemd/system/cpz-tmux.service' $ROOTIMG"
absent "no panel module list"  "debugfs -R 'stat /etc/modules-load.d/cpz-panel.conf' $ROOTIMG"
absent "no panel modprobe"     "debugfs -R 'stat /etc/modprobe.d/cpz-panel.conf' $ROOTIMG"
absent "no cpz profile"        "debugfs -R 'stat /etc/profile.d/00-cpz.sh' $ROOTIMG"

log "login paths"
need "serial recovery getty"   "debugfs -R 'ls -l /etc/systemd/system/getty.target.wants' $ROOTIMG 2>/dev/null | grep -q 'serial-getty@ttyS0'"
need "getty@tty1 not enabled"  "! debugfs -R 'ls /etc/systemd/system/getty.target.wants' $ROOTIMG 2>/dev/null | grep -q 'getty@tty1'"

log "ui session entry point"
need "ui session template"     "debugfs -R 'stat /usr/lib/systemd/system/cpz-ui@.service' $ROOTIMG | grep -q Inode"
need "ui session uses PAM"     "debugfs -R 'cat /usr/lib/systemd/system/cpz-ui@.service' $ROOTIMG | grep -q '^PAMName=login'"
need "ui session entry point"  "debugfs -R 'cat /usr/lib/systemd/system/cpz-ui@.service' $ROOTIMG | grep -q '^ExecStart=/usr/lib/cpz/session'"
need "ui session not enabled"  "! debugfs -R 'ls /etc/systemd/system/multi-user.target.wants' $ROOTIMG 2>/dev/null | grep -q 'cpz-ui@'"
if [ "$ENABLE_SSH" = "1" ]; then
    need "openssh installed"    "pacman --root $ROOT -Q openssh"
    need "sshd enabled"         "debugfs -R 'ls /etc/systemd/system/multi-user.target.wants' $ROOTIMG | grep -q sshd"
    need "networkd enabled"     "debugfs -R 'ls /etc/systemd/system/multi-user.target.wants' $ROOTIMG | grep -q systemd-networkd"
    need "wired DHCP network"   "debugfs -R 'cat /etc/systemd/network/20-wired.network' $ROOTIMG | grep -q 'DHCP=yes'"
fi

log "base configuration"
need "systemd watchdog config" "debugfs -R 'cat /etc/systemd/system.conf.d/10-cpz-watchdog.conf' $ROOTIMG | grep -q 'RuntimeWatchdogSec=15s'"
need "volatile journal"        "debugfs -R 'cat /etc/systemd/journald.conf.d/10-cpz.conf' $ROOTIMG | grep -q 'Storage=volatile'"
need "i2c-dev autoload"        "debugfs -R 'cat /etc/modules-load.d/cpz.conf' $ROOTIMG | grep -q '^i2c-dev$'"
need "device permissions"      "debugfs -R 'cat /etc/udev/rules.d/70-cpz-permissions.rules' $ROOTIMG | grep -q 'i2c-dev'"

log "ui repository"
need "ui signing key"          "debugfs -R 'stat /usr/share/pacman/keyrings/cpz-ui-signing.asc' $ROOTIMG | grep -q Inode"
need "ui key trusted"          "chroot $ROOT pacman-key --list-keys $UI_REPO_KEY_FPR | grep -q 'CPZ UI Signing'"
need "ui stable config"        "debugfs -R 'cat /etc/pacman.d/cpz-ui.conf' $ROOTIMG | grep -q 'releases/download/ui-stable'"
need "ui beta config"          "debugfs -R 'cat /etc/pacman.d/cpz-ui-beta.conf' $ROOTIMG | grep -q 'releases/download/ui-beta'"
need "ui repo requires signatures" "debugfs -R 'cat /etc/pacman.d/cpz-ui.conf' $ROOTIMG | grep -q 'DatabaseRequired'"
need "pacman includes ui repo" "debugfs -R 'cat /etc/pacman.conf' $ROOTIMG | grep -q 'Include = /etc/pacman.d/cpz-ui.conf'"

log "packages"
need_pkg linux-rpi
need_pkg sudo
need_pkg iwd
need_pkg bluez
need_absent_pkg libtsm
need_absent_pkg freetype2
need_absent_pkg libxkbcommon
need_absent_pkg libevdev
need_absent_pkg libdrm
need_absent_pkg tmux
need_absent_pkg ttf-dejavu
need_absent_pkg python
need_absent_pkg git
need_absent_pkg vim
need_absent_pkg nnn
need_absent_pkg htop
need_absent_pkg alsa-utils
need_absent_pkg fontconfig
need_absent_pkg mesa
need_absent_pkg sdl2-compat
need_absent_pkg cairo
need_absent_pkg pango
need_absent_pkg libinput

need "sudo is setuid"       "debugfs -R 'stat /usr/bin/sudo' $ROOTIMG | grep -q 'Mode:  0\{0,1\}4755'"
need "no initramfs in /boot" "! debugfs -R 'ls /boot' $ROOTIMG 2>/dev/null | grep -qi initramfs"
absent "no gcc"              "debugfs -R 'stat /usr/bin/gcc' $ROOTIMG"
need "no mkinitcpio preset"  "! debugfs -R 'ls /etc/mkinitcpio.d' $ROOTIMG 2>/dev/null | grep -q '\.preset'"
need "no package cache"      "! debugfs -R 'ls /var/cache/pacman/pkg' $ROOTIMG 2>/dev/null | grep -q '\.pkg\.'"
absent "no build sources"    "debugfs -R 'stat /tmp/dtoverlays' $ROOTIMG"

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
