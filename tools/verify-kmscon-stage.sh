#!/bin/bash
# Host-side structural checks for the CPZ kmscon image branch.
# No root, Docker or ARM hardware required.
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

echo "== stage layout =="
for file in \
	stage3/prerun.sh \
	stage3/EXPORT_IMAGE \
	stage3/00-kmscon/00-run.sh \
	stage3/01-session/00-packages \
	stage3/01-session/01-run.sh \
	stage3/01-session/02-run.sh \
	stage3/01-session/files/kmscon.conf \
	stage3/01-session/files/cpz-kmscon \
	stage3/01-session/files/cpz-login \
	stage3/01-session/files/cpz-session.sh \
	stage3/01-session/files/tmux.conf \
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
	stage3/00-kmscon/00-run.sh \
	stage3/01-session/01-run.sh \
	stage3/01-session/02-run.sh \
	stage3/01-session/files/cpz-kmscon \
	stage3/01-session/files/cpz-login \
	stage3/01-session/files/cpz-session.sh \
	tools/verify-kmscon-stage.sh \
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

echo "== kmscon session =="
contains stage3/00-kmscon/00-run.sh "10.0.4-1~bpo13+1"
contains stage3/01-session/files/kmscon.conf "multi-monitor=scaled"
contains stage3/01-session/files/kmscon.conf "font-name=Terminus"
contains stage3/01-session/files/tmux.conf "status-position top"
contains stage3/01-session/02-run.sh "kmsconvt@tty1.service"
contains stage3/01-session/02-run.sh "kmsconvt@tty2.service"
contains stage3/01-session/02-run.sh "rpi-preseed.service"
contains stage3/01-session/02-run.sh "mask getty@tty1.service"
contains stage2/05-cardputerzero/02-run.sh "fb_load.service"
contains build.sh 'STAGE_LIST=${STAGE_LIST:-${BASE_DIR}/stage*}'
not_contains config.cpz.example 'STAGE_LIST='
not_contains stage2/05-cardputerzero/02-run.sh 'cmdline.txt'
not_contains export-image/04-set-partuuid/00-run.sh 'console=serial0,115200'
contains stage3/01-session/02-run.sh 'remove_cmdline_tokens'
contains stage3/01-session/files/cmdline.append 'fbcon=map:off'
not_contains stage3/01-session/files/cancel-rename 'greetd'

echo
echo "verify-kmscon-stage: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
