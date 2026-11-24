# cpz-term: why it looks bad, and how to rebuild the presentation

`cpz-term` is functionally honest: a pty, `bash -l`, libtsm for VT state, and
SDL_ttf for text. The problem is not the terminal engine. It is the
*presentation layer*: the app treats the VT grid as something to paste into the
middle of an SDL window, then draws a second cursor on top of it. On the 320x170
panel the result reads as a debug view, not as an appliance screen.

This note is an assessment and a rework plan. It does not change the VT core.

## 1. What the user actually sees

1. A navy frame around a pure-black grid. The window is cleared to
   `(10, 10, 16)` while every terminal cell is filled with the palette
   background `(0, 0, 0)`, and the grid is centred with an integer origin
   (`ox`/`oy`). The leftover pixels form an uneven dark-blue border at the top,
   bottom and sides.
2. A cursor that is two cursors. libtsm's `tsm_screen_draw()` already delivers
   the cursor cell with `attr.inverse` flipped, so the app paints a full grey
   block with a black glyph. `cpz-term` then paints an additional blinking
   amber 2 px underline in the same cell.
3. Tiny, dense text. On the panel the font is 11 px with `TTF_FontLineSkip`
   leading; the 28 px row look of the launcher does not exist here. It is
   legible, but it looks like a desktop terminal squeezed into roughly 44 x 12
   cells, not a handheld appliance.
4. Smudged "bold". Bold is synthesised by drawing the same glyph twice with a
   1 px offset and 160/255 alpha. At 11 px this blurs the letterform; the
   conventional terminal trick, switching to the bright palette colour, is not
   used.
5. A 1990s VGA palette: `(170, 0, 0)` red, `(170, 85, 0)` yellow,
   `(192, 192, 192)` foreground on `(0, 0, 0)`. It clashes with the silver /
   white / azure launcher and makes coloured CLI output look dirty.
6. No scrollbar, no indication that the view is in scrollback, no wheel
   scrolling, no selection, no copy/paste, no bell. Scrollback is reachable
   only with Shift+PgUp/Shift+PgDn; typing silently jumps back to live.
7. Character loss under load. The glyph cache has 4096 slots and no eviction.
   Once it fills, `glyph_get()` returns `NULL` for every new code point, so
   new text stops appearing. Pages of CJK or emoji hit this quickly. There is
   also no font fallback: the bundled Noto Symbol/Emoji/CJK fonts are never
   used, and if `DejaVuSansMono.ttf` is missing the fallback is the
   *proportional* `DejaVuSans.ttf`, which destroys the column grid.
8. Full-screen repaint twice a second, and a poll loop that wakes 100 times a
   second doing nothing. The cursor blink sets `dirty`, which redraws every
   cell and every glyph texture. `tsm_screen_draw()`'s `age` argument is
   ignored, so the VT's change tracking is thrown away.
9. Input edge cases: only `ch[0]` of a libtsm symbol is drawn, so combining
   marks (`e` + U+0301, many Indic scripts, ZWJ emoji) lose their parts; the
   `width` argument for double-width CJK is ignored; `attr.blink` is ignored
   even though it is encoded in the callback `id`.
10. No visible way out. `Ctrl+Shift+Q` is the only quit gesture and nothing on
    screen mentions it. On a handheld with a 56-key keyboard that is a page of
    documentation nobody reads.

## 2. Root causes in the code

