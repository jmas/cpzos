#!/bin/bash
# Stage 30 — configure the image: identity, boot files, and every removal or
# mask that exists for boot speed.
#
# Rule for this stage: if it is not needed to reach the session, it is not
# configured. Anything optional is behind a flag in config.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
. ./config.sh
. scripts/lib.sh

KVER=$(kernel_version)
ROOT_PARTUUID="${DISK_ID#0x}-02"
BOOT_PARTUUID="${DISK_ID#0x}-01"

# --- identity ---------------------------------------------------------------
log "configuring identity: $USER_NAME / $HOSTNAME"
printf '%s\n' "$HOSTNAME" > "$ROOT/etc/hostname"
cat > "$ROOT/etc/hosts" <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME
EOF
printf 'LANG=%s\n' "$LOCALE" > "$ROOT/etc/locale.conf"
ln -sf "/usr/share/zoneinfo/$TIMEZONE" "$ROOT/etc/localtime"

# A pre-generated machine-id avoids the first-boot "generate it" path.
head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$ROOT/etc/machine-id"
printf '\n' >> "$ROOT/etc/machine-id"

# --- groups and the login user ---------------------------------------------
# gpio/spi/i2c do not exist in a stock Arch install; the vendor udev rules and
# any future tooling expect them.
for grp in wheel input video audio render gpio spi i2c; do
    in_root "getent group $grp >/dev/null || groupadd -r $grp"
done

if ! in_root "id -u $USER_NAME >/dev/null 2>&1"; then
    # -M: useradd's own skel copy is unreliable inside a chroot (it leaves the
    # files empty), so the home directory is created explicitly below.
    in_root "useradd -M -U -s /bin/bash -G wheel,input,video,audio,render,gpio,spi,i2c $USER_NAME"
    in_root "install -d -m 0755 -o $USER_NAME -g $USER_NAME /home/$USER_NAME"
    cp -a "$ROOT/etc/skel/." "$ROOT/home/$USER_NAME/"
    in_root "chown -R $USER_NAME:$USER_NAME /home/$USER_NAME"
fi
in_root "printf '%s:%s\n' '$USER_NAME' '$USER_PASS' | chpasswd"
in_root "passwd -l root >/dev/null"

cat > "$ROOT/etc/sudoers.d/10-wheel" <<'EOF'
%wheel ALL=(ALL:ALL) ALL
EOF
chmod 0440 "$ROOT/etc/sudoers.d/10-wheel"

# --- boot speed: systemd surface -------------------------------------------
log "trimming systemd to the boot path"
mkdir -p "$ROOT/etc/systemd/journald.conf.d"
cat > "$ROOT/etc/systemd/journald.conf.d/10-cpz.conf" <<'EOF'
# Keep the journal in memory: one less write stream on the SD card during boot.
[Journal]
Storage=volatile
RuntimeMaxUse=16M
SystemMaxUse=16M
EOF

mkdir -p "$ROOT/etc/systemd/system.conf.d"
cat > "$ROOT/etc/systemd/system.conf.d/10-cpz-watchdog.conf" <<'EOF'
# An appliance must recover from a hung session, not sit on a black screen.
[Manager]
RuntimeWatchdogSec=15s
RebootWatchdogSec=60s
EOF

# Nothing on this image needs these at boot.
for unit in systemd-timesyncd.service systemd-binfmt.service; do
    in_root "systemctl disable $unit >/dev/null 2>&1 || true"
    in_root "systemctl mask $unit >/dev/null 2>&1 || true"
done

# The session engine. cpz-session boots into cpz-ui: one SDL2 launcher, one
# active output, no login prompt on the panel.
cat > "$ROOT/etc/systemd/system/cpz-session.service" <<EOF
[Unit]
Description=Cardputer Zero appliance session (SDL2/KMSDRM)
DefaultDependencies=no
After=systemd-modules-load.service systemd-udevd.service cpz-menud.service
Wants=cpz-menud.service
Before=basic.target getty.target
Conflicts=getty@tty1.service
StartLimitIntervalSec=0

