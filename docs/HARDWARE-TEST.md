# Hardware test build

This document describes the UI test image and what to check on the Cardputer
Zero. The normal image is the clean base; this build installs the UI package so
the device boots straight into cage + foot + tmux.

## Build

```sh
make verify UI_TEST=1
```

The build:

1. builds `out/ui/packages/stable/cpz-ui-*.pkg.tar.*` with `makepkg`;
2. installs the base, the vendor modules and the UI package into the rootfs;
3. writes `out/cpz-arch-0.1.0-cm0-ui.img` and `.img.zst`.

The UI test image is larger than the base (1 GiB root geometry) and is marked
with the `-ui` suffix. It is not the release base image.

## Flash and access

- Flash `out/cpz-arch-0.1.0-cm0-ui.img` with Raspberry Pi Imager,
  balenaEtcher or `dd`.
- Serial: `ttyS0` at 115200 baud.
- SSH: wired Ethernet, user `cpz` / password `cpz`.

Keep the serial console attached during the first boot. If the panel stays
dark, serial is the only diagnostic path.

## Expected boot

```text
firmware
  → kernel (no initramfs)
  → systemd
      ├─ cpz-tmux.service    persistent tmux server on tty1
      └─ cpz-ui@tty1.service cage + foot + tmux
            └─ Home tab
```

The first visible frame should be the tmux status row and a shell prompt.
`Alt+O` opens the application menu, `Alt+T` opens a new tab, `Alt+W` closes it.

## Checks

### Display

- Panel: 320×170, readable text, no flicker, no tearing on scroll.
- HDMI: monitor is detected at boot; the panel backlight turns off.
- Output selection: HDMI when connected, panel otherwise. Hotplug requires a
  restart of `cpz-ui@tty1.service`.
- Panel backlight: visible at boot; `sudo /usr/lib/cpz/backlight status` shows
  the m5ioe1 registers.

### Input

- Matrix keyboard produces events at the login prompt and in tmux.
- `Alt+Shift` switches `us`/`ua` layout without restarting the terminal.
- `Alt+O`, `Alt+T`, `Alt+W`, `Alt+Left/Right`, `Alt+1..9` work.
- Function/Sym keys do not stick or repeat.

### Session

- `tmux -L cpz list-sessions` shows `main`.
- `systemctl restart cpz-ui@tty1.service` returns to the same tmux tab.
- Closing a terminal app returns to the same tab and working directory.
- `tmux` survives a cage restart.

### Applications

- `Alt+O` lists `Terminal` and `Help` from the desktop entries.
- `Terminal` opens a new tmux window.
- A graphical app (if installed) opens over foot and returns on close.
- `desktop-file-validate` passes for installed entries.

### Status and notifications

- The tmux status row shows battery, network and clock.
- `/run/cpz/status` contains `battery=`, `network=`, `clock=`.
- `sudo /usr/lib/cpz/notify "test"` shows a transient tmux message.

### Audio, battery, network

- `aplay`/`mpv` reach the speaker; media keys work.
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

- Output switching is one-shot at session start; live hotplug is not
  implemented.
- The notification daemon and theme tokens are not implemented.
- Locale catalogs cover the core entries; the full 11-language set is later.
- The panel SPI workaround and backlight are hardware-specific and need
  validation on the device.
