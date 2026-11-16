#!/usr/bin/env python3
"""Generate an M5 Imager OS-list entry for a built CPZ image.

M5 Imager (CardputerZero/m5stack-imager) accepts the Raspberry Pi Imager
manifest schema but its current validator only supports these init formats:

    "", "systemd", "cloudinit", "cloudinit-rpi", "none"

It does not accept "rpi-preseed" and prunes such entries from the OS list.
Use --init-format systemd for the M5 Imager customisation flow.

Example:

    python3 tools/make-m5stack-entry.py \
        --image deploy/image_2026-11-16-cardputerzero-trixie-arm64.img.xz \
        --url https://example.invalid/cardputerzero-cpz-trixie-arm64-20261116.img.xz \
        --release-date 2026-11-16
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import lzma
import sys
from datetime import date
from pathlib import Path

M5_INIT_FORMATS = ("", "systemd", "cloudinit", "cloudinit-rpi", "none")
FIRMWARE_BOOT_MIN_DATE = date(2023, 10, 11)


def hash_stream(stream) -> tuple[int, str]:
    digest = hashlib.sha256()
    size = 0
    while True:
        chunk = stream.read(1024 * 1024)
        if not chunk:
            break
        size += len(chunk)
        digest.update(chunk)
    return size, digest.hexdigest()


def compressed_stream(path: Path):
    suffix = path.suffix.lower()
    if suffix == ".xz":
        return lzma.open(path, "rb")
    if suffix == ".gz":
        return gzip.open(path, "rb")
    if suffix in (".img", ".raw"):
        return path.open("rb")
    raise SystemExit(
        f"unsupported image suffix {suffix!r}; expected .img, .raw, .xz or .gz"
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--image", required=True, type=Path)
    parser.add_argument("--url", required=True)
    parser.add_argument("--release-date", required=True,
                        help="YYYY-MM-DD; must be >= 2023-10-11 for /boot/firmware")
    parser.add_argument("--name", default="CardputerZero CPZ (Trixie arm64)")
    parser.add_argument(
        "--description",
        default="Terminal-first kmscon + tmux image for CardputerZero.",
    )
    parser.add_argument(
        "--icon",
        default="https://cardputer-zero-repo.oss-cn-shenzhen.aliyuncs.com/icons/cardputerzero.png",
    )
    parser.add_argument(
        "--init-format",
        default="systemd",
        choices=M5_INIT_FORMATS,
        help="M5 Imager init_format; use systemd, not rpi-preseed",
    )
    parser.add_argument(
        "--devices",
        default="m5-cardputerzero,pi3-64bit",
        help="comma-separated device tags",
    )
    parser.add_argument("--architecture", default="armv8")
    parser.add_argument(
        "--capabilities",
        default="i2c,spi,serial,usb_otg",
        help="comma-separated capability names",
    )
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    try:
        release_date = date.fromisoformat(args.release_date)
    except ValueError as exc:
        raise SystemExit(f"invalid --release-date: {exc}") from exc
    if release_date < FIRMWARE_BOOT_MIN_DATE:
        raise SystemExit(
            f"release-date {release_date} is before {FIRMWARE_BOOT_MIN_DATE}; "
            "M5 Imager would use /boot/firstrun.sh instead of /boot/firmware"
        )

    if not args.image.is_file():
        raise SystemExit(f"image not found: {args.image}")

    with args.image.open("rb") as stream:
        download_size, download_sha = hash_stream(stream)

    with compressed_stream(args.image) as stream:
        extract_size, extract_sha = hash_stream(stream)

    if extract_size <= 0:
        raise SystemExit("decompressed image is empty")

    entry = {
        "name": args.name,
        "description": args.description,
        "icon": args.icon,
        "url": args.url,
        "extract_size": extract_size,
        "extract_sha256": extract_sha,
        "image_download_size": download_size,
        "image_download_sha256": download_sha,
        "release_date": release_date.isoformat(),
        "init_format": args.init_format,
        "devices": [d.strip() for d in args.devices.split(",") if d.strip()],
        "architecture": args.architecture,
        "capabilities": [c.strip() for c in args.capabilities.split(",") if c.strip()],
    }

    text = json.dumps(entry, indent=2) + "\n"
    if args.output:
        args.output.write_text(text, encoding="utf-8")
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
