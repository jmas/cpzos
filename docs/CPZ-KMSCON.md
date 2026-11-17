# CPZ terminal session (kmscon)

The regular CPZ image is a terminal system: kmscon owns the DRM/KMS console and
runs tmux with the CPZ status bar and Settings TUI. There is no compositor,
desktop or launcher. fbcon stays mapped to the panel before kmscon takes over.

```text
firmware splash
  → kmsconvt@tty1 → cpz-kmscon → cpz-login tty1 → login(1) as uid 1000
  → cpz-session.sh → tmux (top status bar, tabs, Settings)
  → HDMI usable: kmscon draws on HDMI and disables the panel screen,
    cpz-kmscon-output switches the panel backlight off
  → HDMI removed: kmscon re-enables the panel, backlight on
  → tty2/tty3: fbcon recovery logins
```

The fbcon backend lives on the `main` branch (`docs/CPZ-FBCON.md` there).

## Why fbcon stays mapped

kmscon needs the panel card to have an **active CRTC** when it starts. With
`fbcon=map:off` nothing sets a panel mode at boot, kmscon's "original" mode is
0x0, and its first atomic commit fails with

```text
Error: drm_shared: test-only atomic commit failed, -13
```

after which the panel display is dropped and never re-added.

`cmdline.append` therefore keeps fbcon mapped to the panel:

```text
fbcon=map:10 consoleblank=0 vt.global_cursor_default=0
```

fbcon sets the 320x170 mode on the panel at boot, so kmscon finds a valid mode.
kmscon starts with `--switchvt`: activating the VT runs `vt_enter()`, sets
`KD_GRAPHICS` and releases the framebuffer to kmscon. tty2/tty3 stay fbcon
recovery consoles (tty2 on HDMI, tty3 on the panel, following `map:10`), and
`getty@tty1` is masked because kmscon owns tty1.

## Build

```sh
cp config.cpz.example config
sudo ./build.sh
# or on macOS with Docker:
./build-docker.sh
```

`stage3/00-kmscon` installs a pinned kmscon and libtsm from
`trixie-backports` (`KMSCON_VERSION`, `LIBTSM_VERSION`) and holds them with
`apt-mark`. If the package disappears, build it from the pinned upstream
tarball instead of falling back to kmscon 9.

## One working output

kmscon uses `multi-monitor=largest`: it draws on the screen with the most
cells at the configured font size and stops drawing on the others. With the
internal panel (320x170) and an HDMI monitor, HDMI always wins, so the panel
screen is disabled (`enabled=false` in kmscon, `bl_power=4` + brightness 0
from the helper). When HDMI is removed, kmscon re-enables the panel itself.

`display=panel` in Settings switches the generated configuration to
`multi-monitor=clone`, so the panel keeps being drawn while HDMI is attached
(`largest` would always pick HDMI).

| State | kmscon draws on | Panel backlight |
| --- | --- | --- |
| HDMI connected, EDID readable (or pinned mode) | HDMI | off |
| HDMI connected, EDID unreadable, session already on HDMI | HDMI | off |
| HDMI connected, EDID unreadable, session on the panel | panel | on |
| HDMI disconnected | panel | on |
| `display=panel` (clone mode) | panel and HDMI | on |
| `display=hdmi`, no monitor | panel | on |

The backlight is switched off **only when kmscon reports the HDMI connector as
enabled**. A monitor that is connected but not driven therefore leaves a
visible panel instead of a black machine.

`cpz-kmscon-output` runs from a two-second timer and from a DRM hotplug
uevent:

```sh
sudo cpz-kmscon-output --status
# mode    : auto
# HDMI    : connected, EDID 256 bytes, pinned no, enabled yes
# target  : hdmi
# current : hdmi
# drm     : card0-HDMI-A-1 connected/enabled, card1-DSI-1 connected/disabled
# panel   : backlight brightness=0/255 bl_power=4
# session : active
```

Other modes:

```sh
sudo cpz-kmscon-output --panel     # force the panel for this run
sudo cpz-kmscon-output --hdmi      # force HDMI (falls back when unplugged)
sudo cpz-kmscon-output --auto      # follow the settings again
sudo cpz-kmscon-output --force     # re-render and restart the session now
sudo cpz-kmscon-output --recover   # restart the session (HDMI link recovery)
```

