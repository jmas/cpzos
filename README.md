# cpz-arch

A minimal Arch Linux ARM image for the M5Stack **Cardputer Zero** (CM0): the
same hardware support as the main CPZ image, one appliance session rendered by
SDL2/KMSDRM on the internal panel or on HDMI, and a small launcher for console,
SDL2 and fullscreen applications.

No compositor and no desktop environment. The graphics stack is **SDL2 +
Mesa** (vc4 for HDMI, `kms_swrast` for the SPI panel) with a single session
supervisor and a launcher. There is no alternate console backend in the image.

`cpz-session` owns process lifecycle and output selection. It does not draw.
`cpz-menud` owns the menu tree and status widgets; installed apps contribute
root-owned JSON manifests, live providers register typed widgets over a Unix
socket, and `cpz-ui` is a thin renderer with an explicit state machine.
`cpz-term` is the terminal application, and every other app is a normal SDL2
process started by the session. Only one process owns the display at a time;
switching outputs is a process restart, not a live DRM modeset.

Two hardware bring-up details remain from the original image:

1. **SPI chip select 0 was taken by `spidev@0`.** `dtparam=spi=on` creates
   `spidev@0`/`spidev@1`; the vendor overlay puts the ST7789V panel at `reg =
   <0>`, and the SPI core keeps the first device on a chip select, so the panel
   never probed and no DRM card existed. `src/cpz-spi.dts` disables both
   spidev children by node name (the vendor overlay's `&spidev0` symbol does
   not exist in this device tree).
2. **The panel driver has no SPI modalias.** udev never autoloads
   `panel-mipi-dbi-m`, so `/etc/modules-load.d/cpz-panel.conf` loads it, and a
   `softdep vc4 pre: panel-mipi-dbi-m` keeps it ahead of vc4 so the panel
   probes first.

```text
firmware -> start.elf -> kernel8.img -> ext4 root -> cpz-session (systemd)
                                                        |
                                      +-----------------+------------------+
                                      |                                    |
                                  cpz-ui (launcher)                    app (fullscreen)
                                  SDL2 + SDL_ttf                      SDL2 / cpz-term
                                      |                                    |
                              SDL2 KMSDRM on the active card: panel (kms_swrast) or HDMI (vc4)
```

## Status

| Artifact | Size |
| --- | --- |
| `out/cpz-arch-0.1.0-cm0.img` | 961 MiB |
| `out/cpz-arch-0.1.0-cm0.img.zst` | 241 MiB |
| root filesystem content | 826 MiB |
| build time on an Apple Silicon Mac | ~3–4 min |

**The graphics stack has not been booted on the device yet.** The build and the
`cpz-sdlprobe`/`cpz-term` selftests pass in the target chroot, but the two
hardware questions remain open:

1. does SDL2/KMSDRM + Mesa `kms_swrast` drive the SPI panel on this kernel, and
2. does `sdl2-compat` pass `SDL_KMSDRM_DEVICE_INDEX` through to the correct
   `/dev/dri/cardN`.

The acceptance checklist is in `docs/GRAPHICS.md`.

## Quick start

Requires Docker (native `linux/arm64`, which Docker Desktop provides on Apple
Silicon). No host root, no loop devices, no privileged container.

```sh
make builder   # Arch Linux ARM + pacman tooling (one-time)
make image     # rootfs -> vendor modules -> graphics stack -> disk image
make verify    # structural and functional checks
```

Flash `out/cpz-arch-0.1.0-cm0.img` (or the `.img.zst`) with Raspberry Pi Imager,
balenaEtcher or `dd`. The device boots into `cpz-ui`; use the Terminal app or
SSH (`cpz` / `cpz`) for a shell. `sudo` uses the same password, root is locked.

## Graphics: SDL2/KMSDRM

One session, one active output, one display owner. `cpz-session` does not draw:
it finds the connected card, exports the SDL environment, starts `cpz-ui`, and
restarts it when an app exits or crashes. The panel shows a white triangle from
firmware start: `cpz-splash.bin` is a Splash Asm dump that `start.elf` draws
before Linux runs. The first `cpz-ui` of a boot is started with `--splash` and
repeats the same picture while it initialises; restarts after an app, a crash
or an output switch go straight to the menu. `cpz-ui` starts apps through
`/run/cpz/session.sock`; the supervisor stops the launcher before the app opens
DRM. A crash therefore cannot leave the display "handed over" forever.

