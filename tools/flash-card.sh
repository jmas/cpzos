#!/bin/bash
# tools/flash-card.sh — write the -sdcard image to the SD card reader (macOS).
#
#   tools/card-image.sh out/cpz-arch-0.1.0-cm0-ui.img
#   tools/flash-card.sh out/cpz-arch-0.1.0-cm0-ui-sdcard.img
#
# One sudo prompt: raw disk writes are not allowed by the app sandbox, so run
# this from Terminal.app. The partition table and the ext4 superblock are read
# back and compared after the write; a mismatch aborts before the card is
# ejected.
set -euo pipefail
cd "$(dirname "$0")/.."

img=${1:-out/cpz-arch-0.1.0-cm0-ui-sdcard.img}
[ -f "$img" ] || { echo "no such image: $img" >&2; exit 2; }

dev=""
for d in /dev/disk*; do
    case "$d" in *s[0-9]*) continue ;; esac
    [ -e "$d" ] || continue
    if diskutil info "$d" 2>/dev/null | grep -q "Secure Digital"; then
        dev="$d"
        break
    fi
done
[ -n "$dev" ] || { echo "no SD card found - insert it and run again" >&2; exit 2; }

echo "card: $dev"
diskutil info "$dev" | grep -Ei "  Device / Media Name|  Disk Size|Media Read-Only"
if diskutil info "$dev" | grep -Eq "Media Read-Only:[[:space:]]+Yes"; then
    echo "card is write-protected - move the lock switch to Unlock" >&2
    exit 3
fi

diskutil unmountDisk "$dev"
raw="/dev/r${dev#/dev/}"
echo "writing $(basename "$img") -> $raw"
sudo dd if="$img" of="$raw" bs=4194304
sync

mbr=$(sudo dd if="$raw" bs=512 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')
want=$(head -c 512 "$img" | od -An -tx1 | tr -d ' \n')
[ "$mbr" = "$want" ] || { echo "partition table MISMATCH" >&2; exit 4; }
echo "partition table verified"

magic=$(sudo dd if="$raw" bs=512 skip=133122 count=1 2>/dev/null | od -An -tx1 -j 56 -N 2 | tr -d ' \n')
[ "$magic" = "53ef" ] || { echo "ext4 superblock MISMATCH: $magic" >&2; exit 5; }
echo "ext4 superblock verified"

diskutil eject "$dev"
echo "done - card ejected, safe to remove"
