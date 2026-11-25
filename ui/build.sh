#!/bin/bash
# Build the CPZ UI package inside the arm64 Arch builder.
#
# Usage (inside the builder container, as root):
#   ./ui/build.sh [channel]
#
# The output lands in out/ui/packages/<channel>/ for tools/ui-repo.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

CHANNEL="${1:-stable}"
case "$CHANNEL" in
    stable|beta) ;;
    *) echo "invalid channel: $CHANNEL" >&2; exit 1 ;;
esac

log() { printf '==> %s\n' "$*"; }

log "installing the package build toolchain"
pacman -Sy --needed --noconfirm base-devel >/dev/null

if ! id builder >/dev/null 2>&1; then
    useradd -m -s /bin/bash builder
fi

log "building cpz-ui"
rm -rf /tmp/cpz-ui-build
cp -a ui /tmp/cpz-ui-build
chown -R builder:builder /tmp/cpz-ui-build
su builder -c 'cd /tmp/cpz-ui-build/cpz-ui && makepkg -f --nodeps'

mkdir -p "/work/out/ui/packages/$CHANNEL"
cp /tmp/cpz-ui-build/cpz-ui/*.pkg.tar.* "/work/out/ui/packages/$CHANNEL/"
log "package:"
ls -l "/work/out/ui/packages/$CHANNEL"/*.pkg.tar.*
