# TUI contract v1

Status: agreed on `design/app-platform` (2026-11-26). This document is binding
for every CPZ console application built on this platform, including the system
apps in `cpz-system-apps` and third-party apps that want the standard look. It
sits under [UI-QUALITIES.md](UI-QUALITIES.md);
[APP-CONTRACT.md](APP-CONTRACT.md) covers packaging and launch,
[APP-PLATFORM.md](APP-PLATFORM.md) covers the repository and Apps Manager, and
[LANGUAGE.md](LANGUAGE.md) covers translations.

If a requirement here conflicts with a hardware fact, the hardware wins and
this document is corrected. Do not work around the keyboard with Fn chords.

## 1. Scope and stack

- One toolkit for every CPZ TUI: Go 1.24 + Bubble Tea 1.3 + Lip Gloss,
  wrapped in the shared `internal/tui` kit of `cpzos-apps`.
- Ship one static aarch64 binary (the `cpz-app` multicall binary is preferred:
  `cpz-app home`, `cpz-app apps`, `cpz-app settings`).
- No daemon, no background process, no shell, no network on startup. Process
  launches use argv arrays only.
- No alternative TUI library without an explicit decision in
  `APP-PLATFORM.md`. Consistency is a feature; a second stack doubles the
  review surface on a 320×170 panel.
- Apps are terminal programs. They never draw the tmux status row, the tab bar
  or any other session chrome.

## 2. Hardware facts that drive the interface

The Cardputer Zero matrix keyboard has no dedicated arrow keys:

| Input | Base layer | Fn layer |
| --- | --- | --- |
| `F` | letter `f` | `Up` |
| `X` | letter `x` | `Down` |
| `Z` | letter `z` | `Left` |
| `C` | letter `c` | `Right` |
| `Esc`, `Tab`, `Enter` | plain | plain |
| `Fn+H`, `Fn+K/N`, `Fn+L/M`, `Fn+B` | — | Help, Home/End, PgUp/PgDn, Insert |
| `Fn+1..0`, `Fn+O/P` | — | F1–F12 |
| punctuation | Sym layer | — |

Source: `modules/tca8418-1.0/tca8418_m5stack.dts` (vendor overlay pinned in
`config.sh`) and the M5Stack Cardputer Zero guide. `F`/`X`/`Z`/`C` sit in a
physical d-pad shape around the home row; the Fn layer turns the same four keys
into arrows. M5Stack's own apps treat plain `F`/`X`/`Z`/`C` as arrows on
screens without text input.

**Rules:**

1. Movement in every list is bound to plain `F`/`X`/`Z`/`C`. No Fn, ever, for
   the primary flow.
2. Real arrows (`Up`, `Down`, `Left`, `Right`, including the Fn chords and an
   external USB/HDMI keyboard) work in the same places.
3. Confirm is `Enter`; back/cancel is `Esc`; there are no Fn-only primary
   actions. `F1`–`F12`, `Insert`, `Delete`, `Home`, `End`, `PageUp`,
   `PageDown` and punctuation are secondary at most.
4. Reserved for tmux: `Alt+*` (daily actions) and `C-a` (prefix). A TUI must
   not require either. `Alt+O`, `Alt+T`, `Alt+W`, `Alt+Tab` and the other
   bindings in `HELP` must keep working from inside an app.
5. `Esc` is never "quit the tab". It goes back one level, cancels an edit or
   closes a dialog. Closing a tab stays on `Alt+W`.
6. `Ctrl+C` cancels the running operation; at a root screen it exits the app.
   It never leaves the terminal in a broken state.

## 3. Keyboard layouts

The session runs `us,ua` and switches live. On the `ua` layout the physical
d-pad keys produce Cyrillic letters, so bind both:

| Key | us | ua |
| --- | --- | --- |
| up | `f` | `а` |
| down | `x` | `ч` |
| left | `z` | `я` |
| right | `c` | `с` |

`Esc`, `Tab`, `Enter` and arrows are layout-independent and always work. Under
any other layout the user still has arrows and `Esc`; do not silently break the
d-pad by matching only `msg.String() == "f"`. Adding a language means adding
the four physical letters for its layout to the kit's keymap table before the
translation ships.

While a text field has focus, `F`/`X`/`Z`/`C` type letters; arrows remain on
the Fn layer. Never capture printable letters globally.

## 4. Screen anatomy

Every screen is built from the same three parts:

```text
<title>                         <context>     1 line, dim, never a box
<list / detail / form body>                   all remaining rows
<status>                                     0 or 1 line, transient
```

- No footer hint bar, no key legend, no permanent help line. Help is an overlay
  opened with plain `h` outside a text field (`Esc` closes it).
- No borders, frames or box drawing: they cost 2–4 columns on a 45-column
  screen and add nothing. Focus is an inverse bar, not a border.
- No scrollbars, no paging indicators, no progress bars. Pad the list with
  blanks and keep the cursor on screen.
- Exactly one focus at a time, always visible without colour (inverse bar and
  a leading marker).
- The status line is used for one message, replaces itself, and disappears on
  the next key press or after five seconds.

Reference screens for the panel (45 columns shown, not to scale):

```text
Home
> Terminal                   shell
  Player                     media
  Settings                   system
```

