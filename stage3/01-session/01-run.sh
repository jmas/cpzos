#!/bin/bash -e

# Install the CPZ terminal session (kmscon + tmux).

install -d -m 0755 "${ROOTFS_DIR}/etc/kmscon"
install -m 0644 files/kmscon.conf "${ROOTFS_DIR}/etc/kmscon/kmscon.conf"

install -d -m 0755 "${ROOTFS_DIR}/usr/local/bin"
install -m 0755 files/cpz-kmscon files/cpz-kmscon-config files/cpz-login \
	files/cpz-kmscon-output "${ROOTFS_DIR}/usr/local/bin/"

install -d -m 0755 "${ROOTFS_DIR}/etc/profile.d"
install -m 0644 files/cpz-session.sh \
	"${ROOTFS_DIR}/etc/profile.d/cpz-session.sh"

install -m 0644 files/tmux.conf "${ROOTFS_DIR}/etc/tmux.conf"

# /tmp is disk-backed because tmp.mount is masked in 02-run.sh.
install -d -m 1777 "${ROOTFS_DIR}/tmp"

# Status bar, Settings TUI and tab/session helpers.
install -m 0755 \
	files/cpz-session-ensure files/cpz-tab-new files/cpz-tab-close \
	files/cpz-tab-close-key files/cpz-tab-mount \
	files/cpz-settings-open \
	files/cpz-settings files/cpz-settings-shell files/cpz-status \
	files/cpz-apply-settings files/cpz-help files/cpz-hint \
	files/cpz-keys files/cpz-search \
	files/cpz-first-login \
	files/cpz-session-save files/cpz-session-restore \
	files/cpz-session-save-as-user files/cpz-conn-status \
	files/cpz-brightness files/cpz-font files/cpz-volume \
	files/cpz-keyboard-layout \
	files/cpz-layout-map \
	files/cpz-layout-next files/cpz-layout-apply files/cpz-display-toggle \
	files/cpz-automount files/cpz-battery \
	"${ROOTFS_DIR}/usr/local/bin/"
install -d -m 0755 "${ROOTFS_DIR}/etc/udev/rules.d"
install -m 0644 files/99-cpz-backlight.rules files/99-cpz-keyboard.rules \
	files/99-cpz-kmscon-output.rules files/99-cpz-kmscon-nudge.rules \
	files/99-cpz-automount.rules \
	"${ROOTFS_DIR}/etc/udev/rules.d/"
install -m 0644 files/cpz-keyboard-layout.service \
	files/cpz-keyboard-layout.path \
	files/cpz-automount@.service \
	files/cpz-battery-guard.service \
	"${ROOTFS_DIR}/etc/systemd/system/"

# USB filesystems are mounted here by cpz-automount/99-cpz-automount.rules.
install -d -m 0755 "${ROOTFS_DIR}/media"

# kmscon uses libxkbcommon, not the VT keymap, so the TCA8418 Sym/Fn overlay
# needs an XKB layout. cpz-kmscon-config selects this layout while the internal
# keyboard is active; an external keyboard keeps the standard layout.
install -d -m 0755 "${ROOTFS_DIR}/usr/share/X11/xkb/symbols"
install -m 0644 files/xkb/symbols/cpz \
	"${ROOTFS_DIR}/usr/share/X11/xkb/symbols/cpz"
# cpz-keyboard-layout generates one CPZ layout per selected language
# (cpz_us, cpz_ua, ...) from this template so systemd-localed can change the
# live kmscon keymap without restarting the session. cpz_us is also installed
# as a first-boot fallback before the helper has run.
install -m 0644 files/xkb/symbols/cpz \
	"${ROOTFS_DIR}/usr/share/X11/xkb/symbols/cpz_us"
install -d -m 0755 "${ROOTFS_DIR}/usr/local/share/cpz/xkb"
install -m 0644 files/xkb/symbols/cpz \
	"${ROOTFS_DIR}/usr/local/share/cpz/xkb/cpz.template"

# xkb-data does not name the keycode the Sym layer uses for ">" (Linux
# KEY_ZENKAKUHANKAKU, XKB keycode 93). Name it so symbols/cpz can map it. The
# image masks automatic xkb-data upgrades, so this stays in place.
keycodes="${ROOTFS_DIR}/usr/share/X11/xkb/keycodes/evdev"
if [ -f "$keycodes" ] && ! grep -q '<ZENK>' "$keycodes"; then
	if grep -q '<HKTG> = 101;' "$keycodes"; then
		sed -i '/<HKTG> = 101;/i\
	<ZENK> = 93;' "$keycodes"
	else
		echo "stage3: xkb-data evdev keycodes changed; cannot add <ZENK>" >&2
		exit 1
	fi
