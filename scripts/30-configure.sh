#!/bin/bash
# Stage 30 — configure the base image: identity, boot files, and every removal
# or mask that exists for boot speed.
#
# This stage defines no display stack and no UI. It leaves the system reachable
# over serial and SSH, with the hardware drivers installed and available. A
# graphics or terminal stack is added later, outside this base.
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
# An appliance must recover from a hang, not sit dead until the battery drains.
[Manager]
RuntimeWatchdogSec=15s
RebootWatchdogSec=60s
EOF

# Nothing on this image needs these at boot.
for unit in systemd-timesyncd.service systemd-binfmt.service; do
    in_root "systemctl disable $unit >/dev/null 2>&1 || true"
    in_root "systemctl mask $unit >/dev/null 2>&1 || true"
done

# --- login paths ------------------------------------------------------------
# There is no display output on this image, so a tty getty would be a prompt
# nobody can see. Local access is the serial console; remote access is SSH.
log "configuring login paths"
for vt in 1 2 3 4 5 6; do
    in_root "systemctl disable getty@tty$vt.service >/dev/null 2>&1 || true"
done
in_root "systemctl enable serial-getty@ttyS0.service >/dev/null 2>&1 || true"

# --- session entry point ----------------------------------------------------
# The platform owns the session unit; the UI package provides the executable
# and enables one instance. It is inert until /usr/lib/cpz/session exists.
# PAMName=login creates a logind session and seat, so the UI gets DRM, evdev
# and audio through the normal login path instead of a root daemon.
cat > "$ROOT/usr/lib/systemd/system/cpz-ui@.service" <<'EOF'
[Unit]
Description=CPZ UI session on %I
After=systemd-user-sessions.service
Wants=systemd-user-sessions.service
Conflicts=getty@%I.service
ConditionPathExists=/usr/lib/cpz/session

[Service]
PAMName=login
User=cpz
Group=cpz
TTYPath=/dev/%I
StandardInput=tty
StandardOutput=tty
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=no
ExecStart=/usr/lib/cpz/session
Restart=always
RestartSec=1
KillMode=control-group

[Install]
WantedBy=multi-user.target
EOF

# --- boot speed: module autoload -------------------------------------------
# i2c-dev is what turns the vendor's i2c1 bus into /dev/i2c-1. It is generic
# hardware access for whatever stack is added later; display modules are
# deliberately not loaded at boot.
cat > "$ROOT/etc/modules-load.d/cpz.conf" <<'EOF'
i2c-dev
EOF

# --- boot speed: udev -------------------------------------------------------
cat > "$ROOT/etc/udev/rules.d/70-cpz-permissions.rules" <<'EOF'
# Device nodes the hardware needs; harmless for a bare shell.
SUBSYSTEM=="gpio",  KERNEL=="gpiochip*", GROUP="gpio", MODE="0660"
SUBSYSTEM=="spidev",                     GROUP="spi",  MODE="0660"
SUBSYSTEM=="i2c-dev",                    GROUP="i2c",  MODE="0660"
SUBSYSTEM=="input",  KERNEL=="event*",   GROUP="input", MODE="0660"
EOF

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

# The board overlay describes the keypad, PMIC, battery gauge, audio codec and
# IMU rails. It is hardware description only; no display policy is configured
# here. The panel/HDMI drivers are present in the image for a later stack.
cat > "$ROOT/boot/config.txt" <<EOF
# Cardputer Zero — cpz-arch base profile ($BOARD)
# Generated by scripts/30-configure.sh. Edit config.sh, not this file.

arm_64bit=1

# Do not probe hardware we do not have.
camera_auto_detect=0

# Buses the Cardputer Zero needs.
dtparam=i2c_arm=on
dtparam=i2s=on
dtparam=spi=on
dtparam=audio=off

# Serial console available for recovery.
enable_uart=1

# USB host mode.
dtoverlay=dwc2

# Vendor board overlay: keypad, M5 IO expander, audio, power-fail handler,
# LEDs, battery gauge and IMU.
$BOARD_OVERLAYS

dtparam=watchdog=on
EOF

# No initramfs: the kernel, SD/MMC and ext4 are either built in or loaded from
# the device-tree overlay, so the firmware boots straight into the root
# filesystem. fbcon is mapped off: this image has no display output.
cat > "$ROOT/boot/cmdline.txt" <<EOF
root=PARTUUID=$ROOT_PARTUUID rw rootfstype=ext4 rootwait noatime quiet loglevel=3 audit=0 console=ttyS0,115200 fbcon=map:off panic=10
EOF

# --- size: drop what is not on the boot path -------------------------------
log "removing build toolchain: $BUILD_PACKAGES"
for pkg in $BUILD_PACKAGES; do
    pacman_target -Q "$pkg" >/dev/null 2>&1 || continue
    pacman_target -Rns "$pkg" >/dev/null 2>&1 || warn "cannot remove build package $pkg"
done

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

# The build chroot is not the running system: do not ship test state or tmp files.
rm -rf "$ROOT/run"/* "$ROOT/tmp"/* 2>/dev/null || true

log "removing documentation and unused locales"
rm -rf "$ROOT"/usr/share/{doc,man,info,locale,help} \
       "$ROOT"/var/cache/pacman/pkg/* "$ROOT"/var/lib/pacman/sync

find "$ROOT" -type f -name '*.pacnew' -delete
find "$ROOT" -type f -name '*.pacsave' -delete

log "configured rootfs: $(du -sh "$ROOT" | cut -f1), kernel $KVER, PARTUUID $ROOT_PARTUUID"
