#!/bin/bash
# Host-side structural checks for the CPZ cage image branch.
# No root, Docker or ARM hardware required.
# shellcheck disable=SC2016  # grep patterns intentionally contain a literal $
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fail=0
pass=0

ok() { pass=$((pass + 1)); }
bad() { echo "FAIL: $*" >&2; fail=$((fail + 1)); }

have() {
	if [ -e "$ROOT/$1" ]; then ok; else bad "missing $1"; fi
}

absent() {
	if [ -e "$ROOT/$1" ]; then bad "unexpected $1"; else ok; fi
}

contains() {
	if [ -f "$ROOT/$1" ] && grep -qF -- "$2" "$ROOT/$1"; then
		ok
	else
		bad "$1 does not contain: $2"
	fi
}

not_contains() {
	if [ -f "$ROOT/$1" ] && grep -qF -- "$2" "$ROOT/$1"; then
		bad "$1 still contains: $2"
	else
		ok
	fi
}

not_in_code() {
	if [ -f "$ROOT/$1" ] &&
		grep -v '^[[:space:]]*#' "$ROOT/$1" | grep -qF -- "$2"; then
		bad "$1 still installs: $2"
	else
		ok
	fi
}

python_ok() {
	if python3 -c 'import ast, sys; ast.parse(open(sys.argv[1], encoding="utf-8").read())' \
		"$ROOT/$1"; then
		ok
	else
		bad "$1 does not parse as Python"
	fi
}

theme_ok() {
	if python3 - "$ROOT/$1" "$ROOT/$2" <<'PY'
import re
import sys

conf_path, palette_path = sys.argv[1:3]
text = open(conf_path, encoding="utf-8").read()

required_styles = {
    "status",
    "window",
    "window-active",
    "status-left",
    "status-right",
    "window-status",
    "window-status-current",
    "window-status-activity",
    "pane-border",
    "pane-active-border",
    "message",
    "message-command",
    "mode",
    "copy-mode-match",
}


def luminance(value):
    value = value.lstrip("#")
    channels = []
    for offset in (0, 2, 4):
        channel = int(value[offset:offset + 2], 16) / 255
        if channel <= 0.03928:
            channels.append(channel / 12.92)
        else:
            channels.append(((channel + 0.055) / 1.055) ** 2.4)
    return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]


def contrast(one, two):
    high, low = sorted((luminance(one), luminance(two)), reverse=True)
    return (high + 0.05) / (low + 0.05)


errors = []
styles = {}
for line in text.splitlines():
    match = re.match(r'set -g ([\w-]+)-style "([^"]*)"', line)
    if not match:
        continue
    name, spec = match.groups()
    fg = re.search(r"fg=(#[0-9a-fA-F]{6})", spec)
    bg = re.search(r"bg=(#[0-9a-fA-F]{6})", spec)
    styles[name] = (
        fg.group(1) if fg else None,
        bg.group(1) if bg else None,
    )

if not any(
    line.startswith("# name:") and line.split(":", 1)[1].strip()
    for line in text.splitlines()
):
    errors.append("missing # name")

missing = required_styles - set(styles)
if missing:
    errors.append("missing styles: " + ", ".join(sorted(missing)))


def background(name):
    _, bg = styles.get(name, (None, None))
    return bg


status_bg = background("status")
window_bg = background("window")
if not status_bg:
    errors.append("missing status background")
if not window_bg:
    errors.append("missing window background")

for name, (fg, bg) in styles.items():
    if not fg:
        continue
    if bg:
        limit, against = 4.5, bg
    elif name.startswith("status-") and status_bg:
        limit, against = 4.5, status_bg
    elif name.startswith("pane-") and window_bg:
        limit, against = 3.0, window_bg
    else:
        continue
    ratio = contrast(fg, against)
    if ratio < limit:
        errors.append(f"{name} {ratio:.2f} < {limit}")

metadata = {}
for line in text.splitlines():
    match = re.match(r"# (alert|warn)=([0-9a-fA-F]{6})$", line)
    if match:
        metadata[match.group(1)] = "#" + match.group(2)

for key in ("alert", "warn"):
    value = metadata.get(key)
    if not value:
        errors.append(f"missing # {key}")
    elif status_bg and contrast(value, status_bg) < 4.5:
        errors.append(f"{key} {contrast(value, status_bg):.2f}")

embedded = {}
for line in text.splitlines():
    match = re.match(r"# palette (\d+)=([0-9a-fA-F]{6})$", line)
    if match:
        embedded[int(match.group(1))] = match.group(2)

external = {}
with open(palette_path, encoding="utf-8") as handle:
    for line in handle:
        match = re.match(r"(\d+)=([0-9a-fA-F]{6})$", line.strip())
        if match:
            external[int(match.group(1))] = match.group(2)

if sorted(embedded) != list(range(16)) or embedded != external:
    errors.append("palette 0..15 does not match the .palette file")
elif window_bg:
    for index in range(1, 16):
        ratio = contrast("#" + embedded[index], window_bg)
        if ratio < 4.5:
            errors.append(f"palette {index} {ratio:.2f}")

if errors:
    print("; ".join(errors), file=sys.stderr)
    sys.exit(1)
PY
	then
		ok
	else
		bad "$1: theme check failed"
	fi
}

echo "== stage layout =="
for file in \
	stage3/prerun.sh \
	stage3/EXPORT_IMAGE \
	stage3/00-graphics/00-run.sh \
	stage2/04-locales/00-run.sh \
	stage3/01-session/00-packages \
	stage3/01-session/01-run.sh \
	stage3/01-session/02-run.sh \
	stage3/01-session/files/cpz-first-login \
	stage3/01-session/files/cpz-first-login-popup \
	stage3/01-session/files/cpz-cage \
	stage3/01-session/files/cpz-cage-output \
	stage3/01-session/files/cpz-cage-session \
	stage3/01-session/files/cpz-session-supervise \
	stage3/01-session/files/10-ssh.conf \
	stage3/01-session/files/cpz-cage-output.service \
	stage3/01-session/files/cpz-cage-output.timer \
	stage3/01-session/files/cpz-cage-output.path \
	stage3/01-session/files/cpz-cage-output-hotplug.service \
	stage3/01-session/files/cpz-panel-backlight \
	stage3/01-session/files/cpz-cage-sleep \
	stage3/01-session/files/cpz-cage.tmpfiles \
	stage3/01-session/files/cpz-open \
	stage3/01-session/files/cpz-music \
	stage3/01-session/files/cpz-media-keys \
	stage3/01-session/files/cpz-track \
	stage3/01-session/files/cpz-media-keys.service \
	stage3/01-session/files/lfrc \
	stage3/01-session/files/mpv.conf \
	stage3/01-session/files/imv-config \
	stage3/01-session/files/cmus-rc \
	stage3/01-session/files/cpz-pointer \
	stage3/01-session/files/cpz-pointer-speed.c \
	stage3/01-session/files/cpz-i18n \
	stage3/01-session/files/i18n/en.json \
	stage3/01-session/files/i18n/uk.json \
	stage3/01-session/files/i18n/pl.json \
	stage3/01-session/files/i18n/de.json \
	stage3/01-session/files/i18n/fr.json \
	stage3/01-session/files/i18n/es.json \
	stage3/01-session/files/i18n/it.json \
	stage3/01-session/files/i18n/pt.json \
	stage3/01-session/files/i18n/tr.json \
	stage3/01-session/files/i18n/ja.json \
	stage3/01-session/files/i18n/zh.json \
	stage3/01-session/files/cpz-pointer.service \
	stage3/01-session/files/cpz-pointer.path \
	stage3/01-session/files/cpz-pointer-cursor.service \
	stage3/01-session/files/cpz-foot-config \
	stage3/01-session/files/cpz-foot-reload \
	stage3/01-session/files/cpz-getty \
	stage3/01-session/files/cpz-getty-prepare \
	stage3/01-session/files/cpz-run \
	stage3/01-session/files/cpz-session.sh \
	stage3/01-session/files/getty@tty1.service.d/10-cpz.conf \
	stage3/01-session/files/cpz-tmux \
	stage3/01-session/files/cpz-tmux-start \
	stage3/01-session/files/cpz-tmux.service \
	stage3/01-session/files/99-cpz-cage-output.rules \
	stage3/01-session/files/99-zz-cpz-input.rules \
	stage3/01-session/files/99-cpz-automount.rules \
	stage3/01-session/files/cpz-automount \
	stage3/01-session/files/cpz-battery \
	stage3/01-session/files/cpz-battery-guard.service \
	stage3/01-session/files/battery.conf \
	stage3/01-session/files/cpz-automount@.service \
	stage3/01-session/files/tmux.conf \
	stage3/01-session/files/mc.ini \
	stage3/01-session/files/mc-skin.ini \
	stage3/01-session/files/cpz-session-ensure \
	stage3/01-session/files/cpz-tab-new \
	stage3/01-session/files/cpz-tab-close \
	stage3/01-session/files/cpz-tab-close-key \
	stage3/01-session/files/cpz-tab-mount \
	stage3/01-session/files/cpz-settings-open \
	stage3/01-session/files/cpz-settings \
	stage3/01-session/files/cpz-settings-shell \
	stage3/01-session/files/cpz-status \
	stage3/01-session/files/cpz-apply-settings \
	stage3/01-session/files/cpz-help \
	stage3/01-session/files/cpz-keys \
	stage3/01-session/files/cpz-search \
	stage3/01-session/files/cpz-session-save \
	stage3/01-session/files/cpz-session-restore \
	stage3/01-session/files/cpz-session-save-as-user \
	stage3/01-session/files/cpz-session-save.service \
	stage3/01-session/files/cpz-session-save.timer \
	stage3/01-session/files/cpz-conn-status \
	stage3/01-session/files/cpz-conn-status.service \
	stage3/01-session/files/cpz-conn-status.timer \
	stage3/01-session/files/cpz-brightness \
	stage3/01-session/files/cpz-font \
	stage3/01-session/files/cpz-volume \
	stage3/01-session/files/cpz-keyboard-layout \
	stage3/01-session/files/cpz-layout-map \
	stage3/01-session/files/cpz-layout-next \
	stage3/01-session/files/cpz-layout-apply \
	stage3/01-session/files/cpz-display-toggle \
	stage3/01-session/files/cpz-locale-apply \
	stage3/01-session/files/50-cpz-locale \
	stage3/01-session/files/10-cpz-locale.sh \
	stage3/01-session/files/50-cpz-layout \
	stage3/01-session/files/cpz-keyboard-layout.service \
	stage3/01-session/files/cpz-keyboard-layout.path \
	stage3/01-session/files/cardputerzero-keymap.service \
	stage3/01-session/files/99-cpz-backlight.rules \
	stage3/01-session/files/99-cpz-keyboard.rules \
	stage3/01-session/files/settings.conf \
	stage3/01-session/files/50-cpz-networkmanager.rules \
	stage3/01-session/files/cpz-bt-agent.service \
	stage3/01-session/files/themes/cpz-campbell.conf \
	stage3/01-session/files/cancel-rename \
	config.cpz.example \
	config.debug.example \
	docs/M5-IMAGER.md \
	docs/CPZ-KEYS.md \
	docs/APPS.md \
	tools/make-m5stack-entry.py; do
	have "$file"
