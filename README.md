# cpz-arch

A minimal Arch Linux ARM image for the M5Stack **Cardputer Zero** (CM0). It boots
into a terminal-first shell: one DRM owner, a fast libtsm terminal, tmux, and a
small set of TUI applications. There is no compositor, no desktop environment,
and no SDL/Mesa/Cairo/Pango in the base image.

The design is deliberately close to the hardware: 320×170 panel, 512 MB RAM,
a matrix keyboard and a battery. Text is the product, not a fallback.

## What boots

```text
firmware splash
  → kernel (no initramfs)
  → systemd
      ├─ cpz-shell.service     registry, provider broker, tmux panel
      ├─ cpz-tmux.service      tmux server, /run/user/1000
      │    └─ Home: cpz-launcher
      │    └─ app windows: shell, vim, nnn, htop, settings, battery…
      ├─ cpz-session.service   the only DRM owner
      │    └─ cpz-term         unprivileged renderer + input + pty → tmux attach
      └─ providers             battery, clock, network, bluetooth, volume
```

`cpz-session` selects the panel or HDMI, sets the mode, creates two dumb
buffers and passes the DRM fd plus buffer metadata to `cpz-term`. The terminal
runs as `cpz`, renders into the buffers, page-flips and reads evdev through
xkbcommon. A graphical application, if installed, can temporarily take over
DRM; tmux survives and the terminal is restarted afterwards.

## Shell and applications

The shell is the showcase, not a framework every app reimplements:

- **tmux** is the window manager and the persistence layer.
- **`cpz-shell`** scans app manifests, accepts typed status widgets from
  providers, writes `/run/cpz/ui.state`, and updates the tmux panel only when
  something changes.
- **`cpz-launcher`** is the Home window: a filterable list of registered apps.
  It reads the state file; it does not talk to the shell socket.
- **`cpz-help`** is a normal app and the only place for shortcuts and
  instructions.
- **Settings, Battery, Network, Bluetooth and Sound are apps.** They register
  with a manifest and may run a `--provider` mode that publishes status widgets.
- The shell contains no application names.

There are no permanent hint bars. The user knows the keys; Help has the list.

## Protocol

Everything is line-oriented `key=value`. There is no JSON parser in the image.

Manifest (`/usr/share/cpz/apps/<id>.app`):

```ini
id=battery
name=Battery
desc=Charge, voltage, health
exec=/usr/local/bin/cpz-battery
type=tui
icon=battery
category=System
order=310
provider=1
```

Provider messages (`/run/cpz/ui.sock`), values percent-encoded:

```text
op=hello&app=battery
op=clear&app=battery
op=widget&app=battery&id=battery&kind=battery&level=87&charging=0&order=100&priority=90
op=notify&app=battery&level=1&text=Battery%2020%25
```

State file (`/run/cpz/ui.state`):

```text
app id=terminal name=Terminal desc=Shell%2C%20tmux%2C%20ssh type=tui icon=terminal category=System order=100 exec=/bin/bash exec=-l
status app=battery id=battery kind=battery level=87 charging=0 order=100 priority=90
notify level=1 text=Battery%2020%25
end
```

Session control (`/run/cpz/session.sock`):

```text
status
output auto|panel|hdmi
restart-term
gui /absolute/command
poweroff|reboot
```

`cpz-ctl` is the client: `cpz-ctl status`, `cpz-ctl output panel`,
`cpz-ctl restart-term`.

## Icons

Icons are real raster images, not font glyphs. `src/make-icons.py` writes
`/usr/share/cpz/icons/<name>.rgba` (8-byte header + RGBA) and `icons.map`
(`PUA codepoint → name`). The launcher prints the PUA codepoint; `cpz-term`
draws the image into the cell. Tmux sees an ordinary character, so redraw and
scrolling do not lose the icon. If an icon is missing, the gutter is blank.

## Build

Docker Desktop on Apple Silicon runs the `linux/arm64` builder natively.

```sh
make builder
make image
make verify
```

Artifacts land in `out/`:

| Artifact | Size |
| --- | --- |
| `out/cpz-arch-0.1.0-cm0.img` | 897 MiB |
| `out/cpz-arch-0.1.0-cm0.img.zst` | 213 MiB |
| root filesystem content | ~771 MiB |

Flash the image with Raspberry Pi Imager, balenaEtcher or `dd`. The device
boots into Home; SSH is `cpz` / `cpz` and serial recovery is
`console=ttyS0,115200`.

