#!/bin/bash
# Host-side structural checks for the CPZ kmscon image branch.
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
	stage3/00-kmscon/00-run.sh \
	stage3/01-session/00-packages \
	stage3/01-session/01-run.sh \
	stage3/01-session/02-run.sh \
	stage3/01-session/files/cpz-first-login \
	stage3/01-session/files/kmscon.conf \
	stage3/01-session/files/cpz-kmscon \
	stage3/01-session/files/cpz-kmscon-config \
	stage3/01-session/files/cpz-login \
	stage3/01-session/files/cpz-kmscon-output \
	stage3/01-session/files/cpz-kmscon-output.service \
	stage3/01-session/files/cpz-kmscon-output.timer \
	stage3/01-session/files/cpz-kmscon-sleep \
	stage3/01-session/files/99-cpz-kmscon-output.rules \
	stage3/01-session/files/99-cpz-kmscon-nudge.rules \
	stage3/01-session/files/99-cpz-automount.rules \
	stage3/01-session/files/cpz-automount \
	stage3/01-session/files/cpz-automount@.service \
	stage3/01-session/files/kmsconvt@.service.d/10-cpz.conf \
	stage3/01-session/files/cpz-session.sh \
	stage3/01-session/files/tmux.conf \
	stage3/01-session/files/cpz-session-ensure \
	stage3/01-session/files/cpz-tab-new \
	stage3/01-session/files/cpz-tab-close \
	stage3/01-session/files/cpz-tab-close-key \
	stage3/01-session/files/cpz-tab-info \
	stage3/01-session/files/cpz-settings-open \
	stage3/01-session/files/cpz-settings \
	stage3/01-session/files/cpz-settings-shell \
	stage3/01-session/files/cpz-status \
	stage3/01-session/files/cpz-apply-settings \
	stage3/01-session/files/cpz-help \
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
	stage3/01-session/files/cpz-keyboard-layout \
	stage3/01-session/files/cpz-layout-map \
	stage3/01-session/files/cpz-layout-next \
	stage3/01-session/files/cpz-layout-apply \
	stage3/01-session/files/cpz-display-toggle \
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
	docs/CPZ-KMSCON.md \
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
	stage3/00-kmscon/00-run.sh \
	stage3/01-session/01-run.sh \
	stage3/01-session/02-run.sh \
	stage3/01-session/files/cpz-first-login \
	stage3/01-session/files/cpz-kmscon \
	stage3/01-session/files/cpz-kmscon-config \
	stage3/01-session/files/cpz-login \
	stage3/01-session/files/cpz-kmscon-output \
	stage3/01-session/files/cpz-kmscon-sleep \
	stage3/01-session/files/cpz-session.sh \
	stage3/01-session/files/cpz-session-ensure \
	stage3/01-session/files/cpz-tab-new \
	stage3/01-session/files/cpz-tab-close \
	stage3/01-session/files/cpz-tab-close-key \
	stage3/01-session/files/cpz-tab-info \
	stage3/01-session/files/cpz-settings-open \
	stage3/01-session/files/cpz-settings \
	stage3/01-session/files/cpz-settings-shell \
	stage3/01-session/files/cpz-status \
	stage3/01-session/files/cpz-apply-settings \
	stage3/01-session/files/cpz-help \
	stage3/01-session/files/cpz-search \
	stage3/01-session/files/cpz-session-save \
	stage3/01-session/files/cpz-session-restore \
	stage3/01-session/files/cpz-session-save-as-user \
	stage3/01-session/files/cpz-conn-status \
	stage3/01-session/files/cpz-brightness \
	stage3/01-session/files/cpz-font \
	stage3/01-session/files/cpz-keyboard-layout \
	stage3/01-session/files/cpz-layout-map \
	stage3/01-session/files/cpz-layout-next \
	stage3/01-session/files/cpz-layout-apply \
	stage3/01-session/files/cpz-display-toggle \
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

