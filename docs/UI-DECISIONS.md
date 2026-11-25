# UI implementation decisions

Status: agreed on the `ui/qualities` branch. These decisions sit under
[UI-QUALITIES.md](UI-QUALITIES.md) and may change with evidence from the
device.

## 1. Session entry point

**Decision: platform-owned `cpz-ui@.service` template with `PAMName=login`.**

Cage 0.3.1 ships only `/usr/bin/cage`; it has no systemd unit. The platform
ships the template, the UI package provides `/usr/lib/cpz/session` and enables
`cpz-ui@tty1.service`:

```ini
[Service]
PAMName=login
User=cpz
TTYPath=/dev/tty1
StandardInput=tty
StandardOutput=tty
ExecStart=/usr/lib/cpz/session
```

- PAM/logind creates the seat and the user session, so the UI gets DRM,
  evdev and audio through the normal login path.
- systemd owns restart, watchdog and logging.
- The unit is inert until the UI package installs the entry point; the base
  image does not enable it.
- Recovery stays on serial and SSH.

## 2. Session stack

**Decision: `cage` + `foot` + `tmux`.**

- `cage` is the kiosk compositor: one fullscreen client, Xwayland for X11
  programs.
- `foot` renders through `wl_shm`, so the RGB565 SPI panel needs no GPU
  renderer.
- `tmux` supplies tabs, panes, the status row and persistence across a
  compositor restart. There is exactly one session (`main`), `C-b` is
  unbound and `C-a` is the advanced prefix fallback; session commands are
  unbound, and daily window/pane control uses direct Alt bindings.
- No system bar, tray or layer-shell panel. Status and notifications live
  inside tmux.
- Cage has no layer-shell; overlay launchers such as `fuzzel`, `wofi` or
  `bemenu` are not an option for this stack.
- Output selection is dynamic: `cpz-output.service` is triggered by the HDMI
  connector udev event, compares the desired output with `/run/cpz/output`
  and restarts `cpz-ui@tty1.service` only when the output changed. tmux is a
  separate service, so tabs and applications survive the switch. A one-shot
  10-second post-boot timer catches connector events that happen while the
  session is still writing its state.

## 3. Application model

**Decision: a normal pacman package plus one or more freedesktop Desktop
Entries.**

- The package is the install/remove unit; each `.desktop` entry is an app.
- The UI reads `/usr/share/applications`, `~/.local/share/applications` and
  `XDG_DATA_DIRS`; there is no custom registry or manifest.
- Standard fields carry the high-level information: `Name`, `Comment`,
  `Exec`, `Terminal`, `Categories`, `Keywords`, `Icon`, `Actions`,
  `StartupWMClass`, `DBusActivatable`, `Name[lang]`.
- `Terminal=true` means "open in a tmux tab"; `Terminal=false` means a
  graphical client.
- Launch with existing tools (`j4-dmenu-desktop`, `dex`, `gio launch`); never
  evaluate `Exec` through a shell; handle the field codes correctly.
- Minimal `X-CPZ-*` keys are allowed only where the standard has no
  equivalent, for tab/single-instance semantics.
- Validate with `desktop-file-validate` and `update-desktop-database`.
- The package depends on `cpz-ui` through normal pacman dependencies.

## 4. Launcher

**Recommendation: `j4-dmenu-desktop` + `fzf` inside a tmux popup.**

```sh
tmux display-popup -E \
  j4-dmenu-desktop --dmenu="fzf --no-sort --prompt='> '" \
                   --term=/usr/lib/cpz/term-launch
```

- `j4-dmenu-desktop` is in the Arch `extra` repository and reads `.desktop`
  files from the XDG directories.
- `fzf` provides the TUI selection; it is in `extra`.
- `term-launch` is a small adapter that receives `-e <command>` and runs
  `tmux new-window <command>` so terminal apps stay in the session.
- The launcher is compositor-independent; it works on the panel and HDMI.
- Validate the argument passing, popup size on 320×170 and usage history on
  hardware.

Alternatives and why they are not the default:

- `fuzzel`, `wofi`, `bemenu`: need layer-shell; cage does not provide it.
- `rofi`: layer-shell on Wayland; an Xwayland fallback works but is not
  native.
- `dex`/`gio launch`: execute a chosen entry, but are not a menu. They remain
  useful for scripts.
- A custom launcher is unnecessary unless `j4-dmenu-desktop` fails the
  argument or tab test.

**Pending replacement (design, not implemented):** the Apps store and the Home
screen replace the `fzf` picker for daily use. `Alt+O` will open
`cpz-app apps`; a new tab will run `cpz-app home` instead of a bare shell.
`j4-dmenu-desktop`, `fzf` and `cpz-launcher` stay until the store passes the
hardware checklist. See [APP-PLATFORM.md](APP-PLATFORM.md) and
[TUI-CONTRACT.md](TUI-CONTRACT.md).

## 5. Status

**Decision: one tmux status row, event-driven, with a cache file.**

- The status helper writes `/run/cpz/status` (`key=value`) and calls
  `tmux set-option` only when a value changes.
- `status-interval 0`; there is no periodic status command.
- Sources: battery (`/sys` power supply and udev), network
  (`systemd-networkd`/`iwd` events), audio (ALSA/WirePlumber), keyboard layout
  (XKB event), clock once per minute.
- No separate `waybar` or other panel; cage does not support layer-shell and
  the UI is intentionally minimal.

## 6. Notifications

**Decision: `tmux display-message` for system notifications; no custom
protocol.**

- Battery, network, session and error messages use the standard tmux message
  line.
- Applications can set their terminal title (`OSC 0/2`) or use a standard
  D-Bus notification if a daemon is present.
- No custom notification socket or daemon in the base.
- A desktop notification daemon (`mako`, `fnott`, `dunst`) is optional later;
  the layer-shell ones need a different compositor, and `dunst` is X11.

## 7. Release policy

**Decision: stable only for now; the current release and one previous release
stay installable.**

- Publish with `ui-vX.Y.Z`; CI signs and updates the `ui-stable` release.
- `beta` remains configured but unused until a beta programme is introduced.
- Keep the current and previous UI core release, plus the application
  versions tested with them.
- Roll back with `pacman -U` from the signed repository or the local package
  cache.
- Stable needs a hardware sign-off: boot, panel/HDMI, input, audio, network
  and the rollback drill.
- Retention automation and the exact soak period are defined after the first
  real UI release.

## 8. Implementation status

- Launcher: implemented as `cpz-launcher` + `cpz-term-launch`.
- Status: implemented as `cpz-status` with `/run/cpz/status` and the tmux row.
- UI package: `ui/cpz-ui` builds with makepkg in CI and is published to the
  `ui-stable` release.
- Platform contract: `docs/PLATFORM-CONTRACT.md`.
- App contract: `docs/APP-CONTRACT.md`.
- TUI contract: `docs/TUI-CONTRACT.md` (proposed).
- Application platform: `docs/APP-PLATFORM.md` (proposed; separate
  `cpzos-apps` repository, catalog, store, Home, Settings).
- Panel/HDMI and budget validation: pending on hardware.
- Notification daemon, theme tokens and locale catalogs: later.
