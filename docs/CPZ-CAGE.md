# CPZ graphics session (cage + foot)

The regular CPZ image boots into a **graphics session**, but it is not a
desktop. `cage` is a Wayland kiosk compositor with one full-screen client:
`foot`, which runs the CPZ tmux session. Terminal programs stay in tmux;
Wayland and X11 programs open a window on top of foot and return to the
terminal when they close.

```text
firmware splash
  → cpz-tmux.service (tmux server, independent of the compositor)
  → getty@tty1.service (PAM login on tty1)
      → cage (Wayland kiosk, DRM/KMS)
          → cpz-cage-session (supervisor + idle anchor terminal)
              → foot (visible, fullscreen terminal)
                  → cpz-tmux → tmux (top status bar, tabs, Settings)
                      ↘ Doom / mpv / any app window on top
```

There is no launcher, panel, window manager, task switcher or per-application
graphics registry. An application decides by itself: a terminal program uses
the tmux pane, a graphical program connects to `WAYLAND_DISPLAY` (or `DISPLAY`
through Xwayland) and cage places its window on top.

## Why cage and foot

`kmscon` owned the DRM console and therefore needed a special handoff for every
graphical app. cage owns the same console permanently, so there is no
background/foreground escape sequence, no marker file, no VT switch and no
application classification. The terminal is simply the first client.

Cage's upstream model is exactly this one:

> If Cage is launched with a terminal emulator and an application is launched
> from this terminal emulator, that application is placed “on top” of the
> terminal emulator and takes all input until it is closed. When this
> application is closed, the terminal emulator becomes visible again.

Only one application is visible at a time. That is deliberate: it fits games,
media players and full-screen tools, and it keeps the session small on the
CM0. It is not a desktop; use `sway` instead if window switching becomes a
requirement.

## Boot and session units

`cpz-tmux.service` starts a tmux server as uid 1000 and stays active. It is
independent of the compositor, so a cage restart does not lose tabs, panes or
running programs.

The tty1 getty is overridden with an autologin wrapper. `login(1)` creates the
PAM/logind session on tty1, `/etc/profile.d/cpz-session.sh` replaces the login
shell with `cpz-cage`, and the script renders the foot configuration, reads
`/run/cpz-cage/session.env` and runs:

```text
cage -m last -s -d -- cpz-cage-session
```

`cpz-cage-session` starts an idle anchor terminal and then the visible
`foot --config=/run/cpz-cage/foot.ini -- cpz-tmux`. The anchor is never seen in
normal use; it keeps cage (and the current DRM mode) alive for the fraction of a
second in which a font or theme change replaces the visible foot.

`-s` keeps VT switching available for the recovery consoles; `-d` suppresses
client-side decorations. `cage` pulls Xwayland, so X11 programs work without a
separate Xorg.

The getty unit restarts cage if it exits. `cpz-tmux` reattaches the independent
tmux server, so a compositor crash costs a screen blink, not the session. The
getty is not rate-limited: the internal panel has no text-console fallback, so
a transient DRM/seat failure retries every 3 seconds instead of leaving a
permanently failed unit and a black screen.

`cpz-tmux.service` pulls in `user-runtime-dir@1000.service`, because tmux needs
`/run/user/1000` and logind only creates it for a session (the tmux server is a
system service, not a session process).

## One output

`cpz-cage-output` is the output reconciler (five-second fallback timer, an
immediate DRM hotplug unit and a path unit for Settings changes). It reads the
same settings as before:

| Setting | Behaviour |
| --- | --- |
| `display=auto` | HDMI when a usable monitor is attached, otherwise the panel |
| `display=panel` | panel only; HDMI is not driven |
| `display=hdmi` | HDMI while connected, panel otherwise |

Auto and `display=hdmi` hand cage **only the selected DRM card**, as the
primary device. In auto mode that is `/dev/dri/card0` (vc4 HDMI) while a usable
monitor is attached, and `/dev/dri/card1` (SPI panel) otherwise. A target
change rewrites `session.env` and restarts the compositor.

