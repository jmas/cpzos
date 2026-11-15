#!/bin/bash -e

# CardputerZero hardware/session plumbing for CPZ OS.
#
# This is the upstream CardputerZero stage with the launcher/OOBE blocks removed
# (fork change for CPZ OS): APPLaunch, LaunchWizard, the piwiz/lightdm first-boot
# wizard and the keyboard guide are not installed. Everything that makes the
# CM0 hardware work on the panel - boot splash, cmdline, i2c, rfkill, backlight,
# journald and PipeWire realtime/volume defaults - is kept exactly as upstream.

# Boot splash: firmware start.elf/fixup.dat + BMP splash.
install -m 644 files/start.elf "${ROOTFS_DIR}/boot/firmware/start.elf"
install -m 644 files/fixup.dat "${ROOTFS_DIR}/boot/firmware/fixup.dat"
install -m 644 files/splash.bmp "${ROOTFS_DIR}/boot/firmware/splash.bmp"
install -m 644 files/CardputerZero_splash_custom.bin \
    "${ROOTFS_DIR}/boot/firmware/CardputerZero_splash_custom.bin"
sed -i \
    -e '/^splash_screen=/d' \
    -e '/^gpu_mem=/d' \
    -e '1i splash_screen=CardputerZero_splash_custom.bin\ngpu_mem=128\n' \
    "${ROOTFS_DIR}/boot/firmware/config.txt"

# ADB is off by default. adbd ships in this stage's package list; the launcher
# package used to enable the hotplug monitor, so keep the default explicit.
on_chroot << CHROOT
set -e
systemctl disable cardputer-adb-hotplug.service adbd.service 2>/dev/null || true
rm -f /etc/systemd/system/multi-user.target.wants/cardputer-adb-hotplug.service \
    /etc/systemd/system/multi-user.target.wants/adbd.service
CHROOT

# Keep realtime media scheduling deterministic on the low-memory target.
for config_dir in \
    pipewire.conf.d \
    pipewire-pulse.conf.d \
    filter-chain.conf.d \
    client.conf.d; do
    install -d "${ROOTFS_DIR}/etc/pipewire/${config_dir}"
    install -m 644 files/20-rtkit-direct.conf \
        "${ROOTFS_DIR}/etc/pipewire/${config_dir}/20-rtkit-direct.conf"
done

install -d "${ROOTFS_DIR}/etc/systemd/system/user@1000.service.d"
install -m 644 files/20-rtkit-order.conf \
    "${ROOTFS_DIR}/etc/systemd/system/user@1000.service.d/20-rtkit-order.conf"

# Factory default output volume: WirePlumber's stock 40% (0.064 linear) is
# nearly inaudible on the small speaker.
install -d "${ROOTFS_DIR}/etc/wireplumber/wireplumber.conf.d"
install -m 644 files/50-cardputerzero-default-volume.conf \
    "${ROOTFS_DIR}/etc/wireplumber/wireplumber.conf.d/50-cardputerzero-default-volume.conf"

# Audio rlimits belong in the real uid-1000 user's config. Resolve the home
# from the rootfs passwd so a renamed first user still gets them.
FIRST_HOME=$(awk -F: '$3 == 1000 { print $6; exit }' \
    "${ROOTFS_DIR}/etc/passwd" 2>/dev/null || true)
FIRST_HOME=${FIRST_HOME:-/home/pi}
FIRST_HOME=${FIRST_HOME#/}
for audio_service in pipewire pipewire-pulse filter-chain; do
    service_dropin="${ROOTFS_DIR}/${FIRST_HOME}/.config/systemd/user/${audio_service}.service.d"
    install -d -m 755 -o 1000 -g 1000 "$service_dropin"
    install -m 644 -o 1000 -g 1000 files/20-audio-rlimits.conf \
        "$service_dropin/20-audio-rlimits.conf"
done

on_chroot << 'CHROOT'
systemctl enable rtkit-daemon.service
CHROOT

# Append custom cmdline parameters for CardputerZero.
sed -i 's/$/ quiet fbcon=map:off cfg80211.ieee80211_regdom=AE/' \
    "${ROOTFS_DIR}/boot/firmware/cmdline.txt"

# Clean up CardputerZero cmdline tokens.
for cmd in "${ROOTFS_DIR}/boot/firmware/cmdline.txt" "${ROOTFS_DIR}/boot/cmdline.txt"; do
    [ -f "$cmd" ] || continue
    awk '
        {
            out = ""
            for (i = 1; i <= NF; i++) {
                if ($i != "console=serial0,115200" && $i != "splash" && $i != "plymouth.ignore-serial-consoles") {
                    out = out (out == "" ? "" : " ") $i
                }
            }
            print out
        }
    ' "$cmd" > "${cmd}.tmp"
    mv "${cmd}.tmp" "$cmd"
done

# Module load config
cat > "${ROOTFS_DIR}/etc/modules-load.d/cardputerzero.conf" << 'EOF'
i2c-dev
EOF

# Disable systemd-backlight auto-start for backlight devices.
install -d "${ROOTFS_DIR}/etc/systemd/system"
ln -sf /dev/null "${ROOTFS_DIR}/etc/systemd/system/systemd-backlight@backlight:backlight.service"

# Modprobe configs
cat > "${ROOTFS_DIR}/etc/modprobe.d/blacklist-8192cu.conf" << 'EOF'
blacklist 8192cu
EOF

cat > "${ROOTFS_DIR}/etc/modprobe.d/rfkill_default.conf" << 'EOF'
options rfkill default_state=0
EOF

# Persistent journal - retain logs across reboots for debugging.
mkdir -p "${ROOTFS_DIR}/var/log/journal"
mkdir -p "${ROOTFS_DIR}/etc/systemd/journald.conf.d"
cat > "${ROOTFS_DIR}/etc/systemd/journald.conf.d/persist.conf" << 'EOF'
[Journal]
Storage=persistent
SystemMaxUse=50M
EOF