done

echo "== regular image layout =="
for file in \
	stage-cpz \
	stage4 \
	stage5 \
	export-noobs \
	stage2/EXPORT_IMAGE \
	stage2/SKIP_IMAGES \
	stage2/03-accept-mathematica-eula \
	stage2/04-cloud-init \
	stage2/05-cardputerzero/03-run.sh \
	stage2/05-cardputerzero/04-run.sh \
	stage2/05-cardputerzero/files/fb-mirror.py \
	stage2/05-cardputerzero/files/fb-mirror.desktop \
	stage2/05-cardputerzero/files/template.zip \
	stage2/05-cardputerzero/files/kernel8-splash.img \
	export-image/01-user-rename \
	docs/CARDPUTERZERO-IMAGE-DESIGN.md \
	docs/CPZ-FBCON.md \
	docs/fix-firstboot-partition-expand.md \
	tools/compare-images.sh \
	tools/fix-os-list-init-format.sh; do
	absent "$file"
done

for pkg in adbd fastfetch cmatrix pulseaudio-utils python3-cairo python3-gi-cairo fonts-noto-cjk-extra; do
	not_in_code stage2/05-cardputerzero/00-packages "$pkg"
done

for script in \
	stage3/prerun.sh \
	stage3/00-graphics/00-run.sh \
	stage3/01-session/01-run.sh \
	stage3/01-session/02-run.sh \
	stage3/01-session/files/cpz-first-login \
	stage3/01-session/files/cpz-first-login-popup \
	stage3/01-session/files/cpz-cage \
	stage3/01-session/files/cpz-cage-output \
	stage3/01-session/files/cpz-cage-session \
	stage3/01-session/files/cpz-cage-sleep \
	stage3/01-session/files/cpz-pointer \
	stage3/01-session/files/cpz-i18n \
	stage3/01-session/files/cpz-foot-config \
	stage3/01-session/files/cpz-foot-reload \
	stage3/01-session/files/cpz-tmux \
	stage3/01-session/files/cpz-tmux-start \
	stage3/01-session/files/cpz-session-ensure \
	stage3/01-session/files/cpz-tab-new \
	stage3/01-session/files/cpz-tab-close \
	stage3/01-session/files/cpz-tab-close-key \
	stage3/01-session/files/cpz-tab-mount \
	stage3/01-session/files/cpz-settings-open \
	stage3/01-session/files/cpz-settings \
	stage3/01-session/files/cpz-settings-shell \
	stage3/01-session/files/cpz-status \
	stage3/01-session/files/cpz-apply-settings \
	stage3/01-session/files/cpz-help \
	stage3/01-session/files/cpz-keys \
	stage3/01-session/files/cpz-search \
	stage3/01-session/files/cpz-session-save \
	stage3/01-session/files/cpz-session-restore \
	stage3/01-session/files/cpz-session-save-as-user \
	stage3/01-session/files/cpz-conn-status \
	stage3/01-session/files/cpz-brightness \
	stage3/01-session/files/cpz-font \
	stage3/01-session/files/cpz-volume \
	stage3/01-session/files/cpz-keyboard-layout \
	stage3/01-session/files/cpz-layout-map \
	stage3/01-session/files/cpz-layout-next \
	stage3/01-session/files/cpz-layout-apply \
	stage3/01-session/files/cpz-display-toggle \
	stage3/01-session/files/cpz-battery \
	tools/verify-stage.sh \
	tools/make-m5stack-entry.py; do
	if [ -x "$ROOT/$script" ]; then ok; else bad "$script is not executable"; fi
done

echo "== old UI removed =="
absent stage2/05-cardputerzero/03-run.sh
absent stage2/05-cardputerzero/04-run.sh
absent stage2/05-cardputerzero/files/fb-mirror.py
absent stage2/05-cardputerzero/files/fb-mirror.desktop
not_in_code stage2/05-cardputerzero/02-run.sh "APPLaunch"
not_in_code stage2/05-cardputerzero/02-run.sh "LaunchWizard"
not_in_code stage2/05-cardputerzero/02-run.sh "lightdm"

echo "== boot tuning =="
contains export-image/05-finalise/01-run.sh 'MODULES=list'
contains export-image/05-finalise/01-run.sh 'COMPRESS=xz'
contains export-image/05-finalise/01-run.sh 'sdhci_of_dwcmshc'
contains export-image/05-finalise/01-run.sh 'initramfs_size'
have export-image/05-finalise/files/zz-cpz-trim
contains export-image/05-finalise/files/zz-cpz-trim 'hwdb.bin'
contains stage3/01-session/files/cardputerzero-keymap.service 'CPZ_LAYOUT_SETTLE=0'
contains stage3/01-session/files/cpz-keyboard-layout 'CPZ_LAYOUT_SETTLE'
contains stage3/01-session/02-run.sh 'disable console-setup.service'
contains stage3/01-session/files/cpz-conn-status.timer 'OnBootSec=10s'

