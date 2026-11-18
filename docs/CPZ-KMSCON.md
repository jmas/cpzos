# CPZ terminal session (kmscon)

The regular CPZ image is a terminal system: kmscon owns the DRM/KMS console and
runs tmux with the CPZ status bar and Settings TUI. UI and text rules are in
[CPZ-UI.md](CPZ-UI.md). There is no compositor,
desktop or launcher. The internal panel is a pure DRM display (card1/SPI-1);
kmscon drives it through KMS and fbcon is disabled.

```text
firmware splash
  → kmsconvt@tty1 → cpz-kmscon → cpz-login tty1 → login(1) as uid 1000
  → cpz-session.sh → tmux (top status bar, tabs, Settings)
  → HDMI usable: kmscon draws on HDMI and disables the panel screen,
    cpz-kmscon-output switches the panel backlight off
  → HDMI removed: kmscon re-enables the panel, backlight on
  → tty2/tty3: getty fallbacks (not drawn while fbcon=map:off)
```

The fbcon backend lives on the `main` branch (`docs/CPZ-FBCON.md` there).

## The panel is a DRM display, not an fbdev one

The CM0 panel is driven by `panel-mipi-dbi-m` (mipi-dbi), which registers
`/dev/dri/card1` with the `SPI-1` connector and a 320x170 mode. The normal
image deliberately does **not** register the driver's fbdev emulation, so
there is no `/dev/fb1` for the panel.

That matters because kmscon treats an fbdev node that belongs to a DRM device
as a duplicate and ignores it. It detects that by checking whether
`fb_fix_screeninfo.id` ends in `drmfb`. The kernel builds that id as
`"<driver>drmfb"` into `char id[16]`; `panel-mipi-dbi` + `drmfb` does not fit
and is truncated to `panel-mipi-dbid`, so kmscon cannot recognise it. It then
picks the fbdev backend, which has no atomic modesetting, page flips or DRM
hotplug. Removing the fbdev node is the reliable fix.

With no fbdev node, fbcon has nothing to draw on and is disabled globally:

```text
fbcon=map:off
```

kmscon sets the panel mode itself through KMS. The old boot-time "active CRTC"
workaround (`fbcon=map:10`) and the VT nudge in `cpz-kmscon-output` are gone.
`--switchvt` is still used so kmscon owns tty1 and VT switching behaves
normally.

The debug image is the exception: it keeps the panel fbdev and
`fbcon=map:10` so the kernel log is visible on the panel before kmscon starts.
The source patch that removes the emulation is applied to the pinned m5stack
dtoverlays checkout in `stage2/05-cardputerzero/01-run.sh`; `CPZ_DEBUG_BOOT=1`
skips it.

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

## Boot tuning

The shipped initramfs is built with `MODULES=list`, not the default
`MODULES=most`. Common root media (SD/eMMC on CM4, NVMe, USB storage) and ext4
are built into the RPi kernel; the list only adds the CM5
`sdhci_of_dwcmshc` controller, and the `rpi-sys-mods` initramfs hook adds the
boot i2c modules. The `zz-cpz-trim` hook drops `/usr/lib/udev/hwdb.bin` from
the initramfs; the full hardware database stays in the root filesystem, where
udev uses it after `switch_root`. `COMPRESS=xz` keeps the resulting archive
under 8 MiB. `MODULES=dep` is written back after the build for on-device
kernel updates, where the running Pi is a reliable dependency source. The
build fails if an initramfs grows past 8 MiB, so a regression back to
`MODULES=most` or a reintroduced hwdb copy is caught immediately.

The normal image disables `console-setup.service` and `keyboard-setup.service`
for the invisible tty2/tty3 fbcon; kmscon uses its own FreeType font and XKB
layout. `cardputerzero-keymap.service` also sets `CPZ_LAYOUT_SETTLE=0`, so the
boot keymap load does not run a redundant `udevadm settle` before kmscon's
first frame. The hotplug path keeps the settle. The debug image keeps the
fbcon services because its consoles are visible.

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
# drm     : card0-HDMI-A-1 connected/enabled, card1-SPI-1 connected/disabled
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

