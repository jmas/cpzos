#!/bin/bash -e

# Trim build-only, obsolete and duplicate packages once the image is
# assembled. Everything listed here is optional at runtime:
#
#   * the CardputerZero kernel modules are compiled in stage2/05, and
#     rpi-update is deliberately absent, so no C toolchain is needed later;
#   * the panel is DRM-only (no /dev/fb1, fbcon off), so fbdev helpers such as
#     fbset cannot do anything;
#   * the remaining entries duplicate a package that stays installed
#     (7zip vs p7zip-full, vim vs vim-tiny, iproute2 vs net-tools, iw vs
#     wireless-tools, bluetoothctl vs bluez-tools, grep vs ack).
#
# Every purge is simulated on its own first. If apt would also remove a
# package outside this list (a changed dependency, a metapackage that still
# pulls the tool in), the package is kept and the build continues, so a future
# archive update cannot silently break the session.

on_chroot << 'CHROOT'
set -e

PACKAGES="
	p7zip-full
	vim-tiny
	ed
	ack
	net-tools
	wireless-tools
	bluez-tools
	lua5.1
	luajit
	manpages-dev
	fbset
	dmidecode
	ueberzug
	debconf-utils

	build-essential
	gcc
	g++
	cpp
	make
	gdb
	strace
	binutils
	libc6-dev
	linux-libc-dev
	pkg-config
	dpkg-dev
	fakeroot
	patch
	device-tree-compiler
	pahole
	git
	git-man

	rpi-eeprom
	raspi-utils-eeprom
	rpieepromab
	librpieepromab0
"

installed=""
for package in $PACKAGES; do
	if dpkg-query -W -f='${Status}' "$package" 2>/dev/null |
		grep -q "install ok installed"; then
		installed="$installed $package"
	fi
done

[ -n "$installed" ] || exit 0

# p7zip-full is only a transitional alias for 7zip. When it was installed from
# an older package list, 7zip is an automatic dependency and autoremove would
# take the real archiver together with the alias.
if dpkg-query -W -f='${Status}' 7zip 2>/dev/null |
	grep -q "install ok installed"; then
	apt-mark manual 7zip >/dev/null
fi

purge=""
for package in $installed; do
	planned=$(apt-get -s purge "$package" 2>/dev/null |
		awk '/^(Purg|Remv) /{print $2}' || true)
	conflict=""
	for other in $planned; do
		other="${other%%:*}"
		case " $installed " in
			*" $other "*) ;;
			*) conflict="$other" ;;
		esac
	done
	if [ -n "$conflict" ]; then
		echo "cpz-cleanup: keeping $package (apt would also remove $conflict)"
	else
		purge="$purge $package"
	fi
done

[ -n "$purge" ] || exit 0

echo "cpz-cleanup: purging$purge"
apt-get purge -y $purge
apt-get autoremove --purge -y
CHROOT
