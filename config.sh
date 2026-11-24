# Shared build configuration for cpz-arch.
# Sourced by every script in scripts/ and by the Makefile.
#
# Everything here is a deliberate choice. Change a value, re-run `make image`.

CPZ_ARCH_VERSION="0.1.0"

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

# HDMI/vc4. On: the session can use the internal panel or an HDMI monitor.
# Off: the panel is the only DRM card, which removes the vc4 probe from the
# boot path.
ENABLE_HDMI="1"

# SSH over Ethernet. On: installs openssh and brings up any wired interface
# with DHCP through systemd-networkd + systemd-resolved. The login is the normal
# account (cpz/cpz), so this is a development convenience, not a default:
# change the password before putting the device on an untrusted network.
ENABLE_SSH="1"

# ---------------------------------------------------------------------------
# Identity
# ---------------------------------------------------------------------------
HOSTNAME="cpz"
USER_NAME="cpz"
USER_PASS="cpz"
# No locale-gen: glibc provides C.UTF-8 without generated locale files. C.UTF-8
# is enough for UTF-8 terminal output and Cyrillic; DejaVu Sans Mono supplies
# the glyphs. Switch to e.g. en_US.UTF-8 and add `locales` to EXTRA_PACKAGES if a
# program insists on a named locale.
LOCALE="C.UTF-8"
TIMEZONE="UTC"
# Physical keyboard layout(s) for the terminal session. fbcon is not used.
XKB_LAYOUT="us,ua"
XKB_OPTIONS="grp:alt_shift_toggle"

# ---------------------------------------------------------------------------
# Image geometry
# ---------------------------------------------------------------------------
BOOT_MB="64"
# Root size in MiB. `make image` refuses to build if the rootfs does not fit.
# The economy stack (terminal, tmux, TUI apps, Python, git, vim) uses about
# 771 MiB. 832 MiB leaves room for package updates without wasting a large
# unallocated tail on the SD card.
ROOT_MB="832"

# Deterministic MBR disk identifier. PARTUUIDs are derived from it:
#   <DISK_ID>-01 = boot (FAT32) and -02 = root (ext4)
DISK_ID="c0de2710"

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------
# `base` is the only meta group. Everything else is explicit on purpose.
BASE_PACKAGES="base"
DEVICE_PACKAGES="linux-rpi"
BOOT_PACKAGES="raspberrypi-bootloader"
TOOLS_PACKAGES="sudo libdrm"

# The economy UI has no SDL/Mesa/Pango/Cairo in the base image. The terminal
# renders into DRM dumb buffers with FreeType; tmux and the TUI apps need
# ncurses; XKB/evdev provide input; icons are raw RGBA.
GRAPHICS_PACKAGES="libdrm freetype2 libxkbcommon xkeyboard-config libevdev ncurses libtsm"
FONT_PACKAGES="ttf-dejavu"
INPUT_PACKAGES=""
AUDIO_PACKAGES="alsa-ucm-conf alsa-utils"
UI_TOOL_PACKAGES="tmux git python vim nnn htop less cmus"
GRAPHICS_PACKAGES="$GRAPHICS_PACKAGES $FONT_PACKAGES $AUDIO_PACKAGES $UI_TOOL_PACKAGES"

# Applications are installed separately. The terminal keeps libtsm; media
# decoders and GUI toolkits are not part of the base economy image.
APP_PACKAGES=""

if [ "$ENABLE_SSH" = "1" ]; then
    NETWORK_PACKAGES="openssh iwd bluez"
else
    NETWORK_PACKAGES="iwd bluez"
fi

# Installed only to build the vendor modules and our binaries, removed before
# the image is made. pkgconf is needed by the app build stage.
BUILD_PACKAGES="linux-rpi-headers gcc make bc dtc pahole pkgconf"

# Removed after the build if nothing needs them. Each entry is tried
# individually, so a package that turns out to be a dependency is kept and
# reported instead of failing the build. None of them is on the boot path.
PRUNE_PACKAGES="cryptsetup device-mapper tpm2-tss libsecret gnupg gpgme pinentry
	nftables iptables libnftnl libnetfilter_conntrack libnfnetlink libmnl libpcap
	hwdata licenses icu krb5 libldap sqlite lmdb perl guile gc"

# Add packages here (for example: "nano htop"). Empty by default.
EXTRA_PACKAGES=""