| Symptom | Where | Cause |
| --- | --- | --- |
| Navy frame, floating grid | `cpz-term.c:346`, `:374-379`, `:393` | 4 px margin, centred integer grid, clear colour different from the cell background |
| Double cursor | `cpz-term.c:397-409` | app-level amber underline added on top of libtsm's inverted cursor cell |
| Blink redraws everything | `cpz-term.c:698-705` | one `dirty` flag for the whole window; cursor phase marks the screen dirty |
| Font jumps / tiny panel text | `cpz-term.c:354` | three height buckets, no DPI or user size setting |
| Dense leading | `cpz-term.c:371` | `TTF_FontLineSkip` with no optical adjustment |
| Smudged bold | `cpz-term.c:327-332` | 1 px double-draw at 160/255 alpha instead of a real bold face or bright colour |
| No italic, no fallback | `cpz-term.c:125-151` | a single regular face, DejaVu Sans Mono, candidates include a proportional font |
| Dull palette | `cpz-term.c:60-79` | 16 VGA colours; foreground is grey 192 on pure black |
| Lost glyphs | `cpz-term.c:252-283` | open-addressing cache with no eviction; no path back after 4096 code points |
| Wide/combining chars broken | `cpz-term.c:296` | `ch[0]` only; `width` ignored |
| Full repaint per frame | `cpz-term.c:291` | `age` argument discarded |
| No scroll state UI | `cpz-term.c:468-481` | only scroll API calls, no `sb_get_line_count/pos`, no wheel, no thumb |
| Idle power waste | `cpz-term.c:674-681` | `poll(..., 10)` with nothing to do 99 % of the time |
| Renderer can starve | `cpz-term.c:598-619` | `read_pty()` loops until `EAGAIN`; a fast writer can keep it there |
| No selection/paste/mouse/bell | whole file | libtsm features (`selection_*`, `handle_mouse`, bell callback) are not wired |
| Undiscoverable exit | `cpz-term.c:463` | `Ctrl+Shift+Q` with no on-screen hint |

The important point: libtsm already provides most of what is missing — cell
ages, cursor-as-inverse, selection, scrollback positions, mouse reporting and a
bell callback. The fix is to use the library instead of re-drawing around it.

## 3. Target look

- Edge-to-edge terminal: the whole screen is the terminal background, no
  coloured frame, no centred island. Use a warm near-black (`#101318`) for both
  the clear and `TSM_COLOR_BACKGROUND`.
- One palette that belongs to the same device as the launcher: off-white text
  (`#d8dce3`), muted blue-grey bright black, and accents close to the launcher
  azure. Suggested: `#e06c75`, `#98c379`, `#e5c07b`, `#61afef`, `#c678dd`,
  `#56b6c2`, `#dcdfe4` for the eight base colours, bright variants one step
  lighter.
- Real faces: DejaVu Sans Mono regular / bold / oblique, falling back per glyph
  to the already-bundled `NotoSansSymbols2`, `NotoEmoji` and
  `NotoSansCJKsc`. Fixed advance always comes from the mono face.
- One cursor: hide libtsm's cursor (`TSM_SCREEN_HIDE_CURSOR`) and draw a single
  block or bar in the accent colour, or keep libtsm's inverse cursor and delete
  the amber underline. Blink only after ~500 ms of inactivity and only repaint
  the cursor cell.
- Breathing room: 2 px inner padding, no outer margin; 12–13 rows on the panel
  instead of 12 with two dead bands.
- A 1–2 px scrollbar thumb on the right only when the view is scrolled back,
  and a transient first-run hint (`Ctrl+Shift+Q — вихід, Shift+PgUp — історія`)
  that disappears on the first key.
- Selection uses a translucent azure fill, matching the launcher's selection
  bar instead of the inverse-video default.

## 4. Rework plan

### P0 — make it look like an appliance

1. **Own the whole surface.** Set the SDL clear colour to the VT background,
   set `TSM_COLOR_BACKGROUND` to the same value, use `ox = oy = 0` and a 2 px
   left/top padding only. Delete the navy frame.
2. **Remove the double cursor.** Pick one representation. The cleanest is
   `tsm_screen_set_flags(screen, TSM_SCREEN_HIDE_CURSOR)` plus a cursor drawn
   from `get_cursor_x/y` as an accent block/bar. Reset the blink phase on every
   key or pty write so it is solid while typing. Repaint only the old and new
   cursor rectangles.
3. **Typography.** Open regular, bold and oblique faces from the same family.
   Verify `TTF_FontFaceIsFixedWidth()`; if it fails, use the mono face anyway
   or ship a mono fallback — never a proportional face. Derive the cell box from
   `TTF_GlyphMetrics32('M')`, keep `cell_w` an integer, and set
   `cell_h = ascent + descent + leading` with 1–3 px of optical leading rather
   than raw `FontLineSkip`. Add `CPZ_TERM_FONT_SIZE` for overrides and log the
   chosen font, size and grid once at startup.
4. **Bold and italic.** Use the real faces; if a face is missing, map bold to
   the bright palette entry (xterm `bold-is-bright`) instead of alpha smearing.
   Fix the underline offset to sit just below the baseline, not at
   `cell_h - 2`.
