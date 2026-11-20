#!/bin/bash -e

# Install the CPZ graphics session (cage + foot + tmux).

install -d -m 0755 "${ROOTFS_DIR}/usr/local/bin"
install -m 0755 files/cpz-cage files/cpz-cage-output files/cpz-cage-session \
	files/cpz-session-supervise files/cpz-open files/cpz-music \
	files/cpz-media-keys files/cpz-track files/cpz-idle files/cpz-lock \
	files/cpz-panel-backlight \
	files/cpz-foot-config files/cpz-foot-reload \
	files/cpz-getty files/cpz-getty-prepare files/cpz-run \
	files/cpz-tmux files/cpz-tmux-start \
	files/cpz-pointer files/cpz-i18n \
	"${ROOTFS_DIR}/usr/local/bin/"

install -d -m 0755 "${ROOTFS_DIR}/etc/profile.d"
install -m 0644 files/cpz-session.sh files/10-cpz-locale.sh \
	"${ROOTFS_DIR}/etc/profile.d/"

# cage has no pointer-acceleration setting; this LD_PRELOAD shim applies
# Settings > Input > Mouse Speed to every libinput device. The source is
# installed here and compiled in the chroot below, while the toolchain from
# stage2 is still present (stage3/03-cleanup removes it from the image).
install -d -m 0755 "${ROOTFS_DIR}/usr/local/lib" \
	"${ROOTFS_DIR}/usr/local/share/cpz"
install -m 0644 files/cpz-pointer-speed.c \
	"${ROOTFS_DIR}/usr/local/share/cpz/cpz-pointer-speed.c"
install -m 0644 files/cpz-xkb-layout.c \
	"${ROOTFS_DIR}/usr/local/share/cpz/cpz-xkb-layout.c"

# Wi-Fi is intentionally soft-blocked in the factory image and is enabled
# from Settings. The stock login-shell check then prints "Wi-Fi is currently
# blocked by rfkill" and points at raspi-config, which is not part of the CPZ
# UI. Remove the warning instead of showing it on every login.
rm -f "${ROOTFS_DIR}/etc/profile.d/wifi-check.sh"

# SSH recovery: the first user can log in with FIRST_USER_PASS. The drop-in
# wins over the main sshd_config because Debian includes this directory first.
install -d -m 0755 "${ROOTFS_DIR}/etc/ssh/sshd_config.d"
install -m 0644 files/10-ssh.conf \
	"${ROOTFS_DIR}/etc/ssh/sshd_config.d/10-cpz.conf"
install -d -m 0755 "${ROOTFS_DIR}/usr/lib/tmpfiles.d"
install -m 0644 files/cpz-cage.tmpfiles \
	"${ROOTFS_DIR}/usr/lib/tmpfiles.d/cpz-cage.conf"

install -m 0644 files/tmux.conf "${ROOTFS_DIR}/etc/tmux.conf"

# Midnight Commander keeps the menu bar, key bar and hint bar hidden by
# default: on the small display those three rows are more useful as file
# listings. mc reads /etc/mc/mc.ini until the user has ~/.config/mc/ini.
# The skin is palette-based so it follows the CPZ theme selected in Settings.
install -d -m 0755 "${ROOTFS_DIR}/etc/mc/skins"
install -m 0644 files/mc.ini "${ROOTFS_DIR}/etc/mc/mc.ini"
install -m 0644 files/mc-skin.ini "${ROOTFS_DIR}/etc/mc/skins/cpz.ini"

# /tmp is disk-backed because tmp.mount is masked in 02-run.sh.
install -d -m 1777 "${ROOTFS_DIR}/tmp"

