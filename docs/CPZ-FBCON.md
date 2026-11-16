# CPZ terminal session (fbcon)

This branch is the terminal-only CPZ image. It replaces the desktop and
APPLaunch boot path with a Linux fbcon console + tmux session. The desktop
stages, NOOBS, cloud-init and full-image extras are not present in this branch.
It is the regular CPZ image:

```text
firmware splash
  → getty on tty1 (internal panel, fb1)
  → autologin as uid 1000
  → tmux with a top status bar
  → HDMI connect: tty1 moves to HDMI (fb0) with a mode-appropriate console font
    and the internal panel is switched off
  → HDMI unplug: tty1 returns to the panel immediately (hotplug uevent)
  → tty2/tty3 getty logins for recovery
```

kmscon is not installed: it cannot reliably drive the SPI panel (kmscon 10
loses DRM master when the panel card has no display at boot and fails to
re-acquire it on hotplug). fbcon is the console.

Sway, Greetd, foot, the launcher app debs and the desktop/full stages are not
installed or present in this branch.

## Build

```sh
cp config.cpz.example config
sudo ./build.sh
# or on macOS with Docker:
./build-docker.sh
```

The image should contain:

```text
/usr/local/bin/cpz-settings
/usr/local/bin/cpz-status
/usr/local/bin/cpz-getty
/usr/local/bin/cpz-first-login
/usr/local/bin/cpz-apply-settings
/usr/local/bin/cpz-console-theme
/usr/local/bin/cpz-hdmi-console
/usr/local/bin/cpz-display-toggle
/usr/local/bin/cpz-conn-status
/usr/local/bin/cpz-session-save
/usr/local/bin/cpz-session-restore
/usr/local/sbin/cpz-font-blocks
/usr/local/sbin/cpz-font-scale
/etc/systemd/system/cpz-session-save.service
/etc/systemd/system/cpz-session-save.timer
/etc/systemd/system/cpz-hdmi-console.service
/etc/systemd/system/cpz-hdmi-console.timer
/etc/udev/rules.d/99-cpz-hdmi-console.rules
/etc/systemd/system-sleep/cpz-hdmi
/usr/bin/nmtui
/etc/polkit-1/rules.d/50-cpz-networkmanager.rules
/etc/systemd/system/getty@tty1.service.d/10-cpz-autologin.conf
/etc/cpz/settings.conf
/etc/cpz/themes/*.conf
/etc/profile.d/cpz-session.sh
/etc/tmux.conf
/etc/default/console-setup        # Terminus 6x12
```

`cpz-getty` resolves uid 1000 at service start and starts `agetty --autologin`,
so `getty@tty1` reaches the tmux session without a password prompt. The first
local console login after flashing runs `cpz-first-login`: while `/etc/shadow`
still has the build-time mtime, it requires `passwd` before the session starts.
An Imager or `rpi-preseed` password change clears the gate automatically.
tty2 and tty3 keep normal getty logins for recovery.

Enabled:

```text
getty@tty1.service, getty@tty2.service, getty@tty3.service
cpz-hdmi-console.timer
cpz-conn-status.timer
cpz-session-save.timer
cardputerzero-keymap.service
cpz-keyboard-layout.path
cpz-bt-agent.service
bluetooth.service
NetworkManager.service
rpi-preseed.service
rpi-preseed-runcmd-early.service, rpi-preseed-runcmd-late.service
```

Masked/disabled:

```text
userconfig.service
NetworkManager-wait-online.service
apt-daily.timer, apt-daily-upgrade.timer, man-db.timer
unattended-upgrades.service
```

## Session layout and keys

The top row is the tmux status bar: `current / total` working tabs on the left
(Settings is a maintenance window and shows as `S / N` while focused); on the
right, the selected language layout (`US`, `UA`, ...), optional output volume
(`V2`, or `VM` while muted) and panel brightness (`B0`-`B10`), battery,
connection indicators, optional date, and clock. Volume and brightness are off
by default and can be enabled under Settings → Status Bar. The battery level
uses the theme colour while healthy, turns yellow at 40% or below and red at
20% or below; the volume and brightness tokens are kept separate so the
readings cannot be confused. The internal CardputerZero map is an overlay on
that layout, so the status bar keeps showing the language instead of a separate
`CPZ` marker. The indicators are `E`/`E+` for Ethernet present/connected, `W`/`W+`
for Wi-Fi radio on/connected and `B`/`B+` for Bluetooth powered/connected.
An indicator is only shown while its interface exists **and is switched on**:
turning Wi-Fi or Bluetooth off (or removing the adapter) hides the token
entirely, while a radio that is on but has nothing connected still shows the
plain `W`/`B` (Ethernet likewise shows `E` with the cable unplugged).
Settings → Status Bar → **Network Indicator** is the master switch;
Ethernet, Wi-Fi and Bluetooth can then be hidden individually. Ethernet is
hidden by default. `cpz-conn-status.timer` refreshes them every 30 seconds;
`cpz-status` only reads the cached value and filters it by the per-interface
settings. The date is off by default and can use `MM-DD`,
`YYYY-MM-DD`, `DD.MM.YYYY` or `MM/DD/YYYY`; the right side grows automatically
for the longer formats. Window 1 is always the shell and the last window is
always Settings, which runs the `cpz-settings` TUI. `cpz-session-ensure`
re-creates either window if it disappears.