echo "== console session =="
contains stage3/01-session/files/tmux.conf "status-position top"
contains stage3/01-session/files/tmux.conf '#{@cpz_tab_current} / #{@cpz_tab_total}'
contains stage3/01-session/files/tmux.conf 'cpz-tab-info'
contains stage3/01-session/files/tmux.conf 'client-attached'
contains stage3/01-session/files/tmux.conf 'cpz-session-ensure'
contains stage3/01-session/files/tmux.conf 'window-size largest'
contains stage3/01-session/files/cpz-session.sh 'cpz-session-ensure main'
contains stage3/01-session/files/cpz-session.sh 'cpz-first-login'
contains stage3/01-session/files/cpz-session.sh '/run/cpz-kmscon/session.tty1.tty'
contains stage3/01-session/files/cpz-login 'session.$vt.tty'
contains stage3/01-session/files/cpz-first-login 'passwd'
contains stage3/01-session/files/cpz-conn-status.timer 'OnUnitActiveSec=30s'
contains stage3/01-session/files/cpz-session-save.timer 'OnUnitActiveSec=5min'
contains stage3/01-session/files/cpz-kmscon-config 'get_setting font_size'
contains stage3/01-session/files/cpz-kmscon-config 'get_setting font_panel'
contains stage3/01-session/files/cpz-kmscon-config 'get_setting screen_timeout'
not_contains stage3/01-session/files/cpz-kmscon-config "printf 'xkb-layout"
contains stage3/01-session/files/cpz-kmscon-config 'palette-background'
contains stage3/01-session/files/cpz-kmscon-config 'multi_monitor=clone'
contains stage3/01-session/files/cpz-kmscon '--configdir /run/cpz-kmscon'
contains stage3/01-session/files/cpz-kmscon-output 'hdmi_debounce=2'
contains stage3/01-session/files/cpz-kmscon-output 'hdmi_edid'
contains stage3/01-session/files/cpz-kmscon-output 'hdmi_pinned'
contains stage3/01-session/files/cpz-kmscon-output 'bl_power'
contains stage3/01-session/files/cpz-kmscon-output 'panel_off'
contains stage3/01-session/files/cpz-kmscon-output 'panel_on'
contains stage3/01-session/files/cpz-kmscon-output 'restart_session'
contains stage3/01-session/files/cpz-kmscon-output '--status'
contains stage3/01-session/files/cpz-kmscon-output '--recover'
contains stage3/01-session/files/kmscon.conf 'multi-monitor=largest'
contains stage3/01-session/files/kmscon.conf 'no-use-original-mode'
contains stage3/01-session/files/kmscon.conf 'term=xterm-256color'
not_contains stage3/01-session/files/cpz-kmscon-output.service '--auto'
contains stage3/01-session/files/cpz-kmscon-output '--auto) override=""'
contains stage3/01-session/files/cpz-settings 'Font Size'
not_contains stage3/01-session/files/cpz-settings 'Panel Text Size'
not_contains stage3/01-session/files/cpz-settings 'HDMI Text Size'
contains stage3/01-session/files/settings.conf 'font_size=12'
contains stage3/01-session/files/99-cpz-kmscon-output.rules 'HOTPLUG'
contains stage3/01-session/files/99-cpz-kmscon-output.rules 'systemctl --no-block start'
contains stage3/01-session/01-run.sh 'cpz-kmscon-output.timer'
contains stage3/01-session/01-run.sh '99-cpz-kmscon-output.rules'
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
contains stage3/01-session/files/cpz-apply-settings 'show_volume'
contains stage3/01-session/files/cpz-apply-settings 'show_brightness'
contains stage3/01-session/files/cpz-settings 'Volume Indicator'
contains stage3/01-session/files/cpz-settings 'Brightness Indicator'
contains stage3/01-session/files/settings.conf 'show_volume=0'
contains stage3/01-session/files/settings.conf 'show_brightness=0'
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
contains stage3/01-session/files/cpz-session.sh 'cpz-session-restore'
contains stage3/01-session/files/cpz-session-ensure '@cpz_restoring'
contains stage3/01-session/files/tmux.conf 'cpz-session-save'
contains stage3/01-session/01-run.sh 'enable cpz-session-save.timer'
contains stage3/01-session/01-run.sh 'cpz-kmscon'
absent stage3/01-session/files/cpz-panel-message
contains stage3/01-session/01-run.sh 'enable cpz-kmscon-output.timer'
contains stage3/01-session/01-run.sh 'system-sleep'
contains stage3/01-session/files/cpz-kmscon-output '--force'
contains stage3/01-session/files/cpz-kmscon-output 'pending_file'
contains stage3/01-session/files/cpz-kmscon-output 'hdmi_debounce=2'
contains stage3/01-session/files/99-cpz-kmscon-output.rules 'systemctl --no-block start'
contains stage3/01-session/files/99-cpz-kmscon-output.rules 'HOTPLUG'
contains stage3/01-session/01-run.sh '99-cpz-kmscon-output.rules'
contains stage3/01-session/files/cpz-kmscon-output '--panel'
contains stage3/01-session/files/cpz-kmscon-output 'status_mode'
contains stage3/01-session/files/cpz-kmscon-output 'hdmi_usable'
contains stage3/01-session/files/cpz-kmscon-output 'hdmi_edid'
contains stage3/01-session/files/cpz-kmscon-output 'hdmi_pinned'
contains stage3/01-session/files/cpz-kmscon-output '--recover'
contains stage3/01-session/files/cpz-kmscon-output 'systemctl restart'
contains stage3/01-session/files/cpz-kmscon-output 'nudge_drm'
not_contains stage3/01-session/files/cpz-kmscon-output 'vt_nudge'
contains stage3/01-session/files/99-cpz-kmscon-nudge.rules 'ENV{HOTPLUG}="1"'
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
contains stage3/01-session/files/cpz-automount 'umount -l'
contains stage3/01-session/files/cpz-automount 'findmnt --fstab'
contains stage3/01-session/01-run.sh '99-cpz-automount.rules'
contains stage3/01-session/01-run.sh 'cpz-automount@.service'
contains stage3/01-session/01-run.sh 'install -d -m 0755 "${ROOTFS_DIR}/media"'
have tests/test_cpz_automount.py
contains stage3/01-session/02-run.sh 'CPZ_HDMI_VIDEO'
contains build.sh 'CPZ_HDMI_VIDEO'
contains config.cpz.example 'CPZ_HDMI_VIDEO'
contains stage3/01-session/files/cpz-kmscon-output 'backlight'
contains stage3/01-session/files/cpz-kmscon-output 'bl_power'
contains stage3/01-session/files/cpz-kmscon-output 'panel_on'
not_contains stage3/01-session/files/cpz-apply-settings 'cpz-screen-timeout'
absent stage3/01-session/files/cpz-screen-timeout
not_contains stage3/01-session/files/cpz-settings '-powerdown'
contains stage3/01-session/files/kmscon.conf 'dpms-timeout'
contains stage3/01-session/files/cmdline.append 'fbcon=map:off'
contains stage3/01-session/02-run.sh "mask getty@tty1.service"
contains stage3/01-session/02-run.sh 'mask tmp.mount'
contains stage3/01-session/01-run.sh 'install -d -m 1777'
have stage3/03-cleanup/00-run.sh
contains stage3/03-cleanup/00-run.sh 'apt-get -s purge'
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
contains stage3/01-session/files/settings.conf 'show_eth=0'
contains stage3/01-session/files/settings.conf 'show_wifi=1'
contains stage3/01-session/files/settings.conf 'show_bt=1'
contains stage3/01-session/files/settings.conf 'display=auto'
contains stage3/01-session/files/settings.conf 'brightness=100'
contains stage3/01-session/files/settings.conf 'screen_timeout=0'
contains stage3/01-session/files/settings.conf 'mode_keys=vi'
contains stage3/01-session/files/settings.conf 'status_interval=5'
contains stage3/01-session/files/settings.conf 'set_clipboard=0'
contains stage3/01-session/files/settings.conf 'automatic_rename=1'
contains stage3/01-session/files/cpz-status 'show_conn'
contains stage3/01-session/files/cpz-status 'show_eth'
contains stage3/01-session/files/cpz-status 'show_wifi'
contains stage3/01-session/files/cpz-status 'show_bt'
contains stage3/01-session/files/cpz-settings 'page_items'
contains stage3/01-session/files/cpz-settings 'Ethernet Indicator'
contains stage3/01-session/files/cpz-settings 'Indicators hide while the interface is off'
contains stage3/01-session/files/cpz-settings 'Brightness'
contains stage3/01-session/files/cpz-settings 'Output Volume'
contains stage3/01-session/files/cpz-settings 'Change Password'
contains stage3/01-session/files/cpz-settings 'VPN'
contains stage3/01-session/files/cpz-settings 'status_interval'
contains stage3/01-session/files/cpz-settings 'Terminal Trove'
contains stage3/01-session/files/cpz-settings 'trove_apps_screen'
contains stage3/01-session/files/cpz-settings 'filter_trove_tools'
contains stage3/01-session/files/cpz-settings 'apt_command_package'
contains stage3/01-session/files/cpz-settings 'trove_apt_names'
contains stage3/01-session/files/cpz-settings 'trove_tool_apt_supported'
contains stage3/01-session/files/cpz-settings 'apt_lists_present'
contains stage3/01-session/files/cpz-settings 'apt_only'
contains stage3/01-session/files/cpz-settings 'apt-cache", "pkgnames'
contains stage3/01-session/files/cpz-settings 'apt-get'
not_contains stage3/01-session/files/cpz-settings 'read_available_packages'
not_contains stage3/01-session/files/cpz-settings 'dumpavail'
contains stage3/01-session/files/cpz-settings 'TROVE_INDEX_DEFAULT_URL'
contains stage3/01-session/01-run.sh 'trove-index'
contains stage3/01-session/01-run.sh 'apt-packages.txt.gz'
contains config.cpz.example 'CPZ_TROVE_INDEX_URL'
contains build.sh 'CPZ_TROVE_INDEX_URL'
contains docs/APPS.md 'apt-get purge'
not_contains stage3/01-session/files/cpz-settings 'Aptitude::Delete-Unused'
not_contains stage3/01-session/00-packages 'aptitude'
contains stage3/01-session/files/cpz-apply-settings 'cpz-brightness'
not_contains stage3/01-session/files/cpz-apply-settings 'setterm'
contains stage3/01-session/files/cpz-apply-settings 'mode-keys'
contains stage3/01-session/files/cpz-apply-settings 'set-clipboard'
contains stage3/01-session/files/cpz-apply-settings 'automatic-rename'
contains stage3/01-session/files/cpz-kmscon-output 'get_setting display'
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
not_contains stage3/01-session/files/cpz-kmscon-config 'cpz-layout.active'
not_contains stage3/01-session/files/cpz-kmscon-config 'xkb-layout='
contains stage3/01-session/files/cpz-keyboard-layout 'publish cpz'
contains stage3/01-session/files/cpz-keyboard-layout 'localectl'
contains stage3/01-session/files/cpz-keyboard-layout 'set-x11-keymap'
contains stage3/01-session/files/cpz-keyboard-layout 'cpz_xkb_template'
contains stage3/01-session/files/cpz-keyboard-layout 'write_cpz_xkb'
have stage3/01-session/files/cpz-font
contains stage3/01-session/files/cpz-font 'font_size'
contains stage3/01-session/files/tmux.conf 'prefix C-a'
contains stage3/01-session/files/tmux.conf 'cpz-font up'
contains stage3/01-session/files/tmux.conf 'cpz-font down'
contains stage3/01-session/files/tmux.conf 'bind -n M-v split-window -h'
contains stage3/01-session/files/tmux.conf 'bind -n M-b split-window -v'
contains stage3/01-session/files/tmux.conf 'bind -n M-n select-pane'
contains stage3/01-session/files/tmux.conf 'bind -n M-p select-pane'
contains stage3/01-session/files/tmux.conf 'bind -n M-z resize-pane -Z'
contains stage3/01-session/files/tmux.conf 'bind -n M-x confirm-before'
contains stage3/01-session/files/tmux.conf 'bind -n M-r command-prompt'
contains stage3/01-session/files/tmux.conf 'bind -n M-l choose-tree'
contains stage3/01-session/files/tmux.conf 'bind -n M-q detach-client'
contains stage3/01-session/files/tmux.conf 'bind -n M-i run-shell'
contains stage3/01-session/files/tmux.conf 'bind -n M-c copy-mode'
contains stage3/01-session/files/tmux.conf 'bind -n M-y paste-buffer'
not_contains stage3/01-session/files/kmscon.conf 'grab-zoom-in='
not_contains stage3/01-session/files/kmscon.conf 'grab-zoom-out='
not_contains stage3/01-session/files/kmscon.conf '<Alt>plus'
not_contains stage3/01-session/files/kmscon.conf '<Alt>minus'
have stage3/01-session/files/cpz-hint
contains stage3/01-session/files/cpz-hint 'display-message -c'
contains stage3/01-session/files/cpz-hint 'V/B split'
contains stage3/01-session/files/tmux.conf 'cpz-hint'
contains stage3/01-session/01-run.sh 'cpz-hint'
contains stage3/01-session/files/cpz-help 'larger / smaller font'
contains stage3/01-session/files/cpz-help 'Alt+V'
contains stage3/01-session/files/cpz-settings 'Alt+V'
contains stage3/01-session/files/cpz-help 'Alt+N / Alt+P'
not_contains stage3/01-session/files/cpz-help 'Ctrl-b'
not_contains stage3/01-session/files/cpz-help 'Ctrl-a '
contains stage3/01-session/files/cpz-tab-info '#{window_index} #{window_active}'
contains stage3/01-session/files/cpz-tab-info 'set-option -t "$session"'
not_contains stage3/01-session/files/cpz-tab-info 'set-option -t "=$session"'
not_contains stage3/01-session/files/cpz-tab-info 'IFS=$tab'
not_contains stage3/01-session/files/cpz-tab-close 'IFS=$tab'
not_contains stage3/01-session/files/cpz-tab-close-key 'IFS=$tab'
not_contains stage3/01-session/files/cpz-session-save 'IFS="$tab" read'
contains stage3/01-session/files/cpz-session-save 'display-message -p -t "$id"'
contains stage3/01-session/files/cpz-settings 'system_info_lines'
contains stage3/01-session/files/cpz-settings 'theme_label'
contains stage3/01-session/files/cpz-settings 'theme_labels'
contains stage3/01-session/files/cpz-kmscon-config '# palette'
contains stage3/01-session/files/cpz-settings 'select_popup'
contains stage3/01-session/files/cpz-settings 'display-popup'
contains stage3/01-session/files/cpz-settings 'Power:'
contains stage3/01-session/files/cpz-bt-agent.service 'rfkill'
contains stage3/01-session/files/cpz-settings 'Key Bindings'
contains stage3/01-session/files/cpz-settings 'Input'
contains stage3/01-session/files/cpz-settings 'keyboard_layout'
contains stage3/01-session/files/settings.conf 'keyboard_layout=auto'
contains stage3/01-session/files/tmux.conf 'M-Space'
contains stage3/01-session/files/tmux.conf 'cpz-layout-next'
contains stage3/01-session/files/tmux.conf 'M-d'
contains stage3/01-session/files/tmux.conf 'cpz-display-toggle'
contains stage3/01-session/01-run.sh 'cpz-display-toggle'
contains stage3/01-session/files/cpz-help 'Alt+D'
contains stage3/01-session/files/cpz-help 'Z/X/C/F'
contains stage3/01-session/files/cpz-help 'Alt+O'
contains stage3/01-session/files/tmux.conf 'cpz-search'
contains stage3/01-session/files/tmux.conf 'bind -n M-o display-popup'
contains stage3/01-session/01-run.sh 'cpz-search'
contains stage3/01-session/files/cpz-settings '--list-pages'
contains stage3/01-session/files/cpz-settings '--page'
contains stage3/01-session/files/cpz-settings '--list-tools'
contains stage3/01-session/files/cpz-settings '--tool'
contains stage3/01-session/files/cpz-search '--with-nth=3'
contains stage3/01-session/files/cpz-search 'DEFAULT_ROOTS'
contains stage3/01-session/files/cpz-search 'safe_eval'
contains stage3/01-session/files/cpz-search '--trove'
contains stage3/01-session/files/cpz-search '--buffers'
contains stage3/01-session/files/cpz-layout-next 'keyboard_layouts'
contains stage3/01-session/files/cpz-layout-next 'cpz-layout-apply'
contains stage3/01-session/files/cpz-layout-apply 'cpz-keyboard-layout.service'
contains stage3/01-session/01-run.sh '50-cpz-layout'
contains stage3/01-session/01-run.sh 'cpz-layout-next'
contains stage3/01-session/01-run.sh 'cpz-layout-map'
contains stage3/01-session/files/cpz-keyboard-layout 'cpz-layout-map'
contains stage3/01-session/files/cpz-keyboard-layout 'prepare_cpz_maps'
contains stage3/01-session/files/cpz-keyboard-layout 'cpz_base_map'
contains stage3/01-session/files/cpz-layout-map 'is_letter'
contains stage3/01-session/files/cpz-layout-map 'render_vt'
contains stage2/05-cardputerzero/01-run.sh 'tca8418_fsm_can_activate'
contains stage2/05-cardputerzero/01-run.sh 'if (device->id == 1)'
contains stage3/01-session/files/cpz-help 'Shift+Sym'
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
contains stage3/01-session/files/cpz-help 'Alt+Space'
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
contains stage3/01-session/files/cpz-settings 'Scan for Devices'
contains stage3/01-session/files/cpz-settings 'Settings refreshed'
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
contains stage3/01-session/files/cpz-kmscon-config 'font_size'
contains stage3/01-session/files/cpz-kmscon 'cpz-kmscon-config'
contains stage3/01-session/01-run.sh 'chown 1000:1000 "$user_config"'
contains stage2/05-cardputerzero/02-run.sh 'chown 1000:1000 "$user_config"'
contains stage3/01-session/files/cpz-settings 'nmtui'
contains stage3/01-session/files/cpz-settings 'bluetoothctl'
contains stage3/01-session/01-run.sh '50-cpz-networkmanager.rules'
contains stage3/01-session/01-run.sh 'cpz-bt-agent.service'
contains stage3/01-session/01-run.sh 'usermod -aG bluetooth'
contains stage3/01-session/02-run.sh 'enable NetworkManager.service'
contains stage3/01-session/files/tmux.conf 'cpz-tab-new'
contains stage3/01-session/files/tmux.conf 'M-w'
contains stage3/01-session/files/tmux.conf 'cpz-tab-close-key'
contains stage3/01-session/files/tmux.conf 'bind -n M-Up copy-mode -u'
contains stage3/01-session/files/tmux.conf 'bind -T copy-mode-vi M-Down send-keys -X page-down'
contains stage3/01-session/files/tmux.conf 'bind -T copy-mode NPage send-keys -X page-down'
contains stage3/01-session/files/cpz-tab-close-key 'confirm-before'
contains stage3/01-session/files/cpz-help 'Alt+W'
contains stage3/01-session/files/cpz-help 'Alt+Up / Alt+Down'
contains stage3/01-session/files/cpz-help 'Fn+L / Fn+M'
contains stage3/01-session/files/cpz-settings 'Alt+Up / Alt+Down'
contains stage3/01-session/files/cpz-settings 'Fn+L / Fn+M'
contains stage3/01-session/files/cpz-help 'less'
contains stage3/01-session/files/cpz-tab-close '@cpz_settings'
not_contains stage3/01-session/files/cpz-tab-close '@cpz_main'
contains stage3/01-session/files/cpz-tab-close 'terminals'
contains stage3/01-session/files/cpz-tab-close 'Last tab stays open'
contains stage3/01-session/files/cpz-tab-close-key '@cpz_settings'
contains stage3/01-session/files/cpz-tab-close-key 'terminals'
not_contains stage3/01-session/files/cpz-tab-info 'cpz_settings'
not_contains stage3/01-session/files/cpz-tab-info 'current=S'
contains stage3/01-session/files/cpz-tab-info 'cpz_tab_total'
contains stage3/01-session/01-run.sh 'cpz-tab-close'
contains stage3/01-session/files/cpz-session-ensure '@cpz_main'
contains stage3/01-session/01-run.sh "kmscon"
contains stage3/01-session/02-run.sh "kmscon"
contains stage3/01-session/02-run.sh "rpi-preseed.service"
contains stage3/01-session/02-run.sh "enable getty@tty1.service"
not_contains stage3/01-session/01-run.sh 'cpz-getty'
absent stage3/01-session/files/cpz-getty
absent stage3/01-session/files/getty@tty1.service.d
contains stage3/01-session/02-run.sh 'enable kmsconvt@tty1.service'
contains stage2/05-cardputerzero/02-run.sh "fb_load.service"
contains stage2/05-cardputerzero/01-run.sh 'panel-mipi-dbi-m.c'
contains stage2/05-cardputerzero/01-run.sh 'drm_client_setup_with_fourcc'
contains stage2/05-cardputerzero/01-run.sh 'cpz-keep-panel-fbdev'
contains stage2/05-cardputerzero/02-run.sh '99-cardputer-zero-lcd.rules'
contains stage2/05-cardputerzero/02-run.sh '99-cpz-display.rules'
have stage2/05-cardputerzero/files/99-cpz-display.rules
contains stage2/05-cardputerzero/files/99-cpz-display.rules 'ENV{ID_SEAT}="seat0"'
not_contains stage2/05-cardputerzero/files/99-cpz-display.rules 'ENV{ID_SEAT}="seat-cardputer-zero"'
contains stage3/01-session/02-run.sh 'fbcon=map:10'
contains build.sh 'STAGE_LIST=${STAGE_LIST:-${BASE_DIR}/stage*}'
not_contains config.cpz.example 'STAGE_LIST='
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
if grep -qx 'mc' "$ROOT/stage3/01-session/00-packages"; then
	ok
else
	bad "stage3/01-session/00-packages does not install mc"
fi
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
absent tests/shell/test-hdmi-console.sh
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

echo "== release checks =="
have VERSION
if grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$' VERSION; then ok; else bad "VERSION is not SemVer"; fi
contains build.sh 'CPZ_VERSION'
contains export-image/05-finalise/01-run.sh 'cpz-version'
have tools/release.sh
contains tools/release.sh 'git tag -a'
contains tools/release.sh 'refs/tags/$tag'
contains tools/release.sh 'git commit -m "chore(release): $tag"'
have .github/workflows/build.yml
contains .github/workflows/build.yml 'types: [published]'
not_contains .github/workflows/build.yml 'push:
    tags:'
contains .github/workflows/build.yml 'gh release create'
contains .github/workflows/build.yml 'scripts/update_os_list.py'
contains .github/workflows/build.yml 'VERSION ($FILE_VERSION) does not match tag'
contains scripts/update_os_list.py 'os_entry_name'
have tests/test_update_os_list.py
contains build.sh 'https://github.com/jmas/cpzos'
contains scripts/update_os_list.py '"repo": "jmas/cpzos"'

echo
echo "verify-stage: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
