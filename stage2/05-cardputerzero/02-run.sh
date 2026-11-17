#!/bin/bash -e

# CardputerZero hardware/session plumbing for CPZ OS.
#
# This is the upstream CardputerZero stage with the launcher/OOBE blocks removed
# (fork change for CPZ OS): APPLaunch, LaunchWizard, the piwiz/lightdm first-boot
# wizard and the keyboard guide are not installed. Everything that makes the
# CM0 hardware work on the panel - boot splash, i2c, rfkill, backlight, journald
# and PipeWire realtime/volume defaults - is kept here; boot policy lives in
# stage3.

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

# fb_load comes from the m5stack driver's "make install". It draws the splash
# on the SPI panel and then waits for APPLaunch/LaunchWizard to start - but CPZ
# OS has no launcher, so it never exits and keeps DRM master on the panel card.
# fbcon then cannot take over /dev/dri/card1 and renders on HDMI only.
# The firmware splash (custom start.elf + CardputerZero_splash_custom.bin)
# already covers the pre-terminal screen, so drop the unit entirely.
on_chroot << CHROOT
set -e
systemctl disable fb_load.service 2>/dev/null || true
rm -f /etc/systemd/system/sysinit.target.wants/fb_load.service \
    /etc/systemd/system/fb_load.service
CHROOT

# The vendor display rule puts the panel DRM card on seat-cardputer-zero,
# which hides it from kmscon/libseat on seat0. Replace it with a CPZ rule that
# keeps the card on seat0; the fbdev symlink is no longer needed because the
# normal image has no panel fbdev node.
rm -f "${ROOTFS_DIR}/etc/udev/rules.d/99-cardputer-zero-lcd.rules"
install -m 644 files/99-cpz-display.rules \
    "${ROOTFS_DIR}/etc/udev/rules.d/99-cpz-display.rules"

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

# install -d only applies -o/-g to the final directory. Create the parent
# directories explicitly and chown the whole chain, otherwise ~/.config is
# root-owned and the user cannot create ~/.config/cpz later.
user_config="${ROOTFS_DIR}/${FIRST_HOME}/.config"
install -d -m 0755 "$user_config" "$user_config/systemd" "$user_config/systemd/user"
chown 1000:1000 "$user_config" "$user_config/systemd" "$user_config/systemd/user"

for audio_service in pipewire pipewire-pulse filter-chain; do
    service_dropin="${user_config}/systemd/user/${audio_service}.service.d"
    install -d -m 755 -o 1000 -g 1000 "$service_dropin"
    install -m 644 -o 1000 -g 1000 files/20-audio-rlimits.conf \
        "$service_dropin/20-audio-rlimits.conf"
done

install -d "${ROOTFS_DIR}/etc/sysctl.d"
install -m 0644 files/99-cpz-hardening.conf \
    "${ROOTFS_DIR}/etc/sysctl.d/99-cpz-hardening.conf"

# The firmware can leave the PM watchdog armed; disarm it before sysinit even
# if the initramfs hook did not run.
install -m 0644 files/cardputerzero-watchdog.service \
    "${ROOTFS_DIR}/etc/systemd/system/cardputerzero-watchdog.service"

# The image ships out-of-tree CPZ modules built against this exact kernel.
# rpi-update would replace the kernel and leave the panel and keyboard without
# drivers until the modules are rebuilt, so keep it out of the image even if a
# dependency or a later layer pulls it in. The apt pin also keeps it from being
# installed again later.
install -d "${ROOTFS_DIR}/etc/apt/preferences.d"
install -m 0644 files/99-cpz-no-rpi-update.pref \
    "${ROOTFS_DIR}/etc/apt/preferences.d/99-cpz-no-rpi-update.pref"

on_chroot << 'CHROOT'
systemctl enable rtkit-daemon.service
systemctl enable cardputerzero-watchdog.service

apt-get purge -y rpi-update >/dev/null 2>&1 || true
CHROOT

# Kernel cmdline and boot policy belong to stage3 (the CPZ session stage).

# Module load config
cat > "${ROOTFS_DIR}/etc/modules-load.d/cardputerzero.conf" << 'EOF'
i2c-dev
m5ioe1
pwm_bl_m5stack
panel-mipi-dbi-m
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
