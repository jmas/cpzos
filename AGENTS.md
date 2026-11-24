# Agent rules — cpz-arch

Read `README.md` and `docs/` before changing the system. These rules are part of
the architecture, not suggestions. If a change needs to break one, stop and ask
the product owner.

## Product and UI

1. **One unified UI.** Applications do not draw their own chrome, status bar or
   menu. They use the shared TUI primitives and the shell protocol.
2. **Register, do not hardcode.** An app appears in Home through a `*.app`
   manifest. `cpz-shell` and `cpz-launcher` contain no application names.
3. **The shell owns presentation; apps own data.** A provider publishes typed
   widgets. It never draws the panel.
4. **Minimalism.** No permanent footer, hint bar or key legend. All shortcuts
   and instructions live in `cpz-help`. Prefer useful content over chrome.
5. **Real icons only.** Icons are raster images, not font glyphs or emoji. If
   an icon is missing, leave the gutter blank; never substitute a symbol.
6. **Keyboard first.** No primary flow may require a mouse. Optional mouse
   support must not change the keyboard model.
7. **Design tokens only.** Colours, fonts, spacing and borders come from the
   shared theme. No local palettes or ad-hoc layout systems.

## Architecture

8. **One DRM owner.** `cpz-session` owns the card, mode, buffers and master.
   `cpz-term` is unprivileged and receives the DRM fd. Do not open DRM from a
   TUI app.
9. **No compositor.** Do not reintroduce Wayland, X11, SDL, Mesa, Cairo or
   Pango into the base image. The terminal renders into dumb buffers.
10. **tmux persists.** The tmux server and `cpz-shell` are independent of the
    terminal. A terminal restart or output switch must not lose tabs.
11. **Settings, Battery, Network, Bluetooth and Sound are apps.** Do not embed
    them in the shell or make the shell depend on their names.
12. **Query string, not JSON.** Manifests and runtime protocols are
    line-oriented `key=value`; values are percent-encoded. There is no JSON
    parser in the image.
13. **No backward compatibility.** Old protocols, manifests and UI are deleted,
    not wrapped in shims. Git history is the archive.
14. **Efficiency is a requirement.** Watch boot time, RAM, CPU, process count
    and wakeups. No 5-second shell polls. Use events or compiled daemons.

## Process

15. **Ask when unsure.** Ask about product behaviour and the user's experience,
    not only about implementation details.
16. **Serious changes are loud.** If a change cuts or materially changes system
    properties (graphics, persistence, input, compatibility, security, size),
    tell the owner and record the trade-off in the plan/docs before shipping.
17. **Security.** Use argv arrays, not a shell, for launches. Apps run as
    `cpz`; root belongs to the session and narrow helpers only.
18. **Verify, then commit.** `make verify` must pass. Update docs and tests with
    every architectural change. Hardware-only gaps must be stated explicitly.

## Current map

- `src/cpz-session.c` — DRM broker/supervisor.
- `src/term/cpz-term.c` — DRM/libtsm/FreeType/xkb/evdev terminal.
- `src/cpz-shell.c` — manifest registry, provider broker, tmux panel.
- `src/cpz-launcher.c` — Home TUI.
- `src/cpz-help.c` — the only place for shortcuts.
- `src/cpz-settings.c` — Settings app.
- `src/cpz-battery.c`, `cpz-clock.c`, `cpz-network.c`, `cpz-bluetooth.c`,
  `cpz-volume.c` — apps + providers.
- `src/manifests/*.app` — app registration.
- `src/icons/*.rgba` + `icons.map` — real icons.
- `src/cpz-query.h` — key=value/percent-encoding helpers.
- `docs/` — architecture, protocol, UI and terminal rules.
