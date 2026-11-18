# Graphical applications

CPZ runs a graphics session, not a terminal session with a graphics mode
switch. The session is `cage` (Wayland kiosk) + `foot` (fullscreen terminal) +
tmux. See [CPZ-CAGE.md](CPZ-CAGE.md) for the boot path, output policy,
recovery and limitations.

## How an app becomes graphical

There is no registry and no detection:

- a terminal program runs in the tmux pane;
- a Wayland program connects to `WAYLAND_DISPLAY` and opens a window;
- an X11 program connects through Xwayland (`DISPLAY`) and opens a window;
- cage places that window on top of foot and gives it all input;
- closing the window returns to the same tmux tab and pane.

The application itself decides. `chocolate-doom` works through SDL2 (Wayland
or Xwayland); `mpv` works because it opens a Wayland/X11 video window; a
TUI game works because it stays in tmux. No `ldd` heuristic, `.desktop`
category or per-app list is involved.

Search and Settings launch applications through `cpz-run`, which applies the
`WAYLAND_DISPLAY` / `DISPLAY` / `XAUTHORITY` values published by the foot
client. The tmux server is older than cage, so this small wrapper is what lets
a pane reach the compositor. A direct shell command works for Wayland because
the tmux service also exports the stable `WAYLAND_DISPLAY`; use `cpz-run` for
X11 commands that need `XAUTHORITY`.

## Doom

```sh
sudo apt-get install -y --no-install-recommends chocolate-doom freedoom
```

Launch `chocolate-doom` from Applications or Search. It does not need a special
mode; the free IWAD is `/usr/share/games/doom/freedoom1.wad`. Pass
`-iwad /usr/share/games/doom/freedoom1.wad` if the default WAD search does not
find it.

## What is not supported

- Multiple visible windows and window cycling. cage shows one application on
  top of the terminal. Use `sway` if a desktop-style session is required.
- Direct KMS/GBM clients that want DRM master themselves; cage owns it.
  Wayland, Xwayland and SDL2 Wayland clients are the supported path.
- A per-application launcher or graphics registry. None is needed.