`Alt+D` toggles `display` between `auto` and `panel`; Settings → Display &
Brightness → Output sets `auto`, `panel` or `hdmi`. The timer picks the change
up within two seconds.

### Diagnosing the panel

kmscon logs one line per display it drives:

```sh
journalctl -u kmsconvt@tty1 -b | grep -E 'Display|master|drm'
```

`Display [HDMI-A-1] ...` is the monitor. A working panel adds a second line
with the panel connector (`SPI-1`). If only HDMI appears, look for
`test-only atomic commit failed` in the same log; check what the kernel
reports:

```sh
for d in /sys/class/drm/card*-*; do
    echo "$d: $(cat "$d/status") $(cat "$d/enabled" 2>/dev/null)"
done
cat /sys/class/drm/card*-SPI-*/modes 2>/dev/null
```

`connected/disabled` means the connector is fine but nothing drew on it (the
card nudge should correct that on the next boot or plug). `disconnected` or an
empty `modes` list is a driver issue: kmscon can only use a DRM connector that
reports `connected` with at least one mode.

### Hotplug and the "monitor turns off and on" symptom

kmscon handles hotplug in `drm_video_hotplug`: a new display is added to the
terminal, `largest` re-evaluates the size, and the other screens are disabled.
Restarting kmscon is **not** part of a normal hotplug. That matters because a
restart drops DRM master and makes the monitor renegotiate the link, which
looks like the monitor switching off and on.

kmscon 10 only listens for `HOTPLUG=1` on the **DRM card** device, but vc4
reports an HDMI hotplug on the **connector** (`card0-HDMI-A-1`), which
`uterm_monitor` ignores. `cpz-kmscon-output` therefore writes `change` to
`/sys/class/drm/cardN/uevent` when the connector state changes (and once after
boot, so the panel card is re-scanned). `99-cpz-kmscon-nudge.rules` marks that
synthetic event `HOTPLUG=1`, and kmscon re-scans its connectors in place. The
session, tmux and all panes keep running; only the screen layout changes.

Restarts only happen for:

- a changed generated configuration (font size, theme, screen timeout, layout,
  `display=panel` ↔ auto/HDMI);
- `--force` / `--recover`;
- a hotplug kmscon missed even after the card nudge: HDMI is connected and
  usable but no CRTC is attached for three ticks (~6 s). After one restart
  that still does not enable HDMI, retries stop until the connector state
  changes (replug or monitor wake) or `--recover` is used. The monitor is
  never blinked in a loop.

Switching *to* HDMI is debounced by two samples; returning to the panel is
immediate. Once on HDMI, the session stays there while the connector is
connected even if the EDID read fails for a moment, so a monitor in standby
cannot bounce the session.

## Generated kmscon config

kmscon reads its configuration once at startup and has no runtime API. Values
the Settings TUI can change are rendered into
`/run/cpz-kmscon/kmscon.conf` by `cpz-kmscon-config`; the static half is
`/etc/kmscon/kmscon.conf`.

| Setting | kmscon option |
| --- | --- |
| `display=panel` | `multi-monitor=clone` |
| any other display mode | `multi-monitor=largest` |
| `font_panel=6x12` | `font-size=12` |
| `font_panel=8x16` | `font-size=16` |
| `screen_timeout=5/10/30` | `dpms-timeout=300/600/1800` (0 = never) |
| `keyboard_layout_active` | `xkb-layout=...` |
| `theme` | `palette=custom` + the theme's 16 colours, background and foreground |

