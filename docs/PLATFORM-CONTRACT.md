# Platform contract v1

Status: agreed on the `design/app-platform` branch. This document is normative
for the boundary between the base image and the UI package set. The UI app
contract is separate; see [APP-CONTRACT.md](APP-CONTRACT.md).

## 1. Version file

The platform ships `/etc/cpz/platform.conf`:

```ini
platform=1
contract=1
caps=display.panel,display.hdmi,input.matrix,audio,battery,network,storage,serial
```

- `platform` identifies the platform image generation.
- `contract` is the compatibility version of the interfaces below.
- `caps` lists the hardware capabilities that are present.

The platform also writes `/etc/cpz/language`: one UI language code from
[LANGUAGE.md](LANGUAGE.md). The base writes the system default; a user file in
`~/.config/cpz/language` overrides it.

The UI reads the file at session start. It must refuse to start when
`platform` is below its minimum or `contract` is outside its supported range,
and it must say why on stderr (the journal).

## 2. Session entry point

The platform owns the session unit `cpz-ui@.service` (see
`/usr/lib/systemd/system/cpz-ui@.service`). The UI package provides the
executable and enables one instance:

```text
/usr/lib/cpz/session
cpz-ui@tty1.service
```

The unit uses `PAMName=login`, `User=cpz`, `TTYPath=/dev/tty1`,
`StandardInput=tty` and `StandardOutput=tty`. PAM/logind creates the seat and
the user session, so the UI gets DRM, evdev and audio through the normal login
path. The unit is inert until `/usr/lib/cpz/session` exists.

The UI must:

- run as `cpz`, never as root;
- own its process tree and exit when the compositor exits;
- keep the tmux server independent of the compositor;
- leave serial and SSH recovery untouched.

## 3. Hardware interfaces

The platform provides the standard Linux interfaces; it does not wrap them in
a private API.

| Capability | Interface | Access |
| --- | --- | --- |
| display | DRM/KMS (`/dev/dri/card*`) | logind seat / `video` group |
| input | evdev (`/dev/input/event*`), XKB | `input` group, `xkeyboard-config` |
| audio | ALSA (`/dev/snd/*`) | `audio` group |
| battery | `/sys/class/power_supply` | world-readable |
| network | `systemd-networkd`, `iwd`, `/sys/class/net` | `network` group where needed |
| storage | block devices, udev | `storage` group where needed |
| serial | `ttyS0` | serial getty |
| panel backlight | m5ioe1 I2C PWM | narrow `sudo` rule for `/usr/lib/cpz/backlight` |

The base enables the `vc4` and `cpz-spi` overlays. The UI package loads the
display modules; the base does not autoload them.

## 4. Paths

| Path | Owner | Purpose |
| --- | --- | --- |
| `/etc/cpz/platform.conf` | root | platform version and capabilities |
| `/etc/cpz/language` | root | default UI language code |
| `/usr/share/cpz/protected-packages` | root | packages the app helper never removes |
| `/var/lib/cpz` | root | app helper state (catalog refresh rate limit) |
| `/etc/pacman.d/cpz-apps.conf` | root | signed application repository |
| `/etc/cpz/foot.ini`, `/etc/cpz/tmux.conf` | root | UI defaults, package-owned |
| `/run/cpz` | `cpz` | tmux socket, status cache, launch adapters |
| `/usr/lib/cpz` | root | UI entry point and helpers |
| `~/.config/cpz` | user | user settings |
| `~/.local/state/cpz` | user | session and app state |
| `~/.cache/cpz` | user | caches, may be cleared |

The base never writes user state into `/etc` or `/var`.

## 5. Update and compatibility

- The UI is a signed pacman package set from the `ui-stable` GitHub Release.
- A UI update must not rebuild the image or replace the kernel or boot files.
- The current UI core release and one previous release remain installable.
- The UI declares a supported `contract` range; the platform refuses an
  incompatible UI and reports why.
- The web of package dependencies covers the UI runtime (`cage`, `foot`,
  `tmux`, fonts) and the system apps (`cpz-system-apps`, which depends on
  `cpz-apps-catalog`). The platform check covers the contract version and
  capabilities.
- Applications come from the separate `[cpz-apps]` repository described in
  [APP-PLATFORM.md](APP-PLATFORM.md). The base ships the repository config and
  the signing key; the UI image bakes the current catalog.
- User settings and session data survive UI updates.

## 6. Platform smoke test

A platform is acceptable for the UI when all of these pass:

1. `/etc/cpz/platform.conf` exists and has `platform=1`, `contract=1`.
2. `systemd-analyze verify cpz-ui@tty1.service` reports no configuration error
   other than the missing UI executable before the UI is installed.
3. `/dev/dri/card*` appears for the panel and/or HDMI.
4. `/dev/input/event*` is readable by `cpz`.
5. `/dev/snd/*` is readable by `cpz` when audio is present.
6. Serial getty and SSH still start when the UI is absent or stopped.
7. `/etc/cpz/language` contains a supported code.

## 7. Out of scope

- The application manifest and launch contract: owned by the UI, not the
  platform.
- Theme tokens, locale catalogs and status rendering: owned by the UI.
- A compositor, terminal, launcher or notification daemon: UI packages.