# Status bar, Settings TUI and tab/session helpers.
install -m 0755 \
	files/cpz-session-ensure files/cpz-tab-new files/cpz-tab-close \
	files/cpz-tab-close-key files/cpz-tab-mount files/cpz-tab-cycle \
	files/cpz-settings-open \
	files/cpz-settings files/cpz-settings-shell files/cpz-status \
	files/cpz-wifi files/cpz-bt files/cpz-bt-unblock \
	files/cpz-apply-settings files/cpz-help files/cpz-hint \
	files/cpz-keys files/cpz-search \
	files/cpz-first-login files/cpz-first-login-popup \
	files/cpz-session-save files/cpz-session-restore \
	files/cpz-session-save-as-user files/cpz-conn-status \
	files/cpz-brightness files/cpz-font files/cpz-volume \
	files/cpz-keyboard-layout \
	files/cpz-layout-map \
	files/cpz-layout-next files/cpz-layout-apply files/cpz-display-toggle \
	files/cpz-automount files/cpz-battery \
	files/cpz-locale-apply \
	"${ROOTFS_DIR}/usr/local/bin/"
install -d -m 0755 "${ROOTFS_DIR}/etc/udev/rules.d"
install -m 0644 files/99-cpz-backlight.rules files/99-cpz-keyboard.rules \
	files/99-cpz-cage-output.rules files/99-zz-cpz-input.rules \
	files/99-cpz-automount.rules \
	"${ROOTFS_DIR}/etc/udev/rules.d/"
# libinput quirks: the internal keyboard and the vc4 HDMI CEC node must never
# advertise pointer capability, even if a udev rule restores an ID_INPUT_* tag.
# libinput reads this file once per context, so it has to be in the image.
install -d -m 0755 "${ROOTFS_DIR}/etc/libinput"
install -m 0644 files/60-cpz-phantom-pointer.quirks \
	"${ROOTFS_DIR}/etc/libinput/local-overrides.quirks"
install -m 0644 files/cpz-keyboard-layout.service \
	files/cpz-keyboard-layout.path \
	files/cpz-automount@.service \
	files/cpz-battery-guard.service \
	"${ROOTFS_DIR}/etc/systemd/system/"

# USB filesystems are mounted here by cpz-automount/99-cpz-automount.rules.
install -d -m 0755 "${ROOTFS_DIR}/media"

# cage, foot and the applications use libxkbcommon, not the VT keymap, so the
# TCA8418 Sym/Fn overlay needs an XKB layout. cpz-cage reads the layout that
# cpz-keyboard-layout published to systemd-localed; an external keyboard keeps
# the standard layout.
install -d -m 0755 "${ROOTFS_DIR}/usr/share/X11/xkb/symbols"
install -m 0644 files/xkb/symbols/cpz \
	"${ROOTFS_DIR}/usr/share/X11/xkb/symbols/cpz"
# cpz-keyboard-layout generates one CPZ layout per selected language
# (cpz_us, cpz_ua, ...) from this template so systemd-localed publishes the
# layout cage reads at startup. cpz_us is also installed as a first-boot
# fallback before the helper has run.
install -m 0644 files/xkb/symbols/cpz \
	"${ROOTFS_DIR}/usr/share/X11/xkb/symbols/cpz_us"
install -d -m 0755 "${ROOTFS_DIR}/usr/local/share/cpz/xkb"
install -m 0644 files/xkb/symbols/cpz \
	"${ROOTFS_DIR}/usr/local/share/cpz/xkb/cpz.template"

# xkb-data does not name the keycode the Sym layer uses for ">" (Linux
# KEY_ZENKAKUHANKAKU, XKB keycode 93). Name it so symbols/cpz can map it. The
# image also pins xkb-data (99-cpz-xkb-data.pref) so an in-place apt upgrade
# cannot replace this file and silently break Sym+Shift.
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
install -d -m 0755 "${ROOTFS_DIR}/etc/apt/preferences.d"
install -m 0644 files/99-cpz-xkb-data.pref \
	"${ROOTFS_DIR}/etc/apt/preferences.d/99-cpz-xkb-data.pref"
