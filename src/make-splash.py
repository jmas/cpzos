#!/usr/bin/env python3
"""Generate the firmware (Splash Asm) boot splash for the CM0 panel.

The CM0's stock Raspberry Pi firmware understands ``splash_screen=`` in
``config.txt``: it runs a small SPI dump before the kernel starts.  This script
builds that dump for the Cardputer Zero's 320x170 ST7789 panel, using the panel
initialisation sequence and pin mapping from the vendor's own splash binary.

The picture is deliberately the same one cpz-ui paints as the second stage of
the boot splash: a white screen with a centred dark triangle.  Keeping both
stages identical means the handover is invisible.

Run from the repository root:

    python3 src/make-splash.py

It writes ``src/cpz-splash.bin`` (install it on the boot partition and point
``splash_screen=`` at it) and ``src/cpz-splash.png`` (a preview only).
"""

from __future__ import annotations

import struct
import zlib
from pathlib import Path

WIDTH = 320
HEIGHT = 170

# Same geometry as draw_splash() in cpz-ui.c: half the short side tall,
# equilateral, centred.
TRIANGLE_HEIGHT = HEIGHT // 2
TRIANGLE_HALF = TRIANGLE_HEIGHT * 577 // 1000  # height / sqrt(3)

WHITE = 0xFFFF
DARK = 0x1082  # RGB565 for (20, 18, 22), the launcher's ink colour

# --- Splash Asm binary format -------------------------------------------------
#
# Header: "SPLASH ASM" + five zero bytes + format version 1.
# Instructions: 0x00 DELAY, 0x01 DEFINE, 0x10 COMMAND.
#
# The panel setup below is the vendor CardputerZero_splash_custom.bin sequence
# with MADCTL changed from 0x00 to 0xA0: the kernel uses 0xA0 to present a
# 320x170 landscape framebuffer on the native 170x320 glass, so the firmware
# splash has to use the same rotation and address window to match it.
SPI_DEFINE = struct.pack(
    "<4sBB2x12s",
    b"SPI ",
    12,   # parameter size
    0,    # port
    bytes([
        10, 9, 11, 8,        # COPI, CIPO, SCLK, CS
        25,                  # DC
        1, 1, 1,             # CPOL, CPHA, CSPOL
    ]) + struct.pack("<I", 25_000_000),
)

I2C_DEFINE = struct.pack(
    "<4sBB2x8s",
    b"I2C ",
    8,
    0,
    bytes([2, 3, 0x4F, 0]) + struct.pack("<I", 100_000),
)


def command(out: int, flags: int, data: bytes) -> bytes:
    if len(data) > 0xFFFF:
        raise ValueError("Splash Asm command is limited to 65535 bytes")
    return b"\x10" + struct.pack("<BBH", out, flags, len(data)) + data


def delay_us(us: int) -> bytes:
    return b"\x00" + struct.pack("<I", us)


def triangle_pixels() -> bytes:
    """RGB565, big-endian, 320x170, row-major."""
    top = (HEIGHT - TRIANGLE_HEIGHT) // 2
    cx = WIDTH // 2
    rows = []
    for y in range(HEIGHT):
        spans = [WHITE] * WIDTH
        r = y - top
        if 0 <= r < TRIANGLE_HEIGHT:
            span = TRIANGLE_HALF * (r + 1) // TRIANGLE_HEIGHT
            for x in range(cx - span, cx + span + 1):
                spans[x] = DARK
        rows.append(b"".join(struct.pack(">H", px) for px in spans))
    return b"".join(rows)


def build() -> bytes:
    setup = (
        b"SPLASH ASM\x00\x00\x00\x00\x00\x01"
        + b"\x01" + SPI_DEFINE
        + b"\x01" + I2C_DEFINE
    )

    init = [
        command(0, 0, b"\x11"),                  # SLPOUT
        command(1, 0x80, b"\x04\x02"),           # IO expander: panel/backlight
        command(1, 0x80, b"\x14\x3d"),
        command(1, 0x80, b"\x06\x02"),
        delay_us(120_000),
        command(0, 0, b"\x3a\x05"),              # COLMOD: 16 bit/px
        command(0, 0, b"\xc5\x1a"),              # VCOM
        command(0, 0, b"\x36\xa0"),              # MADCTL: landscape (MV|MY)
        command(0, 0, b"\xb2\x05\x05\x00\x33\x33"),
        command(0, 0, b"\xb7\x05"),
        command(0, 0, b"\xbb\x3f"),
        command(0, 0, b"\xc0\x2c"),
        command(0, 0, b"\xc2\x01"),
        command(0, 0, b"\xc3\x0f"),
        command(0, 0, b"\xc4\x20"),
        command(0, 0, b"\xc6\x01"),
        command(0, 0, b"\xd0\xa4\xa1"),
        command(0, 0, b"\xe8\x03"),
        command(0, 0, b"\xe9\x09\x09\x08"),
        command(0, 0, b"\xe0\xd0\x05\x09\x09\x08\x14\x28\x33"
                       b"\x3f\x07\x13\x14\x28\x30"),
        command(0, 0, b"\xe1\xd0\x05\x09\x09\x08\x03\x24\x32"
                       b"\x32\x3b\x14\x13\x28\x2f"),
        command(0, 0, b"\x21"),                  # INVON (IPS panel)
    ]

    # The kernel's panel-timing is 320x170 with vback-porch 35; with MADCTL
    # 0xA0 the 320 axis is CASET and the 170 axis is RASET.
    window = [
        command(0, 0, b"\x2a\x00\x00\x01\x3f"),          # CASET 0..319
        command(0, 0, b"\x2b\x00\x23\x00\xcc"),          # RASET 35..204
    ]

    pixels = triangle_pixels()
    stride = WIDTH * 2
    rows = [pixels[i:i + stride] for i in range(0, len(pixels), stride)]
    body = [command(0, 0, b"\x2c" + rows[0])]
    body += [command(0, 1, row) for row in rows[1:]]
    tail = [command(0, 0, b"\x29")]               # DISPON

    return setup + b"".join(init + window + body + tail)


def write_preview(path: Path) -> None:
    def chunk(tag: bytes, payload: bytes) -> bytes:
        return (struct.pack(">I", len(payload)) + tag + payload
                + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF))

    pixels = triangle_pixels()
    rows = bytearray()
    for y in range(HEIGHT):
        rows.append(0)
        for x in range(WIDTH):
            value = int.from_bytes(pixels[(y * WIDTH + x) * 2:
                                          (y * WIDTH + x + 1) * 2], "big")
            r = (value >> 11) * 255 // 31
            g = ((value >> 5) & 0x3F) * 255 // 63
            b = (value & 0x1F) * 255 // 31
            rows.extend((r, g, b, 255))

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", WIDTH, HEIGHT, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(rows), 9))
    png += chunk(b"IEND", b"")
    path.write_bytes(png)


def main() -> None:
    root = Path(__file__).resolve().parent
    binary = build()
    (root / "cpz-splash.bin").write_bytes(binary)
    write_preview(root / "cpz-splash.png")
    print(f"wrote {root / 'cpz-splash.bin'} ({len(binary)} bytes)")
    print(f"wrote {root / 'cpz-splash.png'}")


if __name__ == "__main__":
    main()