The reason is a wlroots limitation, not a CPZ preference: the panel card has no
render node and the pixman renderer cannot render on a secondary GPU. Handing
cage `panel:HDMI` made the vc4 output secondary; its cursor plane worked, but
the composited terminal never appeared and the output flickered as page flips
failed. Running HDMI as the primary card avoids that path entirely.
`CPZ_HDMI_VIDEO` still pins a kernel mode for monitors that never expose a
readable EDID; the hotplug unit waits briefly for EDID before deciding.

The selected target is kept in `/run/cpz-cage/output.state`. The card is part
of `session.env`, because it is also the render device. `display=panel` pins
the panel card; auto keeps the panel while a connected monitor has not exposed
a readable EDID yet.

```text
panel only       → WLR_DRM_DEVICES=/dev/dri/card1
HDMI             → WLR_DRM_DEVICES=/dev/dri/card0
```

Both outputs use the pixman renderer and dumb buffers: the panel card has no
render node, and the HDMI card is primary while it is active, so pixman can
scan out on it. foot and software SDL clients use `wl_shm`. The panel backlight
is switched off while HDMI is active and restored when the session returns to
the panel.

The backlight is driven by `cpz-panel-backlight`, which writes the m5ioe1 PWM
channel 3 registers over I2C. The kernel backlight stack cannot do it on 6.18:
`backlight_disable()` sets `BL_CORE_FBBLANK` and nothing in the mipi-dbi path
clears it (the 6.18 `mipi_dbi_pipe_enable()` no longer calls
`backlight_enable()`), so `backlight_is_blank()` stays true and the vendor
pwm-bl driver never programs the PWM. The driver must stay bound — the panel
DRM card depends on its device through a device link — so the channel cannot be
exported through `/sys/class/pwm` either. `cpz-brightness` and the output
helper both go through this script; the backlight class is only a fallback.

Because a target change restarts cage, the reconciler treats HPD as a signal to
re-probe, not as a reason to switch on the first sample: leaving a working HDMI
link requires a second disconnected probe, and entering HDMI is confirmed with
another probe (auto mode additionally needs two ticks when the EDID is not yet
readable). That filters the HPD pulses a TV emits while powering up or changing
inputs. A selected HDMI output that cage never enables counts as a failed
attempt; after two of them the session returns to the panel and auto stops
choosing HDMI until the cable is cycled or the user asks for it again. Automatic
compositor restarts are also limited to one per 20 s, so a monitor cannot be
made to blink indefinitely: every restart drops the HDMI link, and the display
visor shows that as flicker.

The env file is sourced with `set -a`. Sourcing alone creates only shell
variables; cage must actually receive `WLR_DRM_DEVICES` and `WLR_RENDERER`.
Without them it opens every DRM card and lets wlroots pick GLES2, which dies
with `GL_OUT_OF_MEMORY` on the vc4 HDMI card — the session then restarts every
few seconds and the monitor blinks.

Changing the persisted display mode is applied immediately by touching
`/run/cpz-cage/output.request`, which starts the service through
`cpz-cage-output.path`. An external edit that bypasses the UI is caught by the
five-second timer.

```sh
sudo cpz-cage-output --status
sudo cpz-cage-output --report    # status + env, cage stderr, journal, dmesg
sudo cpz-cage-output --panel     # force the panel for this run
sudo cpz-cage-output --hdmi      # force HDMI (falls back when unplugged)
sudo cpz-cage-output --auto      # follow the setting again
sudo cpz-cage-output --force     # re-render and restart now
sudo cpz-cage-output --recover   # restart the compositor
sudo cpz-cage-output --target    # print hdmi or panel
```

`Alt+D` toggles `display` between `auto` and `panel`; Settings → Display →
Display Output selects `auto`, `panel` or `hdmi`.

## Font, theme and keyboard

`cpz-foot-config` renders `/run/cpz-cage/foot.ini` from the CPZ settings and
the selected theme:

- `font_size_panel` or `font_size_hdmi` (whichever output `cpz-cage-output`
  selected) becomes `font=Terminus:pixelsize=N` with `dpi-aware=no` and
  `pad=0x0`, so the panel keeps the 53x14 grid at the default 12 px cell and
  HDMI uses its own, usually larger, size;
- the theme's tmux `window-style` background/foreground become foot's
  background/foreground;
- the 16 theme palette entries become foot's `regular0..7` and `bright0..7`.

