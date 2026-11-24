#!/usr/bin/env python3
"""Generate the launcher icons that each installed app owns.

The shell does not keep a gallery of application icons: every app ships its
own ``icon.png`` next to ``app.json`` and the manifest refers to it by a
relative path.  cpz-ui draws the PNG as an alpha mask, tinted with the row
colour, so one file looks right both on the white list and on the azure
selection bar.

The icons are 96x96 8-bit RGBA PNGs.  They are drawn from simple primitives at
4x and box-filtered down, which gives clean edges without any image library.

Run from the repository root:

    python3 src/make-icons.py
"""

import math
import os
import struct
import zlib

SIZE = 96          # final icon size, px
SS = 4             # supersampling factor
W = H = SIZE * SS
INK = 0x37         # default RGB (colour is ignored: cpz-ui uses alpha as mask)
STROKE = 8.0       # design units (96 px grid)

APP_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "apps")


class Canvas:
    def __init__(self):
        self.mask = bytearray(W * H)

    def _put(self, x, y):
        if 0 <= x < W and 0 <= y < H:
            self.mask[y * W + x] = 255

    def _bbox(self, x0, y0, x1, y1):
        return (max(0, int(x0 * SS) - 1), max(0, int(y0 * SS) - 1),
                min(W, int(x1 * SS) + 2), min(H, int(y1 * SS) + 2))

    @staticmethod
    def _rr_sdf(px, py, x, y, w, h, r):
        cx, cy = x + w / 2.0, y + h / 2.0
        qx = abs(px - cx) - (w / 2.0 - r)
        qy = abs(py - cy) - (h / 2.0 - r)
        ax, ay = max(qx, 0.0), max(qy, 0.0)
        return math.hypot(ax, ay) + min(max(qx, qy), 0.0) - r

    def round_rect(self, x, y, w, h, r, stroke=STROKE, fill=False):
        x0, y0, x1, y1 = self._bbox(x - stroke, y - stroke,
                                    x + w + stroke, y + h + stroke)
        for py in range(y0, y1):
            for px in range(x0, x1):
                d = self._rr_sdf((px + 0.5) / SS, (py + 0.5) / SS,
                                 x, y, w, h, r)
                if (d <= 0) if fill else (abs(d) <= stroke / 2.0):
                    self._put(px, py)

    def line(self, x1, y1, x2, y2, stroke=STROKE):
        r = stroke / 2.0
        x0, y0, xe, ye = self._bbox(min(x1, x2) - r, min(y1, y2) - r,
                                    max(x1, x2) + r, max(y1, y2) + r)
        dx, dy = x2 - x1, y2 - y1
        ll = dx * dx + dy * dy
        for py in range(y0, ye):
            for px in range(x0, xe):
                qx = (px + 0.5) / SS
                qy = (py + 0.5) / SS
                if ll:
                    t = ((qx - x1) * dx + (qy - y1) * dy) / ll
                    t = 0.0 if t < 0 else 1.0 if t > 1 else t
                else:
                    t = 0.0
                ex, ey = x1 + t * dx - qx, y1 + t * dy - qy
                if math.hypot(ex, ey) <= r:
                    self._put(px, py)

    def polyline(self, pts, stroke=STROKE):
        for a, b in zip(pts, pts[1:]):
            self.line(a[0], a[1], b[0], b[1], stroke)

    def circle(self, cx, cy, r, stroke=STROKE, fill=False):
        x0, y0, x1, y1 = self._bbox(cx - r - stroke, cy - r - stroke,
                                    cx + r + stroke, cy + r + stroke)
        for py in range(y0, y1):
            for px in range(x0, x1):
                d = math.hypot((px + 0.5) / SS - cx, (py + 0.5) / SS - cy)
                if (d <= r) if fill else (abs(d - r) <= stroke / 2.0):
                    self._put(px, py)

    def polygon(self, pts):
        xs = [p[0] for p in pts]
        ys = [p[1] for p in pts]
        x0, y0, x1, y1 = self._bbox(min(xs), min(ys), max(xs), max(ys))
        for py in range(y0, y1):
            for px in range(x0, x1):
                qx = (px + 0.5) / SS
                qy = (py + 0.5) / SS
                inside = False
                j = len(pts) - 1
                for i in range(len(pts)):
                    xi, yi = pts[i]
                    xj, yj = pts[j]
                    if (yi > qy) != (yj > qy):
                        xt = (xj - xi) * (qy - yi) / (yj - yi) + xi
                        if qx < xt:
                            inside = not inside
                    j = i
                if inside:
                    self._put(px, py)

    def png(self):
        raw = bytearray()
        for y in range(SIZE):
            raw.append(0)                      # filter: none
            base = y * SS * W
            for x in range(SIZE):
                total = 0
                for j in range(SS):
                    off = base + j * W + x * SS
                    total += sum(self.mask[off:off + SS])
                a = (total + (SS * SS) // 2) // (SS * SS)
                raw += bytes((INK, INK, INK, a))

        def chunk(tag, data):
            return (struct.pack(">I", len(data)) + tag + data +
                    struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff))

        ihdr = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0)
        return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) +
                chunk(b"IDAT", zlib.compress(bytes(raw), 9)) +
                chunk(b"IEND", b""))


def terminal(c):
    c.round_rect(8, 16, 80, 64, 10)
    c.polyline([(32, 38), (44, 48), (32, 58)], 9)
    c.line(52, 58, 68, 58, 9)


def screen(c):
    c.round_rect(8, 14, 80, 50, 8)
    c.line(48, 64, 48, 78, 9)
    c.line(36, 80, 60, 80, 9)


def music(c):
    c.circle(30, 72, 9, fill=True)
    c.circle(64, 64, 9, fill=True)
    c.line(39, 72, 39, 26)
    c.line(73, 64, 73, 18)
    c.polyline([(35, 26), (77, 18)], 9)


def video(c):
    c.round_rect(8, 22, 80, 52, 10)
    c.polygon([(40, 36), (66, 48), (40, 60)])


def photo(c):
    c.round_rect(8, 18, 80, 60, 10)
    c.polyline([(16, 70), (36, 44), (50, 60), (64, 42), (80, 70)])
    c.circle(66, 32, 5, fill=True)


def games(c):
    c.round_rect(6, 32, 84, 38, 19)
    c.line(24, 51, 40, 51)
    c.line(32, 43, 32, 59)
    c.circle(64, 47, 4, fill=True)
    c.circle(74, 55, 4, fill=True)


def settings(c):
    for i in range(8):
        a = i * math.pi / 4
        c.line(48 + math.cos(a) * 26, 48 + math.sin(a) * 26,
               48 + math.cos(a) * 39, 48 + math.sin(a) * 39, 11)
    c.circle(48, 48, 28)
    c.circle(48, 48, 10)


def about(c):
    c.circle(48, 48, 36)
    c.circle(48, 31, 5, fill=True)
    c.line(48, 44, 48, 68, 9)


ICONS = {
    "terminal": terminal,
    "screen": screen,
    "music": music,
    "video": video,
    "photo": photo,
    "games": games,
    "settings": settings,
    "about": about,
}


def main():
    for app, draw in ICONS.items():
        c = Canvas()
        draw(c)
        data = c.png()
        path = os.path.join(APP_DIR, app, "icon.png")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(data)
        print("%-10s %5d bytes  %s" % (app, len(data),
                                       os.path.relpath(path)))


if __name__ == "__main__":
    main()