`fbcon=map:10` maps tty1 to fb1 (internal panel) and tty2 to fb0 (HDMI), but
fbcon does not clone one console to both outputs. `cpz-hdmi-console.timer`
runs a reconciler every two seconds, and a DRM hotplug uevent starts it
immediately:

- HDMI connected with a readable EDID: `con2fbmap 1 0` moves the **active
  tty1 console** to fb0. The console font is selected from the **actual
  framebuffer size** and auto mode keeps **about 25 rows** instead of the old
  33, so the UI is larger on both a 1080p monitor and a 4K TV. The packaged
  Terminus fonts stop at 16x32, so `cpz-font-scale` derives a larger cell size
  (for example 22x44 at 1080p, 28x56 at 1440p and 42x84 at 4K) in `/run`. A DRM
  fallback mode gets the same row count instead of one giant 40x15 grid.
  Settings → Display & Brightness → **HDMI Text Size** can pin a specific cell
  size (32x64 down to 6x12) instead of `Auto`.
  The internal panel is cleared and its backlight is switched off, so only the
  external screen is lit. If HPD is asserted but the connector EDID is empty
  (common while a Dell monitor is in standby), auto stays on the panel instead
  of blanking both screens; set **Output → HDMI** to force it if needed. A
  pinned `video=HDMI-A-1:<mode>` counts as readable: the pin is an explicit
  choice to stop depending on DDC, so an empty EDID does not move the console
  back to the panel.
- HDMI disconnected: tty1 moves back to fb1, the font returns to the panel
  size (**Panel Text Size**, 6x12 by default, 8x16 for larger glyphs) and the
  saved backlight brightness is restored.
- Settings → Display & Brightness can force `panel` or `hdmi`; `auto` follows hotplug. A
  forced HDMI mode falls back to the panel while no monitor is attached.
  Forcing the panel leaves HDMI usable for the tty2/tty3 recovery consoles.

The tmux session, tabs and state are unchanged; only the console it is drawn on
moves. tty2 and tty3 remain plain recovery logins (`Ctrl+Alt+F2`/`F3`, or
SSH).

The reconciler measures the **real** console geometry (`stty size` on tty1) on
every tick and compares it with the geometry the current framebuffer mode and
selected font should produce. The font is re-selected whenever the framebuffer
size changes, so a DRM fallback mode gets a smaller font and a usable grid
immediately rather than waiting for the monitor to renegotiate. If a modeset,
an fbcon font fallback to 8x16, a VT switch or a suspend has left the console
with the wrong scale, both the mapping and the font are re-applied on the next
tick. The state file records the selected output, the last geometry and a retry
counter; it is never used as a "nothing to do" flag, so drift cannot persist
until the next hotplug event.
`journalctl -t cpz-hdmi-console` shows re-applies and geometry mismatches.

HPD is debounced in the HDMI direction only: two consecutive samples are
required before moving to HDMI, because a Dell monitor can pulse HPD or
renegotiate the mode while it powers up. Returning to the panel is immediate:
the internal panel is always usable, and waiting leaves both screens dark
after the cable is pulled. The udev rule `99-cpz-hdmi-console.rules` queues
`cpz-hdmi-console.service` on the kernel hotplug uevent (`systemctl
--no-block`), so the panel comes back as soon as the disconnect is reported
instead of on the next timer tick. If an HPD pulse is transient, the HDMI
debounce limits the result to one quick panel flash instead of a switch loop.

Inactivity blanking deliberately does **not** send DPMS powerdown. The console
turns black but the HDMI link keeps its sync, which prevents the monitor from
renegotiating resolution on wake. On the blank→unblank transition
`cpz-hdmi-console` forces a font/mapping re-apply and tmux resize. If you do not
want the screen to blank at all, set **Screen timeout** to **never** (0).

If the monitor keeps HPD asserted while it is powered off, the Pi cannot tell it
is off. Press **Alt+D** to toggle between the panel and automatic selection
(the panel lights up immediately), use **Settings → Display &
Brightness → Output → CPZ panel**, or as a manual fallback:

```sh
sudo systemctl stop cpz-hdmi-console.timer
sudo cpz-hdmi-console --panel
# later:
sudo systemctl start cpz-hdmi-console.timer
```

`--hdmi` forces the other direction. `--force` re-applies the mapping and font
even when the geometry looks correct; the suspend hook uses it. If the monitor
comes back from standby blank or with a stale link, cycle the HDMI output once:

```sh
sudo cpz-hdmi-console --recover
```

A fixed HDMI mode is the most reliable cure for mode renegotiation. Set it at
build time (empty means “use EDID”):

```sh
CPZ_HDMI_VIDEO="HDMI-A-1:1920x1080@60"
```

or add the same token to `cmdline.txt` manually. Do **not** use
`video=HDMI-A-1:D`: forcing HPD always-connected would make the console keep
the panel off even when the monitor is powered down.

