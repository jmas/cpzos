#!/bin/bash
# Stage 45 — optional UI test image.
#
# Installs the locally built cpz-ui package and its runtime dependencies into
# the rootfs so the image boots straight into the UI. This is a hardware test
# image; the clean base image keeps the UI as a separate package set.
set -euo pipefail
cd "$(dirname "$0")/.."
. ./config.sh
. scripts/lib.sh

if [ "${UI_TEST:-0}" != "1" ]; then
    log "UI test layer disabled"
    exit 0
fi

PKG=$(find out/ui/packages/stable -maxdepth 1 -name 'cpz-ui-*.pkg.tar.*' \
    ! -name '*.sig' | sort -V | tail -1)
[ -n "$PKG" ] || die "missing cpz-ui package; run ./ui/build.sh stable"

log "installing UI runtime packages"
pacman_target -Sy --needed
# shellcheck disable=SC2086
pacman_target -S --needed $UI_TEST_PACKAGES

log "installing $PKG"
pacman_target -U --nodeps "$PWD/$PKG"

# Pacman scriptlets cannot manage units in this chroot; enable them here.
in_root "ldconfig"
in_root "systemctl enable cpz-tmux.service cpz-ui@tty1.service >/dev/null 2>&1 || true"
in_root "systemd-tmpfiles --create /usr/lib/tmpfiles.d/cpz-ui.conf >/dev/null 2>&1 || true"

# Keep logs across reboots for hardware debugging. The clean base image keeps
# the volatile journal; the test image is where logs matter.
install -d "$ROOT/var/log/journal" "$ROOT/etc/systemd/journald.conf.d"
cat > "$ROOT/etc/systemd/journald.conf.d/20-cpz-test.conf" <<'EOF'
[Journal]
Storage=persistent
SystemMaxUse=64M
EOF

# The package cache and sync databases must not end up in the image.
rm -rf "$ROOT/var/cache/pacman/pkg"/* "$ROOT/var/lib/pacman/sync"

log "UI test layer installed"
