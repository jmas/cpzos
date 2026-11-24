# UI rules

## Minimalism

- Prefer a clean screen and more useful content over chrome.
- No permanent footer, hint bar or key legend. The user knows the shortcuts.
- Every instruction, gesture and shortcut lives in `cpz-help` (`Alt+H`/`?`).
- Help is an ordinary app registered in the menu; the shell does not draw
  built-in help pages.
- Empty space is allowed. Do not fill it with text.

## Layout

- 12 px cell → about 53×14 on the panel.
- One tmux status row; no permanent app footer.
- Lists: one row per item, fixed gutter, selected row uses the accent background.
- Dialogs: 1 px border, dimmed background, two or three actions.
- No animations at 30 Hz; cursor blink only. Transitions are instant.

## Typography and colour

- One monospace family (DejaVu Sans Mono; Terminus optional).
- Bold for headings, dim for secondary text; no proportional font in lists.
- Dark default: background `#0e1116`, text `#d8dee9`, accent `#4ea1ff`,
  borders `#2a313c`.
- Theme tokens live in the C sources; apps do not define local palettes.

## Applications

- Apps use the shared TUI primitives and never draw the panel.
- Apps register with a `.app` manifest; the shell has no app names.
- Settings, Battery, Network, Bluetooth and Sound are apps.
- A provider publishes typed widgets; it does not draw them.

## Icons

- Icons are real raster images (`*.rgba`), not font glyphs or emoji.
- The launcher prints a PUA codepoint; the terminal replaces it with the image.
- If an icon is missing, the gutter is blank. Never substitute a symbol.