`cpz-cage-output` detects a changed foot configuration, but it no longer
restarts the compositor. `cpz-foot-reload` renders the file and sends SIGUSR1
to `cpz-cage-session`, which terminates only the visible foot and starts a new
one from the same configuration. The anchor terminal keeps cage and the DRM
mode alive during the swap. The tmux theme is applied immediately by
`cpz-apply-settings`; the new foot reattaches to the same tmux session.

`cpz-font` (Alt+G / Alt+M) and Settings → Display → Text Size use the same
path, so a font change takes effect in well under a second instead of waiting
for a compositor restart. The size is stored per output
(`font_size_panel` / `font_size_hdmi`): the shortcut changes the active one,
and a display switch renders the saved size of the output that starts. A
legacy single `font_size` is migrated into both on the first read.

`cpz-keyboard-layout` still publishes the XKB layout through systemd-localed.
`cpz-cage-output` watches the published layout and restarts the compositor
when it changes, so the next foot/tmux frame uses the new layout. This is a
restart rather than kmscon's in-place keymap swap, and the only remaining
common action that blanks the screen.

## Language

Settings → System → Language changes the CPZ catalogs and the system locale
together. The value is stored in `~/.config/cpz/settings.conf`; the
`cpz-locale-apply` helper, allowed through `/etc/sudoers.d/50-cpz-locale`,
writes the matching `LANG`, `LC_MESSAGES` and `LC_TIME` to `/etc/locale.conf` and
`/etc/default/locale`. New login shells, tty2/tty3 recovery consoles and new
child processes use the new locale. The current session and tmux environment
switch immediately; already running third-party programs keep the old locale
until restarted.

The image generates `en_US.UTF-8`, `uk_UA.UTF-8` and `de_DE.UTF-8` in
`stage2/04-locales`. Adding a language needs a catalog in
`stage3/01-session/files/i18n/`, an entry in `cpz-i18n`, and an entry in
`cpz-locale-apply`.

## Input and pointer

The internal TCA8418 keyboard is kept on **seat0**. kmscon read evdev directly
and ignored `ID_SEAT`, but cage uses libinput, so the old
`ENV{ID_SEAT}="seat1"` rule hid the built-in keyboard from the compositor. It is
now `ID_SEAT="seat0"`, while the stable `cardputer-zero-internal` symlink and
the input group permissions remain.

cage draws a cursor whenever any input device advertises pointer capability.
Some devices do that without a usable mouse: the vc4 HDMI controller exposes a
CEC node with relative axes, and the internal keyboard has a few pointer bits.
`99-zz-cpz-input.rules` calls `cpz-pointer`, which keeps the keyboard half of
those devices and strips only the pointer capabilities.

A device that is **only** a pointer and must not be visible (a mouse while
Mouse Support is off, or any phantom pointer) is moved to
`ID_SEAT=seat-cpz-no-pointer`. libinput filters by `ID_SEAT` before it
classifies the device, so cage never receives it, no matter which
`ID_INPUT_*` tag a later rule restores. A device with a keyboard half stays on
`seat0` and loses only its pointer tags. `/etc/libinput/local-overrides.quirks`
additionally disables `EV_REL`/`EV_ABS` on the internal keyboard and the vc4
HDMI CEC node, so those nodes cannot become pointers even if their tags are
wrong.

The cursor is visible only when both conditions are true:

1. a real USB/Bluetooth mouse, touchpad, trackball or pointing stick is
   connected;
2. **Settings → Input → Mouse Support** is on.

A device counts as a mouse only when it exposes an actual pointer button
(`BTN_MOUSE`, pen/touch contact, or a touchpad button), not merely relative or
absolute axes. `input_id` tags a keyboard with stray axes as `ID_INPUT_MOUSE`,
and that tag alone must not bring the cursor back while no mouse is connected.
As a last-resort ghost-cursor guard, the generated foot configuration sets
`[mouse] hide-when-typing=yes`: the first keystroke hides a stale client
cursor even if the compositor still remembers the old pointer capability.

Turning Mouse Support off also disables tmux wheel scrolling and selection.
The Input page shows the state in one row: **Mouse Support** reads `On · Connected`
or `Off · Not connected`, so the status and the toggle stay together. The
cursor is visible only when the row says `On · Connected`.

