#!/bin/bash -e

# Boot and service policy for the kmscon CPZ session.
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

append_cmdline_file() {
	local file="$1" source="$2"
	[ -f "$file" ] && [ -f "$source" ] || return 0
	local line token
	line=$(tr '\n' ' ' <"$file" | sed 's/[[:space:]]*$//')
	for token in $(sed -e 's/#.*//' "$source"); do
		case " $line " in
			*" $token "*) ;;
			*) line="${line} ${token}" ;;
		esac
	done
	printf '%s\n' "$line" >"$file"
}

append_config_file "${ROOTFS_DIR}/boot/firmware/config.txt" \
	files/config.txt.append
append_cmdline_file "${ROOTFS_DIR}/boot/firmware/cmdline.txt" \
	files/cmdline.append

# Debug boot: keep kmscon out of the way and show a verbose console on the
# panel/HDMI plus serial. This is the image to use when the normal kmscon
# session produces a black screen.
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
		printf '%s\n' "console=serial0,115200 console=tty1 loglevel=8 ignore_loglevel systemd.show_status=1 systemd.log_level=debug" >"$debug_line"
		append_cmdline_file "$cmdline" "$debug_line"
		rm -f "$debug_line"
	fi

	install -m 0644 /dev/null "${ROOTFS_DIR}/etc/cpz-debug-boot"
	echo "stage-cpz: CPZ_DEBUG_BOOT=1 (splash off, verbose console, kmscon masked)"
fi

# Never ship a preseed file; Imager writes the user's one at flash time.
rm -f "${ROOTFS_DIR}/boot/firmware/rpi-preseed.toml"

on_chroot <<'CHROOT'
set -e
export DEBIAN_FRONTEND=noninteractive

# cloud-init is not part of this branch and conflicts with rpi-preseed; purge
# it defensively when reusing an older rootfs.
if dpkg -s cloud-init >/dev/null 2>&1 || dpkg -s rpi-cloud-init-mods >/dev/null 2>&1; then
	apt-get purge -y cloud-init rpi-cloud-init-mods || true
fi
rm -rf /etc/cloud /var/lib/cloud

# Desktop/launcher leftovers from the old image path. Those stages are removed
# from this branch, but keep this defensive for image reuse and upgrades.
for pkg in applaunch packagekit packagekit-tools cups cups-browsed lightdm; do
	if dpkg -s "$pkg" >/dev/null 2>&1; then
		apt-get purge -y "$pkg" || true
	fi
done
apt-get autoremove -y --purge || true

# kmscon is the only login surface on tty1. tty2 keeps a visible recovery
# login through kmscon as well; fbcon is mapped off for the panel.
systemctl set-default multi-user.target

if [ -f /etc/cpz-debug-boot ]; then
	# Debug image: do not start kmscon. Keep tty1/tty2 as visible getty
	# consoles so the kernel/systemd log and a login prompt are available.
	systemctl disable kmsconvt@tty1.service kmsconvt@tty2.service || true
	systemctl mask kmsconvt@tty1.service kmsconvt@tty2.service || true
	systemctl unmask getty@tty1.service getty@tty2.service || true
	systemctl enable getty@tty1.service getty@tty2.service || true
else
	systemctl disable getty@tty1.service || true
	systemctl disable getty@tty2.service || true
	systemctl enable kmsconvt@tty1.service
	systemctl enable kmsconvt@tty2.service
	systemctl add-wants multi-user.target kmsconvt@tty1.service
	systemctl add-wants multi-user.target kmsconvt@tty2.service
	systemctl mask getty@tty1.service || true
fi

# The old first-boot wizard belongs to Raspberry Pi OS. rpi-preseed handles
# account/network setup on this image.
systemctl disable userconfig.service || true
systemctl mask userconfig.service || true
rm -f /etc/xdg/autostart/piwiz.desktop

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
