#!/bin/bash
# Build the signed CPZ UI pacman repository into a static site tree.
#
# Runs inside the arm64 Arch builder image. Inputs come from the environment:
#   CHANNEL           stable or beta (default: stable)
#   SITE_DIR          directory that becomes the Pages artifact (default: site)
#   PKG_DIR           directory with *.pkg.tar.zst packages (default: out/ui/packages)
#   GPG_PRIVATE_KEY   armored private signing key (GitHub secret)
#   GPG_PASSPHRASE    passphrase for the signing key (GitHub secret)
#   GPG_KEY_ID        signing key fingerprint (GitHub secret)
#
# The repository is served from:
#   <site>/ui/<channel>/<arch>/cpz-ui.db
set -euo pipefail
cd "$(dirname "$0")/.."

CHANNEL="${CHANNEL:-stable}"
SITE_DIR="${SITE_DIR:-site}"
PKG_DIR="${PKG_DIR:-out/ui/packages}"
ARCH="${ARCH:-aarch64}"
DEST="$SITE_DIR/ui/$CHANNEL/$ARCH"

case "$CHANNEL" in
    stable|beta) ;;
    *) echo "invalid channel: $CHANNEL" >&2; exit 1 ;;
esac

for var in GPG_PRIVATE_KEY GPG_PASSPHRASE GPG_KEY_ID; do
    [ -n "${!var:-}" ] || { echo "missing $var" >&2; exit 1; }
done

log() { printf '==> %s\n' "$*"; }

GNUPGHOME=$(mktemp -d)
export GNUPGHOME
trap 'rm -rf "$GNUPGHOME"' EXIT
chmod 700 "$GNUPGHOME"

printf '%s' "$GPG_PRIVATE_KEY" | gpg --batch --import >/dev/null 2>&1
FPR=$(gpg --list-secret-keys --with-colons "$GPG_KEY_ID" | \
    awk -F: '/^fpr:/ { print $10; exit }')
[ "$FPR" = "$GPG_KEY_ID" ] || {
    echo "signing key $GPG_KEY_ID is not available after import" >&2
    exit 1
}

sign() {
    gpg --batch --yes --pinentry-mode loopback \
        --passphrase "$GPG_PASSPHRASE" --local-user "$GPG_KEY_ID" \
        --detach-sign "$1"
}

log "preparing $DEST"
mkdir -p "$DEST" "$SITE_DIR/ui"
cp keys/cpz-ui-signing.asc "$SITE_DIR/ui/cpz-ui-signing.asc"

shopt -s nullglob
packages=("$PKG_DIR"/*.pkg.tar.zst)
for pkg in "${packages[@]}"; do
    cp "$pkg" "$DEST/"
done
shopt -u nullglob

log "signing packages"
for pkg in "$DEST"/*.pkg.tar.zst; do
    [ -e "$pkg" ] || continue
    sign "$pkg"
done

log "creating the repository database"
rm -f "$DEST/cpz-ui.db.tar.gz" "$DEST/cpz-ui.files.tar.gz" \
      "$DEST/cpz-ui.db" "$DEST/cpz-ui.files" \
      "$DEST/cpz-ui.db.sig" "$DEST/cpz-ui.files.sig"
if [ "${#packages[@]}" -eq 0 ]; then
    repo-add "$DEST/cpz-ui.db.tar.gz"
else
    repo-add "$DEST/cpz-ui.db.tar.gz" "$DEST"/*.pkg.tar.zst
fi

# GitHub Pages does not preserve the relative symlinks repo-add creates.
rm -f "$DEST/cpz-ui.db" "$DEST/cpz-ui.files"
cp "$DEST/cpz-ui.db.tar.gz" "$DEST/cpz-ui.db"
cp "$DEST/cpz-ui.files.tar.gz" "$DEST/cpz-ui.files"

log "signing the database"
sign "$DEST/cpz-ui.db"
sign "$DEST/cpz-ui.files"

log "repository ready: $DEST"
ls -l "$DEST"