The pin also satisfies the EDID guard. While a real mode is pinned on the
connected HDMI connector, an empty connector EDID does not move the console
back to the panel, and the next boot comes up at the pinned mode instead of the
1024x768 fallback. `cpz-hdmi-console --status` reports the active token as
`HDMI pin:`.

### Diagnosing display/scale problems

`cpz-hdmi-console` logs only when it changes something, plus `con2fbmap`
failures, an empty-EDID episode and a fallback-mode warning, so the journal
stays quiet while the display is stable:

```sh
journalctl -t cpz-hdmi-console -f
```

A healthy correction looks like:

```text
apply fb0 size=1920,1080 font=Lat15-Terminus22x11-22x44.psf.gz before=14 53 expected=24 87 after=24 87 attempt=0
```

`before` is the measured console grid before the fix, `expected` is what the
selected framebuffer + font should produce, and `after` is what fbcon settled
on. Reading the lines:

- `before=20 5 ... after=14 53` — the 16x32 HDMI font was still active on the
  panel; the helper corrected it.
- `apply fb0 size=1024,768 font=Lat15-Terminus32x16.psf.gz ... expected=24 64`
  — the real mode has no room for the 22x44 font used at 1080p, so auto kept
  the packaged 16x32 cell and produced a 64x24 grid instead of the old 85x32
  one. At 640x480 the helper selects 10x20 (64x24) rather than leaving a
  nearly unusable 40x15 grid.
- `apply ... after=20 5` then `still ... expected 14 53` — `setfont` did not
  take effect. Look for `setfont ... failed`, `setfont is not installed` or
  `console font ... is missing` immediately before/after it.
- `con2fbmap tty1 fb0 failed` — the HDMI framebuffer is not registered (mode
  or EDID problem); the panel is intentionally left alone so the console does
  not disappear.
- `accepting stable geometry` — the VT never reached the computed size after
  two attempts. This is usually a padded `virtual_size`, not a broken display;
  the helper stops re-applying to avoid flicker.
- No log line while the scale is visibly wrong — the console grid is correct
  and the problem is above fbcon (tmux client/window size, see below).

Inspect the live state without changing anything:

```sh
sudo cpz-hdmi-console --status
```

The status prints the decision as well as the result. `HDMI pin` shows the
active `video=` token or `none`; `auto decision` explains why the automatic
choice landed on HDMI or the panel (`EDID readable`, `pinned video= mode`,
`HDMI connected, EDID unreadable`, or `HDMI disconnected`); `output override`
appears instead when a CLI/settings choice is active; and `pending switch`
appears only while the HDMI-direction hotplug debounce is counting samples. A
`target` that differs from `state` plus a `pending switch` line means a switch
to HDMI is in progress, not that the mapping failed. Returning to the panel is
not debounced, so it does not show a `pending switch` line.

Watch the kernel side (hotplug, modeset and the fbcon console size):

```sh
journalctl -kf -g 'drm|hdmi|vc4|fbcon|Console'
```

`Console: switching to colour frame buffer device 87x24` is the 1080p HDMI
grid; `53x14` is the panel. Seeing `14x3` on the panel means the HDMI font is
still active there.

`hdmi-audio-codec.*: HDMI: Unknown ELD` is **not a display error**. The HDMI
audio codec calls `snd_parse_eld()` when userspace opens the HDMI PCM
(PipeWire probes it) or on hotplug; version 0 means the sink supplied a blank
ELD, so it has no usable audio capabilities. This is normal with monitors
without speakers, DVI adapters, or a monitor that is asleep at open time. Video
mode and console scale are unaffected. If HDMI audio matters, check
`/proc/asound/card*/eld#*` and the connector EDID:

```sh
cat /proc/asound/card*/eld#*
cat /sys/class/drm/card*-HDMI-A-*/edid | edid-decode
```

An empty connector EDID is a display/EDID problem (fallback mode, renegotiated
scale); a valid EDID without an Audio Data Block explains the ELD message and
is harmless for video.

Useful raw state:

```sh
cat /sys/class/drm/card*-HDMI-A-*/status
cat /sys/class/graphics/fb*/name /sys/class/graphics/fb*/virtual_size
stty -F /dev/tty1 size
cat /run/cpz-hdmi-console.state
cat /sys/class/backlight/*/brightness /sys/class/backlight/*/bl_power
```

If the console grid is correct but the text still looks wrong, compare tmux
with the console (as the logged-in user):

```sh
tmux display-message -p '#{client_width}x#{client_height}'
stty size
```

To reproduce an apply without the timer fighting manual tests:

```sh
sudo systemctl stop cpz-hdmi-console.timer
sudo cpz-hdmi-console --force
sudo cpz-hdmi-console --status
sudo cpz-hdmi-console --recover   # if the link came back blank
# ...
sudo systemctl start cpz-hdmi-console.timer
```

If `--status` shows `HDMI is 1024x768, monitor prefers 1920x1080`, the mode is
a DRM fallback. The helper now selects a smaller font for that framebuffer so
the TUI remains usable, but the monitor still upscales the signal and a 4:3
mode remains geometrically distorted on a 16:9 panel. Pin the mode with
`CPZ_HDMI_VIDEO` (or `video=` in `cmdline.txt`) for a native, sharp picture.

### Dell monitor patterns