## Using it

| Key | Action |
| --- | --- |
| `Alt+Space` | Home / launcher |
| `Alt+T` | New Home window |
| `Alt+W` | Close current window |
| `Alt+1…9` | Switch window |
| `Alt+Tab` | Next window |
| `Alt+H` / `?` | Help |
| `Alt+P` | Settings |
| `Ctrl+Shift+Q` | Restart the terminal session |

Inside Home: type to filter, Up/Down to move, Enter to launch, Esc to clear.
TUI apps open in a new tmux window. The full list is in `cpz-help`.

## Configuration

`config.sh` is the single build switchboard.

| Variable | Meaning |
| --- | --- |
| `BOARD` | `v5` or `v3` |
| `ENABLE_HDMI` | `1` enables vc4/HDMI; `0` panel only |
| `ENABLE_SSH` | installs `openssh` and wired DHCP |
| `USER_NAME`, `USER_PASS` | login account, default `cpz` / `cpz` |
| `ROOT_MB`, `BOOT_MB` | partition sizes |
| `XKB_LAYOUT`, `XKB_OPTIONS` | keyboard layout defaults |
| `EXTRA_PACKAGES`, `PRUNE_PACKAGES` | package additions/removals |

User settings live in `~/.config/cpz/settings.conf`.

## Diagnostics

```sh
cpz-session --probe          # connector/card selection
cpz-term --probe             # inherited DRM/buffer environment
cpz-term --headless /tmp/x.ppm --cols 53 --rows 14
cpz-shell --dump             # write/print the UI state
cpz-ctl status
journalctl -b -u cpz-session
journalctl -b -u cpz-shell
```

## Status and risks

The image builds and passes `make verify`, including every component selftest,
manifest/unit checks, the no-SDL/Mesa invariant, and the synthetic output
selection tests.

Hardware acceptance is still pending because no device was available during
this rewrite. The open risks are:

1. **DRM dumb buffers and page flip on the SPI panel and vc4 HDMI.** The
   terminal was designed around the inherited-fd model; verify it on the real
   panel first.
2. **Input layout on the Cardputer keyboard.** `cpz-term` uses xkbcommon with
   `us,ua` by default. The vendor Fn/Sym layer may need a compiled CPZ keymap.
3. **1080p memory/CPU.** Damage rendering and two 8 MB buffers should fit, but
   measure HDMI text and scrolling.
4. **Audio/Bluetooth management** is intentionally small: Sound opens
   `alsamixer`; Bluetooth shows adapters. Connect/pair flows are terminal work.
5. **Graphical handover** is implemented as stop-term → run-app → restart-term;
   it has not been exercised with a real GUI app.

## Layout

```text
config.sh                 build decisions
docker/Dockerfile         arm64 builder
scripts/10-rootfs.sh      pacman rootfs, no initramfs
scripts/20-device.sh      vendor modules and overlays
scripts/25-apps.sh        build and install the TUI stack
scripts/30-configure.sh   identity, boot files, units, trim
scripts/40-image.sh       FAT32 + ext4 + MBR, no loop devices
scripts/50-verify.sh      structural and functional checks
src/cpz-session.c         DRM broker and supervisor
src/term/cpz-term.c       DRM/libtsm/FreeType/xkb/evdev terminal
src/cpz-shell.c           registry, provider broker, tmux panel
src/cpz-launcher.c        Home TUI
src/cpz-help.c            Help app
src/cpz-settings.c        Settings app
src/cpz-ctl.c             session control client
src/cpz-battery.c         battery app + provider
src/cpz-clock.c           clock provider
src/cpz-network.c         network app + provider
src/cpz-bluetooth.c       bluetooth app + provider
src/cpz-volume.c          sound app + provider
src/cpz-query.h           key=value / percent-encoding helpers
src/cpz-provider.h        provider-side socket client
src/manifests/*.app       app manifests
src/icons/*.rgba          real image icons + icons.map
src/tmux.conf             terminal-first tmux configuration
src/cpz-tmux-start.sh     tmux server + Home window
docs/ARCHITECTURE.md      boot, DRM ownership, privileges, recovery
docs/PROTOCOL.md          manifests, state file, provider and session protocols
docs/UI.md                minimal TUI design rules
docs/TERMINAL.md          renderer, input, damage, tests
```