[Service]
Type=notify
NotifyAccess=main
WatchdogSec=10
Environment=TERM=linux
Environment=SDL_VIDEODRIVER=kmsdrm
Environment=XKB_DEFAULT_LAYOUT=$XKB_LAYOUT
Environment=XKB_DEFAULT_OPTIONS=$XKB_OPTIONS
ExecStart=/usr/local/bin/cpz-session --ui /usr/local/bin/cpz-ui
Restart=always
RestartSec=0.2
KillMode=control-group
TimeoutStopSec=5

[Install]
WantedBy=sysinit.target
EOF

# The menu/status model daemon. It is stateless on disk: static manifests plus
# live provider registrations. The session may restart on every app; this
# process must not.
cat > "$ROOT/etc/systemd/system/cpz-menud.service" <<'EOF'
[Unit]
Description=Cardputer Zero menu and status model (cpz-menud)
DefaultDependencies=no
After=systemd-udevd.service
Before=cpz-session.service
StartLimitIntervalSec=0

[Service]
Type=notify
NotifyAccess=main
RuntimeDirectory=cpz/menu
RuntimeDirectoryMode=0755
ExecStart=/usr/local/bin/cpz-menud
Restart=always
RestartSec=0.2
KillMode=control-group

[Install]
WantedBy=sysinit.target
EOF

# System providers: ordinary daemons on the same protocol, shipped with the
# image, with reserved priority. They only supply typed widgets.
for prov in battery clock network bluetooth; do
    cat > "$ROOT/etc/systemd/system/cpz-$prov.service" <<EOF
[Unit]
Description=Cardputer Zero $prov status provider
DefaultDependencies=no
After=cpz-menud.service
Wants=cpz-menud.service
Before=cpz-session.service
StartLimitIntervalSec=0

[Service]
ExecStart=/usr/local/bin/cpz-$prov
Restart=always
RestartSec=2
KillMode=control-group

[Install]
WantedBy=sysinit.target
EOF
done

in_root "systemctl enable cpz-menud.service cpz-battery.service \
         cpz-clock.service cpz-network.service cpz-bluetooth.service \
         >/dev/null 2>&1 || true"

in_root "systemctl disable getty@tty1.service >/dev/null 2>&1 || true"
in_root "systemctl enable cpz-session.service >/dev/null 2>&1 || true"
# Serial recovery shell. The panel has no fbcon, so this is the only local
# login path if SSH is down.
in_root "systemctl enable serial-getty@ttyAMA0.service >/dev/null 2>&1 || true"

# Never start a getty nobody can see.
for vt in 2 3 4 5 6; do
    in_root "systemctl disable getty@tty$vt.service >/dev/null 2>&1 || true"
done

# --- boot speed: module autoload -------------------------------------------
# i2c-dev is what turns the vendor's i2c1 bus into /dev/i2c-1. Nothing else is
# loaded at boot; every other module comes from the device-tree overlay.
cat > "$ROOT/etc/modules-load.d/cpz.conf" <<'EOF'
i2c-dev
EOF

# --- boot speed: udev -------------------------------------------------------
cat > "$ROOT/etc/udev/rules.d/70-cpz-permissions.rules" <<'EOF'
# Device nodes the device packages will need; harmless for a bare shell.
SUBSYSTEM=="gpio",  KERNEL=="gpiochip*", GROUP="gpio", MODE="0660"
SUBSYSTEM=="spidev",                     GROUP="spi",  MODE="0660"
SUBSYSTEM=="i2c-dev",                    GROUP="i2c",  MODE="0660"
SUBSYSTEM=="input",  KERNEL=="event*",   GROUP="input", MODE="0660"
SUBSYSTEM=="backlight",                      GROUP="video", MODE="0660"
EOF

