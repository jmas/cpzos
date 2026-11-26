# Shared build configuration for cpz-arch.
# Sourced by every script in scripts/ and by the Makefile.
#
# This tree is a base distribution only: kernel, firmware, hardware drivers,
# networking and a login path. It defines no display stack and no UI. Everything
# here is a deliberate choice. Change a value, re-run `make image`.

CPZ_ARCH_VERSION="0.1.0"

# Build a hardware-test image with the UI package installed. The default is the
# clean base image. Set UI_TEST=1 for `make verify UI_TEST=1`.
UI_TEST="${UI_TEST:-0}"

# ---------------------------------------------------------------------------
# Base distribution
# ---------------------------------------------------------------------------
# Arch Linux ARM is the only aarch64 Arch. The tarball is used only to bootstrap
# pacman; the actual rootfs is installed from scratch with `pacman --root`.
ALARM_TARBALL="https://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz"
BUILDER_IMAGE="cpz-arch-builder"
TARGET_ARCH="aarch64"

# ---------------------------------------------------------------------------
# Cardputer Zero
# ---------------------------------------------------------------------------
# v5 = current production board (cardputerzero-v5-overlay + bq27220_v5).
# v3 = older board (cardputerzero-v3-overlay + bq27220_v3 + spk-gpio24 overlay).
BOARD="v5"

# Vendor out-of-tree kernel modules + device-tree overlays. Pinned to the same
# commit the main CPZ image uses, so both trees describe the same hardware.
DTOVERLAYS_URL="https://github.com/m5stack/m5stack-linux-dtoverlays.git"
DTOVERLAYS_REF="4f7aeee9fc103ebb03d22cac476bb191ecfb321e"

# Display hardware enablement. The base ships the DRM cards and overlays but
# no compositor or terminal; the UI layer chooses and drives one output.
# HDMI/vc4: on enables the vc4 overlay and GPU memory. Panel: always enabled by
# the board overlay plus the cpz-spi chip-select workaround.
ENABLE_HDMI="1"

# SSH over Ethernet. On: installs openssh and brings up any wired interface
# with DHCP through systemd-networkd + systemd-resolved. This is the primary
# login path while the image has no display stack.
ENABLE_SSH="1"

# UI language for console apps (see docs/LANGUAGE.md). Written to
# /etc/cpz/language; a user can override it in ~/.config/cpz/language.
UI_LANGUAGE="en"

# ---------------------------------------------------------------------------
# Identity
# ---------------------------------------------------------------------------
HOSTNAME="cpz"
USER_NAME="cpz"
USER_PASS="cpz"
# No locale-gen: glibc provides C.UTF-8 without generated locale files.
LOCALE="C.UTF-8"
TIMEZONE="UTC"

# ---------------------------------------------------------------------------
# Image geometry
# ---------------------------------------------------------------------------
BOOT_MB="64"
# Root size in MiB. `make image` refuses to build if the rootfs does not fit.
# The base (kernel, firmware, hardware modules, networking) is much smaller
# than the UI image; the UI test build uses a larger root.
ROOT_MB="768"
if [ "$UI_TEST" = "1" ]; then
    # Room for installed apps: Midnight Commander, Doom and their engines.
    ROOT_MB="1536"
fi

# Deterministic MBR disk identifier. PARTUUIDs are derived from it:
#   <DISK_ID>-01 = boot (FAT32) and -02 = root (ext4)
DISK_ID="c0de2710"

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------
# `base` is the only meta group. Everything else is explicit on purpose.
# archlinuxarm-keyring is the ARM build key: without it the target keyring can
# read the ALARM repositories but cannot verify their packages, so every
# `pacman -Syu` on the device fails with "unknown trust".
BASE_PACKAGES="base archlinuxarm-keyring"
DEVICE_PACKAGES="linux-rpi"
BOOT_PACKAGES="raspberrypi-bootloader"
TOOLS_PACKAGES="sudo"

if [ "$ENABLE_SSH" = "1" ]; then
    NETWORK_PACKAGES="openssh iwd bluez"
else
    NETWORK_PACKAGES="iwd bluez"
fi

# ---------------------------------------------------------------------------
# UI package repository
# ---------------------------------------------------------------------------
# The UI ships as pacman packages, separately from the base image. Stable is
# enabled in /etc/pacman.conf; beta is installed as an opt-in include.
UI_REPO_STABLE='https://github.com/jmas/cpzos/releases/download/ui-stable'
UI_REPO_BETA='https://github.com/jmas/cpzos/releases/download/ui-beta'
UI_REPO_KEY="keys/cpz-ui-signing.asc"
UI_REPO_KEY_FPR="C7DBEDC1B4855ACB0570C7D229C04B0663395458"

# App repository (Apps Manager and its catalog). Empty in the base image: a
# Server that points at a missing release makes every `pacman -Sy` fail, so the
# Include is written only when a repository really exists. A `file://` value is
# a local test build: the repository directory is copied into the image at
# /opt/cpz/apps-repo and pacman reads it there. Release images use the signed
# app release URL and keep required signatures.
UI_APPS_REPO_STABLE="${UI_APPS_REPO_STABLE:-}"
UI_APPS_REPO_BETA=""
UI_APPS_SIGLEVEL="${UI_APPS_SIGLEVEL:-Required DatabaseRequired}"

# Optional release pin for the catalog package. Empty takes the current
# repository version; release builds set both and fail on a mismatch.
UI_APPS_CATALOG_VERSION="${UI_APPS_CATALOG_VERSION:-}"
UI_APPS_CATALOG_SHA256="${UI_APPS_CATALOG_SHA256:-}"

# Runtime dependencies installed into the UI test image. The UI package itself
# comes from the locally built out/ui/packages/stable directory.
UI_TEST_PACKAGES="cage foot tmux fzf j4-dmenu-desktop desktop-file-utils
	xorg-xwayland mesa ttf-dejavu xkeyboard-config"

# Installed only to build the vendor modules, removed before the image is made.
BUILD_PACKAGES="linux-rpi-headers gcc make bc dtc pahole pkgconf"

# Removed after the build if nothing needs them. Each entry is tried
# individually, so a package that turns out to be a dependency is kept and
# reported instead of failing the build. None of them is on the boot path.
PRUNE_PACKAGES="cryptsetup device-mapper tpm2-tss libsecret gnupg gpgme pinentry
	nftables iptables libnftnl libnetfilter_conntrack libnfnetlink libmnl libpcap
	hwdata licenses icu krb5 libldap sqlite lmdb perl guile gc"

# Add packages here (for example: "nano htop"). Empty by default.
EXTRA_PACKAGES=""
