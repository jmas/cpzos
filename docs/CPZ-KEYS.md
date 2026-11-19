# CPZ keyboard shortcuts

CPZ is a terminal-first image with a small internal keyboard. Punctuation sits
behind the Sym layer and the arrow keys are Fn combinations, so a conventional
Linux desktop shortcut (`Ctrl+Alt+T`, `Alt+Left`, `Prefix + %`) can cost three
or four physical presses. The shortcuts are therefore deliberately narrow:

> **Every user-facing CPZ shortcut is one modifier plus one plain key: two
> physical keys, with Alt as the default modifier.**

`cpz-keys` is the single source of truth. It generates the tmux bindings,
renders `Alt+H`, fills the CPZ Search action list, shows the first-login hint
and backs Settings → Input → Shortcuts.

## Internal and external keyboards

The internal TCA8418 keyboard needs the CPZ overlay (`cpz_us`, `cpz_ua`, ...)
for its Sym layer. Applying that overlay to a USB/Bluetooth keyboard scrambles
punctuation, and cage has a single keymap for the seat, so
`cpz-keyboard-layout` switches it:

- **auto** (default): an external USB/Bluetooth/PS2 keyboard selects the
  standard layout; otherwise the CPZ overlay is used.
- **cpz** / **standard** force one of the two.

The switch is published to localed and `cpz-cage-output` restarts the
compositor (~2 s). Keyboard interfaces that belong to a pointer are ignored: a
gaming mouse often exposes a second HID endpoint advertising a full keyboard
bitmap for macro keys, and treating it as a keyboard would keep the standard
layout forever while the mouse is plugged in. A node counts as a keyboard only
when no interface of the same USB device has relative X/Y axes.

## Rules

1. **Two keys maximum.** One modifier (`Alt`) plus one key. No `Ctrl+Alt`,
   `Shift+Alt`, `Sym` or `Fn` chords for a CPZ action. The one named-key
   exception is previous tab: `Alt+Shift+Tab`, using the conventional reverse
   Tab key.
2. **Alt is the primary modifier.** The defaults use `Alt+letter` and
   `Alt+digit`. `Alt+Space` is the only named key because Space is a single
   normal key on both the internal and an external keyboard.
3. **No punctuation keys.** `+`, `-`, `[`, `]`, `%`, `"` and friends need the
   Sym layer on the internal keyboard. Use a letter instead.
4. **No arrows for global actions.** The internal arrows are `Fn+F/X/Z/C`.
   Global navigation uses letters; copy mode keeps its single-key vi movement.
5. **One action, one binding.** No duplicate aliases. `Alt+A`, `Alt+F`,
   `Ctrl+Plus`, `Ctrl+Minus`, `Alt+I` and the old `Alt+arrow` scroll aliases are
   intentionally gone. Tab switching uses the conventional
   `Alt+Tab` / `Alt+Shift+Tab` pair.
6. **The prefix is a fallback, not the UI.** `C-a` remains available for tmux
   commands that are not in the CPZ registry. Daily actions never need it.
7. **Rebindable by design.** A user-facing binding belongs in `cpz-keys`, never
   in a `bind -n` line in `tmux.conf`, a literal in `cpz-help`, or a hard-coded
   key in `cpz-search`. The tests enforce the registry rules.

## Defaults

| Group | Action | Keys |
| --- | --- | --- |
| Start here | Search | `Alt+O` |
| | Settings | `Alt+S` |
| | Help | `Alt+H` |
| Tabs | Previous / next tab | `Alt+Shift+Tab` / `Alt+Tab` |
| | Select tab 1–9 | `Alt+1` … `Alt+9` |
| | New / close / rename / list | `Alt+T` / `Alt+W` / `Alt+R` / `Alt+L` |
| Panes | Split left/right, top/bottom | `Alt+V` / `Alt+B` |
| | Next / previous pane | `Alt+N` / `Alt+P` |
| | Zoom / close pane | `Alt+Z` / `Alt+X` |
| | Swap pane previous / next | `Alt+J` / `Alt+K` |
| Scroll and copy | Copy mode / paste buffer | `Alt+C` / `Alt+Y` |
| Sound | Volume up / down | `Alt+U` / `Alt+I` |
| | Mute | `Alt+0` |
| Session | Input layout | `Alt+Space` |
| | Display toggle (panel / auto) | `Alt+D` |
| | Font bigger / smaller | `Alt+G` / `Alt+M` |

`Alt+Tab` moves to the next live tab and `Alt+Shift+Tab` to the previous one,
wrapping at the ends in the same order as a browser. The Settings tab is part
of the cycle, so Tab returns to it as well; `Alt+S` still opens (or focuses)
Settings directly. Tabs whose pane has died are skipped, so cycling cannot
land on a blank screen. Tab numbers remain the fastest way to jump directly.
`Alt+U` / `Alt+I` change the default output volume in the same 5% steps as
Settings → Sound; `Alt+0` toggles mute. Both paths use `wpctl`, so the
status-bar volume token stays in sync.

### Copy mode

`Alt+C` enters copy mode. Then:

- `j` / `k` (or `Fn+F` / `Fn+X`) move one line,
- `Ctrl+U` / `Ctrl+D` or `Fn+L` / `Fn+M` page,
- `Space` starts or stops a selection, `Enter` copies,
- a mouse drag enters copy mode and copies the selection on release,
- double-click selects the word under the pointer,
- `q` leaves copy mode.

