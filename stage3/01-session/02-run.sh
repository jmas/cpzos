#!/bin/bash -e

# Boot and service policy for the CPZ cage session.
#
# Hardware enablement, splash, kernel modules and boot firmware remain owned by
# stage2/05-cardputerzero. This stage only replaces the login/UI surface.

append_config_file() {
	local file="$1" source="$2"
	[ -f "$file" ] && [ -f "$source" ] || return 0
	local line
	while IFS= read -r line; do
		case "$line" in
			''|'#'*) continue ;;
		esac
		grep -qxF "$line" "$file" || printf '%s\n' "$line" >>"$file"
	done <"$source"
}

remove_cmdline_tokens() {
	local file="$1"
	shift
	[ -f "$file" ] || return 0
	local token drop out=""
	for token in $(tr '\n' ' ' <"$file"); do
		for drop in "$@"; do
			[ "$token" = "$drop" ] && continue 2
		done
		out="${out}${out:+ }${token}"
	done
	printf '%s\n' "$out" >"$file"
}

append_cmdline_file() {
	local file="$1" source="$2"
	[ -f "$file" ] && [ -f "$source" ] || return 0
	local line token
	line=$(tr '\n' ' ' <"$file" | sed 's/[[:space:]]*$//')
	# shellcheck disable=SC2013  # kernel cmdline tokens are whitespace-separated
	for token in $(sed -e 's/#.*//' "$source"); do
		case " $line " in
			*" $token "*) ;;
			*) line="${line} ${token}" ;;
		esac
	done
	printf '%s\n' "$line" >"$file"
}

remove_cmdline_prefix() {
	local file="$1" prefix="$2"
	[ -f "$file" ] || return 0
	local token out=""
	for token in $(tr '\n' ' ' <"$file"); do
		case "$token" in
			"$prefix"*) continue ;;
		esac
		out="${out}${out:+ }${token}"
	done
	printf '%s\n' "$out" >"$file"
}

append_config_file "${ROOTFS_DIR}/boot/firmware/config.txt" \
	files/config.txt.append
remove_cmdline_tokens "${ROOTFS_DIR}/boot/firmware/cmdline.txt" \
	console=serial0,115200 splash plymouth.ignore-serial-consoles
append_cmdline_file "${ROOTFS_DIR}/boot/firmware/cmdline.txt" \
	files/cmdline.append

# The regulatory domain has exactly one source: WPA_COUNTRY. A hardcoded
# default here would silently override the country selected at build time and
# can enable channels that are not legal in the user's region.
cmdline="${ROOTFS_DIR}/boot/firmware/cmdline.txt"
remove_cmdline_prefix "$cmdline" "cfg80211.ieee80211_regdom="
if [ -n "${WPA_COUNTRY:-}" ]; then
	regdom=$(printf '%s' "$WPA_COUNTRY" | tr '[:lower:]' '[:upper:]')
	case "$regdom" in
		[A-Z][A-Z]) ;;
		*)
			echo "stage3: invalid WPA_COUNTRY '$WPA_COUNTRY'" >&2
			echo "stage3: expected an ISO 3166-1 alpha-2 code, e.g. US or GB" >&2
			exit 1
			;;
	esac
	regdom_file=$(mktemp)
	printf 'cfg80211.ieee80211_regdom=%s\n' "$regdom" >"$regdom_file"
	append_cmdline_file "$cmdline" "$regdom_file"
	rm -f "$regdom_file"
fi

# Optional stable HDMI mode. Some Dell monitors renegotiate or expose a
# fallback mode after standby; pinning the mode avoids the renegotiation.
if [ -n "${CPZ_HDMI_VIDEO:-}" ]; then
	valid=1
	case "$CPZ_HDMI_VIDEO" in
		*[!A-Za-z0-9_.:@x-]*) valid=0 ;;
		*:D | *:d) valid=0 ;;
		?*:*x*) ;;
		*) valid=0 ;;
	esac
	if [ "$valid" = 0 ]; then
		echo "stage3: invalid CPZ_HDMI_VIDEO '$CPZ_HDMI_VIDEO'" >&2
		echo "stage3: expected e.g. HDMI-A-1:1920x1080@60 (not :D)" >&2
		exit 1
	fi
	cmdline="${ROOTFS_DIR}/boot/firmware/cmdline.txt"
	connector=${CPZ_HDMI_VIDEO%%:*}
	remove_cmdline_prefix "$cmdline" "video=${connector}:"
	printf 'video=%s\n' "$CPZ_HDMI_VIDEO" \
		>"${STAGE_WORK_DIR}/cpz-hdmi-video"
	append_cmdline_file "$cmdline" "${STAGE_WORK_DIR}/cpz-hdmi-video"
fi

