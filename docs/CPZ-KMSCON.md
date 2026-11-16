# CPZ kmscon session

This branch is the terminal-only CPZ image. It replaces the desktop and
APPLaunch boot path with a kmscon + tmux session. The desktop stages, NOOBS,
cloud-init and full-image extras are not present in this branch. It is
intentionally a **phase 0 feasibility image**:

```text
firmware splash
  → kmscon on tty1
  → autologin as uid 1000
  → tmux with a top status bar
  → tty2 kmscon login for recovery
```

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

## fb_load / DRM ownership

The m5stack `st7789v` driver installs `fb_load.service`, which runs
`/usr/sbin/fb_load --keep-open` early in boot. It displays the static splash
and waits for `APPLaunch`/`LaunchWizard` before exiting. CPZ has no launcher,
so the original service never releases DRM master on the internal panel and
kmscon cannot take over it.

`stage2/05-cardputerzero/02-run.sh` now disables and removes
`fb_load.service` and its `sysinit.target.wants` symlink. The firmware splash
still covers the pre-terminal screen.

## Debug image

Build a verbose image when the normal kmscon session produces a black screen:

```sh
cp config.debug.example config
sudo ./build.sh
# or:
./build-docker.sh -c config.debug.example
```

The debug image:

- removes the firmware splash
- removes `quiet`, `fbcon=map:off` and `loglevel=3`
- adds `console=tty1 console=serial0,115200 loglevel=8`
- masks `kmsconvt@tty1`/`tty2`
- enables `getty@tty1`/`tty2`
- prevents the CPZ tmux session via `/etc/cpz-debug-boot`

It should show kernel/systemd logs on the panel/HDMI and a login prompt on
tty1/tty2. If it shows nothing, the failure is before the CPZ UI.

## First boot

`export-image/05-finalise` writes `uninitialized` to `/etc/machine-id` so
systemd treats the image as a first boot and runs `rpi-resize.service`. Do not
bake a real machine-id into the image, or the root partition will not expand on
first boot.

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
