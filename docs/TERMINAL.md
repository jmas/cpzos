# Terminal

`cpz-term` is an unprivileged DRM terminal, not a desktop terminal in a window.

## Pipeline

```text
cpz-session (root) → inherited DRM fd + dumb buffers
cpz-term (cpz) → mmap → libtsm grid → FreeType glyphs → page flip
                → evdev + xkbcommon → pty → tmux -L cpz
```

## Rendering

- Double buffering with per-buffer dirty rectangles; shadow buffer is the
  source of truth.
- Cell changes are painted into the shadow, then copied into the back buffer
  before the page flip.
- Cursor is an accent bar; libtsm's own cursor is hidden.
- Font: DejaVu Sans Mono, per-output pixel size (`CPZ_FONT_PX`); glyph cache
  with LRU/clear-on-full, no hard stop.
- Icons: PUA codepoint → raw RGBA, nearest-neighbour scale into the cell.
- Unicode: Cyrillic and box drawing from the primary face; fallback faces for
  symbols/emoji.

## Input

- evdev devices under `/dev/input/event*`.
- xkbcommon keymap from `CPZ_KEYMAP` if present, otherwise
  `XKB_DEFAULT_LAYOUT`/`XKB_DEFAULT_OPTIONS` (default `us,ua`).
- Keycodes are evdev + 8; modifiers are read from xkb state.
- `Ctrl+Shift+Q` restarts the terminal; Shift+PgUp/PgDn scrolls.

## Tests

```sh
cpz-term --selftest
cpz-term --headless /tmp/x.ppm --cols 53 --rows 14
cpz-term --probe
```

`--headless` renders the VT into a PPM without DRM, so layout and UTF-8 can be
checked on a laptop or in the build chroot.

## Hardware acceptance

1. Panel: mode set, page flip, 53×14, Cyrillic, no tearing.
2. HDMI: preferred mode, larger font, no black frame on hotplug.
3. Input: all keys, Fn/Sym layer, Alt shortcuts, Cyrillic layout.
4. Load: `cat 10MB`, `vim`, `htop`, `tmux`; no missed keys, no full repaint on
   cursor blink.
5. tmux: tabs/panes survive terminal restart and output switch.
