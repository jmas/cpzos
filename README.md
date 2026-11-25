# cpz-arch

A minimal Arch Linux ARM base for the M5Stack **Cardputer Zero** (CM0). It
contains the kernel, firmware, hardware drivers, networking and a login path —
and deliberately no display or session layer. It exists so a new stack can be
built on a clean system instead of on top of the old one.

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
  expander, audio codec, battery gauge, IMU). They are installed and
  available; none of them is loaded as a display stack.
- A login user `cpz` in `wheel`, `input`, `video`, `audio`, `gpio`, `spi`,
  `i2c`. `root` is locked; `sudo` uses the normal wheel rule.
- `systemd-networkd` + `systemd-resolved` over wired Ethernet and `sshd` when
  `ENABLE_SSH=1`.
- A 15-second hardware watchdog, an in-memory journal and no initramfs.

## What is deliberately absent

- No `cpz-*` binaries, manifests, icons, themes, fonts or TUI apps.
- No DRM/HDMI/panel selection, backlight control or `/run/cpz` state.
- No `vc4`/HDMI overlay, no panel SPI overlay and no panel module autoload.
- No boot splash; the FAT boot partition holds firmware, kernel, device tree
  and overlays only.
- No `libdrm`, `libtsm`, `freetype2`, `libxkbcommon`, `libevdev`, tmux or
  font packages.

The display drivers remain in `/boot/overlays` and
`/usr/lib/modules/<kernel>/extra` for whichever stack is added next.

## Access

- **Serial:** `ttyS0` at 115200 baud. This is the only local login path.
- **SSH:** wired Ethernet, DHCP, user `cpz` / password `cpz` when
  `ENABLE_SSH=1`. Change the password before putting the device on a network.
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
