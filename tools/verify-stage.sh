#!/bin/bash
# Host-side structural checks for the CPZ fbcon image branch.
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
for line in text.splitlines():
    match = re.match(r'set -g ([\w-]+)-style "([^"]*)"', line)
    if not match:
        continue
    name, spec = match.groups()
    fg = re.search(r"fg=(#[0-9a-fA-F]{6})", spec)
    bg = re.search(r"bg=(#[0-9a-fA-F]{6})", spec)
    if fg and bg and contrast(fg.group(1), bg.group(1)) < 4.5:
        errors.append(f"{name} {contrast(fg.group(1), bg.group(1)):.2f}")

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
else:
    background = "#" + embedded[0]
    for index in range(1, 16):
        ratio = contrast("#" + embedded[index], background)
        if ratio < 4.5:
            errors.append(f"palette {index} {ratio:.2f}")

if errors:
    print("; ".join(errors), file=sys.stderr)
    sys.exit(1)
PY
	then
		ok
	else
		bad "$1: low contrast or palette mismatch"
	fi
}

echo "== stage layout =="
for file in \
	stage3/prerun.sh \
	stage3/EXPORT_IMAGE \
	stage3/01-session/00-packages \
	stage3/01-session/01-run.sh \
	stage3/01-session/02-run.sh \
	stage3/01-session/files/cpz-getty \
	stage3/01-session/files/cpz-first-login \
	stage3/01-session/files/getty@tty1.service.d/10-cpz-autologin.conf \
	stage3/01-session/files/cpz-hdmi-console \
	stage3/01-session/files/cpz-hdmi-console.service \
	stage3/01-session/files/cpz-hdmi-console.timer \
	stage3/01-session/files/cpz-hdmi-sleep \
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
	stage3/01-session/files/cpz-console-theme \
	stage3/01-session/files/cpz-help \
	stage3/01-session/files/cpz-session-save \
	stage3/01-session/files/cpz-session-restore \
	stage3/01-session/files/cpz-session-save-as-user \
	stage3/01-session/files/cpz-session-save.service \
	stage3/01-session/files/cpz-session-save.timer \
	stage3/01-session/files/cpz-conn-status \
	stage3/01-session/files/cpz-conn-status.service \
	stage3/01-session/files/cpz-conn-status.timer \
	stage3/01-session/files/cpz-brightness \
	stage3/01-session/files/cpz-screen-timeout \
	stage3/01-session/files/cpz-keyboard-layout \
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
	stage3/01-session/files/themes/cpz-tokyo-night.conf \
	stage3/01-session/files/cancel-rename \
	config.cpz.example \
	config.debug.example \
	docs/M5-IMAGER.md \
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
	stage3/01-session/01-run.sh \
	stage3/01-session/02-run.sh \
	stage3/01-session/files/cpz-getty \
	stage3/01-session/files/cpz-first-login \
	stage3/01-session/files/cpz-hdmi-console \
	stage3/01-session/files/cpz-hdmi-sleep \
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
	stage3/01-session/files/cpz-console-theme \
	stage3/01-session/files/cpz-help \
	stage3/01-session/files/cpz-session-save \
	stage3/01-session/files/cpz-session-restore \
	stage3/01-session/files/cpz-session-save-as-user \
	stage3/01-session/files/cpz-conn-status \
	stage3/01-session/files/cpz-brightness \
	stage3/01-session/files/cpz-screen-timeout \
	stage3/01-session/files/cpz-keyboard-layout \
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
contains stage3/01-session/files/cpz-first-login 'passwd'
contains stage3/01-session/files/cpz-session.sh 'cpz-console-theme'
contains stage3/01-session/files/cpz-conn-status.timer 'OnUnitActiveSec=30s'
contains stage3/01-session/files/cpz-session-save.timer 'OnUnitActiveSec=5min'
contains stage3/01-session/files/cpz-hdmi-console 'select_console_font'
contains stage3/01-session/files/cpz-hdmi-console 'Terminus18x10'
contains stage3/01-session/files/cpz-hdmi-console 'Terminus24x12'
contains stage3/01-session/files/cpz-hdmi-console 'get_setting font_panel'
contains stage3/01-session/files/cpz-hdmi-console 'get_setting font_hdmi'
contains stage3/01-session/files/cpz-hdmi-console 'Terminus16.psf.gz'
contains stage3/01-session/files/cpz-settings 'Panel Text Size'
contains stage3/01-session/files/cpz-settings 'HDMI Text Size'
contains stage3/01-session/files/settings.conf 'font_panel=6x12'
contains stage3/01-session/files/settings.conf 'font_hdmi=auto'
contains stage3/01-session/01-run.sh 'Terminus18x10'
contains stage3/01-session/01-run.sh 'Terminus24x12'
contains stage3/01-session/files/cpz-status '/run/cpz-conn'
contains stage3/01-session/files/cpz-status 'show_volume'
contains stage3/01-session/files/cpz-status 'show_brightness'
contains stage3/01-session/files/cpz-status '/sys/class/backlight'
contains stage3/01-session/files/cpz-status 'DEFAULT_AUDIO_SINK'
contains stage3/01-session/files/cpz-status '#[fg=red]'
contains stage3/01-session/files/cpz-status '#[fg=yellow]'
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
contains stage3/01-session/files/cpz-apply-settings 'cpz-console-theme'
contains stage3/01-session/files/cpz-apply-settings '--theme'
contains stage3/01-session/files/cpz-apply-settings 'window-active-style'
contains stage3/01-session/files/cpz-apply-settings 'pane-colours'
contains stage3/01-session/files/cpz-apply-settings 'list-clients'
contains stage3/01-session/files/cpz-apply-settings 'refresh-client -t'
contains stage3/01-session/files/cpz-settings 'cpz-apply-settings'
contains stage3/01-session/files/cpz-settings 'refresh_clients'
contains stage3/01-session/files/cpz-settings 'NAV_UP'
contains stage3/01-session/files/cpz-settings 'ord("z")'
contains stage3/01-session/files/cpz-settings 'cpz-console-theme'
contains stage3/01-session/files/cpz-console-theme ']P%X%s'
contains stage3/01-session/files/cpz-session.sh 'cpz-session-restore'
contains stage3/01-session/files/cpz-session-ensure '@cpz_restoring'
contains stage3/01-session/files/tmux.conf 'cpz-session-save'
contains stage3/01-session/01-run.sh 'enable cpz-session-save.timer'
contains stage3/01-session/files/cpz-session.sh '/dev/tty1'
contains stage3/01-session/01-run.sh 'cpz-hdmi-console'
absent stage3/01-session/files/cpz-panel-message
contains stage3/01-session/01-run.sh 'enable cpz-hdmi-console.timer'
contains stage3/01-session/01-run.sh 'system-sleep'
contains stage3/01-session/files/cpz-hdmi-console '--force'
contains stage3/01-session/files/cpz-hdmi-console 'resize-window'
contains stage3/01-session/files/cpz-hdmi-console 'pending_file'
contains stage3/01-session/files/cpz-hdmi-console 'hdmi_debounce=2'
contains stage3/01-session/files/cpz-hdmi-console 'decide_target "$override" "$connected" "$ready"'
contains stage3/01-session/files/99-cpz-hdmi-console.rules 'systemctl --no-block start'
contains stage3/01-session/files/99-cpz-hdmi-console.rules 'HOTPLUG'
contains stage3/01-session/01-run.sh '99-cpz-hdmi-console.rules'
contains stage3/01-session/files/cpz-hdmi-console 'unblank_fb'
contains stage3/01-session/files/cpz-hdmi-console '--panel'
contains stage3/01-session/files/cpz-hdmi-console 'console_geometry'
contains stage3/01-session/files/cpz-hdmi-console 'status_mode'
contains stage3/01-session/files/cpz-hdmi-console 'hdmi_ready'
contains stage3/01-session/files/cpz-hdmi-console 'hdmi_edid_size'
contains stage3/01-session/files/cpz-hdmi-console 'hdmi_edid_ok'
contains stage3/01-session/files/cpz-hdmi-console 'hdmi_pinned_token'
contains stage3/01-session/files/cpz-hdmi-console 'auto decision'
contains stage3/01-session/files/cpz-hdmi-console 'hdmi_preferred_mode'
contains stage3/01-session/files/cpz-hdmi-console '--recover'
contains stage3/01-session/files/cpz-hdmi-console 'fallback_file'
contains stage3/01-session/files/cpz-hdmi-console 'fb_blank_level'
contains stage3/01-session/files/cpz-hdmi-console 'blank_state_file'
contains stage3/01-session/files/cpz-screen-timeout '-powerdown 0'
contains stage3/01-session/files/cpz-settings '-powerdown", "0"'
contains stage3/01-session/02-run.sh 'CPZ_HDMI_VIDEO'
contains build.sh 'CPZ_HDMI_VIDEO'
contains config.cpz.example 'CPZ_HDMI_VIDEO'
contains stage3/01-session/files/cpz-hdmi-console 'virtual_size'
contains stage3/01-session/files/cpz-hdmi-console 'backlight'
contains stage3/01-session/files/cpz-hdmi-console 'bl_power'
contains stage3/01-session/files/cpz-hdmi-console 'clear_fb'
contains stage3/01-session/files/cpz-hdmi-console 'panel_display_off'
contains stage3/01-session/files/cmdline.append 'consoleblank=0'
contains stage3/01-session/02-run.sh 'enable getty@tty3.service'
contains stage3/01-session/02-run.sh 'mask tmp.mount'
contains stage3/01-session/01-run.sh 'install -d -m 1777'
contains stage3/01-session/files/settings.conf 'theme=cpz-tokyo-night'
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
contains stage3/01-session/files/cpz-apply-settings 'cpz-brightness'
contains stage3/01-session/files/cpz-apply-settings 'cpz-screen-timeout'
contains stage3/01-session/files/cpz-apply-settings 'mode-keys'
contains stage3/01-session/files/cpz-apply-settings 'set-clipboard'
contains stage3/01-session/files/cpz-apply-settings 'automatic-rename'
contains stage3/01-session/files/cpz-hdmi-console 'display='
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
contains stage3/01-session/files/cpz-settings 'system_info_lines'
contains stage3/01-session/files/cpz-settings 'theme_label'
contains stage3/01-session/files/cpz-settings 'theme_labels'
contains stage3/01-session/files/cpz-console-theme '# palette'
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
contains stage3/01-session/files/cpz-layout-next 'keyboard_layouts'
contains stage3/01-session/files/cpz-layout-next 'cpz-layout-apply'
contains stage3/01-session/files/cpz-layout-apply 'cpz-keyboard-layout.service'
contains stage3/01-session/01-run.sh '50-cpz-layout'
contains stage3/01-session/01-run.sh 'cpz-layout-next'
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
contains stage3/01-session/01-run.sh 'cpz-font-blocks'
contains stage3/01-session/files/cpz-font-blocks '0x2580'
contains stage3/01-session/files/cpz-font-blocks '0x2584'
contains stage3/01-session/01-run.sh 'cpz-font-scale'
contains stage3/01-session/files/cpz-font-scale 'nearest'
contains stage3/01-session/files/cpz-hdmi-console 'hdmi_target_rows'
contains stage3/01-session/files/cpz-hdmi-console 'select_auto_hdmi_font'
contains stage3/01-session/files/cpz-hdmi-console 'cpz-font-scale'
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
contains stage3/01-session/files/cpz-tab-close-key 'confirm-before'
contains stage3/01-session/files/cpz-help 'Alt+W'
contains stage3/01-session/files/cpz-help 'less'
contains stage3/01-session/files/cpz-tab-close '@cpz_settings'
contains stage3/01-session/files/cpz-tab-close '@cpz_main'
contains stage3/01-session/files/cpz-tab-close-key '@cpz_settings'
contains stage3/01-session/files/cpz-tab-info 'cpz_settings'
contains stage3/01-session/files/cpz-tab-info 'cpz_tab_total'
contains stage3/01-session/01-run.sh 'cpz-tab-close'
contains stage3/01-session/files/cpz-session-ensure '@cpz_main'
not_contains stage3/01-session/01-run.sh "kmscon"
not_contains stage3/01-session/02-run.sh "kmscon"
contains stage3/01-session/02-run.sh "rpi-preseed.service"
contains stage3/01-session/02-run.sh "enable getty@tty1.service"
contains stage3/01-session/01-run.sh 'getty@tty1.service.d'
contains stage3/01-session/01-run.sh 'cpz-getty'
contains stage3/01-session/files/cpz-getty 'getent passwd 1000'
contains stage3/01-session/files/cpz-getty '--autologin'
contains stage3/01-session/files/getty@tty1.service.d/10-cpz-autologin.conf '/usr/local/bin/cpz-getty'
contains stage3/01-session/02-run.sh \
	'rm -f /etc/systemd/system/getty@tty1.service.d/10-cpz-autologin.conf'
