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

Crispy Doom uses the same SDL2 path. On HDMI it still probes the V3D render
node while SDL initialises, and the old **cma-64** reservation was too small
for Mesa's 16 MiB binner next to cage's pixman buffers. The allocation then
failed with `ENOMEM`, Crispy did not check it and crashed with `SIGSEGV`
(`si_addr=NULL`) right after `I_SDL_PrecacheSounds`. The image now reserves
**128 MiB** of CMA (`dtoverlay=vc4-kms-v3d,cma-128`), which leaves room for
both. If a window still stays black with an older SDL2, set
`force_software_renderer 1` in `crispy-doom.cfg` (Crispy's own setting); it
keeps the game on the `wl_shm` path the compositor can present.

## Why accelerated rendering breaks on HDMI

The panel and HDMI behave differently for one concrete reason:

- The panel DRM card has **no render node**, so SDL cannot create an
  accelerated (EGL/GLX) renderer there. It falls back to software, presents via
  `wl_shm`, and cage's pixman renderer composites it normally.
- HDMI uses the vc4 card, which **has** a render node. SDL then picks the
  accelerated renderer, and the client or Xwayland allocates **dmabuf**
  buffers. cage runs with `WLR_RENDERER=pixman`, which cannot import dmabuf, so
  the application surface never reaches the screen. The hardware cursor plane
  still works, which is exactly the “screen flickers with only a cursor”
  symptom.
- Even the probe needs contiguous memory: Mesa/V3D reserves a 16 MiB binner
  plus render buffers. With the old 64 MiB CMA reservation that allocation
  failed with `ENOMEM` (visible in `dmesg` as
  `vc4-drm: Failed to allocate from GEM DMA helper`), and an unchecked failure
  in the client looks like an instant crash. The image reserves 128 MiB.

The session therefore exports these defaults for every pane and every
`cpz-run` launch:

```text
SDL_VIDEODRIVER=wayland
SDL_RENDER_DRIVER=software
```

They are set in `cpz-tmux.service`, in `cpz-tmux`/`cpz-tmux-start` (the tmux
global environment for new panes) and in `cpz-run`. An explicit value from the
caller wins, so a future accelerated path can be tested per application. Do not
remove them while `cpz-cage-output` keeps `renderer=pixman`: the panel needs
pixman, and mixing an accelerated client with it is what produces the
cursor-only output on HDMI.

An application that uses raw OpenGL (not an SDL renderer) has no software
fallback here and must run on the panel or be replaced. OpenTTD is the known
example: use `-v sdl` (the software SDL video driver), not `sdl-opengl`.

## What is not supported

- Multiple visible windows and window cycling. cage shows one application on
  top of the terminal. Use `sway` if a desktop-style session is required.
- Direct KMS/GBM clients that want DRM master themselves; cage owns it.
  Wayland, Xwayland and SDL2 Wayland clients are the supported path.
- A per-application launcher or graphics registry. None is needed.