echo "== console session =="
contains stage3/01-session/files/tmux.conf "status-position top"
contains stage3/01-session/files/tmux.conf 'client-attached'
contains stage3/01-session/files/tmux.conf 'cpz-session-ensure'
contains stage3/01-session/files/tmux.conf 'window-size largest'
contains stage3/01-session/files/tmux.conf 'cpz-keys write'
contains stage3/01-session/files/tmux.conf 'tmux-keys.conf'
not_contains stage3/01-session/files/tmux.conf 'bind -n M-'
contains stage3/01-session/files/mc.ini 'menubar_visible=false'
contains stage3/01-session/files/mc.ini 'keybar_visible=false'
contains stage3/01-session/files/mc.ini 'message_visible=false'
contains stage3/01-session/files/mc.ini 'skin=cpz'
contains stage3/01-session/files/mc-skin.ini '[skin]'
contains stage3/01-session/files/mc-skin.ini '[Lines]'
contains stage3/01-session/files/mc-skin.ini 'lefttop = ┌'
contains stage3/01-session/files/mc-skin.ini '_default_ = lightgray;black'
contains stage3/01-session/files/mc-skin.ini 'frame = blue;black'
not_contains stage3/01-session/files/mc-skin.ini 'lightgray;blue'
contains stage3/01-session/files/cpz-help 'cpz-keys help'
contains stage3/01-session/files/cpz-hint 'cpz-keys hint'
contains stage3/01-session/01-run.sh 'rm -f "${ROOTFS_DIR}/etc/profile.d/wifi-check.sh"'
contains stage3/01-session/files/cpz-first-login 'passwd'
contains stage3/01-session/files/cpz-first-login 'CPZ_PASSWORD_PROMPT_TIMEOUT'
contains stage3/01-session/files/cpz-first-login 'timeout'
contains stage3/01-session/files/cpz-first-login '--check'
contains stage3/01-session/files/cpz-first-login-popup 'display-popup'
contains stage3/01-session/files/cpz-first-login-popup 'client-attached'
contains stage3/01-session/files/tmux.conf 'cpz-first-login-popup'
contains stage3/01-session/files/cpz-tmux 'exec tmux attach-session'
not_contains stage3/01-session/files/cpz-tmux '/usr/local/bin/cpz-first-login'
contains stage3/01-session/files/cpz-conn-status.timer 'OnUnitActiveSec=30s'
contains stage3/01-session/files/cpz-session-save.timer 'OnUnitActiveSec=5min'
contains stage3/01-session/files/cpz-cage-output.timer 'OnUnitActiveSec=5s'
contains stage3/01-session/files/cpz-settings 'Text Size'
contains stage3/01-session/files/getty@tty1.service.d/10-cpz.conf 'cpz-getty'
contains stage3/01-session/files/getty@tty1.service.d/10-cpz.conf 'StartLimitIntervalSec=0'
contains stage3/01-session/files/getty@tty1.service.d/10-cpz.conf 'cpz-getty-prepare'
contains stage3/01-session/files/getty@tty1.service.d/10-cpz.conf 'RestartMaxDelaySec=60'
contains stage3/01-session/files/cpz-cage 'set -a'
contains stage3/01-session/files/cpz-cage 'export WLR_DRM_DEVICES'
contains stage3/01-session/files/cpz-cage 'export WLR_RENDERER WLR_DRM_NO_MODIFIERS'
contains stage3/01-session/files/cpz-cage-output 'restart_gap=5'
contains stage3/01-session/files/cpz-cage-output 'restart_gap_inactive=20'
contains stage3/01-session/files/cpz-cage-output 'flock -n 9'
contains stage3/01-session/files/cpz-cage-output 'logger -t cpz-cage-output --'
contains stage3/01-session/files/getty@tty1.service.d/10-cpz.conf 'ExecStartPre=-+/usr/local/bin/cpz-getty-prepare'
contains stage3/01-session/files/getty@tty1.service.d/10-cpz.conf 'Type=simple'
contains stage3/01-session/files/cpz-getty-prepare '/usr/local/bin/cpz-battery boot'
contains stage3/01-session/files/cpz-getty-prepare '/usr/local/bin/cpz-cage-output --prepare'
contains stage3/01-session/files/cpz-battery 'cpz-battery.boot-checked'
contains stage3/01-session/files/cpz-keyboard-layout 'usb_device_is_pointer'
contains stage3/01-session/files/cpz-keyboard-layout 'capabilities/rel'
contains stage3/01-session/files/cpz-cage-output 'user_request=1'
contains stage3/01-session/files/cpz-cage-output 'cpz-panel-backlight off'
contains stage3/01-session/files/cpz-cage-output 'cpz-panel-backlight on'
contains stage3/01-session/files/cpz-panel-backlight 'PWM_H'
contains stage3/01-session/files/cpz-panel-backlight '/dev/i2c-'
contains stage3/01-session/files/cpz-brightness 'cpz-panel-backlight'
contains stage3/01-session/files/cpz-brightness 'up | down'
contains stage3/01-session/files/50-cpz-backlight 'cpz-panel-backlight'
contains stage3/01-session/files/cpz-cage-output 'HDMI unusable, panel fallback'
contains stage3/01-session/files/cpz-cage-output '--report)'
contains stage3/01-session/files/cpz-session.sh '/dev/tty1'
contains stage3/01-session/files/cpz-session.sh '/usr/local/bin/cpz-session-supervise'
contains stage3/01-session/files/cpz-cage-output 'fast_restart'
contains stage3/01-session/files/cpz-session-supervise 'restart.request'
contains stage3/01-session/files/10-ssh.conf 'PasswordAuthentication yes'
contains stage3/01-session/files/cpz-tmux.service 'RemainAfterExit=yes'
contains stage3/01-session/files/cpz-tmux.service 'Requires=user-runtime-dir@1000.service'
contains stage3/01-session/files/cpz-foot-config 'font=$font_list'
contains stage3/01-session/files/cpz-foot-config 'get_setting font_family'
contains stage3/01-session/files/cpz-foot-config 'font_size_hdmi'
contains stage3/01-session/files/cpz-settings 'FONT_FAMILIES'
contains stage3/01-session/files/cpz-settings 'font_family'
contains stage3/01-session/files/cpz-settings 'font_size_panel'
contains stage3/01-session/files/cpz-settings 'def font_key()'
contains stage3/01-session/files/cpz-font 'font_size_panel'
contains stage3/01-session/files/settings.conf 'font_family=terminus'
contains stage3/01-session/files/settings.conf 'font_size_hdmi=16'
contains stage3/01-session/files/cpz-tmux-start 'cpz-session-ensure main'
contains stage3/01-session/00-packages 'imv'
contains stage3/01-session/00-packages 'mpv'
contains stage3/01-session/00-packages 'cmus'
contains stage3/01-session/files/cpz-tmux 'MC_XDG_OPEN /usr/local/bin/cpz-open'
contains stage3/01-session/files/cpz-open 'imv-wayland'
contains stage3/01-session/files/cpz-open '--vo=wlshm'
contains stage3/01-session/files/cpz-open 'cpz-music'
contains stage3/01-session/files/cpz-open '._*'
contains stage3/01-session/files/cpz-open "trap ':' INT TERM"
contains stage3/01-session/files/cpz-open 'maxdepth 1'
contains stage3/01-session/files/lfrc 'audio/*'
contains stage3/01-session/files/cpz-music 'clear -q'
contains stage3/01-session/files/cpz-music '.pl'
contains stage3/01-session/files/cpz-music '/dev/tty'
contains stage3/01-session/files/cpz-music '(exec 3<>/dev/tty)'
not_contains stage3/01-session/files/cpz-music '{ exec 3<>/dev/tty; }'
contains stage3/01-session/files/cpz-music '/\/\./'
contains stage3/01-session/files/cpz-music 'status playing'
contains stage3/01-session/files/cpz-music 'add -p $queue'
contains stage3/01-session/files/cpz-music 'win-activate'
contains stage3/01-session/files/cmus-rc 'set play_library=false'
contains stage3/01-session/files/cpz-media-keys '164'
contains stage3/01-session/files/cpz-media-keys '224: [BRIGHTNESS, "down"]'
contains stage3/01-session/files/cpz-media-keys '225: [BRIGHTNESS, "up"]'
contains stage3/01-session/files/cpz-media-keys 'cpz-track'
contains stage3/01-session/01-run.sh 'files/cpz-track'
contains stage3/01-session/files/cpz-track 'position'
contains stage3/01-session/files/cpz-track 'player-pause'
contains stage3/01-session/files/cpz-media-keys 'DOUBLE_PRESS'
not_contains stage3/01-session/files/cpz-media-keys 'LONG_PRESS'
contains stage3/01-session/files/cpz-media-keys 'if device == KEYBOARD:'
contains stage3/01-session/files/cmus-rc 'bind -f common q quit'
contains stage3/01-session/01-run.sh 'files/cmus-rc'
contains stage3/01-session/files/lfrc '/usr/local/bin/cpz-open'
contains stage3/01-session/files/mpv.conf 'vo=wlshm'
contains stage3/01-session/files/mpv.conf 'sub-auto=fuzzy'
contains stage3/01-session/files/cpz-volume 'LC_ALL=C awk'
contains stage3/01-session/01-run.sh 'cpz-media-keys'
contains stage3/01-session/02-run.sh 'enable cpz-media-keys.service'
contains stage3/01-session/01-run.sh "user_config/lf/lfrc"
not_contains stage3/01-session/files/cpz-settings 'Panel Text Size'
not_contains stage3/01-session/files/cpz-settings 'HDMI Text Size'
contains stage3/01-session/files/settings.conf 'font_size_panel=12'
contains tools/verify-image.sh 'font_size_panel=12'
not_contains tools/verify-image.sh 'font_size=12'
contains stage3/01-session/01-run.sh 'cpz-cage-output.timer'
contains stage3/01-session/01-run.sh '99-cpz-cage-output.rules'
contains stage3/01-session/files/cpz-cage-output 'devices=$hdmi_dev'
contains stage3/01-session/files/cpz-cage-output 'devices=$panel_dev'
not_contains stage3/01-session/files/cpz-cage-output 'panel_dev:$hdmi_dev'
contains stage3/01-session/files/cpz-status '/run/cpz-conn'
contains stage3/01-session/files/cpz-status 'show_volume'
contains stage3/01-session/files/cpz-status 'show_brightness'
contains stage3/01-session/files/cpz-status '/sys/class/backlight'
contains stage3/01-session/files/cpz-status 'DEFAULT_AUDIO_SINK'
contains stage3/01-session/files/cpz-status '#[fg=red]'
contains stage3/01-session/files/cpz-status '#[fg=yellow]'
contains stage3/01-session/files/cpz-status "'# alert'"
contains stage3/01-session/files/cpz-status "'# warn'"
contains stage3/01-session/files/cpz-status 'alert_style'
contains stage3/01-session/files/cpz-status '#[default]'
contains stage3/01-session/files/cpz-status 'E+) label=Et+'
contains stage3/01-session/files/cpz-status 'W) label=Wi'
contains stage3/01-session/files/cpz-status 'W+) label=Wi+'
contains stage3/01-session/files/cpz-status 'B) label=Bt'
contains stage3/01-session/files/cpz-status 'B+) label=Bt+'
not_contains stage3/01-session/files/cpz-status 'show_wifi'
not_contains stage3/01-session/files/cpz-status 'show_bt'
not_contains stage3/01-session/files/cpz-status 'show_eth'
not_contains stage3/01-session/files/cpz-settings 'show_wifi'
contains stage3/01-session/files/cpz-apply-settings 'show_volume'
contains stage3/01-session/files/cpz-apply-settings 'show_brightness'
contains stage3/01-session/files/cpz-settings '"label": "Volume"'
contains stage3/01-session/files/cpz-settings '"label": "Brightness"'
contains stage3/01-session/files/settings.conf 'show_volume=0'
contains stage3/01-session/files/settings.conf 'show_brightness=0'
contains stage3/01-session/files/settings.conf 'mouse_speed=0'
contains stage3/01-session/files/cpz-conn-status 'E+'
contains stage3/01-session/files/tmux.conf 'status-right-length 36'
contains stage3/01-session/01-run.sh 'enable cpz-conn-status.timer'
not_contains stage3/01-session/files/cpz-apply-settings 'cpz-console-theme'
contains stage3/01-session/files/cpz-apply-settings '--theme'
contains stage3/01-session/files/cpz-apply-settings 'window-active-style'
contains stage3/01-session/files/cpz-apply-settings 'pane-colours'
contains stage3/01-session/files/cpz-apply-settings 'list-clients'
contains stage3/01-session/files/cpz-apply-settings 'refresh-client -t'
contains stage3/01-session/files/cpz-settings 'cpz-apply-settings'
contains stage3/01-session/files/cpz-settings 'refresh_clients'
contains stage3/01-session/files/cpz-settings 'NAV_UP'
contains stage3/01-session/files/cpz-settings 'ord("z")'
not_contains stage3/01-session/files/cpz-settings 'cpz-console-theme'
absent stage3/01-session/files/cpz-console-theme
contains stage3/01-session/files/cpz-session-ensure '@cpz_restoring'
contains stage3/01-session/files/tmux.conf 'cpz-session-save'
contains stage3/01-session/01-run.sh 'enable cpz-session-save.timer'
contains stage3/01-session/01-run.sh 'cpz-cage'
absent stage3/01-session/files/cpz-panel-message
contains stage3/01-session/01-run.sh 'enable cpz-cage-output.timer'
contains stage3/01-session/01-run.sh 'system-sleep'
contains stage3/01-session/01-run.sh '99-cpz-cage-output.rules'
contains stage3/01-session/files/99-zz-cpz-input.rules 'ID_INPUT_MOUSE'
contains stage3/01-session/files/99-zz-cpz-input.rules 'CPZ_REAL_POINTER'
contains stage3/01-session/files/99-zz-cpz-input.rules 'cpz-pointer-cursor.service'
contains stage3/01-session/files/cpz-pointer 'seat-cpz-no-pointer'
contains stage3/01-session/files/cpz-pointer 'request_foot_reload'
have stage3/01-session/files/60-cpz-phantom-pointer.quirks
contains stage3/01-session/files/60-cpz-phantom-pointer.quirks 'AttrEventCode=-REL_X;-REL_Y;-ABS_X;-ABS_Y;'
contains tools/verify-image.sh 'AttrEventCode=-REL_X;-REL_Y;-ABS_X;-ABS_Y;'
not_contains tools/verify-image.sh 'AttrEventCode=-EV_REL;-EV_ABS;'
contains stage3/01-session/files/60-cpz-phantom-pointer.quirks 'MatchName=gpio_ir_recv'
contains stage3/01-session/01-run.sh 'etc/libinput/local-overrides.quirks'
contains stage3/01-session/files/cpz-pointer-speed.c 'libinput_device_config_accel_set_speed'
contains stage3/01-session/files/cpz-pointer-speed.c 'libinput_get_event'
contains stage3/01-session/files/cpz-pointer 'mouse_speed'
contains stage3/01-session/files/cpz-settings 'mouse_speed'
contains stage3/01-session/files/cpz-cage 'cpz-pointer-speed.so'
contains stage3/01-session/01-run.sh 'cpz-pointer-speed.so'
contains stage3/01-session/files/cpz-settings 'language_codes'
contains stage3/01-session/files/cpz-settings '"language"'
contains stage3/01-session/files/i18n/uk.json 'Пошук'
contains stage3/01-session/files/i18n/uk.json '[вкладка]'
contains stage3/01-session/files/i18n/de.json 'Suche'
contains stage3/01-session/files/i18n/ja.json '検索'
contains stage3/01-session/files/i18n/zh.json '搜索'
contains stage2/04-locales/00-run.sh 'locale-gen'
contains stage3/01-session/files/99-zz-cpz-input.rules 'ID_SEAT}="seat0"'
contains stage3/01-session/files/99-cpz-automount.rules 'SUBSYSTEMS=="usb"'
contains stage3/01-session/files/99-cpz-automount.rules 'DEVTYPE}=="partition"'
contains stage3/01-session/files/99-cpz-automount.rules 'ID_PART_TABLE_TYPE}!="?*"'
contains stage3/01-session/files/99-cpz-automount.rules 'ENV{SYSTEMD_WANTS}+="cpz-automount@%k.service"'
contains stage3/01-session/files/cpz-automount@.service 'BindsTo=dev-%i.device'
contains stage3/01-session/files/cpz-automount@.service 'After=local-fs.target'
contains stage3/01-session/files/cpz-automount@.service 'ExecStop=-/usr/local/bin/cpz-automount umount'
contains stage3/01-session/files/cpz-automount 'on_system_disk'
contains stage3/01-session/files/cpz-automount 'probe_filesystem'
contains stage3/01-session/files/cpz-automount 'umask=0022'
contains stage3/01-session/files/cpz-automount 'nosuid,nodev'
contains stage3/01-session/files/cpz-automount 'umount -l'
contains stage3/01-session/files/cpz-automount 'findmnt --fstab'
contains stage3/01-session/files/cpz-automount 'open_mount_tab'
contains stage3/01-session/files/cpz-automount 'close_mount_tabs'
contains stage3/01-session/files/cpz-automount 'delegate_to_systemd'
contains stage3/01-session/files/cpz-tab-mount 'runuser'
contains stage3/01-session/files/cpz-tab-mount '@cpz_mount'
contains stage3/01-session/files/cpz-tab-new '@cpz_mount'
contains stage3/01-session/files/cpz-session-save '@cpz_mount'
contains stage3/01-session/01-run.sh '99-cpz-automount.rules'
contains stage3/01-session/01-run.sh 'cpz-automount@.service'
contains stage3/01-session/01-run.sh 'install -d -m 0755 "${ROOTFS_DIR}/media"'
contains stage3/01-session/01-run.sh 'cpz-tab-mount'
have tests/test_cpz_automount.py
have tests/test_cpz_tab_mount.py
have tests/test_cpz_battery.py
contains stage3/01-session/01-run.sh 'cpz-battery-guard.service'
contains stage3/01-session/01-run.sh 'files/cpz-battery'
contains stage3/01-session/01-run.sh 'battery.conf'
contains stage3/01-session/01-run.sh 'enable cpz-battery-guard.service'
contains stage3/01-session/files/cpz-battery '/sys/class/power_supply'
contains stage3/01-session/files/cpz-battery 'shutdown_level'
contains stage3/01-session/files/cpz-battery 'shutdown_voltage_uv'
contains stage3/01-session/files/battery.conf 'shutdown_level=10'
contains stage3/01-session/files/battery.conf 'shutdown_voltage_uv=3350000'
contains stage3/01-session/files/cpz-battery-guard.service 'ExecStart=/usr/local/bin/cpz-battery guard'
contains stage3/01-session/02-run.sh 'CPZ_HDMI_VIDEO'
contains build.sh 'CPZ_HDMI_VIDEO'
contains config.cpz.example 'CPZ_HDMI_VIDEO'
not_contains stage3/01-session/files/cpz-apply-settings 'cpz-screen-timeout'
absent stage3/01-session/files/cpz-screen-timeout
not_contains stage3/01-session/files/cpz-settings '-powerdown'
contains stage3/01-session/files/cmdline.append 'fbcon=map:off'
contains stage3/01-session/02-run.sh "unmask getty@tty1.service"
contains stage3/01-session/02-run.sh 'mask tmp.mount'
contains stage3/01-session/01-run.sh 'install -d -m 1777'
have stage3/03-cleanup/00-run.sh
contains stage3/03-cleanup/00-run.sh '-s purge "$package"'
contains stage3/03-cleanup/00-run.sh 'cpz-cleanup: keeping'
contains stage3/03-cleanup/00-run.sh 'apt-get autoremove --purge'
contains stage3/03-cleanup/00-run.sh 'vim-tiny'
contains stage3/03-cleanup/00-run.sh 'net-tools'
contains stage3/03-cleanup/00-run.sh 'build-essential'
contains stage3/03-cleanup/00-run.sh 'rpi-eeprom'
contains stage3/03-cleanup/00-run.sh 'apt-mark manual 7zip'
contains stage2/01-sys-tweaks/00-packages '7zip'
not_contains stage2/01-sys-tweaks/00-packages 'p7zip-full'
contains stage3/01-session/files/settings.conf 'theme=cpz-campbell'
contains stage3/01-session/files/settings.conf 'show_date=0'
contains stage3/01-session/files/settings.conf 'date_format=short'
contains stage3/01-session/files/settings.conf 'show_conn=1'
contains stage3/01-session/files/settings.conf 'display=auto'
contains stage3/01-session/files/settings.conf 'brightness=100'
contains stage3/01-session/files/settings.conf 'screen_timeout=0'
contains stage3/01-session/files/settings.conf 'mode_keys=vi'
contains stage3/01-session/files/settings.conf 'status_interval=5'
contains stage3/01-session/files/settings.conf 'set_clipboard=1'
contains stage3/01-session/files/settings.conf 'automatic_rename=1'
contains stage3/01-session/files/cpz-status 'show_conn'
contains stage3/01-session/files/cpz-settings 'page_items'
contains stage3/01-session/files/cpz-settings '{"label": "Network", "kind": "toggle", "key": "show_conn"}'
contains stage3/01-session/files/cpz-settings 'Brightness'
contains stage3/01-session/files/cpz-settings 'Output Volume'
contains stage3/01-session/files/cpz-settings 'Change Password'
contains stage3/01-session/files/cpz-settings 'VPN'
contains stage3/01-session/files/cpz-settings 'status_interval'
contains stage3/01-session/files/cpz-settings 'CPZ Hub'
contains stage3/01-session/files/cpz-settings 'hub_apps_screen'
contains stage3/01-session/files/cpz-settings 'filter_hub_apps'
contains stage3/01-session/files/cpz-settings 'hub_app_status'
contains stage3/01-session/files/cpz-settings 'apt_lists_present'
contains stage3/01-session/files/cpz-settings 'fetch_hub_deb'
contains stage3/01-session/files/cpz-settings 'HUB_INDEX_DEFAULT_URL'
contains stage3/01-session/files/cpz-settings 'apt-get'
not_contains stage3/01-session/files/cpz-settings 'trove_apps_screen'
not_contains stage3/01-session/files/cpz-settings 'filter_trove_tools'
not_contains stage3/01-session/files/cpz-settings 'apt_command_package'
not_contains stage3/01-session/files/cpz-settings 'apt_only'
not_contains stage3/01-session/files/cpz-settings 'read_available_packages'
not_contains stage3/01-session/files/cpz-settings 'dumpavail'
contains stage3/01-session/01-run.sh 'cpzos-hub'
contains stage3/01-session/01-run.sh 'hub.json'
not_contains stage3/01-session/01-run.sh 'trove-index'
not_contains stage3/01-session/01-run.sh 'apt-packages.txt.gz'
contains config.cpz.example 'CPZ_HUB_INDEX_URL'
contains config.cpz.example 'CPZ_HUB_INDEX_PATH'
contains build.sh 'CPZ_HUB_INDEX_URL'
contains build.sh 'CPZ_HUB_INDEX_PATH'
contains docs/APPS.md 'apt-get purge'
not_contains stage3/01-session/files/cpz-settings 'Aptitude::Delete-Unused'
not_contains stage3/01-session/00-packages 'aptitude'
contains stage3/01-session/files/cpz-apply-settings 'cpz-brightness'
not_contains stage3/01-session/files/cpz-apply-settings 'setterm'
contains stage3/01-session/files/cpz-apply-settings 'mode-keys'
contains stage3/01-session/files/cpz-apply-settings 'set-clipboard'
contains stage3/01-session/files/cpz-apply-settings 'automatic-rename'
contains stage3/01-session/files/99-cpz-backlight.rules 'backlight'
contains stage3/01-session/files/cpz-keyboard-layout 'capabilities/key'
contains stage3/01-session/files/cpz-keyboard-layout 'id/bustype'
contains stage3/01-session/files/cpz-keyboard-layout 'tca8418'
contains stage3/01-session/files/cpz-keyboard-layout '--detect'
contains stage3/01-session/files/cpz-keyboard-layout 'cardputer-zero-internal'
contains stage3/01-session/files/cpz-keyboard-layout '3f804000.i2c'
contains stage3/01-session/files/99-cpz-keyboard.rules 'ID_INPUT_KEYBOARD'
not_contains stage3/01-session/files/99-cpz-keyboard.rules 'ACTION=="remove"'
contains stage3/01-session/files/cpz-keyboard-layout.path 'PathChanged=/dev/input'
contains stage3/01-session/files/cpz-keyboard-layout.path 'Unit=cpz-keyboard-layout.service'
contains stage3/01-session/01-run.sh 'systemctl enable cpz-keyboard-layout.path'
contains stage2/01-sys-tweaks/files/99-ignore-i2c-key.rules 'cardputer-zero-internal'
contains stage3/01-session/files/cardputerzero-keymap.service 'cpz-keyboard-layout'
contains stage3/01-session/01-run.sh 'cpz-keyboard-layout'
have stage3/01-session/files/xkb/symbols/cpz
contains stage3/01-session/files/xkb/symbols/cpz 'include "us(basic)"'
contains stage3/01-session/files/xkb/symbols/cpz 'key <HIRA> { [ period'
contains stage3/01-session/files/xkb/symbols/cpz 'key <ZENK> { [ greater'
contains stage3/01-session/01-run.sh 'xkb/symbols/cpz'
contains stage3/01-session/01-run.sh '<ZENK> = 93;'
have stage3/01-session/files/99-cpz-xkb-data.pref
contains stage3/01-session/files/99-cpz-xkb-data.pref 'Package: xkb-data'
contains stage3/01-session/files/99-cpz-xkb-data.pref 'Pin-Priority: -1'
contains stage3/01-session/01-run.sh '99-cpz-xkb-data.pref'
contains stage3/01-session/files/cpz-keyboard-layout 'publish cpz'
contains stage3/01-session/files/cpz-keyboard-layout 'cpz-pointer --reload-keymap'
contains stage3/01-session/files/cpz-keyboard-layout 'cpz-xkb-layout.so'
contains stage3/01-session/files/cpz-keyboard-layout 'xkb_changed'
contains stage3/01-session/files/cpz-keyboard-layout 'cpz_xkb_template'
contains stage3/01-session/files/cpz-keyboard-layout 'write_cpz_xkb'
have stage3/01-session/files/cpz-xkb-layout.c
contains stage3/01-session/files/cpz-xkb-layout.c 'xkb_keymap_new_from_names'
contains stage3/01-session/files/cpz-cage 'cpz-xkb-layout.so'
contains stage3/01-session/01-run.sh 'cpz-xkb-layout.so'
have stage3/01-session/files/cpz-font
contains stage3/01-session/files/cpz-font 'font_size'
have stage3/01-session/files/cpz-volume
contains stage3/01-session/files/cpz-volume 'set-volume'
contains stage3/01-session/files/cpz-volume 'set-mute'
contains stage3/01-session/files/cpz-keys 'cpz-volume up'
contains stage3/01-session/files/cpz-keys 'cpz-volume mute'
contains stage3/01-session/files/tmux.conf 'prefix C-a'
contains stage3/01-session/files/cpz-keys 'cpz-font up'
contains stage3/01-session/files/cpz-keys 'cpz-font down'
contains stage3/01-session/files/cpz-keys 'split-window -h'
contains stage3/01-session/files/cpz-keys 'split-window -v'
contains stage3/01-session/files/cpz-keys 'select-pane -t :.+'
contains stage3/01-session/files/cpz-keys 'select-pane -t :.-'
contains stage3/01-session/files/cpz-keys 'resize-pane -Z'
contains stage3/01-session/files/cpz-keys 'confirm-before'
contains stage3/01-session/files/cpz-keys 'command-prompt'
contains stage3/01-session/files/cpz-keys 'choose-tree -Zw'
contains stage3/01-session/files/cpz-keys 'cpz-layout-next'
contains stage3/01-session/files/cpz-keys 'copy-mode'
contains stage3/01-session/files/cpz-keys 'paste-buffer'
have stage3/01-session/files/cpz-hint
contains stage3/01-session/files/cpz-hint 'display-message -c'
contains stage3/01-session/files/cpz-hint 'cpz-keys hint'
contains stage3/01-session/files/tmux.conf 'cpz-hint'
contains stage3/01-session/01-run.sh 'cpz-hint'
contains stage3/01-session/files/cpz-help 'cpz-keys help'
contains stage3/01-session/files/cpz-keys 'Font Bigger'
contains stage3/01-session/files/cpz-settings 'rebind_action'
contains stage3/01-session/files/cpz-keys 'Previous Pane'
not_contains stage3/01-session/files/cpz-help 'Ctrl-b'
not_contains stage3/01-session/files/cpz-help 'Ctrl-a '
not_contains stage3/01-session/files/cpz-tab-close 'IFS=$tab'
not_contains stage3/01-session/files/cpz-tab-close-key 'IFS=$tab'
not_contains stage3/01-session/files/cpz-session-save 'IFS="$tab" read'
contains stage3/01-session/files/cpz-session-save 'display-message -p -t "$id"'
contains stage3/01-session/files/cpz-settings 'system_info_lines'
contains stage3/01-session/files/cpz-settings 'theme_label'
contains stage3/01-session/files/cpz-settings 'theme_labels'
contains stage3/01-session/files/cpz-settings 'select_popup'
contains stage3/01-session/files/cpz-settings 'cpz-wifi'
contains stage3/01-session/files/cpz-wifi 'rfkill unblock wifi'
contains stage3/01-session/files/cpz-wifi 'WIFITUI_THEME'
contains stage3/01-session/files/wifitui-theme.toml 'NetworkSecureIcon'
contains stage3/01-session/files/cpz-wifi 'wifitui'
contains stage3/01-session/01-run.sh 'files/cpz-wifi'
contains stage3/01-session/01-run.sh 'wifitui_0.13.0_arm64.deb'
contains stage3/01-session/files/cpz-settings 'Power'
contains stage3/01-session/files/cpz-settings 'Shut Down'
not_contains stage3/01-session/files/cpz-settings 'Suspend'
contains stage3/01-session/files/cpz-settings 'System Monitor'
not_contains stage3/01-session/files/cpz-settings '"label": "Diagnostics"'
contains stage3/01-session/files/cpz-settings 'diagnostic_lines(data)'
not_contains stage3/01-session/files/cpz-settings 'Key List'
contains stage3/01-session/files/cpz-settings 'Shortcuts'
contains stage3/01-session/files/cpz-settings 'Input'
contains stage3/01-session/files/cpz-settings 'keyboard_layout'
contains stage3/01-session/files/settings.conf 'keyboard_layout=auto'
contains stage3/01-session/files/cpz-keys '"default": "M-Space"'
contains stage3/01-session/files/cpz-keys 'cpz-layout-next'
contains stage3/01-session/files/cpz-keys '"default": "M-d"'
contains stage3/01-session/files/cpz-keys 'cpz-display-toggle'
contains stage3/01-session/01-run.sh 'cpz-display-toggle'
contains stage3/01-session/files/cpz-keys 'Display Toggle'
contains stage3/01-session/files/cpz-keys 'Z/X/C/F'
contains stage3/01-session/files/cpz-keys '"default": "M-o"'
contains stage3/01-session/files/cpz-search 'cpz-search'
contains stage3/01-session/files/cpz-keys 'cpz-search'
contains stage3/01-session/01-run.sh 'cpz-search'
contains stage3/01-session/files/cpz-settings '--list-pages'
contains stage3/01-session/files/cpz-settings '--page'
contains stage3/01-session/files/cpz-settings '--list-tools'
contains stage3/01-session/files/cpz-settings '--tool'
contains stage3/01-session/files/cpz-search '--with-nth=3'
contains stage3/01-session/files/cpz-search 'DEFAULT_ROOTS'
contains stage3/01-session/files/cpz-search 'safe_eval'
contains stage3/01-session/files/cpz-search '--apps'
contains stage3/01-session/files/cpz-search '--buffers'
contains stage3/01-session/files/cpz-search 'home_items'
contains stage3/01-session/files/cpz-search '--home'
contains stage3/01-session/files/cpz-search 'media-tab'
contains stage3/01-session/files/cpz-search 'cpz-tab-new'
contains stage3/01-session/files/cpz-search 'CPZ_TAB_MOUNT'
contains stage3/01-session/files/cpz-search 'open_settings'
contains stage3/01-session/files/cpz-settings 'take_request'
contains stage3/01-session/files/cpz-settings-open '--page'
contains stage3/01-session/files/cpz-layout-next 'keyboard_layouts'
contains stage3/01-session/files/cpz-layout-next 'cpz-layout-apply'
contains stage3/01-session/files/cpz-layout-apply 'cpz-keyboard-layout.service'
contains stage3/01-session/01-run.sh '50-cpz-layout'
contains stage3/01-session/01-run.sh 'cpz-layout-next'
contains stage3/01-session/01-run.sh 'cpz-layout-map'
contains stage3/01-session/01-run.sh 'cpz-locale-apply'
contains stage3/01-session/01-run.sh '50-cpz-locale'
contains stage3/01-session/01-run.sh '10-cpz-locale.sh'
contains stage3/01-session/files/cpz-settings 'apply_system_locale'
contains stage3/01-session/files/cpz-settings 'cpz-locale-apply'
contains stage3/01-session/files/cpz-locale-apply 'LC_TIME'
contains stage3/01-session/files/10-cpz-locale.sh 'LC_TIME'
contains stage3/01-session/files/cpz-keyboard-layout 'cpz-layout-map'
contains stage3/01-session/files/cpz-keyboard-layout 'prepare_cpz_maps'
contains stage3/01-session/files/cpz-keyboard-layout 'cpz_base_map'
contains stage3/01-session/files/cpz-layout-map 'is_letter'
contains stage3/01-session/files/cpz-layout-map 'render_vt'
contains stage2/05-cardputerzero/01-run.sh 'tca8418_fsm_can_activate'
contains stage2/05-cardputerzero/01-run.sh 'if (device->id == 1)'
contains stage3/01-session/files/cpz-keys 'Shift+Sym'
have tests/test_cpz_layout_map.py
contains stage3/01-session/files/cpz-settings 'evdev.lst'
contains stage3/01-session/files/cpz-settings 'LAYOUTS'
contains stage3/01-session/files/cpz-settings 'layouts_screen'
contains stage3/01-session/files/cpz-settings 'cpz-layout-apply'
contains stage3/01-session/files/cpz-settings '--detect'
contains stage3/01-session/files/cpz-settings 'keyboard_layout_active'
contains stage3/01-session/files/settings.conf 'keyboard_layouts=us'
contains stage3/01-session/files/settings.conf 'keyboard_layout_active=us'
contains stage3/01-session/files/settings.conf 'show_layout=1'
contains stage3/01-session/files/cpz-status 'show_layout'
contains stage3/01-session/files/cpz-status '/run/cpz-layout.active'
contains stage3/01-session/files/cpz-status 'layout_active'
contains stage3/01-session/files/cpz-status 'keyboard_layouts'
contains stage3/01-session/files/cpz-status 'layout_count'
contains stage3/01-session/files/cpz-apply-settings 'keyboard_layouts'
contains stage3/01-session/files/cpz-settings 'layout_codes(data)) > 1'
contains stage3/01-session/files/cpz-status 'CPZ) layout=US'
contains stage3/01-session/files/cpz-keyboard-layout 'cached_UTF-8_del.kmap.gz'
contains stage3/01-session/files/cpz-keyboard-layout 'load_standard'
contains stage3/01-session/files/cpz-keyboard-layout 'cpz-keyboard-layout.log'
contains stage3/01-session/files/cpz-keyboard-layout 'ckbcomp'
contains stage3/01-session/files/cpz-keyboard-layout 'cpz-layout.active'
contains stage3/01-session/files/cpz-keys '"default": "M-Space"'
contains stage3/01-session/files/cpz-keyboard-layout 'keyboard_layout'
contains stage3/01-session/files/cpz-status 'show_date'
contains stage3/01-session/files/cpz-status 'date_format'
contains stage3/01-session/files/cpz-settings 'show_date'
contains stage3/01-session/files/cpz-settings 'date_format'
contains stage3/01-session/files/cpz-settings 'status_right_length'
contains stage3/01-session/files/cpz-settings 'Set Date & Time'
contains stage3/01-session/files/cpz-settings 'datetime_edit_screen'
contains stage3/01-session/files/cpz-settings 'timedatectl", "set-time"'
contains stage3/01-session/files/cpz-settings 'timedatectl", "set-ntp"'
contains stage3/01-session/files/cpz-settings 'read_timezones'
contains stage3/01-session/files/cpz-settings '--check-pages'
not_contains stage3/01-session/files/cpz-settings 'Settings refreshed'
contains stage3/01-session/files/cpz-settings 'PgUp/PgDn'
contains stage3/01-session/files/cpz-settings 'security_issues'
contains stage3/01-session/files/cpz-settings 'factory password in use'
contains stage3/01-session/01-run.sh 'shadow-mtime'
contains stage3/01-session/files/cpz-apply-settings 'status-right-length'
contains stage3/01-session/01-run.sh 'cpz-settings'
contains stage3/01-session/01-run.sh 'FONTSIZE="6x12"'
contains stage3/01-session/01-run.sh 'FONTFACE="Terminus"'
not_contains stage3/01-session/01-run.sh 'cpz-font-blocks'
absent stage3/01-session/files/cpz-font-blocks
not_contains stage3/01-session/01-run.sh 'cpz-font-scale'
absent stage3/01-session/files/cpz-font-scale
contains stage3/01-session/01-run.sh 'chown 1000:1000 "$user_config"'
contains stage2/05-cardputerzero/02-run.sh 'chown 1000:1000 "$user_config"'
contains stage3/01-session/files/cpz-settings 'wifi_action'
# The factory image soft-blocks WLAN through rfkill.default_state=0, so the
# Wi-Fi entry point must clear it as root before the shared manager reads nmcli.
contains stage3/01-session/files/cpz-settings 'cpz-wifi", "--prepare'
contains stage3/01-session/01-run.sh '50-cpz-wifi'
contains stage3/01-session/files/cpz-settings 'bt_action'
# Both radios use one borderless screen with hints and scan status.
contains stage3/01-session/files/cpz-settings 'radio_manager_screen'
contains stage3/01-session/files/cpz-settings 'parse_wifi_networks'
contains stage3/01-session/files/cpz-settings 'bt_pair_command'
contains stage3/01-session/files/cpz-settings 'bluetooth_info'
contains stage3/01-session/files/cpz-wifi '--prepare'
contains stage3/01-session/files/cpz-bt-unblock 'bluetoothctl power on'
contains stage3/01-session/files/cpz-bt-unblock 'bluetoothctl power off'
# Bluetooth is off at boot: BlueZ must not auto-enable the adapter and the
# pairing agent must not unblock rfkill behind the user's back.
contains stage3/01-session/01-run.sh 'AutoEnable = false'
not_contains stage3/01-session/files/cpz-bt-agent.service 'rfkill unblock'
contains stage3/01-session/files/cpz-bt 'cpz-bt-unblock'
contains stage3/01-session/files/cpz-bt 'bluetuith'
# Keep the Bluetooth TUI compact on the 53x14 panel: q quits, the underlined
# help footer stays hidden, and OBEX file transfer is not loaded.
contains stage3/01-session/files/cpz-bt 'disable-obex-services'
contains stage3/01-session/files/bluetuith.conf 'Quit: q'
contains stage3/01-session/files/bluetuith.conf 'no-help-display: true'
contains stage3/01-session/files/bluetuith.conf 'theme:'
# bluetuith rejects the literal "default" for user theme colours; the config
# spelling for the terminal default is "transparent".
not_contains stage3/01-session/files/bluetuith.conf 'MenuBar: default'
not_contains stage3/01-session/files/bluetuith.conf 'Background: default'
contains stage3/01-session/files/bluetuith.conf 'MenuBar: transparent'
contains stage3/01-session/01-run.sh 'files/bluetuith.conf'
contains stage3/01-session/files/cpz-bt-unblock 'rfkill unblock bluetooth'
contains stage3/01-session/01-run.sh 'files/cpz-bt'
contains stage3/01-session/01-run.sh 'bluetuith_0.2.7_Linux_arm64.tar.gz'
contains stage3/01-session/01-run.sh '50-cpz-bt'
contains stage3/01-session/files/cpz-settings 'bluetoothctl'
contains stage3/01-session/01-run.sh '50-cpz-networkmanager.rules'
contains stage3/01-session/01-run.sh 'cpz-bt-agent.service'
contains stage3/01-session/01-run.sh 'usermod -aG bluetooth'
contains stage3/01-session/02-run.sh 'enable NetworkManager.service'
contains stage3/01-session/files/cpz-keys 'cpz-tab-new'
contains stage3/01-session/files/cpz-keys 'cpz-tab-close-key'
contains stage3/01-session/files/tmux.conf 'bind -T copy-mode-vi C-u send-keys -X page-up'
contains stage3/01-session/files/tmux.conf 'bind -T copy-mode-vi C-d send-keys -X page-down'
contains stage3/01-session/files/tmux.conf 'bind -T copy-mode NPage send-keys -X page-down'
contains stage3/01-session/files/cpz-tab-close-key 'confirm-before'
contains stage3/01-session/files/cpz-help 'less'
not_contains stage3/01-session/files/cpz-help 'less -R -X -F'
contains stage3/01-session/files/cpz-tab-close '@cpz_settings'
not_contains stage3/01-session/files/cpz-tab-close '@cpz_main'
not_contains stage3/01-session/files/cpz-tab-close 'Last tab stays open'
contains stage3/01-session/files/cpz-tab-close 'Settings stays open'
contains stage3/01-session/files/cpz-tab-close-key '@cpz_settings'
not_contains stage3/01-session/files/cpz-tab-close-key 'Last tab stays open'
contains stage3/01-session/files/cpz-tab-close-key 'Settings stays open'
not_contains stage3/01-session/files/cpz-settings-shell 'Press Enter'
contains stage3/01-session/files/cpz-settings-shell '/usr/local/bin/cpz-settings'
contains stage3/01-session/01-run.sh 'cpz-tab-close'
contains stage3/01-session/files/cpz-session-ensure '@cpz_main'
contains stage3/01-session/01-run.sh "cage"
contains stage3/01-session/02-run.sh "cage"
contains stage3/01-session/02-run.sh "rpi-preseed.service"
contains stage3/01-session/02-run.sh "enable getty@tty1.service"
contains stage3/01-session/02-run.sh 'getty@tty1'
contains stage2/05-cardputerzero/02-run.sh "fb_load.service"
contains stage2/05-cardputerzero/01-run.sh 'panel-mipi-dbi-m.c'
contains stage2/05-cardputerzero/01-run.sh 'drm_client_setup_with_fourcc'
contains stage2/05-cardputerzero/01-run.sh 'cpz-keep-panel-fbdev'
contains stage2/05-cardputerzero/01-run.sh 'cma-128'
contains stage2/05-cardputerzero/02-run.sh '99-cardputer-zero-lcd.rules'
contains stage2/05-cardputerzero/02-run.sh '99-cpz-display.rules'
have stage2/05-cardputerzero/files/99-cpz-display.rules
contains stage2/05-cardputerzero/files/99-cpz-display.rules 'ENV{ID_SEAT}="seat0"'
not_contains stage2/05-cardputerzero/files/99-cpz-display.rules 'ENV{ID_SEAT}="seat-cardputer-zero"'
contains stage3/01-session/02-run.sh 'fbcon=map:10'
contains build.sh 'STAGE_LIST=${STAGE_LIST:-${BASE_DIR}/stage*}'
not_contains config.cpz.example 'STAGE_LIST='
not_contains config.cpz.example 'IMG_FILENAME='
not_contains config.debug.example 'IMG_FILENAME='
contains .dockerignore '.venv/'
not_contains stage2/05-cardputerzero/02-run.sh 'cmdline.txt'
not_contains export-image/04-set-partuuid/00-run.sh 'console=serial0,115200'
contains stage3/01-session/02-run.sh 'remove_cmdline_tokens'
contains stage3/01-session/files/cmdline.append 'fbcon=map:'
not_contains stage3/01-session/files/cmdline.append 'cfg80211.ieee80211_regdom=AE'
contains stage3/01-session/02-run.sh 'WPA_COUNTRY'
contains stage3/01-session/02-run.sh 'cfg80211.ieee80211_regdom='
contains build.sh 'CPZ_DTOVERLAYS_REF'
contains config.cpz.example 'CPZ_DTOVERLAYS_REF='
contains config.cpz.example 'ENABLE_SSH=0'
contains stage3/01-session/02-run.sh 'systemctl disable ssh ssh.socket'
contains stage3/01-session/02-run.sh 'systemctl mask regenerate_ssh_host_keys.service'
contains stage3/01-session/files/cpz-settings 'ssh-keygen'
contains config.cpz.example 'TIMEZONE_DEFAULT="UTC"'
contains config.debug.example 'TIMEZONE_DEFAULT="UTC"'
contains stage2/03-set-timezone/02-run.sh 'TIMEZONE_DEFAULT:-UTC'
contains scripts/update_os_list.py 'init_format": "systemd'
contains Dockerfile 'ARG BASE_IMAGE=debian:trixie'
not_contains stage2/05-cardputerzero/00-packages 'fonts-noto-cjk'
not_in_code stage2/01-sys-tweaks/00-packages 'rpi-update'
contains stage2/01-sys-tweaks/00-packages 'rpi-update is deliberately absent'
contains stage2/05-cardputerzero/02-run.sh 'purge -y rpi-update'
have stage2/05-cardputerzero/files/99-cpz-no-rpi-update.pref
contains stage2/05-cardputerzero/files/99-cpz-no-rpi-update.pref 'Pin-Priority: -1'
contains stage2/05-cardputerzero/02-run.sh '99-cpz-no-rpi-update.pref'
contains stage3/01-session/00-packages 'fonts-dejavu-core'
contains stage3/01-session/00-packages 'fontconfig'
contains stage3/01-session/00-packages 'fonts-terminus-otb'
for pkg in fonts-liberation fonts-noto-mono fonts-hack fonts-firacode \
	fonts-jetbrains-mono; do
	contains stage3/01-session/00-packages "$pkg"