With Mouse Support on, the pointer also works inside the CPZ interfaces:
Settings rows select on click and open on double-click,
the wheel scrolls pages and pickers, CPZ Search supports click and
double-click, and `Alt+H` pages with the wheel. In a terminal pane, dragging
enters tmux copy mode and copies the selection when the button is released;
double-click selects a word. tmux sends the copied text over OSC 52 and foot
puts it on the Wayland clipboard. `Alt+Y` pastes the tmux buffer. Hold
**Shift** while dragging to bypass tmux and select directly in foot when a
full-screen application has captured the mouse.

A settings change is applied without restarting cage. libinput reacts only to
udev `add`/`remove`, not `change`, so `cpz-pointer --apply` reopens the pointer
devices with a synthetic remove/add pair. `cpz-pointer.path` starts that helper
whenever Settings saves the mouse setting. Plugging or unplugging a mouse is
handled by the udev hook itself, so the cursor appears and disappears with the
device.

### Ghost cursor workaround

cage 0.3.1 has a race: after a pointer is removed it correctly unsets the
cursor and revokes pointer capability, but a client may still send a delayed
`wl_pointer.set_cursor`/`set_shape` request. cage accepts that request without
checking the current seat capabilities and reattaches the client's text cursor
as a permanent ghost. The upstream fix is
[cage PR #526](https://github.com/cage-kiosk/cage/pull/526), merged after the
0.3.1 release and not yet in the Raspberry Pi package.

Until that package is available, `99-zz-cpz-input.rules` marks real pointers
with `CPZ_REAL_POINTER=1` and starts `cpz-pointer-cursor.service` when one is
removed. The service runs `cpz-pointer --nudge`: it waits briefly and
re-adds a keyboard device, which makes cage re-evaluate the seat and unset the
stale cursor image. It then replaces the visible foot. The cursor surface is
owned by the client, so destroying that client is the only certain way to drop
a request that arrives after the seat update. No compositor restart is needed.
The same nudge runs after a Settings change. See `cpz-pointer --status` for the
effective pointer state.

## Screen timeout

The `screen_timeout` setting is persisted, but the cage session does not yet
have a compositor-side DPMS timer. kmscon handled this with `dpms-timeout`;
the equivalent needs an idle helper for cage (`swayidle`/`wlopm` compatibility
has not been proven on the panel). Until that is added, the setting is
reserved and does not blank the screen.

## Boot and hotplug latency

The session no longer waits for HDMI at boot:

- cage starts on whichever card `cpz-cage-output --prepare` selected;
- a target change rewrites `session.env` and restarts the compositor, because
  the target is also the primary DRM render device (see “One output”);
- HPD is confirmed with a second probe, so a TV that pulses the link while
  powering up does not trigger a restart loop;
- the hotplug unit waits briefly for EDID before deciding;
- font and theme changes replace only the visible foot;
- display-mode changes apply through a path unit immediately;
- the boot-time battery check waits at most 3 s for the gauge;
- the first-login password reminder defaults to a 3 s timeout;
- the output timer is a 5 s fallback, with immediate DRM-hotplug and Settings
  triggers.

If the machine still takes a long time to reach the terminal, measure where it
goes:

```sh
systemd-analyze
systemd-analyze blame
systemd-analyze critical-chain getty@tty1.service
journalctl -b -u getty@tty1.service -u cpz-tmux.service
```

A slow first boot is usually `rpi-preseed`, the kernel/initramfs, or a failing
input device rather than cage itself.

## Recovery

The normal image enables `getty@tty1` with autologin; tty2/tty3 remain getty
fallbacks but are not drawn while `fbcon=map:off`. Recovery paths are:

- SSH, if enabled;
- the serial console;
- the debug image (`CPZ_DEBUG_BOOT=1`), which keeps the panel fbdev and shows
  verbose getty consoles;
- `Ctrl+Alt+F2` to a tty2 getty if fbcon has been re-enabled (normally not
  visible on the panel).

Useful checks:

```sh
systemctl status getty@tty1.service cpz-tmux.service
sudo cpz-cage-output --status
journalctl -b -u getty@tty1.service
journalctl -b -u cpz-tmux.service
ls -l /dev/dri
cat /proc/fb                       # normal image: only vc4drmfb
```

If the compositor is wedged but the machine is reachable over SSH:

```sh
sudo systemctl restart getty@tty1.service
```

## Debug image

`CPZ_DEBUG_BOOT=1` masks `cpz-tmux.service`, disables the output timer and
keeps `getty@tty1`/`tty2`/`tty3`. `cpz-getty` detects the debug marker and starts
a normal login prompt instead of autologin, so the profile never replaces the
shell with cage. It keeps the panel fbdev and `fbcon=map:10`, so kernel and
systemd logs are visible.

## Files

```text
/usr/bin/cage
/usr/bin/foot
/usr/local/bin/cpz-cage             # profile ExecStart; runs cage
/usr/local/bin/cpz-cage-session     # anchor + supervised visible foot
/usr/local/bin/cpz-cage-output      # output reconciler
/usr/local/bin/cpz-foot-config      # foot.ini renderer
/usr/local/bin/cpz-foot-reload      # render and replace the visible foot
/usr/local/bin/cpz-getty            # tty1 autologin wrapper
/usr/local/bin/cpz-locale-apply     # writes the system locale; sudo allowlist
/usr/local/bin/cpz-run              # applies Wayland/X11 env, then execs
/usr/local/bin/cpz-tmux             # foot command; attaches tmux
/usr/local/bin/cpz-tmux-start       # creates/ensures the tmux server
/etc/profile.d/10-cpz-locale.sh     # loads LANG/LC_* from /etc/locale.conf
/etc/profile.d/cpz-session.sh       # tty1 login shell -> cpz-cage
/etc/sudoers.d/50-cpz-locale        # allows cpz-locale-apply
/etc/locale.conf                    # system LANG, LC_MESSAGES, LC_TIME
/etc/default/locale                 # Debian/PAM copy of the same values
/etc/systemd/system/getty@tty1.service.d/10-cpz.conf
/etc/systemd/system/cpz-tmux.service
/etc/systemd/system/cpz-cage-output.service
/etc/systemd/system/cpz-cage-output.timer
/etc/systemd/system/cpz-cage-output.path
/etc/systemd/system/cpz-cage-output-hotplug.service
/etc/udev/rules.d/99-cpz-cage-output.rules
/etc/systemd/system-sleep/cpz-cage
/run/cpz-cage/session.env           # WLR_* and XKB_* for cage
/run/cpz-cage/foot.ini              # generated foot configuration
/run/cpz-cage/output.state          # target/card for Settings and brightness
/run/cpz-cage/output.request        # Settings -> immediate output reconcile
/run/cpz-cage/cage-session.pid      # supervisor for a foot-only reload
/run/cpz-cage/client.env            # WAYLAND_DISPLAY/DISPLAY/XAUTHORITY
```

## Known limitations

- **One visible application.** cage does not cycle windows. Close the current
  app to return to foot. Use `sway` if a real window manager is needed.
- **Theme and font changes replace only foot.** The visible terminal is
  swapped in place; cage, the DRM mode and tmux stay up. A display target
  change (HDMI ↔ panel) restarts the compositor, because the target is the
  primary DRM device; the blank lasts about as long as a compositor start.
- **Keyboard layout changes restart the compositor.** kmscon's in-place keymap
  swap is gone; this is the remaining common action that blanks the screen.
- **Screen timeout is not implemented yet.**
- **Panel performance needs a hardware check.** cage uses pixman and dumb
  buffers on the SPI panel; foot uses `wl_shm`. Doom and other software
  renderers should fit, but measure CPU and memory on the CM0.
- **HDMI hotplug restarts the session.** cage runs on one DRM card at a time
  to avoid the pixman secondary-GPU bug; forced `panel` still pins the panel
  and ignores HDMI.
- **No direct KMS applications** (for example `kmscube`): cage owns DRM master.
  Wayland, Xwayland and SDL2 Wayland applications are supported.

## Hardware checks

```sh
# boot to the panel
sudo cpz-cage-output --status
journalctl -b -u getty@tty1.service
# plug HDMI: cage moves to HDMI, panel backlight goes dark
# unplug: panel returns
# Alt+D: panel returns while HDMI stays attached
# install Doom and launch it from Search: window on top, quit returns to tmux
free -m
```
