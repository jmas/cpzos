# CPZ terminal session (kmscon)

The regular CPZ image is a terminal system: kmscon owns the DRM/KMS console on
tty1 and runs tmux with the CPZ status bar and Settings TUI. There is no
compositor, desktop or launcher.

```text
firmware splash
  → kmsconvt@tty1 → cpz-kmscon → cpz-login → login(1) as uid 1000
  → cpz-session.sh → tmux (top status bar, tabs, Settings)
  → HDMI usable: session on HDMI, internal panel backlight off
  → HDMI removed: panel backlight on, session on the internal panel
  → tty2/tty3: fbcon recovery logins
```

The fbcon backend lives on the `main` branch (`docs/CPZ-FBCON.md` there). This
branch replaces it with kmscon for FreeType text, full Unicode and the
`multi-monitor=scaled` layout. It exists because kmscon is a userspace
terminal emulator, so it needs a small wrapper around DRM and a restart-based
configuration model (below), not because fbcon was wrong.

## Build

```sh
cp config.cpz.example config
sudo ./build.sh
# or on macOS with Docker:
./build-docker.sh
```

`stage3/00-kmscon` installs a pinned kmscon and libtsm from
`trixie-backports` (`KMSCON_VERSION`, `LIBTSM_VERSION`) and holds them with
`apt-mark`. The image keeps the backports source so a rebuild resolves the same
pin; if the package disappears, build it from the pinned upstream tarball
instead of falling back to kmscon 9.

## One working output

kmscon uses `multi-monitor=scaled` whenever both connectors are present: the
layout stays at the panel grid (53x14 at 12px) and the font is scaled up on
HDMI. "One working output" is enforced by the backlight and by where the
session is visible:

| State | Session | Panel |
| --- | --- | --- |
| HDMI connected with a readable EDID | drawn on HDMI | backlight off (`bl_power=4`) |
| `video=HDMI-A-1:1920x1080@60` pinned | drawn on HDMI | backlight off, no EDID needed |
| HDMI connected, EDID empty (standby) | internal panel | backlight on |
| HDMI disconnected | internal panel | backlight on |
| `display=panel` | internal panel | backlight on (HDMI keeps mirroring for recovery) |
| `display=hdmi`, no monitor | internal panel | backlight on |

The panel is not disconnected at the DRM level; kmscon keeps drawing the same
grid on it. Switching the backlight off is what makes it dark and saves the
power. This also means the panel comes back instantly on unplug: there is no
mode set involved on the panel side.

`cpz-kmscon-output` is the reconciler. It runs from a two-second timer and from
a DRM hotplug uevent:

```sh
sudo cpz-kmscon-output --status
# mode    : auto
# HDMI    : connected, EDID 256 bytes, pinned no
# target  : hdmi
# current : hdmi
# panel   : backlight brightness=255/255 bl_power=4
# session : active
```

Other modes:

```sh
sudo cpz-kmscon-output --panel     # force the panel for this run
sudo cpz-kmscon-output --hdmi      # force HDMI (falls back when unplugged)
sudo cpz-kmscon-output --auto      # follow the settings again
sudo cpz-kmscon-output --force     # re-render and restart now
sudo cpz-kmscon-output --recover   # cycle HDMI DPMS, then restart
```

`Alt+D` toggles `display` between `auto` and `panel`; Settings → Display &
Brightness → Output sets `auto`, `panel` or `hdmi`. The timer picks the change
up within two seconds.

Switching *to* HDMI is debounced (two samples) because a monitor pulses HPD
while it powers up, and the panel is dark on the other side of the switch.
Returning to the panel is immediate. A failed HDMI start leaves the panel on
and blocks another HDMI attempt for 60 seconds, so a monitor that is present
but cannot be driven does not restart the session every tick.

## Generated kmscon config

kmscon reads its configuration once at startup and has no runtime API. Every
value the Settings TUI can change is rendered into
`/run/cpz-kmscon/kmscon.conf` by `cpz-kmscon-config`; the static half is
`/etc/kmscon/kmscon.conf`.

| Setting | kmscon option |
| --- | --- |
| `font_panel=6x12` | `font-size=12` |
| `font_panel=8x16` | `font-size=16` |
| `screen_timeout=5/10/30` | `dpms-timeout=300/600/1800` (0 = never) |
| `keyboard_layout_active` | `xkb-layout=...` |
| `theme` | `palette=custom` + the theme's 16 colours, background and foreground |

`font_hdmi` is unused on this branch: `multi-monitor=scaled` keeps the panel
grid and scales the font on HDMI, so there is no separate HDMI cell size to
pin. `cpz-kmscon-config` prints `changed` or `same`; `cpz-kmscon-output`
restarts `kmsconvt@tty1` only when the rendered file differs or the output
decision changes.

`term=xterm-256color` is deliberate: kmscon does not ship a terminfo entry for
`TERM=kmscon`, and tmux refuses to attach to an unknown terminal. libtsm is
xterm-compatible, so the ncurses entry from `ncurses-base` is the safe value.

## Themes

`/etc/cpz/themes` ships ten themes. Eight are terminal-first palettes ported
from the macOS Terminal.app profiles and Windows Terminal's Campbell default;
`Mono` and `Light High Contrast` stay as accessibility options.

