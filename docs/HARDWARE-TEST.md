# Hardware test build

This document describes the UI test image and what to check on the Cardputer
Zero. The normal image is the clean base; this build installs the UI package so
the device boots straight into cage + foot + tmux.

## Build

```sh
make verify UI_TEST=1 \
  UI_APPS_REPO_STABLE=https://github.com/jmas/cpzos-apps/releases/download/apps-stable
```

The UI build requires the app repository: it installs `cpz-system-apps` and
bakes the current `cpz-apps-catalog`. For a local test repository use
`UI_APPS_REPO_STABLE=file:///...`: the directory is copied into the image at
`/opt/cpz/apps-repo`, so Apps Manager can install apps offline. The Makefile
translates a host path under the source tree to `/work/...` inside the builder,
so `file://$PWD/out/apps-repo` works as written. That repository is unsigned
and the image is a test image; never ship it.

The build:

1. builds `out/ui/packages/stable/cpz-ui-*.pkg.tar.*` with `makepkg`;
2. installs the base, the vendor modules and the UI package into the rootfs;
3. writes `out/cpz-arch-0.1.0-cm0-ui.img` and `.img.zst`.

The UI test image is larger than the base (1536 MiB root geometry) and is
marked with the `-ui` suffix. It is not the release base image.

## Flash and access

- Give the card its space first: `tools/card-image.sh
  out/cpz-arch-0.1.0-cm0-ui.img` writes `...-sdcard.img` with the root partition
  extended to the card; `tools/flash-card.sh` writes and verifies it on macOS.
- After the first boot: `sudo resize2fs /dev/mmcblk0p2` grows the filesystem.
- Or flash `out/cpz-arch-0.1.0-cm0-ui.img` with Raspberry Pi Imager,
  balenaEtcher or `dd`.
- Serial: `ttyS0` at 115200 baud.
- SSH: wired Ethernet or USB Ethernet, DHCP, user `cpz` / password `cpz`.

Keep the serial console attached during the first boot. If the panel stays
dark, serial is the only diagnostic path.

SSH is enabled by default (`ENABLE_SSH=1`). Host keys are generated at build
time, so the first connection does not wait for `sshdgenkeys`. The test image
keeps a persistent journal for post-mortem logs; the clean base image keeps the
volatile journal.

If the IP is unknown, use serial:

```sh
ip -4 addr
networkctl status
systemctl status sshd
journalctl -b -u sshd
```

From another machine:

```sh
ssh cpz@<device-ip>
journalctl -b -1
journalctl -b -1 -u cpz-ui@tty1
journalctl -b -1 -u cpz-tmux
```


## Expected boot

```text
firmware
  → kernel (no initramfs)
  → systemd
      ├─ cpz-tmux.service    persistent tmux server on tty1
      └─ cpz-ui@tty1.service cage + foot + tmux
            └─ Home tab (installed apps)
```

The first visible frame should be the tmux status row and the Home list.
`Alt+O` opens Apps Manager, `Alt+T` opens a new Home tab, `Alt+W` closes it.
Choosing an app in Home replaces the tab and renames it.

## Checks

### Display

- Panel: 320×170, readable text, no flicker, no tearing on scroll.
- HDMI: monitor is detected at boot; the panel backlight turns off.
- Output selection: HDMI when connected, panel otherwise. Hotplug is dynamic:
  `cpz-output.service` darkens the panel, stops the session, terminates cage
  and starts it again on the new card; tmux survives. A graphical app cannot
  survive the compositor restart. A one-shot 10-second post-boot timer catches
  startup races.
- Panel backlight: visible at boot; `sudo /usr/lib/cpz/backlight status` shows
  the m5ioe1 registers.
- Seat policy: both the panel DRM card and the internal keyboard must be on
  `seat0`:

```sh
cat /etc/udev/rules.d/99-cpz-display.rules
cat /etc/udev/rules.d/99-cpz-input.rules
loginctl seat-status seat0
udevadm info /sys/class/drm/card1 2>/dev/null | grep -E 'ID_SEAT|ID_PATH'
udevadm info /dev/input/event0 2>/dev/null | grep -E 'ID_SEAT|ID_PATH'
```

The vendor `99-cardputer-zero-lcd.rules` and
`99-cardputer-zero-keyboard.rules` must be absent; they put the devices on
`seat-cardputer-zero`, which cage cannot see.

### Input

- Matrix keyboard produces events at the login prompt and in tmux.
- `Alt+Shift` switches `us`/`ua` layout without restarting the terminal.
- `Alt+O`, `Alt+T`, `Alt+W`, `Alt+Left/Right`, `Alt+1..9` work.
- Function/Sym keys do not stick or repeat.

### Session

- `tmux -L cpz list-sessions` shows exactly `main`.
- `tmux -L cpz list-keys -T root | grep C-b` shows nothing; `C-a` is the
  fallback prefix.
- There is no session chooser, rename or new-session UI.
- `systemctl restart cpz-ui@tty1.service` returns to the same tmux tab.
- Quitting any app returns to Home in the same tab and working directory.
- Closing the last tab brings back a fresh Home tab; cage does not restart.
- `tmux` survives a cage restart.

### Applications

- Home lists Apps Manager, Settings, Terminal and installed catalog apps; it
  does not list itself, Foot, Foot Client, Foot Server or Help.
