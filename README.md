# CardputerZero image

This branch builds the **CardputerZero CPZ** image: a terminal-first Raspberry
Pi OS system with the CardputerZero hardware enablement plus a kmscon + tmux
session. This is the regular image; there is no separate desktop or lite
variant.

It is intentionally small:

```text
stage0       debootstrap / apt / firmware
stage1       minimal bootable system
stage2       Raspberry Pi OS base + CardputerZero hardware
stage3       kmscon + tmux login session
export-image final image export
```

There is no desktop, launcher, NOOBS, cloud-init, Mathematica, or desktop/full
image stages. Those paths were removed so the build is shorter and the image
contains only components used by the CPZ terminal session.

The hardware stage still supports the CM0 panel, keyboard, audio, battery,
backlight, WiFi/Bluetooth and boot splash. The terminal session replaces the
old APPLaunch/desktop UI. See [docs/CPZ-KMSCON.md](docs/CPZ-KMSCON.md) for the
boot path and recovery/debug image details.

## Dependencies

Build on a Debian-based system newer than 2017. On other systems use Docker.

```bash
apt install coreutils quilt parted qemu-user-binfmt debootstrap zerofree zip \
  dosfstools e2fsprogs libarchive-tools libcap2-bin grep rsync xz-utils file \
  git curl bc gpg pigz xxd arch-test bmap-tools kmod
```

The file `depends` lists the required tools.

## Build

Copy an example configuration, then build:

```bash
cp config.cpz.example config
sudo ./build.sh
```

On macOS or another non-Debian host:

```bash
./build-docker.sh
```

To build the verbose recovery image that shows kernel/systemd logs instead of
starting kmscon:

```bash
./build-docker.sh -c config.debug.example
```

Results are written to `deploy/`.

## Configuration

`build.sh` sources `config` from the repository root. The important settings:

| Variable | Purpose |
| --- | --- |
| `IMG_NAME` | Image name used by the work directory |
| `IMG_FILENAME` / `ARCHIVE_FILENAME` | Output file names |
| `RELEASE` | Debian release (`trixie` for this branch) |
| `DEPLOY_COMPRESSION` | `xz`, `zip`, or `none` |
| `TARGET_HOSTNAME` | Hostname written into the image |
| `FIRST_USER_NAME` / `FIRST_USER_PASS` | First user account |
| `ENABLE_SSH` | Enable the SSH server |
| `PASSWORDLESS_SUDO` | Give the first user passwordless sudo |
| `LOCALE_DEFAULT`, `KEYBOARD_KEYMAP`, `KEYBOARD_LAYOUT`, `TIMEZONE_DEFAULT` | System defaults |
| `CPZ_DEBUG_BOOT` | `1` builds the verbose non-kmscon recovery image |

Additional pi-gen options such as `APT_PROXY`, `WPA_COUNTRY`,
`PUBKEY_SSH_FIRST_USER`, `PUBKEY_ONLY_SSH`, `USE_QEMU`, `WORK_DIR`,
`DEPLOY_DIR` and `CLEAN` are still supported by `build.sh`.

`STAGE_LIST` defaults to `stage*`, which builds `stage0`, `stage1`, `stage2`
and `stage3` in order.

## Layout

```text
stage0/                      bootstrap and firmware pinning
stage1/                      boot files, network, base packages
stage2/05-cardputerzero/     CM0 hardware, splash, audio, kernel modules
stage3/                      kmscon and tmux session
export-image/                image finalisation
scripts/                     pi-gen helpers
tools/verify-kmscon-stage.sh host-side structural checks (no root)
tools/verify-image.sh        full image content checks (Linux, root)
docs/                        CPZ boot path and M5 Imager notes
```

## Verify before flashing

Run the host-side checks after changing stages:

```bash
./tools/verify-kmscon-stage.sh
```

After a build, verify the produced image on Linux:

```bash
sudo ./tools/verify-image.sh deploy/<image>.img
```

For M5 Imager compatibility notes, see [docs/M5-IMAGER.md](docs/M5-IMAGER.md).

## Upstream documentation

This branch is derived from
[RPi-Distro/pi-gen](https://github.com/RPi-Distro/pi-gen). The generic pi-gen
workflow is unchanged: each stage is built in order, and the last stage with an
`EXPORT_IMAGE` file produces the deployable image.