| Theme | Mode | Source |
| --- | --- | --- |
| Campbell (default) | dark | Windows Terminal |
| Homebrew | dark | macOS Terminal |
| Ocean | dark | macOS Terminal |
| Red Sands | dark | macOS Terminal |
| Terminal Basic | light | macOS Terminal |
| Man Page | light | macOS Terminal |
| Novel | light | macOS Terminal |
| PaperColor Light | light | PaperColor |
| Mono | dark | CPZ |
| Light High Contrast | light | CPZ |

Each theme is a `.conf` (tmux styles plus `# palette 0..15`) and a matching
`.palette`. The terminal-first palettes were tuned where necessary so every
ANSI colour keeps at least 4.5:1 contrast against the theme background.

## Restart semantics

A restart replaces the kmscon process and the login shell inside it. tmux is
started detached (`tmux start-server` + `new-session -d`) and re-attached by
the next login shell, so tabs, pane working directories and running programs
survive. Only a foreground program outside tmux would be lost.

kmscon runs its child on a pty, so `tty` there is `/dev/pts/N`, not
`/dev/tty1`. `cpz-login` records that pty in
`/run/cpz-kmscon/session.tty`, and `cpz-session.sh` attaches tmux only when the
current tty matches it. SSH sessions and the tty2/tty3 recovery logins are
left alone.

## Files

```text
/usr/bin/kmscon
/etc/kmscon/kmscon.conf                     # static template
/usr/local/bin/cpz-kmscon                   # unit ExecStart
/usr/local/bin/cpz-kmscon-config            # renders /run/cpz-kmscon/kmscon.conf
/usr/local/bin/cpz-kmscon-output            # output reconciler
/usr/local/bin/cpz-login                    # uid 1000 autologin + pty marker
/etc/systemd/system/kmsconvt@tty1.service.d/10-cpz.conf
/etc/systemd/system/cpz-kmscon-output.service
/etc/systemd/system/cpz-kmscon-output.timer
/etc/udev/rules.d/99-cpz-kmscon-output.rules
/etc/systemd/system-sleep/cpz-kmscon
/etc/profile.d/cpz-session.sh
/etc/tmux.conf
```

Enabled: `kmsconvt@tty1`, `getty@tty2`, `getty@tty3`,
`cpz-kmscon-output.timer`, `cpz-conn-status.timer`, `cpz-session-save.timer`,
`cardputerzero-keymap.service`, `cpz-keyboard-layout.path`,
`cpz-bt-agent.service`, `bluetooth.service`, `NetworkManager.service`,
`rpi-preseed.service`.

Masked/disabled: `getty@tty1.service` (kmscon owns tty1), `userconfig.service`,
`NetworkManager-wait-online.service`, `apt-daily.timer`,
`apt-daily-upgrade.timer`, `man-db.timer`, `unattended-upgrade.service`.

## Debug image

```sh
cp config.debug.example config
sudo ./build.sh
# or:
./build-docker.sh -c config.debug.example
```

The debug image removes the splash, `quiet` and `loglevel=3`, keeps
`fbcon=map:10`, adds `console=serial0,115200 console=tty1 loglevel=8`, masks
`kmsconvt@tty1` and enables `getty@tty1`/`tty2`/`tty3`. If it shows nothing,
the failure is before kmscon.

## Known limitations

- **The internal TCA8418 keymap is not applied inside kmscon.** kmscon uses
  libxkbcommon, not the VT keymap, so `loadkeys` cannot reach it. The selected
  `xkb-layout` works for external keyboards and `Alt+Space` switches it (with
  a session restart), but the CPZ Sym/Fn overlay needs an XKB keymap port.
  tty2/tty3 keep the fbcon keymap.
- **Screen timeout is DPMS, not blank-only.** kmscon's `dpms-timeout` powers
  the output down. A monitor that renegotiates on wake may therefore change
  the mode; pin `CPZ_HDMI_VIDEO` (`video=HDMI-A-1:1920x1080@60`) if that
  happens. Set `screen_timeout=0` to disable it.
- **Theme changes restart the session** to rebuild the palette (about 1–2 s,
  tmux reattaches).
- **kmscon has no per-connector control.** Forced `panel` mode leaves HDMI
  mirroring the same session; it is a recovery escape, not a second console.
- kmscon is pinned from `trixie-backports`; keep `KMSCON_VERSION` in
  `stage3/00-kmscon/00-run.sh` in step with the image.

## Hardware checks

```sh
# boot to the panel, then plug HDMI: session moves, panel backlight goes dark
sudo cpz-kmscon-output --status
journalctl -t cpz-kmscon-output -b
# unplug: panel returns immediately
# Ctrl+Alt+F2 / Ctrl+Alt+F3: fbcon recovery logins
# Alt+D: panel comes back while HDMI stays attached
# suspend/resume: session and panel state are re-applied
sudo evtest                 # verify Fn key codes
free -m
systemd-analyze
journalctl -u kmsconvt@tty1 -b
```

If kmscon cannot drive the panel reliably, return to the fbcon branch and do
not build the rest of the CPZ UI on an unproven console layer.
