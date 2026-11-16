#!/bin/bash -e

# Install the CPZ terminal session (fbcon + tmux).

install -d -m 0755 "${ROOTFS_DIR}/usr/local/bin"

install -d -m 0755 "${ROOTFS_DIR}/etc/profile.d"
install -m 0644 files/cpz-session.sh \
	"${ROOTFS_DIR}/etc/profile.d/cpz-session.sh"

install -m 0644 files/tmux.conf "${ROOTFS_DIR}/etc/tmux.conf"

# /tmp is disk-backed because tmp.mount is masked in 02-run.sh.
install -d -m 1777 "${ROOTFS_DIR}/tmp"

# Status bar, Settings TUI and tab/session helpers.
install -m 0755 \
	files/cpz-session-ensure files/cpz-tab-new files/cpz-tab-close \
	files/cpz-tab-close-key files/cpz-tab-info \
	files/cpz-settings-open \
	files/cpz-settings files/cpz-settings-shell files/cpz-status \
	files/cpz-apply-settings files/cpz-help files/cpz-console-theme \
	files/cpz-first-login \
	files/cpz-session-save files/cpz-session-restore \
	files/cpz-session-save-as-user files/cpz-conn-status \
	files/cpz-brightness files/cpz-screen-timeout \
	files/cpz-keyboard-layout \
	files/cpz-layout-next files/cpz-layout-apply files/cpz-display-toggle \
	"${ROOTFS_DIR}/usr/local/bin/"
install -d -m 0755 "${ROOTFS_DIR}/etc/udev/rules.d"
install -m 0644 files/99-cpz-backlight.rules files/99-cpz-keyboard.rules \
	files/99-cpz-hdmi-console.rules \
	"${ROOTFS_DIR}/etc/udev/rules.d/"
install -m 0644 files/cpz-keyboard-layout.service \
	files/cpz-keyboard-layout.path \
	"${ROOTFS_DIR}/etc/systemd/system/"
install -d -m 0755 "${ROOTFS_DIR}/etc/cpz/themes"
install -m 0644 files/settings.conf "${ROOTFS_DIR}/etc/cpz/settings.conf"
# cpz-settings warns while the factory password is unchanged. It cannot read
# /etc/shadow, so record the image's mtime here; passwd/usermod/chage all
# update it, which is enough to clear the warning after a password change.
stat -c %Y "${ROOTFS_DIR}/etc/shadow" >"${ROOTFS_DIR}/etc/cpz/shadow-mtime"
install -m 0644 files/themes/*.conf files/themes/*.palette \
	"${ROOTFS_DIR}/etc/cpz/themes/"
install -m 0644 files/cpz-session-save.service files/cpz-session-save.timer \
	files/cpz-conn-status.service files/cpz-conn-status.timer \
	"${ROOTFS_DIR}/etc/systemd/system/"

# Let the netdev user manage NetworkManager (Wi-Fi) without a polkit prompt.
install -d -m 0755 "${ROOTFS_DIR}/etc/polkit-1/rules.d"
install -m 0644 files/50-cpz-networkmanager.rules \
	"${ROOTFS_DIR}/etc/polkit-1/rules.d/50-cpz-networkmanager.rules"

# Bluetooth pairing agent used by cpz-settings.
install -m 0644 files/cpz-bt-agent.service \
	"${ROOTFS_DIR}/etc/systemd/system/cpz-bt-agent.service"

# Alt+Space switches console layouts; allow only the keymap reload helper to
# run without a password prompt.
install -d -m 0755 "${ROOTFS_DIR}/etc/sudoers.d"
install -m 0440 files/50-cpz-layout \
	"${ROOTFS_DIR}/etc/sudoers.d/50-cpz-layout"

# The first user must own their config tree. Older stage2 code created
# ~/.config (and ~/.config/systemd) as root via install -d on a nested path,
# which made cpz-settings fail with a permission error.
first_home=$(awk -F: '$3 == 1000 { print $6; exit }' \
	"${ROOTFS_DIR}/etc/passwd" 2>/dev/null || true)
if [ -n "$first_home" ]; then
	case "$first_home" in
		/*) ;;
		*) first_home="/$first_home" ;;
	esac
	user_config="${ROOTFS_DIR}${first_home}/.config"
	install -d -m 0755 "$user_config" "$user_config/systemd" \
		"$user_config/systemd/user" "$user_config/cpz"
	chown 1000:1000 "$user_config" "$user_config/systemd" \
		"$user_config/systemd/user" "$user_config/cpz"
fi

# The active fbcon path uses console-setup. Terminus 6x12 (53x14 cells on the
# 320x170 panel) is the smallest readable font; the default 8x16 only fits
# 40x10.
console_setup="${ROOTFS_DIR}/etc/default/console-setup"
if [ -f "$console_setup" ]; then
	sed -i \
		's/^FONTFACE=.*/FONTFACE="Terminus"/;s/^FONTSIZE=.*/FONTSIZE="6x12"/' \
		"$console_setup"
fi