`Alt+D` toggles `display` between `auto` and `panel`; Settings → Display → Display Output sets `auto`, `panel` or `hdmi`. The timer picks the change
up within two seconds.

### Diagnosing the panel

kmscon logs one line per display it drives:

```sh
journalctl -u kmsconvt@tty1 -b | grep -E 'Display|new drm device|master|drm'
```

`Display [HDMI-A-1] ...` is the monitor. A working panel adds a second line
with the panel connector (`SPI-1`). The normal image should also log
`new drm device via /dev/dri/card1, using driver panel-mipi-dbi`; if only
card0 appears, kmscon never opened the panel card.

Check what the kernel reports:

```sh
ls -l /dev/dri
for d in /sys/class/drm/card*-*; do
    echo "$d: $(cat "$d/status") $(cat "$d/enabled" 2>/dev/null)"
done
cat /sys/class/drm/card*-SPI-*/modes 2>/dev/null
cat /proc/fb
udevadm info -q property -n /dev/dri/card1 | grep -E 'ID_SEAT|ID_PATH'
```

`connected/disabled` means the connector is fine but nothing drew on it (the
card nudge should correct that on the next boot or plug). `disconnected` or an
empty `modes` list is a driver issue: kmscon can only use a DRM connector that
reports `connected` with at least one mode.

`/proc/fb` must contain only `vc4drmfb` in the normal image; a `panel-mipi-dbi`
entry means the fbdev emulation is still enabled. `ID_SEAT` must be empty or
`seat0`; the vendor rule used to pin the card to `seat-cardputer-zero`, which
made `uterm_monitor` ignore it. Look for `test-only atomic commit failed -13`
in the kmscon log if the card is opened but the first modeset fails.

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
boot, so kmscon re-scans both cards). `99-cpz-kmscon-nudge.rules` marks that
synthetic event `HOTPLUG=1`, and kmscon re-scans its connectors in place. The
session, tmux and all panes keep running; only the screen layout changes.

The internal panel has no hotplug pin: it is present from boot on `SPI-1`. The
nudge matters for HDMI; the panel only disappears if its driver fails to
probe.

Restarts only happen for:

- a changed generated configuration (font size, theme, screen timeout,
  `display=panel` ↔ auto/HDMI);
- `--force` / `--recover`;
- a hotplug kmscon missed even after the card nudge: HDMI is connected and
  usable but no CRTC is attached for three ticks (~6 s). After one restart
  that still does not enable HDMI, retries stop until the connector state
  changes (replug or monitor wake) or `--recover` is used. The monitor is
  never blinked in a loop.

Switching *to* HDMI with a readable EDID (or a pinned `video=` mode) is
confirmed once after 0.2 s instead of waiting for the two-second timer sample.
A monitor whose capabilities cannot be read keeps the two-sample debounce.
Returning to the panel is immediate. Once on HDMI, the session stays there
while the connector is connected even if the EDID read fails for a moment, so
a monitor in standby cannot bounce the session.

## Generated kmscon config

kmscon reads most of its configuration once at startup and has no runtime API
for fonts, palettes or timeouts. Values the Settings TUI can change are
rendered into `/run/cpz-kmscon/kmscon.conf` by `cpz-kmscon-config`; the static
half is `/etc/kmscon/kmscon.conf`.

The keyboard layout is the exception. kmscon follows `systemd-localed` through
its Locale1 D-Bus listener and swaps the live keymap in place. No `xkb-layout`
is written into the generated file, so a layout change does not restart the
session or renegotiate the HDMI link.

| Setting | kmscon option |
| --- | --- |
| `display=panel` | `multi-monitor=clone` |
| any other display mode | `multi-monitor=largest` |
| `font_size=10..64` | `font-size=<pixels>` |
| `screen_timeout=5/10/30` | `dpms-timeout=300/600/1800` (0 = never) |
| `theme` | `palette=custom` + the theme's 16 colours, background and foreground |