install -d -m 0755 "${ROOTFS_DIR}/usr/share/cpz/i18n"
install -m 0644 files/i18n/*.json \
	"${ROOTFS_DIR}/usr/share/cpz/i18n/"
install -d -m 0755 "${ROOTFS_DIR}/etc/cpz/themes"
install -m 0644 files/settings.conf "${ROOTFS_DIR}/etc/cpz/settings.conf"

# cage is the only session. One DRM card at a time; the output helper switches
# between the SPI panel and HDMI with a serialized session restart.
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
#
# Builds must stay usable offline: CPZ_OFFLINE=1 (or an explicit
# CPZ_TROVE_INDEX_URL=none) skips the download instead of waiting for the
# 120 s timeout. Settings can fetch the catalog later on the device.
trove_default="https://raw.githubusercontent.com/jmas/terminal-trove-index/main/index/trove.json.gz"
trove_url="${CPZ_TROVE_INDEX_URL:-$trove_default}"
trove_download=1
case "$trove_url" in
	none | off | 0 | '')
		# Keep the hosted URL in the image so Settings can refresh later.
		trove_url=$trove_default
		trove_download=0
		;;
esac
case "${CPZ_OFFLINE:-0}" in
	1 | yes | on | true) trove_download=0 ;;
esac
install -d -m 0755 "${ROOTFS_DIR}/etc/cpz" "${ROOTFS_DIR}/usr/share/cpz"
printf '%s\n' "$trove_url" >"${ROOTFS_DIR}/etc/cpz/trove-index.url"
if [ "$trove_download" = 1 ]; then
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
	files/cpz-pointer.service files/cpz-pointer.path \
	files/cpz-pointer-cursor.service files/cpz-media-keys.service \
	files/cpz-idle.service \
	"${ROOTFS_DIR}/etc/systemd/system/"

# wifitui is the Wi-Fi manager behind Settings > Connections. It is not in
# Debian, so install the pinned upstream arm64 package from files/:
# https://github.com/shazow/wifitui/releases/tag/v0.13.0
# sha256 f256030840f2d009f004dd346bf1f8eb0746c91d4cd2baed6cd156d37ff2aa96
# The package contains a self-contained static Go binary and declares no
# dependencies; the separate LICENSE file satisfies its MIT notice.
install -m 0644 files/wifitui_0.13.0_arm64.deb \
	"${ROOTFS_DIR}/tmp/wifitui_0.13.0_arm64.deb"
on_chroot <<'CHROOT'
dpkg -i /tmp/wifitui_0.13.0_arm64.deb
rm -f /tmp/wifitui_0.13.0_arm64.deb
CHROOT
install -d -m 0755 "${ROOTFS_DIR}/usr/share/doc/wifitui"
install -m 0644 files/wifitui.LICENSE \
	"${ROOTFS_DIR}/usr/share/doc/wifitui/copyright"
install -m 0644 files/wifitui-theme.toml \
	"${ROOTFS_DIR}/usr/local/share/cpz/wifitui-theme.toml"

# bluetuith is the BlueZ manager behind Settings > Connections. The upstream
# Linux arm64 release is a self-contained static binary; extract only that
# file from the pinned tarball and keep the MIT notice next to it.
# https://github.com/bluetuith-org/bluetuith/releases/tag/v0.2.7
# sha256 81ec8bdbdf18ddabff0ce5fb11f478dfa8dccbd9efc8e14583d4cbb8ef0f8d84
install -m 0644 files/bluetuith_0.2.7_Linux_arm64.tar.gz \
	"${ROOTFS_DIR}/tmp/bluetuith.tar.gz"
tar -xzf "${ROOTFS_DIR}/tmp/bluetuith.tar.gz" \
	-C "${ROOTFS_DIR}/tmp" bluetuith
install -m 0755 "${ROOTFS_DIR}/tmp/bluetuith" \
	"${ROOTFS_DIR}/usr/local/bin/bluetuith"
rm -f "${ROOTFS_DIR}/tmp/bluetuith.tar.gz" "${ROOTFS_DIR}/tmp/bluetuith"
install -d -m 0755 "${ROOTFS_DIR}/usr/share/doc/bluetuith"
install -m 0644 files/bluetuith.LICENSE \
	"${ROOTFS_DIR}/usr/share/doc/bluetuith/copyright"

# Let the netdev user manage NetworkManager (Wi-Fi) without a polkit prompt.
install -d -m 0755 "${ROOTFS_DIR}/etc/polkit-1/rules.d"
install -m 0644 files/50-cpz-networkmanager.rules \
	"${ROOTFS_DIR}/etc/polkit-1/rules.d/50-cpz-networkmanager.rules"

# Bluetooth pairing fallback for incoming Just Works requests. bluetuith
# registers its own agent for pairings it starts; this service keeps headless
# tools (bluetoothctl) usable too.
install -m 0644 files/cpz-bt-agent.service \
	"${ROOTFS_DIR}/etc/systemd/system/cpz-bt-agent.service"

# Bluetooth is off by default, like Wi-Fi: bluetoothd runs, but BlueZ does not
# power the adapter until Settings opens the shared radio manager. Without
# this, AutoEnable=true brings the radio up on every boot.
bt_conf="${ROOTFS_DIR}/etc/bluetooth/main.conf"
if [ -f "$bt_conf" ]; then
	sed -i -E 's/^[#[:space:]]*AutoEnable[[:space:]]*=.*/AutoEnable = false/' \
		"$bt_conf"
	if ! grep -q '^AutoEnable = false' "$bt_conf"; then
		if grep -q '^\[Policy\]' "$bt_conf"; then
			sed -i '/^\[Policy\]/a AutoEnable = false' "$bt_conf"
		else
			printf '\n[Policy]\nAutoEnable = false\n' >>"$bt_conf"
		fi
	fi