contains stage2/05-cardputerzero/02-run.sh "fb_load.service"
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
not_contains stage3/01-session/00-packages 'fonts-dejavu-core'
not_contains stage3/01-session/00-packages 'fontconfig'
not_contains stage3/01-session/00-packages 'fonts-terminus-otb'
not_contains stage3/01-session/00-packages 'xdg-utils'
not_contains stage3/01-session/00-packages 'alsa-utils'
contains stage3/01-session/files/cpz-settings 'devices Connected'
not_contains stage3/01-session/files/cancel-rename 'greetd'

echo "== cpz session helpers =="
python_ok stage3/01-session/files/cpz-settings
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
have tests/shell/test-hdmi-console.sh
have .github/workflows/ci.yml
contains .github/workflows/ci.yml 'pull_request'
contains .github/workflows/ci.yml './tools/verify-stage.sh'
contains .github/workflows/ci.yml './tests/run.sh'
contains .github/workflows/ci.yml './tests/lint.sh'
contains tests/lint.sh 'shellcheck'
contains tests/lint.sh 'ruff'
contains tests/lint.sh 'mypy'
contains tests/shell/test-hdmi-console.sh 'CPZ_HDMI_CONSOLE_LIB'
contains tests/test_cpz_settings.py 'check_pages'

echo
echo "verify-stage: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