### Themes

A theme is a plain tmux configuration file in `/etc/cpz/themes`. Settings
lists every `*.conf` whose name is `[A-Za-z0-9_-]+` and reads the human name
from `# name:`. The same file carries the data the renderers need:

```text
# name: Campbell
# alert=ff4b5c          semantic colour for critical battery
# warn=c19c00           semantic colour for low battery
# palette 0=0c0c0c      ANSI colours 0..15
...
```

`cpz-kmscon-config` renders the background, foreground and 16 palette entries
into kmscon; `cpz-apply-settings` sources the same file for the live tmux
session and keeps `pane-colours` in sync. `cpz-status` reads `alert` and
`warn` so the battery warning is legible on the status bar instead of relying
on ANSI red/yellow, which may be a pale tint in some palettes. Keep the
`.palette` file in sync: it mirrors the embedded list for host-side checks
and external tooling.

The checks in `tools/verify-stage.sh` reject a theme with text below 4.5:1,
pane borders below 3:1, a missing `alert`/`warn` colour, or a palette that
does not match its `.palette` file. A theme file is trusted input because
tmux sources it, so do not install one from an untrusted source.

`cpz-keyboard-layout` writes `/run/cpz-layout.active` (`cpz` or the standard
layout code). It detects a full USB/Bluetooth/PS2 keyboard from sysfs and
applies the matching layout to both the console keymaps and `localectl`. The
localed change reaches kmscon at runtime, so plugging or unplugging a keyboard
does not restart the session.

The CPZ layout maps the TCA8418 Sym layer to punctuation (`Sym+B` is `.`).
The driver's Sym layer reuses ordinary punctuation keycodes, and national
layouts put their extra letters on exactly those keycodes. `cpz-layout-map`
therefore generates a language-aware overlay (`cpz_us`, `cpz_ua`, ...): a
keycode that carries a letter in the selected layout is left alone, so
`Sym+key` types that letter and `Shift+Sym+key` its uppercase form. The ASCII
punctuation that would have been on that keycode moves to `Shift+Sym` of a
punctuation-only keycode. Layouts that only put punctuation there (US, GB,
...) keep the full static table. `cpz-layout-map` builds both the XKB layout and
the VT overlay from the same `ckbcomp` output, so kmscon and the recovery
consoles agree.

The vendor FSM blocks Shift while the sticky Sym layer is latched; the build
patches `tca8418_fsm_can_activate()` in the pinned driver so Shift may activate
during Sym. Tap Sym, then hold Shift and press the key (the FSM treats a short
Shift tap as a one-shot modifier). Fn and Sym stay mutually exclusive.

Switching between US, Ukrainian, Russian and the other enabled layouts now
keeps the full alphabet on the internal keyboard. An external keyboard uses
the plain standard layout; kmscon has one keymap, so the overlay is active only
while the internal keyboard is selected.

The font size is shared by both screens, so HDMI gets more columns at the same
cell size. `Alt+G` / `Alt+M` run `cpz-font`, which writes `font_size` to the CPZ
settings. Settings → Display → Text Size edits the same value and offers the
full 10–64 px range; the keys can be changed in Settings → Keyboard →
Shortcuts. The size survives layout changes, theme restarts and reboots. A font
change still needs a kmscon restart because kmscon has no runtime font API.

`cpz-kmscon-config` prints `changed` or `same`; `cpz-kmscon-output` restarts
the session only when the rendered file differs, the display mode moves
to/from `clone`, or a hotplug was missed.

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
attaches tmux only on the tty1 pty. The tty2/tty3 gettys, SSH and the debug
image stay plain shells.

## Files