- Home lists only what is installed. A catalog app that was never installed
  (for example Doom on a fresh image) is absent from Home and appears in Home
  only after Apps Manager installs it.
- Typing a letter in Home starts search; a Shift letter is inserted as the
  first character. While the field is focused, `F`/`X`/`Z`/`C` type letters.
- `Enter` on Terminal runs a shell in the tab and renames it. Typing echoes
  normally, arrows and backspace work. Exiting the shell returns to Home in the
  same tab; the screen never goes black.
- `Enter` on Doom shows `Starting Doom…` in the status line at once, before the
  game window appears; quitting Doom clears the status and returns to Home. A
  game that cannot start shows the reason instead of a dead key.
- While Doom is still loading, `Enter` on another app in the same tab shows
  `Wait for Doom to start` and starts nothing. In a second Home tab, choosing
  Doom shows `Doom is already running` and no second window appears. After Doom
  quits, both tabs can launch it again.
- `Alt+O` opens Apps Manager; it reads the baked catalog without network.
- Settings opens on `Update system`, `About system`. `Update system` asks
  first with **No** focused, then shows `Updating system…` and ignores keys
  until the transaction ends. Success shows `Updated; restart for a new UI`;
  a failure shows the first pacman error line. The update includes `cpz-ui`,
  `cpz-system-apps` and `cpz-apps-catalog`; `linux-rpi` and
  `raspberrypi-bootloader` stay pinned to the image.
- Apps Manager opens on a menu: `Update app list`, `Installed`, and the
  non-empty categories. `Enter` opens a category, `Esc` goes back.
- Inside a category, `F`/`X` move, `Typing` or `Tab` searches, `Enter` opens
  the detail screen. Installing asks first, then runs the full `pacman -Syu`
  transaction; removing asks with **No** focused.
- Removing Home, Apps Manager, Settings or the catalog is refused.
- `cpz-app apps install <pkg> --yes` works over SSH; without `--yes` it exits 3.
- `cpz-app settings update --yes` works over SSH; without `--yes` it exits 3
  and touches nothing.
- The catalog date is visible on `Update app list`; entering Apps Manager
  refreshes it in the background and never blocks input. `Update app list`
  forces the refresh; the automatic attempt is limited to once per 10 minutes.
- A test image must use a `file://` app repository so the build bakes it into
  `/opt/cpz/apps-repo`. An `http://` URL points at the build host: when that
  server stops, update and install fail with `Could not connect to server`.
  Check `cat /etc/pacman.d/cpz-apps.conf` and `ls /opt/cpz/apps-repo` first.
- `CPZ_LANG=uk cpz-app apps` shows Ukrainian strings; the default is English.
- `desktop-file-validate` passes for the four system entries.
- Terminal starts a login shell in the current tab (from Home) or a new tab
  (from Apps Manager); `Alt+W` closes it and Home returns if it was the last
  tab; it cannot be removed from Apps Manager.

### Status and notifications

- The tmux status row shows battery, network and clock.
- `/run/cpz/status` contains `battery=`, `network=`, `clock=`.
- `sudo /usr/lib/cpz/notify "test"` shows a transient tmux message.

### Audio, battery, network

- `aplay -D default` reaches the ES8389 speaker; `aplay -D
  hw:CARD=ES8389Audio,DEV=0` does too. Doom and the emulators have sound. The
  session runs `/usr/lib/cpz/audio`, which sets the DAC level and connects the
  `Speaker Switch` DAPM pin; check it with `amixer -c ES8389Audio contents`
  and `journalctl -b -t cpz-audio`. HDMI audio is selected explicitly by an
  app, not by the default.
- Battery percentage matches the gauge.
- Wired DHCP works; `sshd` accepts `cpz`.
- SSH and serial remain usable while the UI is running.

### Recovery

```sh
systemctl stop cpz-ui@tty1.service
systemctl status cpz-ui@tty1.service
journalctl -b -u cpz-ui@tty1.service
journalctl -b -u cpz-tmux.service
/usr/lib/cpz/backlight status
cat /etc/cpz/platform.conf
```

If the panel is dark but serial works, collect `dmesg`, `ls /sys/class/drm`,
`lsmod`, and the two unit journals.

```sh
dmesg | grep -iE 'panel|st7789|mipi|drm'
ls -l /dev/dri /dev/input/by-path
lsmod | grep -E 'panel|st7789|m5ioe1|spi_bcm2835'
cat /sys/class/drm/card*-*/status
cat /sys/class/drm/card*-*/modes | head
sudo /usr/lib/cpz/backlight status
udevadm info /sys/class/drm/card1 2>/dev/null | grep -E 'ID_SEAT|ID_PATH'
```


## Budgets

Measure at least five cold boots:

```sh
systemd-analyze
systemd-analyze blame
journalctl -b -o short-monotonic
```

Record first-frame time, UI core RSS, idle wakeups and key-to-paint latency.
The agreed budgets are in `docs/UI-QUALITIES.md`: first frame ≤ 12 s (stretch
10 s), UI core RSS ≤ 64 MB, idle wakeups ≤ 5/min, key 50/100 ms.

## Known gaps

- HDMI hotplug switching is implemented but needs validation with a real
  monitor; the 2-second cooldown is intentional.
- The notification daemon and theme tokens are not implemented.
- Locale catalogs cover the core entries; the full 11-language set is later.
- The panel SPI workaround and backlight are hardware-specific and need
  validation on the device.