```text
Apps Manager · All            2/12
> Update app list
  Player                      0.4.1   *
  Recorder                    0.2.0
  Weather                     1.1.0
```

Detail and confirmation are separate screens, not popups over the list:

```text
Player                        0.4.1
Play music from the library.
Audio · 12.4 MB · installed
> Open
  Remove
  Back
```

## 5. Layout and typography

- Design first for 40×10 usable cells; the panel normally gives about 45
  columns and 12–13 rows after the tmux row. Test at 40×10 and at the nominal
  panel grid from `UI-QUALITIES.md`; never hardcode 320×170.
- One item per line, no wrapping in lists. Truncate with `…` and keep the
  focus marker and the right-hand state column visible.
- Minimum readable content: 8 list rows on the panel. If the list cannot fit,
  reduce chrome, not font size.
- One monospace family (foot ships DejaVu Sans Mono). No icons, no emoji, no
  Nerd Font glyphs, no Unicode box drawing. ASCII plus `…` and `·` only.
- Columns: 1 cell focus marker, 1 space, name, flexible gap, state/version.
- Numbers and versions right-aligned. Never right-align a name.
- Colour tokens come from the kit and match the tmux row: background
  `#1b1b1b`, normal `#cfcfcf`, dim `#8a8a8a`, focus `#101010` on `#d7d7d7`.
  Colour never carries state alone; pair it with text or a marker.
- One accent colour at most. The panel is 320×170; a rainbow is noise.

## 6. Performance

Measured on the panel, from `exec` to first usable frame:

| Budget | Target |
| --- | --- |
| first frame, cold | ≤ 100 ms |
| first frame, warm | ≤ 50 ms |
| key press to visible change | 50 ms typical, 100 ms p95 |
| idle CPU | 0% (blocking event loop, no tick) |
| idle wakeups | 0/min; a clock may wake once per minute |
| RSS | ≤ 16 MB per app |
| stripped binary | ≤ 8 MB |

Consequences:

- Read local files only (`/usr/share/applications`, `~/.local/share`,
  `/etc/cpz`, `/run/cpz`, `/proc`, `/sys`) before the first frame.
- Parse the catalog once at start; do not stat every package or call `pacman`
  in a loop. One `pacman -Q`/`-Qo` call per selected item is the ceiling.
- No network, no `sudo`, no package operation before the first frame.
- Long operations run as asynchronous commands with an explicit "working"
  state and a spinner that redraws no faster than every 100 ms.
- No animation, no fades, no full-screen repaint per keystroke. Bubble Tea's
  diffing renderer is enough; do not disable it.

## 7. Flows, confirmation and errors

- `Enter` on a list item opens it. In Apps Manager, the first `Enter` opens the
  detail screen; actions are a vertical list on that screen.
- Destructive actions ask for confirmation, name the object, and default to
  "No". `Enter` on the default "No" cancels; `Esc` cancels. Focus starts on
  "No" and the dialog is a screen, not a corner popup.
- Removing an app removes its package, not its user data. The confirmation
  says so.
- A failed operation leaves the app running and shows what failed and what to
  do next in the status line. Raw `pacman` output is never dumped on the panel;
  the full log path is shown or written to `~/.local/state/cpz/apps/log`.
- A missing file, invalid desktop entry or unknown package is skipped with a
  reason, not a crash. Panic recovery must restore the terminal.
- An app never asks for a password: privileged work goes through the helper
  from `APP-PLATFORM.md`.

## 8. State, locale, accessibility

- Apps are read-only except for their own files under
  `~/.config/cpz/<app>` (settings) and `~/.local/state/cpz/<app>` (logs,
  state). Caches go under `~/.cache/cpz/<app>`. Never write to `/etc`, the
  package database or another app's files.
- Every visible string comes from a catalog; resolution and file names are in
  [LANGUAGE.md](LANGUAGE.md). English and Ukrainian ship now; the other agreed
  languages resolve to English until translated.
- Ukrainian labels are the width test. If a string does not fit at 40 columns,
  shorten it; truncation of a label is a bug, truncation of a value is allowed.
- Complete keyboard operation, visible focus and a colour-independent state
  are mandatory. A screen reader is out of scope.

## 9. Definition of done for every app

- [ ] Plain `F`/`X`/`Z`/`C`, arrows, `Enter`, `Esc`, `Tab` work on the panel.
- [ ] Works with the `ua` layout active and with a USB keyboard.
- [ ] Layout survives 40×10 and the nominal panel grid; no clipped labels.
- [ ] First frame and key latency measured on hardware and inside budget.
- [ ] Idle CPU is 0% in `top`; no timer runs when nothing changes.
- [ ] `Esc` never closes the tab; `Alt+Tab`/`Alt+W` still work.
- [ ] No shell, no `sh -c`, no command string built from user data.
- [ ] `desktop-file-validate` passes for every installed entry.
- [ ] `gofmt`, `go vet ./...`, `go test ./...` pass; golden frames cover the
      smallest size, both keyboard layouts and `CPZ_LANG=en`/`uk`.
- [ ] Failure path tested: offline, package error, missing catalog, read-only
      home.
- [ ] `README` of the app lists its keys in the same order as this document.