```text
/usr/bin/kmscon
/etc/kmscon/kmscon.conf                     # static template
/usr/local/bin/cpz-kmscon                   # unit ExecStart
/usr/local/bin/cpz-kmscon-config            # renders /run/cpz-kmscon/kmscon.conf
/usr/local/bin/cpz-kmscon-output            # output reconciler
/usr/local/bin/cpz-login                    # uid 1000 autologin + pty marker
/usr/local/bin/cpz-hint                     # one-line key hint on attach
/usr/local/bin/cpz-help                     # Alt+H key reference
/usr/local/bin/cpz-keys                     # shortcut registry + generated tmux binds
/usr/local/bin/cpz-search                   # Alt+O Search popup
/usr/local/bin/cpz-tab-mount                # opens/closes the tab for a USB disk
/usr/local/bin/cpz-font                     # Alt+G/Alt+M, persists font_size
/usr/local/bin/cpz-volume                   # Alt+U/Alt+I/Alt+0, default sink volume
~/.config/cpz/keys.conf                     # optional shortcut overrides
~/.cache/cpz/tmux-keys.conf                 # generated bindings sourced by tmux
/usr/local/bin/cpz-layout-map               # language-aware Sym overlay generator
/usr/local/bin/cpz-automount                # USB filesystem hotplug mounts
/etc/systemd/system/kmsconvt@.service.d/10-cpz.conf
/etc/systemd/system/cpz-kmscon-output.service
/etc/systemd/system/cpz-kmscon-output.timer
/etc/systemd/system/cpz-automount@.service
/etc/udev/rules.d/99-cpz-kmscon-output.rules
/etc/udev/rules.d/99-cpz-kmscon-nudge.rules
/etc/udev/rules.d/99-cpz-automount.rules
/etc/udev/rules.d/99-cpz-display.rules       # panel DRM card stays on seat0
/usr/share/X11/xkb/symbols/cpz              # CPZ Sym/Fn template for kmscon
/usr/share/X11/xkb/symbols/cpz_<lang>       # generated per-language overlay
/usr/local/share/cpz/xkb/cpz.template       # source for the generated overlays
/etc/systemd/system-sleep/cpz-kmscon
/etc/profile.d/cpz-session.sh
/etc/tmux.conf
```

The image adds `<ZENK> = 93;` to `/usr/share/X11/xkb/keycodes/evdev`: xkb-data
leaves the keycode used by Sym+N (`>`) unnamed. Automatic `xkb-data` upgrades
are masked; a manual package upgrade would need that line re-applied.

Daily tmux actions are direct two-key `Alt+key` bindings: `Alt+T` / `Alt+W`
for tabs, `Alt+V` / `Alt+B` for splits, `Alt+N` / `Alt+P` for panes, `Alt+Z`
for pane zoom, and so on. No tmux prefix is needed for the main UI. `C-a`
remains only as an advanced fallback; the default `C-b` is hard to chord on
the small CPZ keyboard. `Alt+U` / `Alt+I` raise and lower the default output
volume and `Alt+0` toggles mute through `cpz-volume`, which uses the same
`wpctl` sink as Settings → Sound. `cpz-keys` generates the bindings and
Settings → Keyboard → Shortcuts can reassign any of them; see
[CPZ-KEYS.md](CPZ-KEYS.md) for the rules, defaults and file format.

Plugging in a USB disk opens a tab in `/media/<label>` (see
`docs/CPZ-STORAGE.md`). The tab is tagged with `@cpz_mount`, is not saved in
the session layout, and is closed before the filesystem is unmounted.

`Alt+O` opens CPZ Search, a short tmux popup with mounted drives, installed
apps, catalog apps, PATH commands, daily CPZ actions, Settings pages and files
in one fzf list. Mounted USB drives show an `Unmount <label>` row first; `Enter`
asks `sudo` and unmounts through `cpz-automount`. `/` switches to file search,
`=` to the calculator, `apps` to the local Terminal Trove catalog and `$` to
tmux paste buffers. Installed apps are
listed first and launch in a new tab; every other app row opens its
Applications details page in the Settings tab, where `i` installs through the
same apt policy as Applications.
`Ctrl+Y` copies the selection to the tmux buffer and `Ctrl+O` opens its
directory in `lf` (or the Applications details). Settings entries use
`cpz-settings --page <page>` and app entries use `cpz-settings --tool <slug>`,
which opens that app's page directly; both are also available outside the
popup. The search is on demand: no daemon or index runs between invocations.

