#!/usr/bin/env python3
"""Generate the small RGBA icon set used by the economy TUI.

The terminal maps a private-use codepoint to a real raster image; it never
substitutes a font glyph for an icon.  This script writes:

    src/icons/<name>.rgba   8-byte header (w, h) + RGBA pixels
    src/icons/icons.map     <PUA codepoint> <name>

Run from the repository root:

    python3 src/make-icons.py
"""

import math
import os
import struct

S = 64          # final icon size
SS = 4          # supersampling
W = H = S * SS
BASE = 0xE000


class Canvas:
    def __init__(self):
        self.mask = bytearray(W * H)

    def _put(self, x, y):
        if 0 <= x < W and 0 <= y < H:
            self.mask[y * W + x] = 255

    def _bbox(self, x0, y0, x1, y1):
        return (max(0, int(x0 * SS) - 1), max(0, int(y0 * SS) - 1),
                min(W, int(x1 * SS) + 2), min(H, int(y1 * SS) + 2))

    def rect(self, x, y, w, h):
        x0, y0, x1, y1 = self._bbox(x, y, x + w, y + h)
        for py in range(y0, y1):
            for px in range(x0, x1):
                qx, qy = (px + 0.5) / SS, (py + 0.5) / SS
                if x <= qx <= x + w and y <= qy <= y + h:
                    self._put(px, py)

    def round_rect(self, x, y, w, h, r):
        x0, y0, x1, y1 = self._bbox(x, y, x + w, y + h)
        for py in range(y0, y1):
            for px in range(x0, x1):
                qx, qy = (px + 0.5) / SS, (py + 0.5) / SS
                cx, cy = x + w / 2, y + h / 2
                dx = abs(qx - cx) - (w / 2 - r)
                dy = abs(qy - cy) - (h / 2 - r)
                ax, ay = max(dx, 0), max(dy, 0)
                if math.hypot(ax, ay) + min(max(dx, dy), 0) - r <= 0:
                    self._put(px, py)

    def line(self, x1, y1, x2, y2, stroke=3):
        r = stroke / 2
        x0, y0, xe, ye = self._bbox(min(x1, x2) - r, min(y1, y2) - r,
                                    max(x1, x2) + r, max(y1, y2) + r)
        dx, dy = x2 - x1, y2 - y1
        ll = dx * dx + dy * dy
        for py in range(y0, ye):
            for px in range(x0, xe):
                qx, qy = (px + 0.5) / SS, (py + 0.5) / SS
                t = 0 if not ll else max(0, min(1, ((qx - x1) * dx +
                                                   (qy - y1) * dy) / ll))
                if math.hypot(x1 + t * dx - qx, y1 + t * dy - qy) <= r:
                    self._put(px, py)

    def circle(self, cx, cy, r, fill=False, stroke=3):
        x0, y0, x1, y1 = self._bbox(cx - r - stroke, cy - r - stroke,
                                    cx + r + stroke, cy + r + stroke)
        for py in range(y0, y1):
            for px in range(x0, x1):
                qx, qy = (px + 0.5) / SS, (py + 0.5) / SS
                d = math.hypot(qx - cx, qy - cy)
                if (d <= r) if fill else (abs(d - r) <= stroke / 2):
                    self._put(px, py)

    def arc(self, cx, cy, r, a0, a1, stroke=3):
        x0, y0, x1, y1 = self._bbox(cx - r - stroke, cy - r - stroke,
                                    cx + r + stroke, cy + r + stroke)
        for py in range(y0, y1):
            for px in range(x0, x1):
                qx, qy = (px + 0.5) / SS, (py + 0.5) / SS
                d = math.hypot(qx - cx, qy - cy)
                a = math.atan2(qy - cy, qx - cx)
                if a < 0:
                    a += 2 * math.pi
                if a0 <= a <= a1 and abs(d - r) <= stroke / 2:
                    self._put(px, py)

    def polygon(self, points, fill=True, stroke=3):
        xs = [p[0] for p in points]
        ys = [p[1] for p in points]
        x0, y0, x1, y1 = self._bbox(min(xs) - stroke, min(ys) - stroke,
                                    max(xs) + stroke, max(ys) + stroke)
        for py in range(y0, y1):
            for px in range(x0, x1):
                qx, qy = (px + 0.5) / SS, (py + 0.5) / SS
                inside = False
                j = len(points) - 1
                for i in range(len(points)):
                    xi, yi = points[i]
                    xj, yj = points[j]
                    if ((yi > qy) != (yj > qy) and
                            qx < (xj - xi) * (qy - yi) / (yj - yi) + xi):
                        inside = not inside
                    j = i
                if inside:
                    self._put(px, py)

    def rgba(self, rgb):
        out = bytearray()
        for y in range(S):
            for x in range(S):
                total = 0
                for j in range(SS):
                    off = ((y * SS + j) * W + x * SS)
                    total += sum(self.mask[off:off + SS])
                a = (total + (SS * SS) // 2) // (SS * SS)
                out += bytes((rgb[0], rgb[1], rgb[2], a))
        return bytes(out)


def terminal(c):
    c.round_rect(4, 10, 56, 44, 6)
    c.line(18, 24, 28, 32, 3)
    c.line(18, 40, 28, 32, 3)
    c.line(34, 40, 46, 40, 3)


def files(c):
    c.round_rect(4, 18, 56, 38, 5)
    c.rect(4, 12, 26, 10)
    c.line(12, 30, 52, 30, 2)
    c.line(12, 38, 44, 38, 2)


def editor(c):
    c.round_rect(12, 4, 40, 56, 4)
    c.line(20, 18, 44, 18, 2)
    c.line(20, 26, 44, 26, 2)
    c.line(20, 34, 44, 34, 2)
    c.line(20, 42, 36, 42, 2)


def settings(c):
    for i in range(8):
        a = i * math.pi / 4
        c.line(32 + math.cos(a) * 18, 32 + math.sin(a) * 18,
               32 + math.cos(a) * 27, 32 + math.sin(a) * 27, 4)
    c.circle(32, 32, 20, stroke=4)
    c.circle(32, 32, 7, stroke=3)


def battery(c):
    c.round_rect(4, 20, 46, 24, 4)
    c.rect(52, 27, 7, 10)
    c.rect(10, 26, 24, 12)


def network(c):
    c.arc(32, 44, 8, math.pi * 1.1, math.pi * 1.9, 3)
    c.arc(32, 44, 18, math.pi * 1.1, math.pi * 1.9, 3)
    c.arc(32, 44, 28, math.pi * 1.1, math.pi * 1.9, 3)
    c.circle(32, 44, 2, fill=True)


def bluetooth(c):
    c.line(32, 8, 48, 22, 3)
    c.line(48, 22, 16, 46, 3)
    c.line(16, 46, 48, 56, 3)
    c.line(48, 56, 32, 64, 3)
    c.line(32, 8, 32, 64, 3)


def volume(c):
    c.polygon([(8, 24), (20, 24), (32, 12), (32, 52), (20, 40), (8, 40)])
    c.arc(36, 32, 12, -0.8, 0.8, 3)
    c.arc(36, 32, 22, -0.8, 0.8, 3)


def help(c):
    c.circle(32, 32, 26, stroke=4)
    c.arc(24, 24, 9, -1.2, 1.8, 3)
    c.line(32, 33, 32, 40, 3)
    c.circle(32, 49, 3, fill=True)


def system(c):
    c.line(8, 54, 56, 54, 3)
    c.line(14, 54, 14, 36, 3)
    c.line(28, 54, 28, 22, 3)
    c.line(42, 54, 42, 30, 3)
    c.line(56, 54, 56, 14, 3)


def music(c):
    c.circle(20, 48, 7, fill=True)
    c.circle(46, 42, 7, fill=True)
    c.line(27, 48, 27, 14, 3)
    c.line(53, 42, 53, 10, 3)
    c.line(26, 14, 54, 10, 3)


ICONS = {
    "terminal": (terminal, (78, 162, 255)),
    "files": (files, (229, 192, 123)),
    "editor": (editor, (152, 195, 121)),
    "settings": (settings, (190, 190, 200)),
    "battery": (battery, (152, 195, 121)),
    "network": (network, (97, 175, 239)),
    "bluetooth": (bluetooth, (86, 182, 194)),
    "volume": (volume, (198, 120, 221)),
    "help": (help, (229, 192, 123)),
    "system": (system, (224, 108, 117)),
    "music": (music, (198, 120, 221)),
}


def main():
    root = os.path.dirname(os.path.abspath(__file__))
    out = os.path.join(root, "icons")
    os.makedirs(out, exist_ok=True)
    lines = []
    for i, (name, (draw, color)) in enumerate(ICONS.items()):
        c = Canvas()
        draw(c)
        data = c.rgba(color)
        path = os.path.join(out, name + ".rgba")
        with open(path, "wb") as f:
            f.write(struct.pack("<II", S, S))
            f.write(data)
        lines.append("%04X %s" % (BASE + i, name))
        print("%-10s %5d bytes" % (name, len(data) + 8))
    with open(os.path.join(out, "icons.map"), "w") as f:
        f.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