fi

# Alt+Space switches console layouts by default (rebindable in Settings >
# Input > Shortcuts); allow only the keymap reload helper to run without a
# password prompt.
install -d -m 0755 "${ROOTFS_DIR}/etc/sudoers.d"
install -m 0440 files/50-cpz-layout \
	"${ROOTFS_DIR}/etc/sudoers.d/50-cpz-layout"
# Settings > System > Language writes /etc/locale.conf and /etc/default/locale
# through cpz-locale-apply, which validates the language code itself.
install -m 0440 files/50-cpz-locale \
	"${ROOTFS_DIR}/etc/sudoers.d/50-cpz-locale"
# Settings > Display > Brightness needs the panel PWM helper without a prompt.
install -m 0440 files/50-cpz-backlight \
	"${ROOTFS_DIR}/etc/sudoers.d/50-cpz-backlight"
# Settings > Connections needs root to clear the rfkill soft block and turn on
# NetworkManager's radio before wifitui starts.
install -m 0440 files/50-cpz-wifi \
	"${ROOTFS_DIR}/etc/sudoers.d/50-cpz-wifi"
# The Bluetooth manager only needs root to clear its own rfkill soft block.
install -m 0440 files/50-cpz-bt \
	"${ROOTFS_DIR}/etc/sudoers.d/50-cpz-bt"

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
		"$user_config/systemd/user" "$user_config/cpz" \
		"$user_config/bluetuith"
	chown 1000:1000 "$user_config" "$user_config/systemd" \
		"$user_config/systemd/user" "$user_config/cpz" \
		"$user_config/bluetuith"

	# Compact bluetuith: no underlined help footer and q quits. bluetuith has
	# no /etc lookup, so the config belongs to the first user.
	install -m 0644 -o 1000 -g 1000 files/bluetuith.conf \
		"$user_config/bluetuith/bluetuith.conf"

	# Minimal media players for mc/lf: imv for images, mpv for video and
	# cmus for music. The configs keep the viewers on the software Wayland
	# path cage can scan out and make q leave the TUI player.
	install -d -m 0755 "$user_config/lf" "$user_config/mpv" "$user_config/imv" \
		"$user_config/cmus"
	chown 1000:1000 "$user_config/lf" "$user_config/mpv" "$user_config/imv" \
		"$user_config/cmus"
	install -m 0644 -o 1000 -g 1000 files/lfrc "$user_config/lf/lfrc"
	install -m 0644 -o 1000 -g 1000 files/mpv.conf "$user_config/mpv/mpv.conf"
	install -m 0644 -o 1000 -g 1000 files/imv-config "$user_config/imv/config"
	install -m 0644 -o 1000 -g 1000 files/cmus-rc "$user_config/cmus/rc"
