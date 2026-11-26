#!/bin/bash
# tools/card-image.sh — grow the image's root partition to a real SD card.
#
# `make image` produces a fixed-size image (ROOT_MB) so the build is
# reproducible. A card is much larger, and its spare space must belong to the
# root partition or the device runs out of room on the first cold boot.
#
#   tools/card-image.sh out/cpz-arch-0.1.0-cm0-ui.img              # macOS: detect the SD card
#   tools/card-image.sh out/cpz-arch-0.1.0-cm0-ui.img 128177930240 # card size in bytes
#
# The result is out/<name>-sdcard.img: same bytes, with the last MBR partition
# extended to the end of the card. The filesystem inside is grown on the device
# with one `sudo resize2fs` after the first boot; ext4 cannot be grown to a
# partition that only exists after flashing.
set -euo pipefail
cd "$(dirname "$0")/.."

img=${1:-out/cpz-arch-0.1.0-cm0-ui.img}
card=${2:-}

[ -f "$img" ] || { echo "no such image: $img" >&2; exit 2; }

if [ -z "$card" ]; then
    command -v diskutil >/dev/null ||
        { echo "usage: tools/card-image.sh <image> [card bytes]" >&2; exit 2; }
    for d in /dev/disk*; do
        case "$d" in *s[0-9]*) continue ;; esac
        [ -e "$d" ] || continue
        if diskutil info "$d" 2>/dev/null | grep -q "Secure Digital"; then
            card=$(diskutil info "$d" | awk -F'[()]' '/Disk Size/ {print $2}' | awk '{print $1}')
            echo "card: $d, $card bytes"
            break
        fi
    done
    [ -n "$card" ] || { echo "no SD card found; pass the card size in bytes" >&2; exit 2; }
fi

out=${img%.img}-sdcard.img

python3 - "$img" "$out" "$card" <<'PY'
import os, shutil, struct, sys

src, dst, card = sys.argv[1], sys.argv[2], int(sys.argv[3])
shutil.copyfile(src, dst)

with open(dst, 'r+b') as f:
    mbr = f.read(512)
    if mbr[510:512] != b'\x55\xaa':
        sys.exit('not an MBR disk image')
    entries = []
    for i in range(4):
        off = 446 + i * 16
        e = mbr[off:off + 16]
        if e[4] == 0:
            continue
        start, count = struct.unpack_from('<II', e, 8)
        entries.append((i, off, e[4], start, count))
    if not entries:
        sys.exit('no MBR partitions')
    i, off, kind, start, count = entries[-1]
    if kind != 0x83:
        sys.exit('last partition is not Linux (0x%02x)' % kind)

    size = card // 512 - start
    if size <= count:
        sys.exit('card is not bigger than the image partition')

    e = bytearray(mbr[off:off + 16])
    e[5:8] = b'\xfe\xff\xff'          # CHS end: "too large", LBA wins
    struct.pack_into('<II', e, 8, start, size)
    f.seek(off)
    f.write(e)
    f.flush()
    os.fsync(f.fileno())

print('image:  %s (%d MiB)' % (dst, os.path.getsize(dst) // 1048576))
print('root:   partition %d, start %d, %d sectors (%.1f GiB)'
      % (i + 1, start, size, size * 512 / 2**30))
PY

echo "next: flash it, boot once, then run on the device: sudo resize2fs /dev/mmcblk0p2"
