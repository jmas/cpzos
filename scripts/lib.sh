#!/bin/bash
# Shared helpers. Sourced by the stage scripts, never executed directly.
set -euo pipefail

BUILD="${BUILD:-$PWD/build}"
ROOT="$BUILD/root"
PACMAN_CONF="/etc/pacman-cpz.conf"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

require() {
    command -v "$1" >/dev/null 2>&1 || die "missing tool: $1"
}

# Run pacman against the target root. The cache stays outside the image: it is
# removed again at the end of the rootfs stage.
pacman_target() {
    mkdir -p "$ROOT/var/cache/pacman/pkg" "$ROOT/var/lib/pacman"
    pacman --root "$ROOT" \
           --config "$PACMAN_CONF" \
           --cachedir "$ROOT/var/cache/pacman/pkg" \
           --noconfirm "$@"
}

# Print the single kernel version installed in the target.
kernel_version() {
    local v
    v=$(basename "$(find "$ROOT/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d | head -n1)")
    [ -n "$v" ] || die "no kernel installed in $ROOT/usr/lib/modules"
    printf '%s\n' "$v"
}

# Run a command inside the target root with the standard chroot mounts that
# package scriptlets and kernel builds expect.
in_root() {
    chroot "$ROOT" /usr/bin/env -i \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        LANG=C.UTF-8 \
        /bin/bash -euo pipefail -c "$*"
}