5. **Palette.** Ship the modern 16 colours above and make the cursor colour a
   single accent, not an unrelated amber.
6. **Smaller idle cost.** Replace the 10 ms poll with a 50–100 ms poll or an
   SDL event + pty wakeup. Coalesce redraws to ~30 FPS, cap `read_pty()` to
   e.g. 64 KiB per wakeup so a flooding child cannot starve rendering, and
   handle `SDL_MOUSEWHEEL` as scrollback.

### P1 — fix correctness under real terminal output

7. **Damage-based rendering.** Keep a `uint32_t cell_age[rows][cols]`; skip a
   cell when `age != 0 && age == stored_age`, and repaint the full grid when
   `tsm_screen_draw()` returns 0 (age overflow). Store the returned age.
   Alternatively `tsm_screen_draw2()` gives the whole cell table in one copy;
   either way, stop repainting 564 cells for a cursor blink.
8. **Glyph atlas + LRU.** One or a few RGBA atlas pages keyed by
   `(codepoint, face, style)` — the callback `id` already encodes bold, italic,
   underline, inverse and blink, so it is the natural cache key. Keep an LRU or
   generation sweep instead of the hard 4096 stop. Render glyphs at the final
   pixel size (no scaling) and draw from the atlas with one texture bound per
   frame.
9. **Font fallback per code point.** Primary mono face for metrics; if the code
   point has no glyph, try `NotoSansSymbols2` / `NotoEmoji` / `NotoSansCJKsc`
   and centre the fallback inside the cell. Use `width == 2` to centre wide
   glyphs across two cells instead of clipping them. Render every code point in
   `ch[]`, not only `ch[0]`, so combining marks survive.
10. **Scroll state.** Use `tsm_screen_sb_get_line_count()` and
    `sb_get_line_pos()` to draw the thumb; add wheel scrolling and a "live"
    reset that is obvious (thumb disappears, cursor returns). Keep
    Shift+PgUp/PgDn as keyboard aliases.
11. **Selection and clipboard.** Wire libtsm's `selection_start/target/word/
    copy` to drag and double-click, draw the selection with the azure colour,
    and add Ctrl+Shift+C / Ctrl+Shift+V (plus OSC 52 later if SSH use matters).
12. **Mouse reporting and bell.** Forward `SDL_MOUSEBUTTON*` through
    `tsm_vte_handle_mouse()` when vim/htop/mc request tracking; wire the bell
    callback to a short flash or a toast rather than a silent drop.

### P2 — polish and keep it polished

13. **First-run hint and exit affordance.** A 1.5 s overlay with the quit and
    scroll gestures; repeatable with `F1`. No permanent chrome, so full-screen
    apps keep all rows.
14. **Visual regression harness.** Add `cpz-term --render-test out.png` using
    `SDL_VIDEODRIVER=dummy`: feed a fixed byte stream into libtsm, render to a
    surface, write a PNG. Review layout changes on a laptop instead of
    reflashing the device; compare against a checked-in baseline.
15. **Measure on hardware.** Log first-frame time and grid size, then record
    panel FPS for `cat` of a large log, `htop`, `vim` and a 24x80 `mc` screen.
    Idle CPU should be near zero and the panel should not visibly blink whole
    frames.

## 5. Acceptance criteria

- No pixel outside the terminal body uses a different colour from the terminal
  background; no letterbox bands on any output.
- Exactly one cursor. It blinks only when idle, and a keypress shows it
  immediately.
- Panel: at least 12 rows at the default size, no clipped glyph edges, no
  horizontal jitter when scrolling.
- 1080p: the grid scales to a readable size, all four font faces crisp, no
  blurry upscaled glyphs.
- Cyrillic, `e` + combining acute, CJK width 2, emoji and a 5000-distinct-
  codepoint dump all render (or fall back to a box), with no silent text loss.
- `cat` of a 10 MB log keeps input responsive; `yes` cannot lock the UI.
- Scrollback thumb appears when scrolled; typing returns to live; wheel works.
- Selection/copy works; vim and mc receive mouse events when they ask for them.
- Idle CPU is effectively zero; a cursor blink redraws one cell, not the screen.

The VT engine, the pty and the child session setup do not need to change for
any of this. It is a renderer rewrite in `cpz-term.c`, not a new terminal.
