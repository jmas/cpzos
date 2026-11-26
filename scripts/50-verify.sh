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

UI_SUFFIX=""
[ "$UI_TEST" = "1" ] && UI_SUFFIX="-ui"
NAME="cpz-arch-${CPZ_ARCH_VERSION}-cm0${UI_SUFFIX}"
IMG="$BUILD/$NAME.img"
BOOTIMG="$BUILD/verify-boot.fat"
ROOTIMG="$BUILD/verify-root.ext4"
ROOT_PARTUUID="${DISK_ID#0x}-02"
KVER=$(kernel_version)

fail=0
ok()   { printf '  \033[1;32mok\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; fail=1; }
need() { if ( set +o pipefail; eval "$2" ) >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
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
if [ "$ENABLE_HDMI" = "1" ]; then
    need "vc4 overlay enabled"     "mtype -i $BOOTIMG ::/config.txt | grep -q '^dtoverlay=vc4-kms-v3d'"
    need "gpu memory set"          "mtype -i $BOOTIMG ::/config.txt | grep -q '^gpu_mem=64'"
else
    need "vc4 overlay disabled"    "! mtype -i $BOOTIMG ::/config.txt | grep -q '^dtoverlay=vc4-kms-v3d'"
fi
need "panel spi overlay"           "mtype -i $BOOTIMG ::/config.txt | grep -q '^dtoverlay=cpz-spi'"
need "cpz-spi dtbo"                "mtype -i $BOOTIMG ::/overlays/cpz-spi.dtbo"
need "no boot splash"              "! mdir -i $BOOTIMG ::/ | grep -qi 'splash'"

log "root partition"
need "ext4 filesystem"       "debugfs -R 'stats' $ROOTIMG"
need "systemd present"       "debugfs -R 'stat /usr/lib/systemd/systemd' $ROOTIMG"
need "login user cpz"        "debugfs -R 'cat /etc/passwd' $ROOTIMG | grep -q '^cpz:'"
need "root account locked"   "debugfs -R 'cat /etc/shadow' $ROOTIMG | grep -qE '^root:!'"
need "wheel sudo rule"       "debugfs -R 'cat /etc/sudoers.d/10-wheel' $ROOTIMG | grep -q '%wheel'"
need "fstab root PARTUUID"   "debugfs -R 'cat /etc/fstab' $ROOTIMG | grep -q '$ROOT_PARTUUID'"
need "platform contract"     "debugfs -R 'cat /etc/cpz/platform.conf' $ROOTIMG | grep -q '^platform=1'"
need "contract version"      "debugfs -R 'cat /etc/cpz/platform.conf' $ROOTIMG | grep -q '^contract=1'"
need "platform capabilities" "debugfs -R 'cat /etc/cpz/platform.conf' $ROOTIMG | grep -q 'display.panel'"
need "hdmi capability"       "debugfs -R 'cat /etc/cpz/platform.conf' $ROOTIMG | grep -q 'display.hdmi'"

if [ "$UI_TEST" = "1" ]; then
    log "ui test image"
    need_pkg cpz-ui
    need_pkg cage
    need_pkg foot
    need_pkg tmux
    need_pkg fzf
    need_pkg j4-dmenu-desktop
    need_pkg mesa
    need_pkg ttf-dejavu
    need "ui session"          "debugfs -R 'stat /usr/lib/cpz/session' $ROOTIMG | grep -q Inode"
    need "ui attach"           "debugfs -R 'stat /usr/lib/cpz/attach' $ROOTIMG | grep -q Inode"
    need "ui launcher"         "debugfs -R 'stat /usr/lib/cpz/launcher' $ROOTIMG | grep -q Inode"
    need "ui status helper"    "debugfs -R 'stat /usr/lib/cpz/status' $ROOTIMG | grep -q Inode"
    need "ui output helper"    "debugfs -R 'stat /usr/lib/cpz/output' $ROOTIMG | grep -q Inode"
    need "ui output unit"      "debugfs -R 'stat /usr/lib/systemd/system/cpz-output.service' $ROOTIMG | grep -q Inode"
    need "ui output timer"     "debugfs -R 'stat /usr/lib/systemd/system/cpz-output-boot.timer' $ROOTIMG | grep -q Inode"
    need "ui output timer enabled" "debugfs -R 'ls /etc/systemd/system/timers.target.wants' $ROOTIMG | grep -q cpz-output-boot"
    need "ui output rule"      "debugfs -R 'cat /usr/lib/udev/rules.d/99-cpz-output.rules' $ROOTIMG | grep -q 'cpz-output.service'"
    need "ui hdmi edid wait"   "debugfs -R 'cat /usr/lib/cpz/session' $ROOTIMG | grep -q 'edid'"
    need "ui foot panel size"  "debugfs -R 'cat /etc/cpz/foot.ini' $ROOTIMG | grep -q 'pixelsize=12'"
    need "ui foot fullscreen"  "debugfs -R 'cat /etc/cpz/foot.ini' $ROOTIMG | grep -q 'initial-window-mode=fullscreen'"
    need "ui backlight helper" "debugfs -R 'stat /usr/lib/cpz/backlight' $ROOTIMG | grep -q Inode"
    need "ui tmux unit"        "debugfs -R 'stat /usr/lib/systemd/system/cpz-tmux.service' $ROOTIMG | grep -q Inode"
    need "ui tmux drop-in"     "debugfs -R 'stat /usr/lib/systemd/system/cpz-ui@.service.d/10-tmux.conf' $ROOTIMG | grep -q Inode"
    need "ui fast restart"     "debugfs -R 'cat /usr/lib/systemd/system/cpz-ui@.service.d/20-restart.conf' $ROOTIMG | grep -q 'TimeoutStopSec=5s'"
    need "ui single session"   "debugfs -R 'cat /etc/cpz/tmux.conf' $ROOTIMG | grep -q 'set -g prefix C-a'"
    need "ui tmux loads config" "debugfs -R 'cat /usr/lib/cpz/tmux-start' $ROOTIMG | grep -q -- '-f /etc/cpz/tmux.conf'"
    need "alsa default is the codec" "debugfs -R 'cat /etc/asound.conf' $ROOTIMG | grep -q 'ES8389Audio'"
    need "ui tmux enabled"     "debugfs -R 'ls /etc/systemd/system/multi-user.target.wants' $ROOTIMG | grep -q cpz-tmux"
    need "ui session enabled"  "debugfs -R 'ls /etc/systemd/system/multi-user.target.wants' $ROOTIMG | grep -q 'cpz-ui@tty1'"
    need "terminal entry"      "debugfs -R 'stat /usr/share/applications/cpz-terminal.desktop' $ROOTIMG | grep -q Inode"
    need "terminal is system"  "debugfs -R 'cat /usr/share/applications/cpz-terminal.desktop' $ROOTIMG | grep -q '^X-CPZ-System=true'"
    need "terminal owned by system apps" "pacman --root $ROOT -Qoq $ROOT/usr/share/applications/cpz-terminal.desktop | grep -q '^cpz-system-apps$'"
    need "ui help entry"       "debugfs -R 'stat /usr/share/applications/cpz-help.desktop' $ROOTIMG | grep -q Inode"
    need_pkg cpz-system-apps
    need_pkg cpz-apps-catalog
    need "cpz-app binary"      "debugfs -R 'stat /usr/bin/cpz-app' $ROOTIMG | grep -q Inode"
    need "app helper"          "debugfs -R 'stat /usr/lib/cpz/app-install' $ROOTIMG | grep -q Inode"
    need "apps sudoers"        "debugfs -R 'cat /etc/sudoers.d/20-cpz-apps' $ROOTIMG | grep -q '/usr/lib/cpz/app-install'"
    need "protected packages"  "debugfs -R 'cat /usr/share/cpz/protected-packages' $ROOTIMG | grep -q '^cpz-system-apps$'"
    need "apps tmpfiles"       "debugfs -R 'cat /usr/lib/tmpfiles.d/cpz-apps.conf' $ROOTIMG | grep -q '/var/lib/cpz'"
    need "home entry"          "debugfs -R 'stat /usr/share/applications/cpz-app-home.desktop' $ROOTIMG | grep -q Inode"
    need "apps manager entry"  "debugfs -R 'stat /usr/share/applications/cpz-apps-manager.desktop' $ROOTIMG | grep -q Inode"
    need "settings entry"      "debugfs -R 'stat /usr/share/applications/cpz-settings.desktop' $ROOTIMG | grep -q Inode"
    need "app catalog"         "debugfs -R 'stat /usr/share/cpz/catalog/apps.json' $ROOTIMG | grep -q Inode"
    need "app catalog schema"  "debugfs -R 'cat /usr/share/cpz/catalog/apps.json' $ROOTIMG | grep -q '\"version\": 1'"
    need "catalog data only"   "pacman --root $ROOT -Qi cpz-apps-catalog | grep -q '^Depends On.*: None'"
    need "catalog ships only apps.json" "[ \$(pacman --root $ROOT -Ql cpz-apps-catalog | grep -vc '/$') -eq 1 ]"
    need "home default command" "debugfs -R 'cat /etc/cpz/tmux.conf' $ROOTIMG | grep -q 'default-command \"/usr/bin/cpz-app home\"'"
    need "apps popup binding"  "debugfs -R 'cat /etc/cpz/tmux.conf' $ROOTIMG | grep -q '/usr/bin/cpz-app apps'"
    need "ui sudoers"          "debugfs -R 'stat /etc/sudoers.d/20-cpz-ui' $ROOTIMG | grep -q Inode"
    need "ui modules"          "debugfs -R 'cat /usr/lib/modules-load.d/cpz-ui.conf' $ROOTIMG | grep -q panel-mipi-dbi-m"
    need "ui tmpfiles"         "debugfs -R 'cat /usr/lib/tmpfiles.d/cpz-ui.conf' $ROOTIMG | grep -q '/run/cpz'"
    need "persistent journal"  "debugfs -R 'cat /etc/systemd/journald.conf.d/20-cpz-test.conf' $ROOTIMG | grep -q 'Storage=persistent'"
else
    log "no UI or display stack"
    absent "no cpz-session"        "debugfs -R 'stat /usr/local/bin/cpz-session' $ROOTIMG"
    absent "no cpz-term"           "debugfs -R 'stat /usr/local/bin/cpz-term' $ROOTIMG"
    absent "no cpz-shell"          "debugfs -R 'stat /usr/local/bin/cpz-shell' $ROOTIMG"
    absent "no cpz-launcher"       "debugfs -R 'stat /usr/local/bin/cpz-launcher' $ROOTIMG"
    absent "no cpz-settings"       "debugfs -R 'stat /usr/local/bin/cpz-settings' $ROOTIMG"
    absent "no cpz-help"           "debugfs -R 'stat /usr/local/bin/cpz-help' $ROOTIMG"
    absent "no cpz-app"            "debugfs -R 'stat /usr/bin/cpz-app' $ROOTIMG"
    absent "no app catalog"        "debugfs -R 'stat /usr/share/cpz/catalog/apps.json' $ROOTIMG"
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
fi

log "login paths"
need "serial recovery getty"   "debugfs -R 'ls -l /etc/systemd/system/getty.target.wants' $ROOTIMG 2>/dev/null | grep -q 'serial-getty@ttyS0'"
need "getty@tty1 not enabled"  "! debugfs -R 'ls /etc/systemd/system/getty.target.wants' $ROOTIMG 2>/dev/null | grep -q 'getty@tty1'"

log "ui session entry point"
need "ui session template"     "debugfs -R 'stat /usr/lib/systemd/system/cpz-ui@.service' $ROOTIMG | grep -q Inode"
need "ui session uses PAM"     "debugfs -R 'cat /usr/lib/systemd/system/cpz-ui@.service' $ROOTIMG | grep -q '^PAMName=login'"
need "ui session entry point"  "debugfs -R 'cat /usr/lib/systemd/system/cpz-ui@.service' $ROOTIMG | grep -q '^ExecStart=/usr/lib/cpz/session'"
if [ "$UI_TEST" = "1" ]; then
    need "ui session enabled"  "debugfs -R 'ls /etc/systemd/system/multi-user.target.wants' $ROOTIMG 2>/dev/null | grep -q 'cpz-ui@tty1'"
else
    need "ui session not enabled" "! debugfs -R 'ls /etc/systemd/system/multi-user.target.wants' $ROOTIMG 2>/dev/null | grep -q 'cpz-ui@'"
fi
if [ "$ENABLE_SSH" = "1" ]; then
    need "openssh installed"    "pacman --root $ROOT -Q openssh"
    need "sshd enabled"         "debugfs -R 'ls /etc/systemd/system/multi-user.target.wants' $ROOTIMG | grep -q sshd"
    need "ssh host key"         "debugfs -R 'stat /etc/ssh/ssh_host_ed25519_key' $ROOTIMG | grep -q Inode"
    need "ssh password auth"    "debugfs -R 'cat /etc/ssh/sshd_config.d/10-cpz.conf' $ROOTIMG | grep -q '^PasswordAuthentication yes'"
    need "ssh only cpz"         "debugfs -R 'cat /etc/ssh/sshd_config.d/10-cpz.conf' $ROOTIMG | grep -q '^AllowUsers cpz'"
    need "sshd keygen enabled"  "debugfs -R 'ls /etc/systemd/system/multi-user.target.wants' $ROOTIMG | grep -q sshdgenkeys"
    need "networkd enabled"     "debugfs -R 'ls /etc/systemd/system/multi-user.target.wants' $ROOTIMG | grep -q systemd-networkd"
    need "wired DHCP network"   "debugfs -R 'cat /etc/systemd/network/20-wired.network' $ROOTIMG | grep -q 'DHCP=yes'"
    need "usb ethernet match"   "debugfs -R 'cat /etc/systemd/network/20-wired.network' $ROOTIMG | grep -q 'usb\*'"
fi

log "ui language"
need "ui language"             "debugfs -R 'cat /etc/cpz/language' $ROOTIMG | grep -Eq '^(en|de|es|fr|it|ja|pl|pt|tr|uk|zh)$'"

log "base configuration"
need "systemd watchdog config" "debugfs -R 'cat /etc/systemd/system.conf.d/10-cpz-watchdog.conf' $ROOTIMG | grep -q 'RuntimeWatchdogSec=15s'"
need "volatile journal"        "debugfs -R 'cat /etc/systemd/journald.conf.d/10-cpz.conf' $ROOTIMG | grep -q 'Storage=volatile'"
need "i2c-dev autoload"        "debugfs -R 'cat /etc/modules-load.d/cpz.conf' $ROOTIMG | grep -q '^i2c-dev$'"
need "device permissions"      "debugfs -R 'cat /etc/udev/rules.d/70-cpz-permissions.rules' $ROOTIMG | grep -q 'i2c-dev'"
need "panel on seat0"          "debugfs -R 'cat /etc/udev/rules.d/99-cpz-display.rules' $ROOTIMG | grep -q 'ID_SEAT.*seat0'"
need "keyboard on seat0"       "debugfs -R 'cat /etc/udev/rules.d/99-cpz-input.rules' $ROOTIMG | grep -q 'ID_SEAT.*seat0'"
absent "no vendor lcd seat rule" "debugfs -R 'stat /etc/udev/rules.d/99-cardputer-zero-lcd.rules' $ROOTIMG"
absent "no vendor key seat rule" "debugfs -R 'stat /etc/udev/rules.d/99-cardputer-zero-keyboard.rules' $ROOTIMG"

log "pacman trust"
need "alarm keyring file"      "debugfs -R 'stat /usr/share/pacman/keyrings/archlinuxarm.gpg' $ROOTIMG | grep -q Inode"
need "alarm build key trusted" "chroot $ROOT pacman-key --list-keys builder@archlinuxarm.org | grep -q full"

log "ui repository"
need "ui signing key"          "debugfs -R 'stat /usr/share/pacman/keyrings/cpz-ui-signing.asc' $ROOTIMG | grep -q Inode"
need "ui key trusted"          "chroot $ROOT pacman-key --list-keys $UI_REPO_KEY_FPR | grep -q 'CPZ UI Signing'"
need "ui stable config"        "debugfs -R 'cat /etc/pacman.d/cpz-ui.conf' $ROOTIMG | grep -q 'releases/download/ui-stable'"
need "ui beta config"          "debugfs -R 'cat /etc/pacman.d/cpz-ui-beta.conf' $ROOTIMG | grep -q 'releases/download/ui-beta'"
need "ui repo requires signatures" "debugfs -R 'cat /etc/pacman.d/cpz-ui.conf' $ROOTIMG | grep -q 'DatabaseRequired'"
need "pacman includes ui repo" "debugfs -R 'cat /etc/pacman.conf' $ROOTIMG | grep -q 'Include = /etc/pacman.d/cpz-ui.conf'"
case "$UI_APPS_REPO_STABLE" in
    "")
        absent "no apps repo config" "debugfs -R 'stat /etc/pacman.d/cpz-apps.conf' $ROOTIMG"
        need "no apps repo include" "! debugfs -R 'cat /etc/pacman.conf' $ROOTIMG | grep -q 'cpz-apps.conf'"
        ;;
    file:*)
        need "apps repo config"    "debugfs -R 'cat /etc/pacman.d/cpz-apps.conf' $ROOTIMG | grep -q '^\[cpz-apps\]$'"
        need "apps repo is local"  "debugfs -R 'cat /etc/pacman.d/cpz-apps.conf' $ROOTIMG | grep -q 'Server = file:///opt/cpz/apps-repo'"
        need "apps repo database in image" "debugfs -R 'stat /opt/cpz/apps-repo/cpz-apps.db.tar.gz' $ROOTIMG | grep -q Inode"
        need "pacman includes apps repo" "debugfs -R 'cat /etc/pacman.conf' $ROOTIMG | grep -q 'Include = /etc/pacman.d/cpz-apps.conf'"
        ;;
    *)
        need "apps repo config"    "debugfs -R 'cat /etc/pacman.d/cpz-apps.conf' $ROOTIMG | grep -q '^\[cpz-apps\]$'"
        need "apps repo requires signatures" "debugfs -R 'cat /etc/pacman.d/cpz-apps.conf' $ROOTIMG | grep -q 'DatabaseRequired'"
        need "pacman includes apps repo" "debugfs -R 'cat /etc/pacman.conf' $ROOTIMG | grep -q 'Include = /etc/pacman.d/cpz-apps.conf'"
        ;;
esac

log "packages"
need_pkg linux-rpi
need_pkg sudo
need_pkg archlinuxarm-keyring
need_pkg iwd
need_pkg bluez
if [ "$UI_TEST" = "1" ]; then
    need_pkg cage
    need_pkg foot
    need_pkg tmux
    need_pkg fzf
    need_pkg j4-dmenu-desktop
    need_pkg desktop-file-utils
    need_pkg xorg-xwayland
    need_pkg mesa
    need_pkg ttf-dejavu
    need_pkg xkeyboard-config
    need_pkg libdrm
    need_pkg freetype2
    need_pkg libxkbcommon
    need_pkg libevdev
    need_pkg libinput
    need_absent_pkg libtsm
    need_absent_pkg python
    need_absent_pkg git
    need_absent_pkg vim
    need_absent_pkg nnn
    need_absent_pkg htop
    need_absent_pkg alsa-utils
    need_absent_pkg sdl2-compat
else
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
    need_absent_pkg libinput
fi

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