# The CardputerZero TCA8418 driver emits different keycodes for the Sym/Fn
# layers. The vendor loadkeys map is installed by the hardware stage but was
# never applied; without it Sym produces the default US punctuation.
install -m 0644 files/cardputerzero-keymap.service \
	"${ROOTFS_DIR}/etc/systemd/system/cardputerzero-keymap.service"

# fbcon tty1 is the CPZ session; cpz-hdmi-console moves it between the panel
# and HDMI. tty2/tty3 stay plain recovery logins.
install -m 0755 files/cpz-getty "${ROOTFS_DIR}/usr/local/bin/"
install -d -m 0755 \
	"${ROOTFS_DIR}/etc/systemd/system/getty@tty1.service.d"
install -m 0644 files/getty@tty1.service.d/10-cpz-autologin.conf \
	"${ROOTFS_DIR}/etc/systemd/system/getty@tty1.service.d/10-cpz-autologin.conf"

# HDMI hotplug: move the active tty1 console to HDMI and back, with a console
# font sized for the actual framebuffer mode (so fallback modes stay usable).
# While HDMI is active the internal panel is cleared and switched off at the
# backlight.
install -m 0755 files/cpz-hdmi-console "${ROOTFS_DIR}/usr/local/bin/"

# Terminal QR renderers (qrencode -t UTF8/ANSIUTF8) use the half-block glyphs
# U+2580/U+2584. The console-setup Terminus builds keep only U+2588, so add the
# missing block glyphs to every console font cpz-hdmi-console can select.
install -m 0755 files/cpz-font-blocks "${ROOTFS_DIR}/usr/local/sbin/"
# Auto HDMI text size keeps about 25 rows; the packaged Terminus fonts stop at
# 16x32, which is too small on 1080p+ screens. cpz-font-scale derives a larger
# cell size at runtime and caches it in /run.
install -m 0755 files/cpz-font-scale "${ROOTFS_DIR}/usr/local/sbin/"
install -m 0644 files/cpz-hdmi-console.service files/cpz-hdmi-console.timer \
	"${ROOTFS_DIR}/etc/systemd/system/"
install -d -m 0755 "${ROOTFS_DIR}/etc/systemd/system-sleep"
install -m 0755 files/cpz-hdmi-sleep \
	"${ROOTFS_DIR}/etc/systemd/system-sleep/cpz-hdmi"

# userconf-pi's cancel-rename enables getty/LightDM autologin for Raspberry Pi
# OS. CPZ installs its own getty@tty1 autologin above; keep only the SSH/rename
# bookkeeping so an rpi-preseed rename does not undo the CPZ console session.
install -d -m 0755 "${ROOTFS_DIR}/usr/local/share/cpz"
install -m 0755 files/cancel-rename \
	"${ROOTFS_DIR}/usr/local/share/cpz/cancel-rename"

on_chroot << 'CHROOT'
set -e

if [ -e /usr/bin/cancel-rename ] &&
	! dpkg-divert --list /usr/bin/cancel-rename | grep -q 'cpz-os'; then
	dpkg-divert --package cpz-os --divert /usr/bin/cancel-rename.distrib \
		--rename /usr/bin/cancel-rename
fi
install -m 0755 /usr/local/share/cpz/cancel-rename /usr/bin/cancel-rename

systemctl enable cardputerzero-keymap.service
systemctl enable cpz-keyboard-layout.path
systemctl enable cpz-hdmi-console.timer
systemctl enable cpz-session-save.timer
systemctl enable cpz-conn-status.timer

# Bluetooth: enable BlueZ, the pairing agent and give the first user access.
systemctl enable bluetooth.service 2>/dev/null || true
systemctl enable cpz-bt-agent.service 2>/dev/null || true
FIRST_USER=$(getent passwd 1000 | cut -d: -f1 || true)
if [ -n "$FIRST_USER" ]; then
	groupadd -f bluetooth
	usermod -aG bluetooth "$FIRST_USER"
fi

# Add the block glyphs missing from the packaged Terminus subsets, then apply
# the 6x12 console font at boot (fbcon path). Only PSF2 sizes are listed:
# cpz-font-blocks cannot patch the PSF1 Terminus14/16 files. The font files are
# overwritten in place so console-setup's cache and cpz-hdmi-console's setfont
# path both see the patched versions.
/usr/local/sbin/cpz-font-blocks \
	/usr/share/consolefonts/Lat15-Terminus12x6.psf.gz \
	/usr/share/consolefonts/Lat15-Terminus18x10.psf.gz \
	/usr/share/consolefonts/Lat15-Terminus20x10.psf.gz \
	/usr/share/consolefonts/Lat15-Terminus22x11.psf.gz \
	/usr/share/consolefonts/Lat15-Terminus24x12.psf.gz \
	/usr/share/consolefonts/Lat15-Terminus28x14.psf.gz \
	/usr/share/consolefonts/Lat15-Terminus32x16.psf.gz
systemctl enable console-setup.service 2>/dev/null || true
setupcon --force --save-only 2>/dev/null || true

# Fail the build early on a malformed sudoers drop-in.
visudo -cf /etc/sudoers.d/50-cpz-layout

systemctl daemon-reload || true
CHROOT