| Property | Panel | HDMI |
| --- | --- | --- |
| DRM card | connector type `SPI` | connector type `HDMIA` |
| Mesa driver | `kms_swrast` (software, dumb buffers) | `vc4` (hardware GLES) |
| Mode | 320x170 @ 30 Hz | preferred mode from EDID, capped at 1080p |
| App rendering | SDL software renderer | SDL/GLES, page flip |
| Switching | process restart on the panel card | process restart on the vc4 card |

The important details:

- **No live DRM handover.** Output changes stop the current child and start a
  fresh one on the new card. The panel's init sequence is run by a fresh SDL
  open, not by a plane commit on an old CRTC.
- **HDMI wins when connected.** `cpz-session --output panel|hdmi` or the
  Settings screen forces an output. The default is auto.
- **Hotplug is udev-driven.** The UI moves immediately. A running app is not
  moved mid-frame; the switch is deferred until it exits, because SDL2/KMSDRM
  binds one card for the lifetime of the window.
- **The panel is software-rendered.** It has no render node, so Mesa uses
  `kms_swrast` and the CPU writes into dumb buffers. `cpz-ui` and `cpz-term`
  therefore ask SDL for its software renderer when `CPZ_OUTPUT=panel`; the
  accelerated path would load Mesa's Gallium/LLVM stack and JIT a blit shader
  for a 320x170 menu. 320x170 is small enough for a launcher and a terminal;
  full-screen GLES on the panel is not a target.
- **HDMI is hardware-rendered.** `vc4` provides GLES2 for SDL2 apps and the
  compositor-free launcher.
- **Unicode is real.** `cpz-ui` renders with Cairo + Pango: shaped text,
  automatic font fallback and anti-aliased vector shapes. Noto Sans and the
  script fonts are bundled (OFL); the terminal keeps DejaVu Sans Mono for
  fixed cell widths.

The session environment is visible to every child:

```sh
SDL_VIDEODRIVER=kmsdrm
SDL_KMSDRM_DEVICE_INDEX=<index of the selected card>
CPZ_OUTPUT=panel|hdmi
CPZ_DRM_CARD=/dev/dri/cardN
XKB_DEFAULT_LAYOUT=us,ua
```

`CPZ_RENDERER=software|accelerated` overrides the renderer choice for one run;
the default follows `CPZ_OUTPUT` (software on the panel, accelerated on HDMI).

Diagnostics:

```sh
cpz-session --probe        # which card/connector the supervisor would pick
cpz-sdlprobe --probe       # what SDL sees (driver, display, mode)
cpz-sdlprobe               # fullscreen colour bars + Cyrillic + FPS
cpz-sdlprobe --seconds 10  # same, auto-exit for a test rig
journalctl -b -u cpz-session
```

`cpz-session --probe` only reads sysfs and is safe over SSH.
`cpz-sdlprobe` needs DRM master, so start it from the launcher (which stops the
UI first) or stop `cpz-session` while testing over SSH; otherwise SDL will
report a busy card.

Console applications run inside `cpz-term`, not on the system console. It is a
pty running `bash -l` as the `cpz` user, with libtsm for VT emulation and a
real font for UTF-8. `vim`, `tmux`, `htop` and `mc` are expected to work.
Its current presentation is a known weak point; the symptom-by-symptom review
and the rework plan are in [`docs/TERMINAL.md`](docs/TERMINAL.md).

SDL2 applications are normal fullscreen processes. The launcher starts one at a
time; when it exits, the launcher comes back. There is no window manager and no
compositor, so apps cannot overlap or draw OSDs over each other. If that is
needed later, it is a separate compositor project, not a reason to bring back
the old DRM console.

What this stack does **not** do: windows, multiple simultaneous apps on one
screen, GLES on the SPI panel, GTK/Qt/X11/Wayland apps, or live output migration
of a running app.

## Applications

Start applications from `cpz-ui`. It asks the supervisor to stop the launcher
before the app opens the card; when the app exits, the launcher comes back.
There is no shell wrapper, no DRM hand-over helper and no compatibility shim.