fi
install -d -m 0755 "${ROOTFS_DIR}/etc/cpz/themes"
install -m 0644 files/settings.conf "${ROOTFS_DIR}/etc/cpz/settings.conf"
# Low-battery policy for cpz-battery / cpz-battery-guard.service.
install -m 0644 files/battery.conf "${ROOTFS_DIR}/etc/cpz/battery.conf"
# cpz-settings warns while the factory password is unchanged. It cannot read
# /etc/shadow, so record the image's mtime here; passwd/usermod/chage all
# update it, which is enough to clear the warning after a password change.
stat -c %Y "${ROOTFS_DIR}/etc/shadow" >"${ROOTFS_DIR}/etc/cpz/shadow-mtime"
install -m 0644 files/themes/*.conf files/themes/*.palette \
	"${ROOTFS_DIR}/etc/cpz/themes/"

# Terminal Trove catalog snapshot. Applications reads this local index, so
# discovery works without the network. Settings can refresh it later. The
# index is built by the separate terminal-trove-index project.
trove_url="${CPZ_TROVE_INDEX_URL:-https://raw.githubusercontent.com/jmas/terminal-trove-index/main/index/trove.json.gz}"
install -d -m 0755 "${ROOTFS_DIR}/etc/cpz" "${ROOTFS_DIR}/usr/share/cpz"
printf '%s\n' "$trove_url" >"${ROOTFS_DIR}/etc/cpz/trove-index.url"
if [ -n "$trove_url" ]; then
	trove_tmp="$(mktemp)"
	if curl --fail --location --silent --show-error --retry 3 --max-time 120 \
		--max-filesize 20971520 "$trove_url" -o "$trove_tmp"; then
		if gzip -t "$trove_tmp" 2>/dev/null; then
			gzip -dc "$trove_tmp" >"${ROOTFS_DIR}/usr/share/cpz/trove-index.json"
		else
			cp "$trove_tmp" "${ROOTFS_DIR}/usr/share/cpz/trove-index.json"
		fi
		chmod 0644 "${ROOTFS_DIR}/usr/share/cpz/trove-index.json"
		if ! grep -q '"tools"' "${ROOTFS_DIR}/usr/share/cpz/trove-index.json"; then
			echo "stage3: invalid Terminal Trove index; removing snapshot" >&2
			rm -f "${ROOTFS_DIR}/usr/share/cpz/trove-index.json"
		fi
	else
		echo "stage3: warning: cannot download Terminal Trove index from $trove_url" >&2
	fi
	rm -f "$trove_tmp"
fi
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

# Alt+Space switches console layouts by default (rebindable in Settings >
# Keyboard > Shortcuts); allow only the keymap reload helper to run without a
# password prompt.
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

# tty2/tty3 keep a plain fbcon console-setup font for recovery logins. The
# kmscon session on tty1 does not use it (FreeType, Terminus OTB), but 6x12 is
# the smallest readable cell on the 320x170 panel.
console_setup="${ROOTFS_DIR}/etc/default/console-setup"
if [ -f "$console_setup" ]; then
	sed -i \
		's/^FONTFACE=.*/FONTFACE="Terminus"/;s/^FONTSIZE=.*/FONTSIZE="6x12"/' \
		"$console_setup"
fi

# The CardputerZero TCA8418 driver emits different keycodes for the Sym/Fn
# layers. The vendor loadkeys map is installed by the hardware stage but was
# never applied; it stays active on the fbcon recovery consoles.
install -m 0644 files/cardputerzero-keymap.service \
	"${ROOTFS_DIR}/etc/systemd/system/cardputerzero-keymap.service"

# kmscon owns tty1. The wrapper renders /run/cpz-kmscon/kmscon.conf from the
# CPZ settings and starts the autologin session through login(1).
install -d -m 0755 \
	"${ROOTFS_DIR}/etc/systemd/system/kmsconvt@.service.d"
install -m 0644 files/kmsconvt@.service.d/10-cpz.conf \
	"${ROOTFS_DIR}/etc/systemd/system/kmsconvt@.service.d/10-cpz.conf"

# One working output: HDMI when a usable monitor is attached, otherwise the
# internal panel. The reconciler restarts kmscon when the decision or the
# rendered configuration changes and switches the panel backlight off while
# HDMI is active.
install -m 0644 files/cpz-kmscon-output.service files/cpz-kmscon-output.timer \
	"${ROOTFS_DIR}/etc/systemd/system/"
install -d -m 0755 "${ROOTFS_DIR}/etc/systemd/system-sleep"
install -m 0755 files/cpz-kmscon-sleep \
	"${ROOTFS_DIR}/etc/systemd/system-sleep/cpz-kmscon"

# userconf-pi's cancel-rename enables getty/LightDM autologin for Raspberry Pi
# OS. CPZ installs its own kmscon autologin above; keep only the SSH/rename
# bookkeeping so an rpi-preseed rename does not undo the CPZ session.
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
systemctl enable cpz-battery-guard.service
systemctl enable cpz-keyboard-layout.path
systemctl enable cpz-kmscon-output.timer
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

# Apply the 6x12 recovery-console font at boot.
systemctl enable console-setup.service 2>/dev/null || true
setupcon --force --save-only 2>/dev/null || true

# Fail the build early on a malformed sudoers drop-in.
visudo -cf /etc/sudoers.d/50-cpz-layout

# Snapshot apt package names before export-image deletes /var/lib/apt/lists.
# Applications uses this offline snapshot to default to apt-backed tools.
if command -v apt-cache >/dev/null 2>&1; then
	install -d -m 0755 /usr/share/cpz
	{
		apt-cache pkgnames 2>/dev/null || true
		dpkg-query -W -f='${Package}\n' 2>/dev/null || true
	} | LC_ALL=C sort -u | gzip -9 > /usr/share/cpz/apt-packages.txt.gz
	chmod 0644 /usr/share/cpz/apt-packages.txt.gz
fi

systemctl daemon-reload || true
CHROOT
