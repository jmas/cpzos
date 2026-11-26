#!/bin/bash
# Stage 10 — build a minimal Arch Linux ARM rootfs from scratch.
#
# There is no debootstrap and no distro tarball here: pacman installs into an
# empty directory. Only `base` and the device packages are installed; every
# later optimization (removals, masks, config) is explicit in stage 30.
set -euo pipefail
cd "$(dirname "$0")/.."
. ./config.sh
. scripts/lib.sh

require pacman

log "building rootfs at $ROOT"
rm -rf "$ROOT"
mkdir -p "$ROOT" "$BUILD/pacman-cache"

# Minimal directory skeleton. `pacman --root` runs post-transaction hooks in a
# chroot that has no /proc; systemd-tmpfiles then refuses to do half its work,
# so the directories it would create are made here instead.
mkdir -p "$ROOT"/{proc,sys,dev,tmp,run,var/tmp,var/log,etc,root,home,opt,srv,mnt,boot}
chmod 1777 "$ROOT/tmp" "$ROOT/var/tmp"

pacman_target -Sy --needed

log "installing base packages: $BASE_PACKAGES $TOOLS_PACKAGES $NETWORK_PACKAGES $EXTRA_PACKAGES"
# shellcheck disable=SC2086
pacman_target -S --needed $BASE_PACKAGES $TOOLS_PACKAGES $NETWORK_PACKAGES $EXTRA_PACKAGES

# The kernel must not run its mkinitcpio hook: this profile boots without an
# initramfs. --noscriptlet also skips depmod, which is done explicitly below.
log "installing device packages (no scriptlets): $DEVICE_PACKAGES $BOOT_PACKAGES"
# shellcheck disable=SC2086
pacman_target -S --needed --noscriptlet $DEVICE_PACKAGES $BOOT_PACKAGES

KVER=$(kernel_version)
log "kernel: $KVER"

# The target needs its own pacman keyring, otherwise `pacman -S` on the device
# fails with "required key missing from keyring" or, worse, "signature from
# Arch Linux ARM Build System is unknown trust" and every package is rejected.
# Both keyrings must be populated: Arch x86_64 keys come from archlinux-keyring,
# the ARM build key from archlinuxarm-keyring, which the base set installs.
log "initialising the pacman keyring in the target"
in_root "pacman-key --init >/dev/null 2>&1 || true"
in_root "pacman-key --populate archlinux archlinuxarm >/dev/null"

# Manual post-install work that --noscriptlet skipped.
in_root "depmod -a $KVER"
in_root "ldconfig"

# Nothing may regenerate an initramfs later: the image has no presets and the
# kernel package hook is disabled.
in_root "rm -rf /etc/mkinitcpio.d/*.preset"
in_root "rm -f /boot/initramfs-*.img /boot/initramfs-*.img.xz /boot/initramfs-*.img.zst"
in_root "rm -f /usr/share/libalpm/hooks/90-mkinitcpio-install.hook"

# Package cache and sync databases must not end up in the image.
rm -rf "$ROOT/var/cache/pacman/pkg"/* "$ROOT/var/lib/pacman/sync"

log "rootfs ready: $(du -sh "$ROOT" | cut -f1)"