The launcher is an iPod-style menu stack styled after the click-wheel iPod
nano (1G/2G): a silver 24 px status bar with the provider-supplied widgets, a
white full-bleed list with 28 px rows, an azure selection bar with a dark top
rim and a light bottom rim, and black chevrons. The title is left-aligned and
shares one text column with every row label; a 20 px app icon sits in a 24 px
gutter to its left, so rows with and without icons keep the same left edge. Icons are part
of the app bundle (`/usr/share/cpz/apps/<id>/icon.png`, referred to as
`icon.png` from that app's manifest), not built into the shell: the launcher
tints the PNG with the row colour and the vector table holds only status
glyphs and severity marks. The root screen is titled `Меню` and opens the
installed apps (Термінал, Тест екрана, Музика, Відео, Фото, Ігри,
Налаштування, Про пристрій) as real submenus. On the Cardputer Zero the bare
`Z`/`F`/`X`/`C` keys are the d-pad (`F`/`X` up/down, `Z` back, `C` open);
Enter/→ also opens and Esc/← goes back for external keyboards. The UI is laid
out on a fixed 320x170 canvas and scaled uniformly to the output, so HDMI keeps
the panel proportions and gets black letterbox bars instead of horizontal
stretching. The status bar never moves; only the list below it slides between
menus (180 ms ease-out). Launches show a full-screen `loading` page, shell
actions a `busy` page, blocking failures an `error` page with retry, and minor
messages a compact bottom toast. `info`, `confirm` and `choice` actions are
rendered by the shell, not by the app.

The menu and status model is implemented by `cpz-menud`. Installed apps drop a
root-owned `/usr/share/cpz/apps/<id>/app.json`; the daemon merges those manifests
with live provider registrations, validates and sorts the tree, and pushes an
atomic snapshot to the shell over `/run/cpz/menu.sock`. The launcher never reads
manifests itself and contains no application names. Battery, clock, network and
Bluetooth are ordinary system provider daemons on the same protocol; they supply
typed `battery`/`text`/`glyph`/`png` widgets and the shell owns the 12 px layout.
The battery widget follows the bq27xxx power supply (`bq27220-N`, not a fixed
`bq27220` path): `cpz-battery` discovers it, re-pushes `level`/`charging` once a
second when the reading changes, and drops the widget if the gauge disappears.
`cpz-battery --status` prints the discovered path and current reading.
Menu actions are `exec` (foreground app), `run` (background shell action, e.g.
`cpz-sessionctl output panel`), `info`, `choice`, or a submenu. The shell states
are `boot`, `menu`, `empty`, `degraded`, `loading`, `busy`, `progress`, `info`,
`error`, `confirm`, `choice`, `input` and `toast`. If `cpz-menud` is down the
shell keeps the last snapshot and falls back to a compiled-in emergency menu.
`cpz-menu list|status|snapshot|rescan|register` is the scriptable debugging CLI.
See [`docs/MENU-RFC.md`](docs/MENU-RFC.md) for the protocol and limits.

- **Console programs** run inside `cpz-term`: a pty, `bash -l` as `cpz`,
  libtsm and a real Unicode font. `vim`, `tmux`, `htop` and `mc` are expected to
  work.
- **SDL2 programs** run fullscreen, one at a time, using the environment the
  session exports.
- Interactive SSH shells get `SDL_VIDEODRIVER=kmsdrm` from
  `/etc/profile.d/00-sdl.sh`, but they cannot open the card while the session
  owns it.
- Applications that only speak `/dev/fb0` are not supported; they need an SDL2
  or DRM port.

## What is in the image

| Layer | Content |
| --- | --- |
| Boot | `start.elf`, `fixup.dat`, `bootcode.bin`, `kernel8.img`, `bcm2710-rpi-cm0.dtb`, `overlays/`, `cpz-splash.bin` |
| Kernel | `linux-rpi` 6.18.64-2-rpi, **no initramfs** |
| Board drivers | 15 out-of-tree modules: panel (`panel-mipi-dbi-m`, `st7789v_m5stack`), backlight PWM, keypad (`tca8418`), M5 IO expander, BQ27220, ES8389 audio, IMU, power-fail, gpio-forwarder |
| Userspace | `base`, `sudo`, `libdrm`, `libtsm`, systemd, bash, SDL2 (`sdl2-compat`), SDL2_ttf, Mesa (`vc4` + `kms_swrast`), libinput, libxkbcommon, Cairo, Pango, Noto Sans + script fonts (bundled), DejaVu fonts |
| Graphics | `cpz-session` (supervisor), `cpz-menud` (menu/status model), `cpz-ui` (launcher), `cpz-term` (terminal), `cpz-sdlprobe` (display test), `cpz-backlight`, `cpz-menu` (CLI) |
| Status providers | `cpz-battery`, `cpz-clock`, `cpz-network`, `cpz-bluetooth` (typed widgets over `/run/cpz/menu.sock`) |
| Session | `cpz-session.service` on `sysinit.target`, `cpz-ui` fullscreen, one active output; `cpz-menud.service` before it; no `getty` on the panel |

Boot configuration (`config.txt`):

```text
dtparam=i2c_arm=on  dtparam=i2s=on  dtparam=spi=on  dtparam=audio=off
dtparam=watchdog=on
dtoverlay=dwc2
dtoverlay=vc4-kms-v3d                  # HDMI + vc4 GLES
dtoverlay=cardputerzero-v5-overlay     # panel, keypad, IO expander, backlight
dtoverlay=bq27220_v5                   # battery gauge
dtoverlay=bmi270_bmm150_overlay        # IMU
gpu_mem=64
splash_screen=cpz-splash.bin           # early Splash Asm white triangle
```

`fbcon` is disabled (`fbcon=map:off`); the SDL session does not need a
framebuffer console. The session finds the connected connector through sysfs and asks SDL
to open that card, so card numbering (`card0`/`card1`) is never assumed. HDMI
is not forced off at boot; `cpz-session` chooses it when a monitor is connected
and the panel otherwise. Recovery is over serial (`console=ttyAMA0,115200`) or
SSH.

## Network and SSH

`ENABLE_SSH=1` (the default in this tree) installs `openssh` and brings up any
wired interface with DHCP through `systemd-networkd` + `systemd-resolved`. No
NetworkManager, no extra daemons.

```sh
ssh cpz@<ip>          # password: cpz
```

Find the address on the console with `ip -4 addr`, or read it from the boot
report on the SD card (`ip -4 addr` is included). The `.network` file matches
`en*` and `eth*`, so built-in ports and USB adapters (which appear as `enx…`)
are covered.

This is a development convenience: the account is `cpz/cpz` and there is no
firewall. Change the password, or set `ENABLE_SSH=0`, before the device lives
on a network you do not control.

## Boot speed decisions

1. **No initramfs.** Root is ext4 on SD; MMC and ext4 are built in. The
   `mkinitcpio` presets are deleted and the install hook removed.
2. **One small session process, started early.** `cpz-session.service` has
   `DefaultDependencies=no`, runs after `systemd-modules-load`/`systemd-udevd`
   and before `basic.target`. It waits for the first connected DRM output, then
   starts `cpz-ui` directly. It does not wait for `systemd-user-sessions` or the
   network. The session owns the panel backlight, so an HDMI boot turns the
   panel off instead of flashing it.
3. **Display modules are loaded in the right order, not by udev coldplug.**
   `gpio_forwarder` must exist before `spi_bcm2835`: the board overlay's
   `cs-gpios` references its GPIO chip, and without it
   `spi_register_controller()` returns `-EPROBE_DEFER` for several seconds.
   `i2c_bcm2835`, `spi_bcm2835`, `m5ioe1`, `pwm_bl_m5stack`, `tca8418` and
   `panel-mipi-dbi-m` are in the same early list. Moving these into the kernel
   is the next boot-time step; it removes the module-order dependency.
4. **`quiet loglevel=3 logo.nologo vt.global_cursor_default=0 audit=0`,
   `noatime`, no `/boot` mount, `pass=0`, `panic=10`, serial recovery
   console.**
5. **Volatile journal** (16 MiB in RAM).
6. **`machine-id` and `hwdb.bin` generated at image time.**
7. **Masked:** `systemd-timesyncd`, `systemd-binfmt`, getty on tty2-tty6.
8. **~170 packages, dev payload trimmed** (static libraries, locale sources,
   docs, extra bootloader variants).

Expect the panel DRM card at roughly 5.7 s (previous measurement), then
0.3–0.8 s for SDL and font initialization. **These numbers are not measured
yet.** The `systemd-analyze` "startup finished" time is larger and varies with
DHCP and `cpz-report` (10–16 s); those units are not on the path to the UI.
Firmware time (loading the 27 MiB kernel from SD) is not included in
`systemd-analyze`.

The launcher now logs the time from its own `main()` to the first presented
menu frame, one line per start:

```text
cpz-ui: first frame 412 ms (kmsdrm, software)
```

`CPZ_UI_TIMING=1` adds the window/renderer and font/layout phases. The first
menu of a boot is also held behind the splash for at most `SPLASH_MS` (300 ms),
so the visible time is `max(fonts, 300 ms)`, not `fonts + 1.5 s`.

Measure, do not assume:

```sh
systemd-analyze
systemd-analyze blame
systemd-analyze critical-chain cpz-session.service
journalctl -b -o short-monotonic -u cpz-session
```

## Configuration

| Variable | Meaning |
| --- | --- |
| `BOARD` | `v5` (current) or `v3`; selects the vendor overlay set |
| `ENABLE_HDMI` | `1` = vc4 + HDMI output available (default), `0` = panel only |
| `XKB_LAYOUT`, `XKB_OPTIONS` | SDL keyboard layout(s), default `us,ua` with Alt+Shift |
| `ENABLE_SSH` | `1` installs `openssh`, enables `sshd` and wired DHCP (default) |
| `USER_NAME`, `USER_PASS` | login account, default `cpz` / `cpz` |
| `BOOT_MB`, `ROOT_MB` | partition sizes; the build fails if the rootfs does not fit |
| `DISK_ID` | MBR signature; PARTUUIDs are `<DISK_ID>-01` (boot) and `-02` (root) |
| `EXTRA_PACKAGES` | extra packages, empty by default |
| `PRUNE_PACKAGES` | removal candidates; a required package is kept and reported |

## Layout

```text
config.sh                 every decision, one file
docker/Dockerfile         Arch Linux ARM builder + mtools/e2fsprogs/sfdisk
scripts/10-rootfs.sh      pacman --root into an empty directory, no initramfs
scripts/20-device.sh      build the pinned vendor modules and overlays
scripts/25-apps.sh        build the session, menu daemon, providers, launcher, terminal and probe
scripts/30-configure.sh   identity, boot files, cpz-session/cpz-menud units, watchdog, trim
scripts/40-image.sh       FAT32 + ext4 + MBR, no loop devices
scripts/50-verify.sh      structural and functional checks
src/cpz-session.c         appliance supervisor, output selection, hotplug, launch/run socket
src/cpz-menud.c           menu/status daemon: manifests, merge, TTL, icons, subscriptions
src/cpz-json.c/.h         shared small JSON reader/writer for the NDJSON protocol
src/cpz-ui.c              iPod-like Cairo/Pango shell: snapshot renderer, states
src/cpz-menu.c            cpz-menu CLI (list/status/snapshot/rescan/register)
src/cpz-sessionctl.c      one-line control helper used by `run` menu actions
src/cpz-battery.c         system status provider: battery widget
src/cpz-clock.c           system status provider: clock text widget
src/cpz-network.c         system status provider: network glyph
src/cpz-bluetooth.c       system status provider: Bluetooth glyph
src/cpz-provider.h        small provider-side client for cpz-menud
src/apps/<id>/app.json    static installed-app manifests (scanned by cpz-menud)
src/apps/<id>/icon.png    menu artwork owned by that app (tinted alpha mask)
src/make-icons.py         regenerates the app icons (no image library needed)
src/make-splash.py        generates the firmware boot splash binary/preview
src/cpz-splash.bin        Splash Asm dump drawn by start.elf (white triangle)
src/cpz-term.c            terminal app: pty + libtsm + SDL_ttf
src/cpz-sdlprobe.c        SDL2/KMSDRM probe and fullscreen test pattern
src/cpz-backlight.c       m5ioe1 PWM registers (the kernel path does not work)
src/cpz-spi.dts           frees SPI chip select 0 for the panel
src/fonts/Noto*.ttf      launcher font (Noto Sans + fallbacks, OFL)
src/fonts/NotoSansCJKsc-*.otf  CJK fallback (~16 MiB, OFL)
```

### Why a Docker volume

Bind mounts on Docker Desktop for macOS do not preserve ownership or mode bits,
which silently breaks `sudo` (setuid), `$HOME` and `/etc/shadow`. The rootfs
lives in a named volume; only the finished image is copied to `./out`.

### Why no loop devices

`mtools` builds the FAT32 partition on a plain file, `mke2fs -d` populates ext4
from a tree, `sfdisk` writes the MBR and `dd` places both parts. Unprivileged.

## Known risks on hardware

1. **The graphics stack is new and unvalidated on the device.** The build and
   the `cpz-sdlprobe`/`cpz-term` selftests pass in the target chroot, but SDL2
   on the real panel/HDMI, the KMSDRM device index and udev hotplug still need
   a hardware run. See `docs/GRAPHICS.md` for the acceptance checklist.
2. **Panel support is the main unknown.** The SPI panel has no render node, so
   SDL2 must go through Mesa `kms_swrast` and dumb buffers. If GBM/EGL on the
   panel card fails, the fix is a small custom SDL video driver; the rest of
   the architecture does not change.
3. **`sdl2-compat` uses SDL3 behind the SDL2 ABI.** It exposes KMSDRM in this
   build, but the `SDL_KMSDRM_DEVICE_INDEX` hint must be verified on both
   cards. `cpz-sdlprobe --probe` prints the selected driver and display.
4. **The panel may stay dark.** The kernel mipi-dbi path leaves
   `backlight_is_blank()` true and the vendor PWM driver does not program the
   backlight. `cpz-backlight` writes the m5ioe1 registers and `cpz-session`
   turns the panel off only when HDMI is active. If the vendor driver still
   clears the enable bit, it needs a kernel fix or a udev-triggered correction,
   not polling.
5. **Mesa is large.** `mesa` + `libLLVM` is ~228 MiB; the raw image is 961 MiB
   and the rootfs is 826 MiB. It fits the 1 GiB budget, but there is little
   room for video/game packages. A custom Mesa build with only `vc4` and
   `kms_swrast` is the next size step.
6. **Input layout needs a real test.** `XKB_DEFAULT_LAYOUT=us,ua` is exported,
   but SDL2's KMSDRM input path does not necessarily honour xkb layouts for
   every key. The launcher uses arrows/Enter, so it is usable regardless; the
   terminal must be tested with Cyrillic. If SDL input is insufficient, use
   libinput + xkbcommon in `cpz-term` and a small SDL input shim.
7. **DRM master runs as root.** `cpz-session` starts the UI and apps as root so
   SDL can take DRM master without a logind session. `cpz-term` drops to the
   `cpz` user for the shell. A production image should use a logind session or
   a privileged helper and run apps unprivileged.
8. **No battery guard, no suspend, no first-boot provisioning.** The BQ27220
   driver is loaded, but nothing shuts down at low charge and there is no
   filesystem resize or user wizard.
9. **`pacman -Qkk` would report the trim** (files deleted, packages still own
   them).
10. **The menu/status stack is new.** `cpz-menud`, the provider protocol and
    the four system providers are exercised by the build, `cpz-menud --selftest`
    and the socket tests, but not on the device. If the daemon is down the shell
    keeps the last snapshot and falls back to the compiled-in emergency menu;
    providers retry the socket, so a menud restart does not require a session
    restart.

## Next steps

The acceptance checklist is in `docs/GRAPHICS.md`. The short version:

1. Boot without a monitor. `journalctl -b -u cpz-session` must show
   `output panel (cardN-SPI-1)`, and `cpz-ui` must appear on the panel.
2. `cpz-sdlprobe --probe` on the panel: confirm `kmsdrm`, the panel display and
   a sane mode. `cpz-sdlprobe` must draw colour bars and the Cyrillic line.
3. Attach 1080p HDMI. The session must restart the UI on the vc4 card, turn the
   panel backlight off, and `cpz-sdlprobe --probe` must show HDMI.
4. Unplug/plug HDMI repeatedly with the UI and with an app running. The UI must
   move; a running app must finish on its original card; no black screen.
5. Open `cpz-term`, run `ls`, `vim`, `tmux`, and type Cyrillic. Verify that the
   keyboard layout and UTF-8 output work.
6. Power-cycle 20 times. The UI must return without manual intervention; the
   hardware watchdog must recover a deliberately hung session.
7. Record real `systemd-analyze` numbers, `cpz-session` output-switch times and
   panel/HDMI FPS in this README.
8. On the device run `cpz-menu list` and `cpz-menu status`; stop
   `cpz-menud.service` and confirm the shell keeps the last snapshot, then
   confirm it recovers when the daemon returns. Check that the battery, clock,
   network and Bluetooth widgets appear and disappear with their providers.