done
if grep -qx 'mc' "$ROOT/stage3/01-session/00-packages"; then
	ok
else
	bad "stage3/01-session/00-packages does not install mc"
fi
# mc creates ~/.cache/mc on first start; install -d only chowns the final
# component, so ~/.cache itself has to be created with the user's ownership.
contains stage3/01-session/01-run.sh \
	'install -d -m 0755 -o 1000 -g 1000 "$first_home/.cache"'
not_contains stage3/01-session/00-packages 'xdg-utils'
not_contains stage3/01-session/00-packages 'alsa-utils'
contains stage3/01-session/files/cpz-settings 'devices Connected'
not_contains stage3/01-session/files/cancel-rename 'greetd'

echo "== cpz session helpers =="
python_ok stage3/01-session/files/cpz-settings
python_ok stage3/01-session/files/cpz-search
for conf in stage3/01-session/files/themes/*.conf; do
	base=${conf##*/}
	base=${base%.conf}
	palette="stage3/01-session/files/themes/${base}.palette"
	have "$conf"
	have "$palette"
	contains "$conf" 'window-style'
	contains "$conf" 'window-active-style'
	contains "$conf" '# name:'
	contains "$conf" '# palette'
	contains "$palette" '15='
	theme_ok "$conf" "$palette"
done

