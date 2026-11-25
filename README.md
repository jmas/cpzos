# cpz-arch

A minimal Arch Linux ARM base for the M5Stack **Cardputer Zero** (CM0). It
contains the kernel, firmware, hardware drivers, display enablement, networking
and a login path — and deliberately no UI: no compositor, terminal session or
application layer. The UI ships as a separate pacman package set.

## What boots

```text
firmware
  → kernel (no initramfs)
  → systemd
      ├─ serial-getty@ttyS0   recovery login on the serial console
      └─ sshd                 remote login over wired Ethernet
```

There is no compositor, terminal emulator, window manager, tmux, DRM userspace,
splash or application framework. The kernel framebuffer console is mapped off
(`fbcon=map:off`), so the image produces no display output at all.

## What is in the image

- Arch Linux ARM `base`, `linux-rpi`, `raspberrypi-bootloader`.
- The Cardputer Zero vendor kernel modules and device-tree overlays (keypad,
  expander, audio codec, battery gauge, IMU, panel and vc4/HDMI). The hardware
  paths are enabled; no userspace stack is loaded.
- A login user `cpz` in `wheel`, `input`, `video`, `audio`, `gpio`, `spi`,
  `i2c`. `root` is locked; `sudo` uses the normal wheel rule.
- `/etc/cpz/platform.conf` with the platform and contract version and the
  hardware capability list.
- `systemd-networkd` + `systemd-resolved` over wired Ethernet and `sshd` when
  `ENABLE_SSH=1`.
- A 15-second hardware watchdog, an in-memory journal and no initramfs.

## What is deliberately absent

- No compositor, terminal emulator, window manager, tmux or application
  framework. The UI is a separate pacman package set.
- No `cpz-*` UI binaries, manifests, icons, themes, fonts or TUI apps.
- No `/run/cpz` UI state in the base.
- No boot splash; the FAT boot partition holds firmware, kernel, device tree
  and overlays only.
- No `libdrm`, `libtsm`, `freetype2`, `libxkbcommon`, `libevdev`, tmux or
  font packages in the base.

The display drivers and overlays are installed and enabled; the UI package
loads the modules and chooses the output.

## Access

- **Serial:** `ttyS0` at 115200 baud. This is the local recovery path.
- **SSH:** wired or USB Ethernet, DHCP, user `cpz` / password `cpz` when
  `ENABLE_SSH=1`. Host keys are generated at build time. The UI test image
  keeps a persistent journal for `journalctl -b -1`; the clean base keeps the
  volatile journal. Change the password before putting the device on a network.
- **root:** locked (`root:!`); use `sudo`.

## UI packages

The UI is a separate pacman package set. The base image ships the public signing
key (`keys/cpz-ui-signing.asc`) and enables the stable repository:

```text
https://github.com/jmas/cpzos/releases/download/ui-stable
```

`/etc/pacman.d/cpz-ui-beta.conf` is installed for the beta channel but is not
included by default. Add its `Include` line after `cpz-ui.conf` to opt in.

The repository is signed with the CPZ UI key
`C7DBEDC1B4855ACB0570C7D229C04B0663395458`. The private key lives only in
GitHub Actions secrets; CI signs packages and the repository database.

The stable channel is the only active channel for now; the beta configuration
is reserved for later. The platform also ships an inert
`cpz-ui@.service` template: the UI package provides `/usr/lib/cpz/session` and
enables `cpz-ui@tty1.service`, which uses `PAMName=login` to create the logind
session and seat.

Install the UI layer on a running system with:

```sh
sudo pacman -Sy cpz-ui
```

The package pulls `cage`, `foot`, `tmux`, the launcher and the status helper,
enables `cpz-tmux.service` and starts `cpz-ui@tty1.service`.

## Build

Docker Desktop on Apple Silicon runs the `linux/arm64` builder natively.

```sh
make builder
make image
make verify
```

| Target | Result |
| --- | --- |
| `make rootfs` | base Arch ARM + vendor modules in the build volume |
| `make image` | `out/cpz-arch-0.1.0-cm0.img` and `.img.zst` |
| `make verify` | structural and package checks without mounting the image |
| `make verify UI_TEST=1` | UI hardware-test image `out/cpz-arch-0.1.0-cm0-ui.img` |

The rootfs is assembled with `pacman --root`; the FAT32 boot partition with
mtools and the ext4 root with `mke2fs -d`, so no loop devices or host root are
needed.

## Flash

Write `out/cpz-arch-0.1.0-cm0.img` with Raspberry Pi Imager, balenaEtcher or
`dd`. The system comes up on serial and, if enabled, on wired SSH.

## Layout

```text
config.sh              board, packages, identity, image geometry
Makefile               builder/rootfs/image/verify entry points
docker/Dockerfile      arm64 builder with mtools and e2fsprogs
scripts/10-rootfs.sh   pacman rootfs, no initramfs
scripts/20-device.sh   vendor modules, overlays, firmware, keymaps
scripts/30-configure.sh identity, boot files, login paths, pruning
scripts/35-ui-repo.sh  UI signing key and pacman repository
scripts/40-image.sh    FAT32 + ext4 + MBR, no loop devices
scripts/50-verify.sh   base-image invariants
tools/ui-repo.sh       sign packages and build the static UI repository
keys/                  public UI signing key
.github/workflows/     base verify and UI repository publishing
docs/UI-QUALITIES.md   UI quality requirements
docs/UI-DECISIONS.md   session, app, launcher and status decisions
docs/PLATFORM-CONTRACT.md  platform/UI boundary and session entry
docs/APP-CONTRACT.md   desktop-entry app model and launch rules
docs/APP-PLATFORM.md   apps repository, catalog, store, Home and Settings
docs/TUI-CONTRACT.md   binding rules for console apps on the device
docs/HARDWARE-TEST.md  UI test image and device checklist
```

## Status and risks

The image builds and passes `make verify`. The UI signing key expires on
2028-11-24; rotate it before then and ship the new public key in a platform
update. It has no display output by design; bring-up and acceptance of any
future stack must be done separately. The hardware-only gaps to check on a
device are:

1. serial console at 115200 baud and the `cpz` login;
2. wired DHCP and `sshd`;
3. the vendor modules load without errors when a stack requests them.

## Extending the base

Add a new stage after `20-device.sh` (or a new script called from `Makefile`).
Keep the base rules in `AGENTS.md`, update this README and
`scripts/50-verify.sh`, and run `make verify`.
