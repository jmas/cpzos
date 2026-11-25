#!/bin/bash
# Build the signed CPZ UI pacman repository.
#
# Runs inside the arm64 Arch builder image. Inputs come from the environment:
#   CHANNEL           stable or beta (default: stable)
#   OUT_DIR           output directory (default: out/ui/repo/<channel>)
#   PKG_DIR           directory with *.pkg.tar.zst packages
#                     (default: out/ui/packages/<channel>)
#   GPG_PRIVATE_KEY   armored private signing key (GitHub secret)
#   GPG_PASSPHRASE    passphrase for the signing key (GitHub secret)
#   GPG_KEY_ID        signing key fingerprint (GitHub secret)
#
# The output is uploaded as the assets of the GitHub release ui-<channel>:
#   https://github.com/jmas/cpzos/releases/download/ui-<channel>/cpz-ui.db
set -euo pipefail
cd "$(dirname "$0")/.."

CHANNEL="${CHANNEL:-stable}"
OUT_DIR="${OUT_DIR:-out/ui/repo/$CHANNEL}"
PKG_DIR="${PKG_DIR:-out/ui/packages/$CHANNEL}"

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

log "preparing $OUT_DIR"
mkdir -p "$OUT_DIR"

shopt -s nullglob
packages=("$PKG_DIR"/*.pkg.tar.zst "$PKG_DIR"/*.pkg.tar.xz)
copied=()
for pkg in "${packages[@]}"; do
    cp "$pkg" "$OUT_DIR/"
    copied+=("$OUT_DIR/$(basename "$pkg")")
done
shopt -u nullglob

log "signing packages"
for pkg in "${copied[@]}"; do
    sign "$pkg"
done

log "creating the repository database"
rm -f "$OUT_DIR/cpz-ui.db.tar.gz" "$OUT_DIR/cpz-ui.files.tar.gz" \
      "$OUT_DIR/cpz-ui.db" "$OUT_DIR/cpz-ui.files" \
      "$OUT_DIR/cpz-ui.db.sig" "$OUT_DIR/cpz-ui.files.sig"
if [ "${#copied[@]}" -eq 0 ]; then
    repo-add "$OUT_DIR/cpz-ui.db.tar.gz"
else
    repo-add "$OUT_DIR/cpz-ui.db.tar.gz" "${copied[@]}"
fi

# GitHub release assets cannot be symlinks; ship the database under its
# canonical name as well.
rm -f "$OUT_DIR/cpz-ui.db" "$OUT_DIR/cpz-ui.files"
cp "$OUT_DIR/cpz-ui.db.tar.gz" "$OUT_DIR/cpz-ui.db"
cp "$OUT_DIR/cpz-ui.files.tar.gz" "$OUT_DIR/cpz-ui.files"

log "signing the database"
sign "$OUT_DIR/cpz-ui.db"
sign "$OUT_DIR/cpz-ui.files"

log "repository ready: $OUT_DIR"
ls -l "$OUT_DIR"