# Debug boot: show a verbose console on the panel/HDMI plus serial. This is
# the image to use when the normal cage session produces a black screen.
if [ "${CPZ_DEBUG_BOOT:-0}" = "1" ]; then
	config="${ROOTFS_DIR}/boot/firmware/config.txt"
	cmdline="${ROOTFS_DIR}/boot/firmware/cmdline.txt"

	if [ -f "$config" ]; then
		sed -i '/^[[:space:]]*splash_screen=/d' "$config"
		sed -i '/^[[:space:]]*disable_splash=/d' "$config"
		sed -i '1i disable_splash=1' "$config"
	fi
	rm -f "${ROOTFS_DIR}/boot/firmware/splash.bmp" \
		"${ROOTFS_DIR}/boot/firmware/CardputerZero_splash_custom.bin"

	if [ -f "$cmdline" ]; then
		awk '
			{
				out = ""
				for (i = 1; i <= NF; i++) {
					if ($i != "quiet" &&
					    $i != "fbcon=map:off" &&
					    $i != "loglevel=3" &&
					    $i != "vt.global_cursor_default=0" &&
					    $i != "logo.nologo")
						out = out (out == "" ? "" : " ") $i
				}
				print out
			}
		' "$cmdline" > "${cmdline}.tmp"
		mv "${cmdline}.tmp" "$cmdline"
		debug_line=$(mktemp)
		printf '%s\n' "fbcon=map:10 consoleblank=0 console=serial0,115200 console=tty1 loglevel=8 ignore_loglevel systemd.show_status=1 systemd.log_level=debug" >"$debug_line"
		append_cmdline_file "$cmdline" "$debug_line"
		rm -f "$debug_line"
	fi

	install -m 0644 /dev/null "${ROOTFS_DIR}/etc/cpz-debug-boot"
	echo "stage3: CPZ_DEBUG_BOOT=1 (splash off, verbose console, no autologin)"
fi

# Never ship a preseed file; Imager writes the user's one at flash time.
rm -f "${ROOTFS_DIR}/boot/firmware/rpi-preseed.toml"

on_chroot <<'CHROOT'
set -e

# cage owns the DRM console on tty1. The normal image has no panel fbdev node
# and boots with fbcon=map:off, so tty2/tty3 gettys are kept only as a fallback;
# they are not drawn unless fbcon is bound again. SSH/serial and the debug
# image are the primary recovery paths.
systemctl set-default multi-user.target

if [ -f /etc/cpz-debug-boot ]; then
	# Debug image: keep tty1/tty2 as visible getty consoles so the
	# kernel/systemd log and a login prompt are available. The debug build
	# keeps the panel fbdev and uses fbcon=map:10, so these consoles appear
	# on the panel. The cage session must not take the VT, otherwise the logs
	# would be hidden.
	systemctl disable cpz-tmux.service 2>/dev/null || true
	systemctl mask cpz-tmux.service || true
	systemctl disable cpz-cage-output.timer cpz-cage-output.path 2>/dev/null || true
	systemctl unmask getty@tty1.service getty@tty2.service getty@tty3.service || true
	systemctl enable getty@tty1.service getty@tty2.service getty@tty3.service || true
	systemctl enable console-setup.service 2>/dev/null || true
else
	# The tty1 getty starts the login session that cpz-cage replaces; the
	# tmux server is independent. tty2/tty3 stay plain getty fallbacks; with
	# fbcon=map:off they have no visible console.
	systemctl unmask getty@tty1.service || true
	systemctl enable getty@tty1.service
	systemctl enable cpz-tmux.service
	systemctl enable cpz-pointer.service cpz-pointer.path
	# Headphone volume buttons are plain evdev keys that cage never
	# forwards to foot; a small user daemon turns them into wpctl calls.
	systemctl enable cpz-media-keys.service
	systemctl unmask getty@tty2.service getty@tty3.service || true
	systemctl enable getty@tty2.service getty@tty3.service
	# tty2/tty3 are not drawn while fbcon=map:off, and foot renders with
	# fontconfig and XKB. setupcon/loadkeys at boot only delay the graphical
	# path; the debug image keeps them for the visible fbcon consoles.
	# cpz-keyboard-layout still loads the recovery keymap for tty2/tty3.
	systemctl disable console-setup.service keyboard-setup.service \
		2>/dev/null || true
fi

# The normal image must not start the fbcon setup services even if a package
# recreated their enablement links. The debug image keeps both for its
# visible consoles.
if [ ! -f /etc/cpz-debug-boot ]; then
	rm -f \
		/etc/systemd/system/multi-user.target.wants/console-setup.service \
		/etc/systemd/system/sysinit.target.wants/keyboard-setup.service
fi

# /tmp is a tmpfs sized from RAM by systemd. On the small-RAM CM0 the default
# limit (~177M) is too small for npm/opencode and raising it consumes RAM,
# which leads to OOM/watchdog resets. Keep /tmp on the root filesystem.
systemctl mask tmp.mount || true

# rpi-preseed owns account/network setup on this image.
systemctl disable userconfig.service || true

systemctl mask userconfig.service || true

# NetworkManager is the Wi-Fi backend used by wifitui (Settings > Connections).
systemctl enable NetworkManager.service 2>/dev/null || true

# Boot budget: do not block or wake for network, package or man-page work.
systemctl mask NetworkManager-wait-online.service || true
systemctl mask apt-daily.timer apt-daily-upgrade.timer man-db.timer || true
systemctl mask unattended-upgrades.service || true

# rpi-preseed reads /boot/firmware/rpi-preseed.toml, applies it once and then
# leaves /var/lib/rpi-preseed/applied.
systemctl enable rpi-preseed.service || true
systemctl enable rpi-preseed-runcmd-early.service || true
systemctl enable rpi-preseed-runcmd-late.service || true

systemctl daemon-reload || true
CHROOT

# The fast build path reuses a cached stage2 rootfs, which may have been built
# with ENABLE_SSH=0. Enable it here from the current config so the image always
# matches the requested SSH policy.
if [ "${ENABLE_SSH}" = "1" ]; then
	on_chroot <<'CHROOT'
ssh-keygen -A 2>/dev/null || true
systemctl enable ssh 2>/dev/null || true
systemctl disable ssh.socket 2>/dev/null || true
systemctl unmask regenerate_ssh_host_keys.service 2>/dev/null || true
CHROOT
else
	on_chroot <<'CHROOT'
systemctl disable ssh ssh.socket 2>/dev/null || true
systemctl mask regenerate_ssh_host_keys.service 2>/dev/null || true
CHROOT
fi
