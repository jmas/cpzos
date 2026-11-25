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

[ -n "$UI_APPS_REPO_STABLE" ] || die "UI_TEST=1 needs UI_APPS_REPO_STABLE (the signed apps repository)"

# Each stage runs in its own container; pacman_target reads the builder config,
# not the target's pacman.conf, so the app repository is added here.
if ! grep -q '^\[cpz-apps\]$' /etc/pacman-cpz.conf; then
    cat >> /etc/pacman-cpz.conf <<EOF

[cpz-apps]
Server = $UI_APPS_REPO_STABLE
SigLevel = $UI_APPS_SIGLEVEL
EOF
fi

log "installing UI runtime packages"
pacman_target -Sy --needed
# shellcheck disable=SC2086
pacman_target -S --needed $UI_TEST_PACKAGES

log "installing system apps and the app catalog"
if [ -n "$UI_APPS_CATALOG_VERSION" ]; then
    pacman_target -S --needed cpz-system-apps "cpz-apps-catalog=$UI_APPS_CATALOG_VERSION"
else
    pacman_target -S --needed cpz-system-apps cpz-apps-catalog
fi

CATALOG_PKG=""
for p in "$ROOT"/var/cache/pacman/pkg/cpz-apps-catalog-*.pkg.tar.*; do
    case "$p" in
        *.sig) continue ;;
    esac
    CATALOG_PKG="$p"
done
[ -n "$CATALOG_PKG" ] || die "catalog package missing from the pacman cache"
if [ -n "$UI_APPS_CATALOG_SHA256" ]; then
    printf '%s  %s\n' "$UI_APPS_CATALOG_SHA256" "$CATALOG_PKG" | sha256sum -c - ||
        die "catalog package sha256 mismatch"
fi
cat > "$BUILD/apps-catalog.txt" <<EOF
catalog: $(pacman --root "$ROOT" -Q cpz-apps-catalog)
catalog sha256: $(sha256sum "$CATALOG_PKG" | cut -d' ' -f1)
catalog generated: $(grep -o '"generated": *"[^"]*"' "$ROOT/usr/share/cpz/catalog/apps.json" | head -n1)
EOF

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