Searches for “Dell monitor turns off / wrong resolution after wake” show the
same handful of monitor-side behaviours across GPUs and drivers. They are not
CPZ-specific, but they explain what the console reconciler can and cannot fix:

- **HPD stays high in standby** — the monitor is off but the OS still sees
  `connected`, so it keeps driving HDMI. This is the case Alt+D exists for.
  Examples: [Ubuntu discourse](https://discourse.ubuntu.com/t/hdmi-monitor-turned-off-but-system-behaves-as-if-its-on/53770),
  [Unix SE](https://unix.stackexchange.com/questions/61857/detect-if-hdmi-monitor-is-switched-off).
  The EDID guard covers the variant where DDC is also unreadable while HPD
  remains high; a pinned `video=` mode deliberately bypasses that guard.
  If the monitor is awake but its DDC is flaky, pin the mode and use
  `display=hdmi` instead of fighting the guard.
- **HPD gets stuck low after resume/power cycle** — another machine needed
  `video=HDMI-A-2:D` to work around a stuck HPD bit:
  [Dell XPS 8940 + i915](https://www.dell.com/community/en/conversations/linux-general/xps-8940-hdmi-monitor-disconnected-after-sleep-s3-on-linux/6a81c21f260d6e8070f12fbe).
  On CPZ prefer a fixed mode (`video=HDMI-A-1:1920x1080@60`) over `:D`;
  forcing `:D` would also defeat the “panel off while HDMI is active” policy.
- **Only 640x480/1024x768 after standby** — the driver re-reads a broken mode
  list until a replug. Examples:
  [NVIDIA + KDE bug 488201](https://bugs.kde.org/show_bug.cgi?id=488201),
  [Dell E2416H stuck at 1024x768](https://www.dell.com/community/en/conversations/monitors/e2416h-linux-stuck-in-wrong-resolution/647f6cd3f4ccf8a8dea07968).
  The console font can be right for that fallback mode and still look “wrong”;
  `cpz-hdmi-console --status` shows the real framebuffer size.
- **Dell HDMI EDID quirks** — e.g. the U2711 does not advertise its full
  resolution over HDMI (DP/DVI work):
  [u2711-hdmi-linux](https://github.com/EdJoPaTo/u2711-hdmi-linux),
  [RPi forum U2711](https://forums.raspberrypi.com/viewtopic.php?t=273548).
  The fix is a different input or an EDID override, not a console font change.
  Dell also documents older HDMI ports being limited to 1920x1080/1200:
  [Dell KB 000126548](https://www.dell.com/support/kbdoc/en-us/000126548/resolution-on-external-monitor-limited-to-1920-x-1080-using-hdmi).
- **Input auto-selection / DPMS** — Dell **Auto Select** can move away from
  HDMI after the source sleeps, and **PowerNap/Deep Sleep** can make DPMS
  unreliable: [U2723QE DPMS](https://www.dell.com/community/en/conversations/monitors/u2723qe-does-not-standby-on-dpms-off/65d00b15b595411ad6cdebad),
  [U2723QE input switching](https://community.spiceworks.com/t/dell-monitor-u2723qe-keeps-switching-from-displayport-to-hdmi-after-pc-lock-unlock/1245289).
  Set the input source manually and disable Auto Select / PowerNap / Deep Sleep
  while diagnosing.
- **Random HDMI blanking reports** — e.g.
  [P2421D](https://www.dell.com/community/en/conversations/inspiron/external-monitor-turning-on-and-off-while-connected-via-hdmi-to-an-inspiron-7580/647f9930f4ccf8a8dec75af0)
  (the reporter said Linux was fine). Treat these as cable/link/monitor firmware
  until the logs say otherwise.

Before/after a monitor power cycle, compare:

```sh
wc -c </sys/class/drm/card0-HDMI-A-1/edid
cat /sys/class/drm/card0-HDMI-A-1/modes
cat /sys/class/graphics/fb0/virtual_size
```

If the EDID size drops to 0 while `status` stays `connected`, the Pi cannot
tell that the monitor is off; if the mode list shrinks to a fallback mode, the
kernel has renegotiated. Pinning the mode keeps both the resolution and the
automatic output on HDMI; otherwise force `display=hdmi` or override the EDID.

If the large display keeps renegotiating modes, force a stable HDMI mode in
`cmdline.txt` (use a mode the monitor supports), or set `CPZ_HDMI_VIDEO` in
the build config:

```text
video=HDMI-A-1:1920x1080@60
```

On resume from suspend, `/etc/systemd/system-sleep/cpz-hdmi` runs
`cpz-hdmi-console --force`, which re-applies the mapping/font and resizes tmux.

`consoleblank=0` is added to the kernel command line so fbcon does not blank
the console after ten minutes of inactivity. That blanking is the other common
cause of a display that “randomly” turns off until a key is pressed.

| Key | Action |
| --- | --- |
| `Alt+Left` / `Alt+Right` | previous / next tab |
| `Alt+1` … `Alt+9` | select tab |
| `Alt+T` | new tab (inserted before Settings) |
| `Alt+W` | close tab (asks; tab 1 and Settings stay open) |
| `Ctrl-b c` | new tab (inserted before Settings) |
| `Ctrl-b n` / `Ctrl-b p` | next / previous tab |
| `Ctrl-b 0` … `Ctrl-b 9` | select tab by number |
| `Ctrl-b ,` | rename tab |
| `Ctrl-b &` | close tab (asks; same path as `Alt+W`) |
| `Ctrl-b w` | list tabs |
| `Ctrl-b %` / `Ctrl-b "` | split pane left/right or top/bottom |
| `Ctrl-b o` | next pane |
| `Ctrl-b z` | zoom pane |
| `Ctrl-b x` | close pane (asks) |
| `Ctrl-b {` / `Ctrl-b }` | swap pane with previous / next |
| `Ctrl-b [` | scroll/copy mode (vi keys) |
| `Space`, `Enter` | start selection, copy it (in copy mode) |
| `q` | leave copy mode |
| `Ctrl-b ]` | paste a tmux buffer |
| `Ctrl-b d` | detach |
| `Ctrl-b ?` | every tmux key |
| `Alt+S` | jump to Settings |
| `Alt+H` | key help popup |
| `Alt+Space` | switch input layout (external keyboard) |
| `Alt+D` | toggle CPZ panel / auto display |

Closing a tab asks first because it kills every process in it. `cpz-tab-close`
refuses tab 1 and Settings: `cpz-session-ensure` re-creates them anyway, so
closing them would only replace the running shell with a fresh one. Closing the
active tab moves to the neighbouring one, and the kill hooks save the remaining
layout.

`Alt+H` opens the same list in a popup. The list is taller than the 53x14 panel,
so `cpz-help` pages it with `less` (`Up`/`Down`, `q` to close).

Each attach shows a one-line hint with the main bindings.

### Session persistence

The tab layout is saved to `~/.local/state/cpz/session.tsv`: window names,
active-pane working directories and the active tab. tmux hooks save on
new/kill/rename/select/detach, and `cpz-session-save.timer` saves every five
minutes as a fallback.

On the next tty1 login after a reboot, `cpz-session-restore` recreates the saved
tabs as new shells in their last working directory and keeps the saved tab
names. Settings is not saved; it is always recreated last. Only the active pane
of each tab is saved: pane splits, running programs and scrollback cannot
survive a power cycle and are not restored; only hibernation preserves running
processes.

### Settings menu

`cpz-settings` edits `~/.config/cpz/settings.conf`; the defaults in
`/etc/cpz/settings.conf` are read-only. The main menu is split into submenus so
it fits the 53x14 panel:

- **Network** — Wi-Fi (`nmtui`), Ethernet state and IP, VPN profiles when
  configured, full connection details.
- **Bluetooth** — power On/Off, Scan for Devices, pair/trust/connect,
  disconnect.
- **Display & Brightness** — theme, brightness, screen timeout, output
  (Auto / CPZ panel / HDMI) and the status-bar segments (clock, date, volume,
  brightness, battery, connections, keyboard). Auto follows hotplug and switches
  the panel off while
  HDMI is connected; forcing the panel restores it and leaves HDMI for recovery
  consoles.
- **Sound** — output and input volume, mute and default device (`wpctl`).
- **Keyboard** — layout mode (Auto / CPZ internal / Standard), the enabled
  layouts, the active layout, and the Key Bindings page with hotkeys.
- **Date & Time** — set the system date and time manually, timezone and NTP
  (automatic time sync). The timezone page lists every zone from
  `/usr/share/zoneinfo/zone.tab`. Manual changes prompt for `sudo` and turn NTP
  off.
- **Power** — battery state, reboot, shut down, suspend.
- **Applications** — opens `aptitude`, the Debian ncurses package browser, for
  finding installed packages with their descriptions and removing them.
  Aptitude runs with `Aptitude::Delete-Unused=false`, so removing an
  application does not automatically remove unused dependencies. It can still
  remove core packages; the confirmation warns about this.
- **System** — About (host, kernel, uptime, CPU temperature, memory, load,
  battery, display/HDMI, network addresses, services, autologin and storage
  usage), Resources (live `htop` monitor for CPU, memory, swap, load and
  processes), Security (change password, SSH), Terminal settings, and Reset
  Settings.

Long lists start on the current value and scroll with Up/Down and PgUp/PgDn.
`r` reloads the page (useful after changing the layout with `Alt+Space`), `q`
or Esc goes back, and `q` on the main page closes Settings. When the image's
factory password is still unchanged (`/etc/cpz/shadow-mtime` matches
`/etc/shadow`) or the SSH server is running, the main page replaces its header
rule with a reversed `!` warning, for example `! factory password in use + SSH
is on`. Changing the password in **System → Security** or turning SSH off
clears it; `r` rechecks.

The **Terminal** page under System exposes basic tmux options: mouse support,
scrollback, vi/emacs copy keys, status refresh interval, OSC52 clipboard sharing
and automatic window renaming.

Autologin is reported in **System → About** and is intentionally read-only.
Changing it means editing the getty drop-in
`/etc/systemd/system/getty@tty1.service.d/10-cpz-autologin.conf`.

Brightness uses `/sys/class/backlight` and the udev rule
`99-cpz-backlight.rules`, which grants the `video` group write access. While
HDMI is the active output the panel backlight is held off; the saved value is
restored when the session returns to the panel. Screen timeout uses `setterm`
on tty1 to **blank only** (`-powerdown 0`): the HDMI link stays active, so
waking the screen does not trigger a mode renegotiation and scale change.
`cpz-hdmi-console` also detects the blank→unblank transition and re-applies
font/mapping/tmux sizing. Date/time changes, timezone, NTP, SSH and power
actions prompt for `sudo`; password changes use `passwd`.

VPN support lists and activates existing NetworkManager profiles. Importing
OpenVPN/WireGuard profiles needs the corresponding NetworkManager plugin and is
not included in the base image.

### Keyboard layouts

The internal TCA8418 keyboard uses the vendor map
`/usr/share/keymaps/tca8418_keypad_m5stack_keymap.map`. Applying that map
globally breaks a standard USB or Bluetooth keyboard, so
`cpz-keyboard-layout` selects the layout dynamically:

- `auto` (default): external USB/Bluetooth/PS2 keyboard present → the
  selected console layout; otherwise the CPZ TCA8418 map;
- `cpz`: always the CPZ TCA8418 map;
- `standard`: always the selected console layout.

`auto` classifies each `/dev/input/event*` node from sysfs, not from the udev
property database, so boot-time and unplug races cannot leave a stale result:

- `device/capabilities/key` must contain udev's full-keyboard mask (keycodes
  1..31: ESC, the number row and Q to D). Media remotes, mice, touchpads and
  USB receiver dongles do not have it, so they cannot force the standard
  layout by themselves.
- `device/id/bustype` must be USB (`0003`), Bluetooth (`0005`) or PS/2
  (`0011`). Virtual (`uinput`) keyboards are ignored.
- The internal TCA8418 is recognised by its i2c bus (`0018`), the
  `cardputer-zero-internal` udev symlink, the `3f804000.i2c` device path, or
  its name.

If both keyboards are connected, the external one takes precedence.

Check what the detector currently sees with:

```sh
cpz-keyboard-layout --detect          # external or internal
cat /run/cpz-keyboard-layout.log      # candidates and the reason each was ignored
cat /sys/class/input/event*/device/capabilities/key
systemctl status cpz-keyboard-layout.path   # hotplug watcher
```

If `--detect` reports `external` with no external keyboard attached, unplug the
USB/Bluetooth receiver, or force the internal map with Settings → Keyboard →
**Layout Mode** = `CPZ`; the choice is saved for the next boot.

The mode is in Settings → Keyboard. **Layouts** opens a checklist
of every layout packaged in xkb-data (about 99, including English US/UK,
Ukrainian, Russian, German, French, Spanish, Italian, Polish, Portuguese,
Czech, Swedish, Norwegian, Danish, Finnish, Dutch, Greek, Turkish, Hebrew,
Japanese, Korean and many more), with the common ones first and PgUp/PgDn for
fast scrolling. Every checked layout is available for switching; at least one
stays enabled. **Active Layout** chooses the current one, and **Key Bindings**
lists the `Alt+Space` binding that cycles through them.

Layout keymaps are generated with `ckbcomp` (the same source as
console-setup) and applied with `loadkeys` to tty1–tty3. `Alt+Space` runs
`cpz-layout-next`, which updates `keyboard_layout_active`, reloads the keymap and
refreshes the status bar. The root helper `cpz-layout-apply` is allowlisted in
`/etc/sudoers.d/50-cpz-layout` so switching does not prompt for a password.

The selected layout only changes the standard (external) keyboard. With the CPZ
internal map active, `Alt+Space` still saves the choice for the next external
keyboard, and the status bar shows that language layout (`US`, `UA`, ...).

#### Wrong punctuation on an external keyboard

The CPZ TCA8418 keymap is a **partial overlay** that remaps the internal
keyboard's Sym/Fn keycodes, including keycodes that a standard keyboard uses for
`,` `.` and `/`. If it is left loaded on an external keyboard, punctuation is
scrambled (`&`, `*`, `(` instead of `,` `.` `/`) and `/` appears to be missing.

`cpz-keyboard-layout` now:

- loads a complete layout generated by `ckbcomp` for external keyboards,
- falls back to US and then to console-setup's cached keymap if generation
  fails, rather than leaving the internal overlay active,
- reloads a clean US base before applying the CPZ overlay, so a previously
  selected national layout cannot leak into the internal keyboard.

Diagnose with:

```sh
cat /run/cpz-layout.active          # layout code with an external keyboard, or cpz
cat /run/cpz-keyboard-layout.log    # what was selected/applied
dumpkeys | grep -E '^keycode +(51|52|53) '   # comma, period, slash under US
```

Punctuation follows the selected XKB layout. For example, Ukrainian puts `/` on
the ISO `<`/`>` extra key and `.`,`,` on the `/?` key, which differs from a US
keyboard.

`cardputerzero-keymap.service` runs the selector at boot.
`99-cpz-keyboard.rules` re-runs it when a keyboard is added.
`cpz-keyboard-layout.path` watches `/dev/input` and re-runs it on every input
device change. That is what switches back to the CPZ map when the external
keyboard is unplugged: a udev `remove` rule cannot do it, because systemd
ignores `SYSTEMD_WANTS` on remove events. Bluetooth keyboards that connect or
disconnect after boot are covered by the same path unit.

The right side of the bar is produced by `cpz-status`, which reads the battery
from `/sys/class/power_supply/*/capacity`, the backlight brightness from
`/sys/class/backlight/*`, the output volume from
`wpctl get-volume @DEFAULT_AUDIO_SINK@`, the date/clock settings and the
cached connection indicators. The battery level is colour-coded with the
theme's red and yellow palette entries (see above). No notification daemon
exists yet.

Built-in themes are eight balanced presets: **Tokyo Night** (default indigo
dark), **Catppuccin Mocha** (soft warm dark), **Gruvbox Dark** (warm retro
dark), **Nord** (cool blue-grey dark), **Kanagawa** (muted ink-wash dark),
**GitHub Light** (crisp daylight), plus **Mono** and **Light High Contrast**
as accessibility fallbacks. Each one is tuned for the small CPZ panel, keeps
ANSI red/green/yellow/blue distinguishable, and avoids low-contrast
accent-on-background combinations. A few upstream ANSI shades are nudged in
lightness so every palette entry clears 4.5:1 against the theme background.
Light themes switch the whole tmux window and console background to light.

### Adding themes

Each `/etc/cpz/themes/<name>.conf` is self-describing. A theme can be added by
copying one file into that directory; it appears in Settings automatically:

```tmux
# name: My Theme
set -g status-style "bg=#101418,fg=#e6edf3"
set -g window-style "bg=#101418,fg=#e6edf3"
...
# palette 0=101418
# palette 1=...
# palette 7=e6edf3
# palette 15=ffffff
```

`cpz-settings` reads the `# name:` line for the label. `cpz-console-theme`
prefers the embedded `# palette 0..15` block; if it is absent it falls back to
`<name>.palette` for older themes. `tools/verify-stage.sh` checks every
bundled theme: all text/background pairs must reach at least 4.5:1 contrast, the
embedded palette must match `<name>.palette`, and palette entries 1–15 must stay
legible on the theme background.

Themes set the status bar, the full window/pane background and foreground,
borders, messages and copy-mode selection. A theme change is applied to every
existing tmux window and pane, and tmux's 16-colour pane palette is updated to
the same values as the console palette, so the shell and the Settings TUI show
the same body colours immediately. `cpz-console-theme` also applies the
selected theme's 16-colour palette to the Linux console with the VT OSC P
sequence, so the default background and ANSI colours outside tmux (including
the login prompt) change too. This works as the tty owner and does not need
root.

### Wi-Fi

The Settings menu has **Network → Wi-Fi**. It enables the NetworkManager
radio and opens NetworkManager's `nmtui` for scanning and connecting. `nmtui`
runs in a **tmux popup**, so its alternate-screen/terminal-mode changes cannot
disturb the Settings pane or force a console resize. The first user is in the
`netdev` group and
`/etc/polkit-1/rules.d/50-cpz-networkmanager.rules` allows that group to manage
NetworkManager without a polkit prompt.

If the external display still turns off/on after leaving `nmtui`, the trigger
is outside the TUI: check HDMI HPD/mode changes
(`journalctl -k -b | grep -Ei 'drm|hdmi|vc4'`), `vcgencmd get_throttled`, and the
monitor's own DPMS/Eco/PowerNap settings. A wrong console scale is corrected by
`cpz-hdmi-console.timer` on the next tick; a fixed HDMI mode
(`video=HDMI-A-1:1920x1080@60`) can prevent EDID/mode renegotiation.

If the image was built without `WPA_COUNTRY`, NetworkManager starts with
`WirelessEnabled=false`; the Settings entry turns the radio on. Set
`WPA_COUNTRY` in `config` for the correct regulatory domain. `nmtui` is easiest
on HDMI (the shared session uses the HDMI grid) or over SSH; it is cramped on
the 53x14 panel.

### Bluetooth

**Settings → Bluetooth** has an explicit **Power** row (Enter toggles), a short
scan, and pair/trust/connect or disconnect for the selected device. The first
user is in the `bluetooth` group and `bluetooth.service` is enabled.

`cpz-bt-agent.service` unblocks Bluetooth via `rfkill` and runs BlueZ's
`bt-agent` with the `NoInputNoOutput` capability, so Just Works and
numeric-comparison devices pair without a separate confirmation UI. If a
user-level `bluetoothctl power` is denied, Settings falls back to one `sudo`
prompt (`rfkill unblock bluetooth` + `bluetoothctl power`). Devices that require
a passkey typed on the device may still need `bluetoothctl` manually.

### Font

The console uses Terminus 6x12 (53x14 cells on the 320x170 panel), applied at
boot by console-setup (`FONTFACE="Terminus"`, `FONTSIZE="6x12"`). Settings →
Display & Brightness sets the panel and HDMI sizes independently:

- **Panel Text Size**: `6x12` (default, 53x14 cells) or `8x16` (40x10 cells).
  The 8x16 font is PSF1, so `cpz-font-blocks` cannot append the QR half-block
  glyphs to it; the compact `qrencode -t UTF8` output loses those characters
  while the large panel font is selected.
- **HDMI Text Size**: `Auto (large)`, or a fixed cell size from `32x64` down
  to `6x12`. Auto keeps roughly 25 rows at the real framebuffer size and
  scales a Terminus base font when the packaged sizes are too small (for
  example 22x44 at 1080p). The scaled sizes 32x64, 28x56, 24x48 and 20x40 are
  also selectable explicitly; if the scaling helper or a base font is missing,
  the selection falls back to the packaged Terminus size.

`cpz-hdmi-console` re-applies the console font on its next two-second tick
after a change, so no privileged action is needed from the Settings pane.
Auto-mode scaled fonts are cached in `/run/cpz-console-fonts` and regenerated
on the next boot; only integer scale factors are used so Terminus stays crisp.
Loading a cell taller than 32 pixels uses fbcon's tall-font support
(`KD_FONT_OP_SET_TALL`, kernel 6.9+); the pinned 6.18 kernel and trixie's kbd
support it. A failed load is logged by `cpz-hdmi-console` and leaves the
previously loaded font in place.

The packaged `Lat15-Terminus*.psf.gz` subsets keep U+2588 FULL BLOCK but omit
the half blocks U+2580/U+2584 (and the vertical halves U+258C/U+2590).
Terminal QR renderers such as `qrencode -t UTF8` and
`qrencode -t ANSIUTF8` use those half blocks to fit two QR rows into one
console row, so the missing glyphs appear as replacement characters. The image
runs `cpz-font-blocks` before `setupcon` and appends the four glyphs to the
PSF2 console fonts. Use `qrencode -t ANSIUTF8` (or `-t UTF8`) for a compact
code; `-t ANSI` is font-independent, and `-t ASCII` falls back to `#` squares
at the cost of a much larger code.

### /tmp and memory

`/tmp` is disk-backed: `tmp.mount` is masked and `/tmp` lives on the root
filesystem (`/tmp` is created with mode 1777). The systemd default is a tmpfs
sized from RAM — about 177M on this board — which is too small for npm/opencode
and, if enlarged, consumes RAM until OOM or a watchdog reset.

For a one-off install on an existing image, use `TMPDIR=$HOME/tmp` (or
`/var/tmp`) or mask `tmp.mount` at runtime. Check `free -h`, `swapon --show`
and `zramctl`; if there is no swap, a disk swapfile protects large installs on
this small-RAM board.

## fb_load / DRM ownership

The m5stack `st7789v` driver installs `fb_load.service`, which runs
`/usr/sbin/fb_load --keep-open` early in boot. It displays the static splash
and waits for `APPLaunch`/`LaunchWizard` before exiting. CPZ has no launcher,
so the original service never releases the panel.

`stage2/05-cardputerzero/02-run.sh` disables and removes `fb_load.service` and
its `sysinit.target.wants` symlink. The firmware splash still covers the
pre-terminal screen.

## Debug image

Build a verbose image when the normal session produces a black screen:

```sh
cp config.debug.example config
sudo ./build.sh
# or:
./build-docker.sh -c config.debug.example
```

The debug image:

- removes the firmware splash
- removes `quiet` and `loglevel=3`
- keeps the `fbcon=map:10` mapping (tty1=panel, tty2=HDMI)
- adds `console=tty1 console=serial0,115200 loglevel=8`
- removes the tty1 autologin drop-in
- enables `getty@tty1`/`tty2`/`tty3`
- prevents the CPZ tmux session via `/etc/cpz-debug-boot`

It should show kernel/systemd logs on the panel/HDMI and a login prompt on
tty1/tty2/tty3. If it shows nothing, the failure is before the CPZ UI.

## First boot

`export-image/05-finalise` writes `uninitialized` to `/etc/machine-id` so
systemd treats the image as a first boot and runs `rpi-resize.service`. Do not
bake a real machine-id into the image, or the root partition will not expand on
first boot.

## Hardware checks

Run these on a real CM0 when validating a new image:

```sh
# HDMI hotplug moves the tty1 session to the external display
# console font/rotation
# keyboard input
sudo evtest                 # verify Fn key codes
# Ctrl+Alt+F2 → tty2 recovery login
# Ctrl+Alt+F3 → tty3 recovery login (panel)
# DPMS blank/wake after 30s
# boot time and idle RAM
free -m
systemd-analyze
journalctl -b
```

If the console cannot drive the panel, HDMI or keyboard reliably, stop and
fall back to the Sway backend. Do not build the rest of the CPZ UI on an
unproven console layer.

## Known limitations

- No separate CPZ bar daemon; the tmux status line provides the bar
  (`1 / N`, layout, optional volume/brightness, battery, connections, clock).
- No notification daemon. Settings covers theme, status-bar items, network,
  Bluetooth, sound, display, power, keyboard layouts, date/time, security and
  terminal options.
- No images/video/GUI apps.
- tmux themes change the status bar, window list and pane borders;
  `cpz-console-theme` applies the same 16-colour palette to the console.
- SSH is off by default. Enable `ENABLE_SSH=1` only after changing the factory
  password.

See [M5-IMAGER.md](M5-IMAGER.md) before publishing an OS-list entry: M5 Imager
does not accept `rpi-preseed` and needs `init_format: "systemd"`.