echo "== host checks =="
have tests/run.sh
have tests/lint.sh
have tests/test_cpz_settings.py
have tests/test_build_fast.py
have tests/test_cpz_battery.py
absent tests/shell/test-hdmi-console.sh
have tools/build-fast.sh
contains tools/build-fast.sh 'PREV_ROOTFS_DIR'
contains stage0/02-firmware/01-run.sh 'cache/kernel-debs'
contains stage3/03-cleanup/00-run.sh 'xargs -r -P'
contains README.md 'Fast local iterations'
have .github/workflows/ci.yml
contains .github/workflows/ci.yml 'pull_request'
contains .github/workflows/ci.yml './tools/verify-stage.sh'
contains .github/workflows/ci.yml './tests/run.sh'
contains .github/workflows/ci.yml './tests/lint.sh'
contains tests/lint.sh 'shellcheck'
contains tests/lint.sh 'ruff'
contains tests/lint.sh 'mypy'
contains tests/run.sh 'unittest discover'
contains tests/test_cpz_settings.py 'check_pages'

echo "== UI rules =="
have docs/CPZ-UI.md
contains docs/CPZ-UI.md 'Purpose test for every string'
have site/check.py
not_contains stage3/01-session/files/cpz-settings 'Display & Brightness'
not_contains stage3/01-session/files/cpz-settings 'Indicators hide while the interface is off'
not_contains stage3/01-session/files/cpz-settings 'Settings refreshed'
not_contains stage3/01-session/files/cpz-hint 'V/B split'
contains stage3/01-session/files/cpz-settings '"label": "Connections"'
contains stage3/01-session/files/cpz-settings '"label": "Text Size"'
not_contains site/index.html 'data-i18n="why.intro"'
not_contains site/index.html 'data-i18n="nav.why"'
contains site/index.html 'data-i18n="nav.download"'

