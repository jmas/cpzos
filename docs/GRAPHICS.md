# Graphics — SDL2/KMSDRM appliance session

Status: **implemented, hardware acceptance pending.** This document records the
design of the SDL2/KMSDRM session.

## Goal

An iPod-like appliance:

- boots into a launcher, not a login prompt;
- uses the internal 320x170 SPI panel or an HDMI monitor, one active output at
  a time;
- switches outputs quickly and predictably;
- runs console programs and SDL2 applications without a compositor;
- recovers from a crashed app/session without a black screen;
- stays inside the 1 GiB image budget.

## Architecture

```
systemd
  └── cpz-session.service          (Type=notify, WatchdogSec=10, Restart=always)
        └── cpz-session            supervisor: no DRM, no drawing
              ├── cpz-ui           launcher (SDL2 + SDL_ttf)
              ├── cpz-term         terminal app (pty + libtsm + SDL_ttf)
              └── other apps       SDL2 fullscreen, one at a time
```

`cpz-session`:

1. Scans `/sys/class/drm/card[0-9]*-*/status`.
2. Picks HDMI when connected, otherwise the SPI panel. A forced output is
   available with `--output panel|hdmi` and from the UI Settings screen.
3. Exports `SDL_VIDEODRIVER=kmsdrm`, `SDL_KMSDRM_DEVICE_INDEX=<N>`,
   `CPZ_OUTPUT`, `CPZ_DRM_CARD`, `XKB_DEFAULT_LAYOUT`, `XKB_DEFAULT_OPTIONS`.
4. Starts `cpz-ui` and sends `READY=1`/`WATCHDOG=1` to systemd. Before that,
   `start.elf` has already drawn the firmware splash (see below). The first
   start of a boot passes `--splash`: `cpz-ui` paints the same white screen
   with a dark triangle until the menu is ready (or the first key press).
   Later restarts skip it.
5. Restarts the UI if it exits or crashes. The launcher writes
   `/run/cpz/ui.heartbeat` once a second; five seconds without it is treated as
   a hang and the UI is restarted.
6. On hotplug, stops the UI and starts a fresh UI on the new card. A running
   app is not moved; the switch is deferred until it exits.
7. Owns the panel backlight through `cpz-backlight`.

`cpz-ui` starts apps through `/run/cpz/session.sock`:

```text
ping                         -> ok
status                       -> ok ui|app panel|hdmi cardN
launch /usr/local/bin/app    -> ok
home                         -> ok
output auto|panel|hdmi       -> ok
poweroff | reboot            -> ok
```

The supervisor stops the launcher before the app opens DRM, and restarts the
launcher when the app exits. There is no live DRM hand-over and no process that
can be left holding a suspended display forever.

## Why this stack

- **SDL2 is the app contract.** Console apps live in `cpz-term`; SDL2 apps run
  as ordinary fullscreen SDL2 processes. The same binary can run on the panel
  or HDMI.
- **No compositor.** One app at a time, no windows, no protocol IPC.
- **Mesa, not a custom DRM library.** HDMI uses `vc4` GLES; the SPI panel has
  no render node, so it uses `kms_swrast` and dumb buffers.
- **Process isolation.** A crash in the UI, terminal or an app cannot corrupt
  the supervisor. systemd restarts the supervisor; the supervisor restarts the
  UI.
- **No fbcon/VT fight.** `fbcon=map:off`; the session does not use
  `KD_GRAPHICS`, `VT_ACTIVATE` or retrying `drmSetMaster`.
- **Unicode.** SDL_ttf/FreeType with DejaVu; Cyrillic labels and terminal
  output work. The old console font had 95 ASCII glyphs.

## Typography

The click-wheel color iPods used **Podium Sans**, a bitmap humanist sans based
on Myriad. Its defining traits are a humanist skeleton, open apertures, a
single-storey `g`, a straight `M`, and a narrow, low-resolution-friendly
rhythm. The 2007 iPod classic switched to Helvetica Bold; this project targets
the earlier click-wheel look.

PT Sans was the original choice for the right traits and Cyrillic coverage.
It has since been replaced by **Noto Sans** Regular/Bold, which keeps the
humanist, open-aperture, single-storey-g look while adding Greek and a much
wider symbol and script range. Its vertical metrics are slightly larger, so
the launcher sizes its 28 px row grid and type around those metrics instead of
copying the iPod's original 24 px row. Noto Sans is bundled in `src/fonts/`
together with the Open Font License; the image does not depend on a distro
font package.

The rest of the range comes from bundled fallback families:

| File | Coverage |
| --- | --- |
| Noto Sans Symbols / Symbols 2 | arrows, checks, stars, music, math, braille |
| Noto Emoji | monochrome pictographs |
| Noto Sans Arabic, Hebrew, Devanagari, Bengali, Tamil, Telugu, Thai | those scripts |
| Noto Sans CJK SC | Chinese, Japanese kana, Korean Hangul (~16 MiB) |

