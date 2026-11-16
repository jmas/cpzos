#!/bin/sh
# Unit tests for the pure helpers in cpz-hdmi-console.
#
# The script is sourced with CPZ_HDMI_CONSOLE_LIB=1, which stops it before the
# live framebuffer/console code. sysfs readers and the font setters are then
# replaced with stubs so every decision can be checked without hardware.
# shellcheck disable=SC2034  # globals below are read by the sourced script
set -u

here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH='' cd -- "$here/../.." && pwd)
console=$root/stage3/01-session/files/cpz-hdmi-console

pass=0
fail=0

check() {
	desc=$1
	want=$2
	got=$3
	if [ "$want" = "$got" ]; then
		pass=$((pass + 1))
	else
		printf 'FAIL: %s: want %s, got %s\n' "$desc" "$want" "$got" >&2
		fail=$((fail + 1))
	fi
}

# shellcheck disable=SC1090,SC1091  # resolved relative to this test at runtime
CPZ_HDMI_CONSOLE_LIB=1 . "$console"

# --- output policy ---------------------------------------------------------
check "auto + readable EDID -> HDMI" hdmi "$(decide_target '' 1 1 0 1)"
check "auto + no EDID -> panel" panel "$(decide_target '' 1 0 0 1)"
check "auto + disconnected -> panel" panel "$(decide_target '' 0 0 0 1)"
check "display=panel wins" panel "$(decide_target panel 1 1 0 1)"
check "display=hdmi + disconnected -> panel" panel "$(decide_target hdmi 0 0 0 1)"
check "display=hdmi + connected -> HDMI" hdmi "$(decide_target hdmi 1 0 0 1)"
check "one framebuffer -> panel" panel "$(decide_target '' 1 1 0 0)"

# --- font selection --------------------------------------------------------
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

mkdir -p "$tmp"
for size in 12 16 18 20 22 24 28 32; do
	: >"$tmp/f$size"
done
panel_font=$tmp/f12
panel_font_large=$tmp/f16
hdmi_font_18=$tmp/f18
hdmi_font_20=$tmp/f20
hdmi_font_22=$tmp/f22
hdmi_font_24=$tmp/f24
hdmi_font_28=$tmp/f28
hdmi_font_32=$tmp/f32

test_w=0
test_h=0
target=0
fb_width() { printf '%s' "$test_w"; }
fb_height() { printf '%s' "$test_h"; }

# choose_font / make_scaled_font normally touch the console. Record the
# choice in the globals select_console_font() sets and report success.
choose_font() {
	font=$1
	cell_w=$2
	cell_h=$3
}
make_scaled_font() {
	font="scaled-$4x$5"
	cell_w=$4
	cell_h=$5
}

pick_auto() {
	test_w=$1
	test_h=$2
	select_auto_hdmi_font
	printf '%sx%s' "$cell_w" "$cell_h"
}

check "1280x720 -> native 14x28" "14x28" "$(pick_auto 1280 720)"
check "1024x600 -> native 12x24" "12x24" "$(pick_auto 1024 600)"
check "800x480 -> native 10x20" "10x20" "$(pick_auto 800 480)"
check "1920x1080 -> scaled 22x44" "22x44" "$(pick_auto 1920 1080)"
check "3840x2160 -> scaled 42x84" "42x84" "$(pick_auto 3840 2160)"
check "no geometry -> 10x18 fallback" "10x18" "$(pick_auto 0 0)"

# get_setting reads settings.conf from the live system; replace it with the
# values each case wants to exercise.
panel_setting=auto
hdmi_setting=auto
get_setting() {
	case "$1" in
		font_panel) printf '%s' "$panel_setting" ;;
		font_hdmi) printf '%s' "$hdmi_setting" ;;
		display) printf 'auto' ;;
	esac
}

target=1
hdmi_fb=0
panel_setting=6x12
select_console_font
check "panel default -> 6x12" "6x12" "${cell_w}x${cell_h}"

panel_setting=8x16
select_console_font
check "panel large -> 8x16" "8x16" "${cell_w}x${cell_h}"

target=0
hdmi_setting=16x32
select_console_font
check "HDMI 16x32 pinned" "16x32" "${cell_w}x${cell_h}"

hdmi_setting=20x40
select_console_font
check "HDMI 20x40 scaled" "20x40" "${cell_w}x${cell_h}"

hdmi_setting=auto
test_w=1280
test_h=720
select_console_font
check "HDMI auto follows the mode" "14x28" "${cell_w}x${cell_h}"

# --- console geometry ------------------------------------------------------
test_w=320
test_h=170
check "panel geometry at 6x12" "14 53" "$(expected_geometry 1 6 12)"
test_w=1920
test_h=1080
check "HDMI geometry at 14x28" "38 137" "$(expected_geometry 0 14 28)"

printf 'hdmi-console: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