The tmux helpers avoid two tmux 3.5 behaviours: literal tabs in `-F` output are
replaced with `_`, and `set-option` no longer accepts the `=session` exact-match
prefix. Tab close and session save therefore use
space-separated formats or per-window queries.

`cpz-hint` runs from the `client-attached` hook once per login session and
targets that client's status line, so the short discovery hint is not printed
into the pane under the top status bar. `Alt+H` opens the full paged reference.

Enabled: `kmsconvt@tty1`, `getty@tty2`, `getty@tty3`, `console-setup`,
`cpz-kmscon-output.timer`,
`cpz-conn-status.timer`, `cpz-session-save.timer`,
`cardputerzero-keymap.service`, `cpz-keyboard-layout.path`,
`cpz-bt-agent.service`, `bluetooth.service`, `NetworkManager.service`,
`rpi-preseed.service`. The tty2/tty3 gettys are fallbacks; with
`fbcon=map:off` they are not drawn.

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

The debug image is the one exception to the pure-DRM rule: `CPZ_DEBUG_BOOT=1`
keeps the panel's fbdev emulation so fbcon can draw the kernel log on the
panel. It removes the splash, `quiet`, `loglevel=3` and
`vt.global_cursor_default=0`, replaces `fbcon=map:off` with
`fbcon=map:10 consoleblank=0`, adds `console=serial0,115200 console=tty1
loglevel=8`, masks `kmsconvt@tty1` and enables `getty@tty1`/`tty2`/`tty3`.
If it shows nothing, the failure is before kmscon.

## Known limitations

- **The CPZ Sym/Fn overlay is an XKB layout for kmscon.** The TCA8418 driver
  reuses ordinary punctuation keycodes for the Sym layer; the console keymap
  (`loadkeys`) and kmscon's XKB layout are both generated from the same
  language-aware table by `cpz-layout-map`. It leaves a keycode alone when the
  selected layout carries a letter there, so national alphabets keep their
  letters (`Sym+key`, `Shift+Sym+key` for uppercase) and only the displaced
  ASCII punctuation moves to `Shift+Sym`. An external USB/Bluetooth keyboard
  switches the session to the plain standard XKB layout, so the internal
  overlay and an external keyboard cannot use different layouts at the same
  time.
- **Screen timeout is DPMS, not blank-only.** kmscon's `dpms-timeout` powers
  the output down. A monitor that renegotiates on wake may change the mode;
  pin `CPZ_HDMI_VIDEO` (`video=HDMI-A-1:1920x1080@60`) if that happens. Set
  `screen_timeout=0` to disable it. A DPMS timeout is a deliberate blank, not
  a crash loop.
- **Theme changes restart the session** to rebuild the palette (about 1–2 s,
  tmux reattaches).
- **tty1 is graphics-only.** The normal image boots with `fbcon=map:off`, so
  tty2/tty3 gettys are fallbacks without a visible console; if kmscon cannot
  start, use SSH, the serial console or the debug image.
- kmscon is pinned from `trixie-backports`; keep `KMSCON_VERSION` in
  `stage3/00-kmscon/00-run.sh` in step with the image.

## Hardware checks

```sh
# boot to the panel, then plug HDMI: session moves, panel backlight goes dark
sudo cpz-kmscon-output --status
journalctl -t cpz-kmscon-output -b
journalctl -u kmsconvt@tty1 -b     # expect card1/SPI-1 and "Display [SPI-1]"
cat /proc/fb                       # only vc4drmfb in the normal image
# unplug: panel returns without an HDMI blink
# Alt+D: panel comes back while HDMI stays attached
# suspend/resume: output and backlight are re-applied
sudo evtest                 # verify Fn key codes
free -m
systemd-analyze
```

If kmscon cannot drive the panel reliably, return to the fbcon branch and do
not build the rest of the CPZ UI on an unproven console layer.