Text is rendered by **Pango** on a **Cairo** surface, so fontconfig performs
automatic fallback and HarfBuzz/FriBidi shape complex scripts and
right-to-left text. Cairo draws every vector element (status bar, selection,
battery, scrollbar, dialogs) with anti-aliased arcs, gradients and shadows;
SDL is only the window, input and presentation layer. The terminal keeps
DejaVu Sans Mono because it needs fixed cell widths.

Apple's Podium Sans is proprietary and is not redistributed here. The bundled
fonts are independent open alternatives, not copies of the Apple font.

## Launcher

`cpz-ui` follows the click-wheel iPod's navigation model rather than a flat
list with mode flags:

- A screen is data: a title, a kind, and an array of items. The root screen
  opens Музика, Відео, Фото, Ігри, Налаштування and Про пристрій as real
  submenus.
- Navigation is a bounded stack (`push` on Enter/C/RIGHT, `pop` on
  Esc/Z/LEFT/Backspace). On the Cardputer Zero the bare `Z`/`F`/`X`/`C` keys
  are the d-pad (F/X up/down, Z back, C forward), matching the arrows printed
  on the Fn layer. Selection and scroll live in the stack entry, so going back
  restores the cursor.
- One generic Cairo renderer draws every list. The look follows the iPod
  nano (1G/2G) menu, scaled for the 320x170 panel: a 24 px silver status bar
  (white to #BCC6C9) with a centered bold title and a green battery; 28 px rows
  on white, a #5797E1 to #2567CB selection bar with a dark top rim and a light
  bottom rim; anti-aliased black chevrons; a green cell with a dark outline and
  a gray nub for the battery; a thin vertical scrollbar when the list overflows.
  The fonts and colours were matched against Apple's iPod nano 1G Features
  Guide, which captures the same Podium-era UI. The launcher uses a fixed
  320x170 logical canvas and is scaled uniformly to the output, capped at 4x
  and at 72% of the screen height on monitors, then centred on a dark
  surround. HDMI never stretches the layout and the panel stays 1:1.
  The status bar is fixed; only the content below it slides horizontally
  (180 ms ease-out), so the title is always visible. Launches and output
  switches use a full-screen wait page modelled on the nano's "Synchronizing"
  screen (the two-arrow sync glyph from Apple's nano 4G guide), blocking
  failures use a full-screen warning page, and minor transient messages use a
  compact bottom toast. No floating modal dialogs. Apple's iPods had no
  launcher actions, so the toast is a deliberate launcher extension; the
  full-screen status pages follow the nano pattern.
- The About screen follows the iPod's label/value rows instead of free text.
- A submenu always shows a back chevron in the header, so "where am I" and
  "how do I leave" are visible without a footer legend.

Item kinds (`IT_LAUNCH`, `IT_SUBMENU`, `IT_OUTPUT_*`, `IT_REBOOT`, …) are the
only coupling between the data tables and the supervisor protocol.

## Output selection

| Output | Connector | Mesa driver | Rendering |
| --- | --- | --- | --- |
| Panel | `cardN-SPI-*` | `kms_swrast` | software into dumb buffers |
| HDMI | `cardN-HDMI-*` | `vc4` | GLES / page flip |

When `CPZ_OUTPUT=panel`, `cpz-ui` and `cpz-term` ask SDL for the software
renderer directly. The panel has no render node, so an accelerated request
means Mesa `kms_swrast`: it maps the Gallium/LLVM libraries (~220 MiB) and
JIT-compiles a blit shader for a 320x170 menu. `CPZ_RENDERER=software|accelerated`
overrides the default for one run.

Card numbers are not stable. The supervisor derives the index from the sysfs
connector name every time; applications never hard-code `card0`.

The launcher, terminal and probe select a display mode explicitly. On vc4 the
kernel can leave the HDMI connector at 720x400 (a VGA text mode) even when the
monitor advertises 1080p; `SDL_WINDOW_FULLSCREEN_DESKTOP` alone inherits that
mode and the monitor stays blank. `cpz-sdlmode.h` picks the largest mode up to
1080p and switches to `SDL_WINDOW_FULLSCREEN`.

Hotplug policy:

- **UI active:** stop, rescan, start on the new output.
- **App active:** set `pending_switch`; do not change DRM or backlight while
  the app is drawing. Switch when the app exits.
- **No output:** keep waiting (the panel probes several seconds after boot).

## Boot splash

The panel is never intentionally black during boot. Two stages draw the same
picture (a white 320x170 screen with a centred dark triangle):

1. **Firmware.** `config.txt` sets `splash_screen=cpz-splash.bin`. The stock
   `start.elf` runs the Splash Asm dump before the kernel starts and programs
   the ST7789 directly over SPI. It uses `MADCTL=0xA0` and the kernel's
   `vback-porch=35`, so the firmware and DRM frames have the same orientation.
   `src/make-splash.py` regenerates the binary and a PNG preview.
2. **Launcher.** The first `cpz-ui` of a boot is started with `--splash` and
   redraws the same image every 100 ms for 300 ms (or until the first key
   press). The kernel's panel re-initialisation has already completed when the
   launcher presents its first frame; the short hold only avoids a one-frame
   flash. The menu appears as soon as fonts and layout are ready, so the wait is
   `max(SPLASH_MS, fonts)`, not their sum. `cpz-session` does not pass
   `--splash` to later restarts; `CPZ_SPLASH_MS`/`--splash-ms` override the
   hold.

There is no Plymouth and no initramfs: the firmware stage is what covers the
several seconds before the panel driver probes. Both stages keep the same
geometry and colours, so the handover is not visible.

## Build

`config.sh`:

```sh
ROOT_MB="896"                 # Mesa + LLVM needs room
XKB_LAYOUT="us,ua"
XKB_OPTIONS="grp:alt_shift_toggle"
```

Packages: `sdl2-compat`, `sdl2_ttf`, `sdl2_image`, `mesa`, `libinput`,
`libxkbcommon`, `ttf-dejavu`, `alsa-ucm-conf`.

`scripts/25-apps.sh` builds:

- `cpz-session` (libudev)
- `cpz-ui`, `cpz-sdlprobe` (SDL2 + SDL2_ttf)
- `cpz-term` (SDL2 + SDL2_ttf + libtsm + libutil)
- `cpz-backlight`

`scripts/30-configure.sh` installs `cpz-session.service`, enables the hardware
watchdog, writes `fbcon=map:off` and a serial recovery console.

## Acceptance checklist

Run on the device, over serial/SSH, with the panel and a 1080p monitor.

1. **Boot to panel:** `journalctl -b -u cpz-session` shows a SPI card; the
   panel shows `cpz-ui`, not a login prompt.
2. **Probe:** `cpz-session --probe` and `cpz-sdlprobe --probe` agree on the
   card/connector. `cpz-sdlprobe` draws colour bars, the Cyrillic line and a
   moving box.
3. **HDMI:** plug a monitor. The UI restarts on HDMI, panel backlight goes off,
   `cpz-sdlprobe --probe` lists the vc4 card.
4. **Unplug:** the UI returns to the panel; backlight comes back; no black
   screen and no session restart.
5. **App switch:** from the UI open `cpz-sdlprobe`; it runs fullscreen; exiting
   returns to the UI. While it runs, plug/unplug HDMI: the app is not moved;
   the UI uses the new output after exit.
6. **Terminal:** open `cpz-term`; run `ls`, `vim`, `tmux`, `htop`. Type Latin
   and Cyrillic. Check `echo $TERM` is `xterm-256color`.
7. **Crash recovery:** `kill -9 $(pidof cpz-ui)`; systemd/session restarts the
   UI. `kill -9 $(pidof cpz-session)`; systemd restarts the session.
8. **Watchdog:** hang the session deliberately (SIGSTOP) and confirm the
   hardware watchdog reboots within ~15–60 s.
9. **Power loss:** 20 power cuts during idle and during app launch; the UI must
   return without manual repair.
10. **Size/time:** record `du -sh` for the image/rootfs, `systemd-analyze`,
    `critical-chain cpz-session.service`, the `cpz-ui: first frame` line from
    `journalctl -b -u cpz-session`, and panel and HDMI frame rates. Add
    `CPZ_UI_TIMING=1` to the unit environment for one boot to split window,
    renderer and font time.

## Open questions / next work

- **Does `kms_swrast` drive the panel?** This is the gate. If it does not, write
  a small SDL2 video driver (`cpzpanel`) with dumb buffers and RGB565, keeping
  the rest of the architecture unchanged.
- **Does `sdl2-compat` honour `SDL_KMSDRM_DEVICE_INDEX`?** Verify with
  `cpz-sdlprobe --probe` on both cards; if not, set the SDL3 property directly
  or build real SDL2.
- **Keyboard layout:** SDL2 KMSDRM input may not honour xkb layouts for every
  key. If Cyrillic input fails, use libinput + xkbcommon in `cpz-term` and a
  small SDL input shim.
- **DRM master as root:** the current session runs UI/apps as root. A
  production image should use a logind session or a privileged helper and run
  apps as `cpz`.
- **Image size:** Mesa + LLVM is ~228 MiB. A custom Mesa with only `vc4` and
  `kms_swrast` is the next step.
- **Kernel:** build the display drivers in (`vc4`, panel, SPI, GPIO, backlight)
  and drop the module-order/`softdep` dependency. The stack already removed
  `video=HDMI-A-1:d` and the `fw_devlink` hacks.
- **Power/audio:** battery guard, suspend, background music daemon, ALSA UCM.