# --- panel bring-up -------------------------------------------------------
# The panel device (spi0.0) is created by the device tree, but its driver has
# no matching SPI modalias, so udev never autoloads it. Load it explicitly and
# before vc4 so the panel DRM card probes first and the session can find it
# without waiting for an unrelated driver event.
#
# All display dependencies are loaded here, not left to udev coldplug. The
# important one is gpio_forwarder: the board overlay adds a third entry to
# spi0's cs-gpios pointing at its GPIO chip. Until that chip exists,
# spi_register_controller() returns -EPROBE_DEFER and the panel DRM card does
# not appear for several seconds. i2c_bcm2835/spi_bcm2835 must exist before
# m5ioe1/panel, and m5ioe1 before pwm_bl_m5stack (the panel backlight PWM).
# vc4 is only useful when the HDMI overlay is enabled. Loading it without the
# overlay probes a card that does not exist.
VC4_MODULE=""
if [ "$ENABLE_HDMI" = "1" ]; then
    VC4_MODULE="vc4"
fi
cat > "$ROOT/etc/modules-load.d/cpz-panel.conf" <<EOF
i2c-dev
gpio_forwarder
i2c_bcm2835
spi_bcm2835
m5ioe1
pwm_bl_m5stack
tca8418_keypad_m5stack
panel-mipi-dbi-m
$VC4_MODULE
EOF
install -d "$ROOT/etc/modprobe.d"
cat > "$ROOT/etc/modprobe.d/cpz-panel.conf" <<'EOF'
# Panel first, then vc4: keep the panel DRM card probe deterministic.
softdep vc4 pre: panel-mipi-dbi-m
EOF

# --- panel backlight ------------------------------------------------------
# The kernel backlight stack never programs this panel's PWM on 6.18, so the
# panel stays dark until someone writes the m5ioe1 registers over I2C.
# cpz-session owns the backlight and calls cpz-backlight on output changes.

# --- boot report ----------------------------------------------------------
# Runs once per boot after the session is up and copies the result to the FAT
# boot partition, so a dark panel can be diagnosed by reading the SD card.
cat > "$ROOT/etc/systemd/system/cpz-report.service" <<'EOF'
[Unit]
Description=Cardputer Zero boot report
After=multi-user.target cpz-session.service
Wants=cpz-session.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/cpz-report
TimeoutStartSec=30

[Install]
WantedBy=multi-user.target
EOF
in_root "systemctl enable cpz-report.service >/dev/null 2>&1 || true"

# --- optional: SSH ----------------------------------------------------------
if [ "$ENABLE_SSH" = "1" ]; then
    # Minimal wired networking: systemd-networkd has a DHCP client, and
    # systemd-resolved owns /etc/resolv.conf. No NetworkManager, no extra
    # daemons. The match covers built-in (eth0/enp*) and USB (enx*) adapters.
    log "enabling wired DHCP and sshd"
    cat > "$ROOT/etc/systemd/network/20-wired.network" <<'EOF'
[Match]
Name=en* eth*

[Network]
DHCP=yes
IPv6AcceptRA=yes
EOF

    ln -sfn /run/systemd/resolve/stub-resolv.conf "$ROOT/etc/resolv.conf"

    in_root "systemctl enable systemd-networkd.service >/dev/null 2>&1 || true"
    in_root "systemctl enable systemd-resolved.service >/dev/null 2>&1 || true"
    in_root "systemctl enable sshd.service >/dev/null 2>&1 || true"
else
    in_root "systemctl disable systemd-networkd.service >/dev/null 2>&1 || true"
    in_root "systemctl disable systemd-resolved.service >/dev/null 2>&1 || true"
    in_root "systemctl disable sshd.service >/dev/null 2>&1 || true"
fi