echo "== release checks =="
have VERSION
if grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$' VERSION; then ok; else bad "VERSION is not SemVer"; fi
contains build.sh 'CPZ_VERSION'
contains export-image/05-finalise/01-run.sh 'cpz-version'
have docs/RELEASE.md
contains docs/RELEASE.md 'CardputerZero CPZ vX.Y.Z'
contains docs/RELEASE.md '### Highlights'
contains docs/RELEASE.md '### Changes'
contains docs/RELEASE.md '### Install'
contains README.md 'docs/RELEASE.md'
have tools/release.sh
contains tools/release.sh '--untracked-files=all'
contains tools/release.sh 'git tag -a'
contains tools/release.sh 'refs/tags/$tag'
contains tools/release.sh 'git commit -m "chore(release): $tag"'
contains tools/release.sh 'title="CardputerZero CPZ $tag"'
contains tools/release.sh '--publish'
contains tools/release.sh 'gh release create "$tag" --repo "$repo_slug" --verify-tag'
have .github/workflows/build.yml
contains .github/workflows/build.yml 'types: [published]'
not_contains .github/workflows/build.yml 'push:
    tags:'
contains .github/workflows/build.yml 'gh release create'
contains .github/workflows/build.yml 'CardputerZero CPZ $TAG'
contains .github/workflows/build.yml 'TARGET_HOSTNAME=cpz'
contains .github/workflows/build.yml 'FIRST_USER_NAME=cpz'
contains .github/workflows/build.yml 'FIRST_USER_PASS=cpz'
contains .github/workflows/build.yml 'Check OSS mirror credentials'
contains .github/workflows/build.yml "if: steps.oss.outputs.enabled == 'true'"
contains .github/workflows/build.yml 'scripts/update_os_list.py'
contains .github/workflows/build.yml 'VERSION ($FILE_VERSION) does not match tag'
contains scripts/update_os_list.py 'os_entry_name'
have tests/test_update_os_list.py
contains build.sh 'https://github.com/jmas/cpzos'
contains scripts/update_os_list.py '"repo": "jmas/cpzos"'

echo
echo "verify-stage: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
