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

# Never ship a preseed file; Imager writes the user's one at flash time.
rm -f "${ROOTFS_DIR}/boot/firmware/rpi-preseed.toml"

on_chroot <<'CHROOT'
set -e
export DEBIAN_FRONTEND=noninteractive

# cloud-init conflicts with rpi-preseed and is not part of the CPZ boot path.
if dpkg -s cloud-init >/dev/null 2>&1 || dpkg -s rpi-cloud-init-mods >/dev/null 2>&1; then
	apt-get purge -y cloud-init rpi-cloud-init-mods || true
fi
rm -rf /etc/cloud /var/lib/cloud

# Desktop/launcher leftovers from the old image path. The stage list already
# omits stage3/stage4, but keep this defensive for image reuse and upgrades.
for pkg in applaunch packagekit packagekit-tools cups cups-browsed lightdm; do
	if dpkg -s "$pkg" >/dev/null 2>&1; then
		apt-get purge -y "$pkg" || true
	fi
done
apt-get autoremove -y --purge || true

# kmscon is the only login surface on tty1. tty2 keeps a visible recovery
# login through kmscon as well; fbcon is mapped off for the panel.
systemctl set-default multi-user.target
systemctl enable kmsconvt@tty1.service
systemctl enable kmsconvt@tty2.service
systemctl add-wants multi-user.target kmsconvt@tty1.service
systemctl add-wants multi-user.target kmsconvt@tty2.service
systemctl mask getty@tty1.service || true
systemctl disable getty@tty2.service || true

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