# --- fstab ----------------------------------------------------------------
# No /boot entry on purpose: the firmware reads the FAT partition directly and
# nothing on this image needs it mounted. Pass 0 disables systemd-fsck on the
# root; ext4 still replays its journal on mount.
cat > "$ROOT/etc/fstab" <<EOF
# <file system>                <dir>  <type>  <options>                       <dump> <pass>
PARTUUID=$ROOT_PARTUUID  /      ext4    rw,noatime,errors=remount-ro   0      0
EOF

# --- boot files -----------------------------------------------------------
log "writing /boot/config.txt and /boot/cmdline.txt"
case "$BOARD" in
    v5) BOARD_OVERLAYS="dtoverlay=cardputerzero-v5-overlay
dtoverlay=bq27220_v5
dtoverlay=bmi270_bmm150_overlay" ;;
    v3) BOARD_OVERLAYS="dtoverlay=cardputerzero-v3-overlay
dtoverlay=bq27220_v3
dtoverlay=bmi270_overlay
dtoverlay=spk-gpio24-high-overlay" ;;
    *)  die "unknown BOARD '$BOARD' (expected v3 or v5)" ;;
esac

if [ "$ENABLE_HDMI" = "1" ]; then
    HDMI_LINE="dtoverlay=vc4-kms-v3d"
else
    HDMI_LINE="#dtoverlay=vc4-kms-v3d   # disabled: internal panel only"
fi
# fbcon must stay off the panel: it would take the panel's DRM master and the
# SDL/KMS session could no longer draw there. Disable it entirely. Recovery is
# over serial or SSH.
FBCON=" fbcon=map:off"
CMDLINE_EXTRA=" panic=10"
SERIAL_CONSOLE="console=ttyAMA0,115200"
WATCHDOG_LINE="dtparam=watchdog=on"

cat > "$ROOT/boot/config.txt" <<EOF
# Cardputer Zero — cpz-arch minimal CLI profile ($BOARD)
# Generated by scripts/30-configure.sh. Edit config.sh, not this file.

arm_64bit=1
disable_fw_kms_setup=1
disable_overscan=1

# Do not probe hardware we do not have. Both probes cost boot time.
camera_auto_detect=0
display_auto_detect=0

# Buses the Cardputer Zero needs.
dtparam=i2c_arm=on
dtparam=i2s=on
dtparam=spi=on
dtparam=audio=off

# Serial console available for recovery; nothing writes to it unless the kernel
# command line asks for console=serial0,115200.
enable_uart=1

# USB host mode.
dtoverlay=dwc2

$HDMI_LINE

# Disable spidev@0/@1 so the panel can own SPI0 chip select 0.
# Must come after dtparam=spi=on and before the board overlay.
dtoverlay=cpz-spi

# Vendor board overlay: panel, keypad, M5 IO expander, backlight, audio,
# power-fail handler, LEDs, battery gauge and IMU.
$BOARD_OVERLAYS

# Minimum the Pi firmware recommends for vc4; the panel path does not need more.
gpu_mem=64

# Early-boot splash on the SPI panel. The stock firmware's Splash Asm
# interpreter draws the same white triangle that cpz-ui repeats when it takes
# the display, so the panel is not black while Linux probes the panel.
splash_screen=cpz-splash.bin

$WATCHDOG_LINE
EOF

# Splash Asm binary (source: src/make-splash.py). It lives in the firmware's
# boot partition root next to config.txt.
install -m 0644 src/cpz-splash.bin "$ROOT/boot/cpz-splash.bin"

# No initramfs: the kernel, SD/MMC, ext4 and the panel driver are either built
# in or loaded from the device-tree overlay, so the firmware boots straight
# into the root filesystem.
cat > "$ROOT/boot/cmdline.txt" <<EOF
root=PARTUUID=$ROOT_PARTUUID rw rootfstype=ext4 rootwait noatime quiet loglevel=3 logo.nologo vt.global_cursor_default=0 audit=0 $SERIAL_CONSOLE$FBCON$CMDLINE_EXTRA
EOF

