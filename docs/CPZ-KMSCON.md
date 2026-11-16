# CPZ kmscon phase 0

This branch replaces the desktop/APPLaunch boot path with a kmscon + tmux
session. It is intentionally a **phase 0 feasibility image**:

```text
firmware splash
  → kmscon on tty1
  → autologin as uid 1000
  → tmux with a top status bar
  → tty2 kmscon login for recovery
```

Sway, Greetd, foot, the desktop stages and the launcher app debs are not
installed.

## Build

```sh
cp config.cpz.example config
sudo ./build.sh
# or on macOS with Docker:
./build-docker.sh
```

The image should contain:

```text
/usr/bin/kmscon
/etc/kmscon/kmscon.conf
/usr/local/bin/cpz-kmscon
/usr/local/bin/cpz-login
/etc/profile.d/cpz-session.sh
/etc/tmux.conf
/etc/systemd/system/kmsconvt@tty1.service.d/10-cpz.conf
```

Enabled:

```text
kmsconvt@tty1.service
kmsconvt@tty2.service
```

Masked/disabled:

```text
getty@tty1.service
getty@tty2.service
userconfig.service
NetworkManager-wait-online.service
apt-daily.timer, apt-daily-upgrade.timer, man-db.timer
unattended-upgrades.service
```

## Hardware checks

Run these on a real CM0 before adding the CPZ bar/settings layer:

```sh
# panel and HDMI
# console font/rotation
# keyboard input
sudo evtest                 # verify Fn key codes
# Ctrl+Alt+F2 → tty2 login
# DPMS blank/wake after 30s
# boot time and idle RAM
free -m
systemd-analyze
journalctl -u kmsconvt@tty1 -b
```

If kmscon cannot drive the panel, HDMI or keyboard reliably, stop here and
fall back to the Sway backend. Do not build the rest of the CPZ UI on an
unproven console layer.

## Known phase 0 limitations

- No CPZ bar daemon yet; tmux's native status line is used.
- No CPZ settings/alerts/hotkeys yet.
- No images/video/GUI apps.
- kmscon palette is static; CPZ theme integration comes in phase 1/2.
- `rpi-preseed` and SSH are installed, but first-boot testing is part of phase 5.

See [M5-IMAGER.md](M5-IMAGER.md) before publishing an OS-list entry: M5 Imager
does not accept `rpi-preseed` and needs `init_format: "systemd"`.