fi

# tty2/tty3 keep a plain fbcon console-setup font for recovery logins. The
# graphics session on tty1 does not use it (foot uses Terminus OTB), but 6x12 is
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

# cage owns tty1. The tmux server is a separate unit so a compositor restart
# keeps the session; foot attaches as the terminal client.
install -m 0644 files/cpz-tmux.service \
	"${ROOTFS_DIR}/etc/systemd/system/"
install -d -m 0755 \
	"${ROOTFS_DIR}/etc/systemd/system/getty@tty1.service.d"
install -m 0644 files/getty@tty1.service.d/10-cpz.conf \
	"${ROOTFS_DIR}/etc/systemd/system/getty@tty1.service.d/10-cpz.conf"

# One working output: HDMI when a usable monitor is attached, otherwise the
# internal panel. The reconciler writes the cage output environment, restarts
# the session only when that environment changes, replaces foot in place for a
# foot-config change, and switches the panel backlight off while HDMI is active.
install -m 0644 files/cpz-cage-output.service files/cpz-cage-output.timer \
	files/cpz-cage-output.path files/cpz-cage-output-hotplug.service \
	"${ROOTFS_DIR}/etc/systemd/system/"
install -d -m 0755 "${ROOTFS_DIR}/etc/systemd/system-sleep"
install -m 0755 files/cpz-cage-sleep \
	"${ROOTFS_DIR}/etc/systemd/system-sleep/cpz-cage"

# userconf-pi's cancel-rename enables getty/LightDM autologin for Raspberry Pi
# OS. CPZ installs its own cage session above; keep only the SSH/rename
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
systemctl enable cpz-cage-output.timer
systemctl enable cpz-cage-output.path
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
visudo -cf /etc/sudoers.d/50-cpz-locale
visudo -cf /etc/sudoers.d/50-cpz-backlight

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

# Generate the tmux key cache at build time. tmux.conf sources it, and the
# conditional cpz-keys fallback is a Python start on the boot path; the file
# is user-specific because tmux reads ~/.cache/cpz/tmux-keys.conf.
#
# install -d applies -o/-g only to the final path component and never changes
# an existing directory, so always create ~/.cache with the user's ownership
# and chown it explicitly: otherwise it stays root-owned and every XDG cache
# consumer fails, starting with mc ("Cannot create .../.cache/mc directory").
first_home=$(getent passwd 1000 | cut -d: -f6 || true)
if [ -n "$first_home" ]; then
	install -d -m 0755 -o 1000 -g 1000 "$first_home/.cache"
	chown 1000:1000 "$first_home/.cache"
	if [ -x /usr/local/bin/cpz-keys ]; then
		install -d -m 0755 -o 1000 -g 1000 "$first_home/.cache/cpz"
		HOME="$first_home" /usr/local/bin/cpz-keys write >/dev/null 2>&1 || true
		chown -R 1000:1000 "$first_home/.cache" 2>/dev/null || true
	fi
fi

systemctl daemon-reload || true
CHROOT

# Build the LD_PRELOAD shims while build-essential is still in the image.
on_chroot << 'CHROOT'
set -e
cc -O2 -fPIC -shared -Wall -Wextra \
	-o /usr/local/lib/cpz-pointer-speed.so \
	/usr/local/share/cpz/cpz-pointer-speed.c -ldl
chmod 0644 /usr/local/lib/cpz-pointer-speed.so
rm -f /usr/local/share/cpz/cpz-pointer-speed.c
cc -O2 -fPIC -shared -Wall -Wextra \
	-o /usr/local/lib/cpz-xkb-layout.so \
	/usr/local/share/cpz/cpz-xkb-layout.c -ldl
chmod 0644 /usr/local/lib/cpz-xkb-layout.so
rm -f /usr/local/share/cpz/cpz-xkb-layout.c
CHROOT