The font size is shared by both screens, so HDMI gets more columns at the same
cell size. `Ctrl+Plus` / `Ctrl+Minus` zoom the terminal at runtime without a
restart (kmscon's `grab-zoom-in` / `grab-zoom-out`).

`font_hdmi` is unused on this branch. `cpz-kmscon-config` prints `changed` or
`same`; `cpz-kmscon-output` restarts the session only when the rendered file
differs, the display mode moves to/from `clone`, or a hotplug was missed.

`term=xterm-256color` is deliberate: kmscon does not ship a terminfo entry for
`TERM=kmscon`, and tmux refuses to attach to an unknown terminal. libtsm is
xterm-compatible, so the ncurses entry from `ncurses-base` is the safe value.

## Restart semantics

A restart replaces the kmscon process and the login shell inside it. tmux is
started detached (`tmux start-server` + `new-session -d`) and re-attached by
the next login shell, so tabs, pane working directories and running programs
survive. Only a foreground program outside tmux would be lost.

kmscon runs its child on a pty, so `tty` there is `/dev/pts/N`, not
`/dev/tty1`. `cpz-login` records that pty per VT
(`/run/cpz-kmscon/session.tty1.tty`, `session.tty2.tty`), and `cpz-session.sh`
attaches tmux only on the tty1 pty. The tty2/tty3 kmscon logins, SSH and
the debug image stay plain shells.

## Files

```text
/usr/bin/kmscon
/etc/kmscon/kmscon.conf                     # static template
/usr/local/bin/cpz-kmscon                   # unit ExecStart
/usr/local/bin/cpz-kmscon-config            # renders /run/cpz-kmscon/kmscon.conf
/usr/local/bin/cpz-kmscon-output            # output reconciler
/usr/local/bin/cpz-login                    # uid 1000 autologin + pty marker
/etc/systemd/system/kmsconvt@.service.d/10-cpz.conf
/etc/systemd/system/cpz-kmscon-output.service
/etc/systemd/system/cpz-kmscon-output.timer
/etc/udev/rules.d/99-cpz-kmscon-output.rules
/etc/udev/rules.d/99-cpz-kmscon-nudge.rules
/etc/systemd/system-sleep/cpz-kmscon
/etc/profile.d/cpz-session.sh
/etc/tmux.conf
```

Enabled: `kmsconvt@tty1`, `getty@tty2`, `getty@tty3`, `console-setup`,
`cpz-kmscon-output.timer`,
`cpz-conn-status.timer`, `cpz-session-save.timer`,
`cardputerzero-keymap.service`, `cpz-keyboard-layout.path`,
`cpz-bt-agent.service`, `bluetooth.service`, `NetworkManager.service`,
`rpi-preseed.service`.

Masked/disabled: `getty@tty1` (kmscon owns tty1),
`userconfig.service`, `NetworkManager-wait-online.service`,
`apt-daily.timer`, `apt-daily-upgrade.timer`, `man-db.timer`,
`unattended-upgrade.service`.

## Debug image

```sh
cp config.debug.example config
sudo ./build.sh
# or:
./build-docker.sh -c config.debug.example
```

The debug image removes the splash, `quiet`, `loglevel=3` and
`vt.global_cursor_default=0`, keeps `fbcon=map:10 consoleblank=0`, adds
`console=serial0,115200 console=tty1 loglevel=8`, masks `kmsconvt@tty1` and
enables `getty@tty1`/`tty2`/`tty3`. If it shows nothing, the failure is before
kmscon.

## Known limitations

- **The internal TCA8418 keymap is not applied inside kmscon.** kmscon uses
  libxkbcommon, not the VT keymap, so `loadkeys` cannot reach it. The selected
  `xkb-layout` works for external keyboards and `Alt+Space` switches it (with
  a session restart), but the CPZ Sym/Fn overlay needs an XKB keymap port.
- **Screen timeout is DPMS, not blank-only.** kmscon's `dpms-timeout` powers
  the output down. A monitor that renegotiates on wake may change the mode;
  pin `CPZ_HDMI_VIDEO` (`video=HDMI-A-1:1920x1080@60`) if that happens. Set
  `screen_timeout=0` to disable it. A DPMS timeout is a deliberate blank, not
  a crash loop.
- **Theme changes restart the session** to rebuild the palette (about 1–2 s,
  tmux reattaches).
- **tty1 is graphics-only.** tty2/tty3 keep framebuffer consoles; if kmscon
  itself cannot start, use those, SSH or the serial console.
- kmscon is pinned from `trixie-backports`; keep `KMSCON_VERSION` in
  `stage3/00-kmscon/00-run.sh` in step with the image.

## Hardware checks

```sh
# boot to the panel, then plug HDMI: session moves, panel backlight goes dark
sudo cpz-kmscon-output --status
journalctl -t cpz-kmscon-output -b
journalctl -u kmsconvt@tty1 -b     # look for "Cannot set drm master"
# unplug: panel returns without an HDMI blink
# Ctrl+Alt+F2 / Ctrl+Alt+F3: fbcon recovery logins
# Alt+D: panel comes back while HDMI stays attached
# suspend/resume: output and backlight are re-applied
sudo evtest                 # verify Fn key codes
free -m
systemd-analyze
```

If kmscon cannot drive the panel reliably, return to the fbcon branch and do
not build the rest of the CPZ UI on an unproven console layer.