`set-clipboard` is on by default. tmux sends the copied text over OSC 52 and
foot puts it on the Wayland clipboard; `Alt+Y` pastes the tmux buffer when the
receiving application does not accept the clipboard.

Only two keys are needed for the paging keys; the one-key vi movement is inside
a mode, where it does not compete with a global shortcut.

### In-app keys

Modes and full-screen programs have their own local keys. They are not CPZ
global chords and do not need to be rebindable:

- Settings: `F/X/Z/C` (the Fn-off positions) or `h/j/k/l` move; `Enter` opens
  or applies; `q`/`Esc` goes back.
- CPZ Search: `Enter` runs the selected row, `Ctrl+Y` copies it, `Ctrl+O` opens
  its folder or details.
- Applications: `Enter` shows details, `i` installs, `e` runs.
- Copy mode: the vi keys and `Ctrl+U`/`Ctrl+D` paging above.

`Sym` and `Fn` remain layout modifiers: they produce punctuation/extra letters
and arrow keycodes, but a CPZ action never requires them.

## Audit changes

The first pass removed the bindings that could not be produced with two keys
on the internal keyboard and the aliases that made the reference inconsistent:

- Tab switching moved from `Alt+Left` / `Alt+Right` (Fn chord internally) to
  `Alt+Tab` / `Alt+Shift+Tab`. The intermediate `Alt+A` / `Alt+F` defaults were
  removed; both keys remain free for user overrides.
- Text size moved from `Alt+Plus` / `Alt+Minus` and `Ctrl+Plus` / `Ctrl+Minus`
  (Sym layer plus an extra modifier) to `Alt+G` / `Alt+M`.
- The duplicate `Alt+I` layout shortcut was removed; `Alt+Space` is the single
  binding.
- Global history shortcuts `Alt+Up` / `Alt+Down` and `Alt+PageUp` /
  `Alt+PageDown` were removed. `Alt+C` enters copy mode, where `Ctrl+U` /
  `Ctrl+D` (or `Fn+L` / `Fn+M`) page and `j` / `k` move.
- Prefix aliases (`C-a c`, `C-a &`) were removed. `C-a` itself remains only
  for advanced tmux commands that have no CPZ action.
- The global `Detach` shortcut (`Alt+Q`) was removed from the CPZ registry. It
  was confusing on a kiosk because the tty1 client immediately reconnects; use
  the tmux prefix fallback `C-a d` if a real detach is needed.
- The old copy-mode `M-Up` / `M-Down` aliases were removed in favour of the
  mode's own paging keys.

The result is one registry, one binding per action, and no daily action that
needs a third key or the Sym/Fn layer.

## Settings → Input → Shortcuts

The Shortcuts page lists one row per action and its current key.

- `Enter` (or `Space` / `C`) opens the capture dialog.
- Press `Alt+letter`, `Alt+digit`, `Alt+Space` or `Alt+Tab` to bind it.
- `Backspace` restores that action's default.
- `Esc` cancels.
- `Reset Shortcuts` at the bottom restores every default.
- `Reset Settings` also restores the shortcuts.

Saving writes `~/.config/cpz/keys.conf`, regenerates
`~/.cache/cpz/tmux-keys.conf`, and reloads it in the live tmux server. The
`Alt+H` page and CPZ Search show the new keys immediately.

While the capture dialog is open, CPZ temporarily removes its root-table
bindings. Otherwise tmux would consume an already-bound `Alt+key` before the
Settings pane could see it, which would make swapping keys impossible.

## Configuration

`cpz-keys` embeds the defaults. An optional `/etc/cpz/keys.conf` can set
system defaults, and the user file takes precedence:

```text
~/.config/cpz/keys.conf
```

The format is one action id and one `Alt+key` per line; omitted actions use the
default:

```ini
# CPZ shortcut overrides. Written by cpz-settings.
font-up=Alt+U
```

Only these forms are accepted:

```text
Alt+<a-z>   Alt+<0-9>   Alt+Space
```

`Ctrl` is deliberately rejected for global bindings: intercepting `Ctrl+C`,
`Ctrl+D`, `Ctrl+Z`, `Ctrl+U` or `Ctrl+W` before the pane would break the shell
and common terminal programs. Rebind to another `Alt` key instead.

The CLI is useful for scripts and recovery:

```sh
cpz-keys list                 # id, label, group, key, display, default
cpz-keys help                 # the paged key reference
cpz-keys hint                 # one-line first-login hint
cpz-keys write                # regenerate ~/.cache/cpz/tmux-keys.conf
cpz-keys apply                # write and source it in the live server
cpz-keys bind font-up Alt+U   # persist one override
cpz-keys unbind font-up       # restore that default
cpz-keys reset                # remove all overrides
```

## Implementation

- `stage3/01-session/files/cpz-keys` — registry, validation, overrides,
  generated tmux file, help/hint text.
- `stage3/01-session/files/tmux.conf` — sources the generated bindings and
  defines only copy-mode paging and the `C-a` fallback.
- `stage3/01-session/files/cpz-settings` — Shortcuts page and capture dialog.
- `stage3/01-session/files/cpz-search` — action list from the registry.
- `stage3/01-session/files/cpz-help`, `cpz-hint` — output from the registry.

When adding a shortcut, add an action to `ACTIONS` in `cpz-keys`, give it a
unique two-key default, a group and a tmux command, then run `./tests/run.sh`.
Do not add a parallel key list elsewhere.