# --- size: drop what is not on the boot path -------------------------------
log "removing build toolchain: $BUILD_PACKAGES"
# shellcheck disable=SC2086
pacman_target -Rns $BUILD_PACKAGES || warn "some build packages are required by others"

# Prune one package at a time: if something depends on it, pacman refuses and
# the package stays. That keeps this step safe to extend without auditing the
# whole dependency graph first.
removed=""; kept=""
for pkg in $PRUNE_PACKAGES; do
    pacman_target -Q "$pkg" >/dev/null 2>&1 || continue
    if pacman_target -Rns "$pkg" >/dev/null 2>&1; then
        removed="$removed $pkg"
    else
        kept="$kept $pkg"
    fi
done
[ -n "$removed" ] && log "pruned:$removed"
[ -n "$kept" ] && warn "kept (still required):$kept"

# Anything the build pulled in that nothing needs any more.
for _ in 1 2 3; do
    orphans=$(pacman_target -Qdttq 2>/dev/null || true)
    [ -n "$orphans" ] || break
    # shellcheck disable=SC2086
    pacman_target -Rns $orphans >/dev/null 2>&1 || break
done

# File-level trim. `base` keeps several packages (binutils, gettext, glib,
# icu) that cannot be removed without breaking systemd, but their development
# payload is dead weight on an appliance. This is a size optimization only: it
# removes files, not packages, so `pacman -Qkk` would report the difference.
log "trimming development and documentation payload"
find "$ROOT/usr/lib" -type f -name '*.a' -delete
rm -rf "$ROOT/usr/lib/gprofng" "$ROOT/usr/lib/icu" "$ROOT/usr/share/gir-1.0"
rm -f  "$ROOT/usr/bin/"{xgettext,msgfmt,msgmerge,msgcat,msgunfmt,msgattrib,msgconv,msgen,msgexec,msgfilter,msggrep,msginit,msguniq,ngettext,msgcmp,msgcomm,msgfmt,msgmerge,msgcat,ld,ld.bfd,ld.gold,dwp,captree} 2>/dev/null || true
rm -f  "$ROOT"/usr/bin/sqlite3* 2>/dev/null || true
rm -f  "$ROOT/usr/share/hwdata/oui.txt"
rm -rf "$ROOT/usr/share/i18n"

# The compiled udev database is what udev reads; building it here removes a
# first-boot step from the critical path. The sources are build input only.
in_root "systemd-hwdb update" || warn "systemd-hwdb update failed"
if [ -s "$ROOT/etc/udev/hwdb.bin" ]; then
    rm -rf "$ROOT/usr/lib/udev/hwdb.d"
else
    warn "keeping hwdb sources: hwdb.bin was not generated"
fi

# The CM0 only ever uses start.elf + fixup.dat. The 4-series and the
# debug/cut-down variants are ~20 MiB of dead weight on the boot partition.
rm -f "$ROOT/boot"/start4*.elf "$ROOT/boot"/start_*db.elf "$ROOT/boot"/start_cd.elf \
      "$ROOT/boot"/start_db.elf "$ROOT/boot"/start_x.elf \
      "$ROOT/boot"/fixup4*.dat "$ROOT/boot"/fixup_*db.dat "$ROOT/boot"/fixup_cd.dat \
      "$ROOT/boot"/fixup_x.dat

log "removing documentation and unused locales"
rm -rf "$ROOT"/usr/share/{doc,man,info,locale,help} \
       "$ROOT"/var/cache/pacman/pkg/* "$ROOT"/var/lib/pacman/sync

find "$ROOT" -type f -name '*.pacnew' -delete
find "$ROOT" -type f -name '*.pacsave' -delete

log "configured rootfs: $(du -sh "$ROOT" | cut -f1), kernel $KVER, PARTUUID $ROOT_PARTUUID"
