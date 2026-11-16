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
image stage. Those paths were removed so the build is shorter and the boot
surface is limited to the CPZ terminal session.

kmscon owns tty1 and starts tmux with a top status bar (`current / total`
working tabs, language layout, optional volume/brightness, battery, clock),
window 1 as the shell and the last window as the `cpz-settings` TUI. Settings
is a maintenance window and is not counted as a tab. Text is rendered by
kmscon from the Terminus OTB font; the panel uses a 12px cell (53x14) by
default and 16px (40x10) is selectable in Settings. kmscon keeps the panel
grid and scales the font up on HDMI, so the same layout fits both screens.
Themes are switchable from Settings.

There is exactly one working output at a time. When a usable HDMI monitor is
attached the session is drawn there and the internal panel backlight is
switched off; unplugging HDMI restores the panel. `Alt+D` forces the panel
back (useful when a monitor keeps HPD asserted in standby). kmscon only reads
its configuration at startup, so a display change or a Settings change is
applied by restarting the session; tmux runs as a detached server, so tabs,
panes and running programs survive the restart.

The hardware stage still supports the CM0 panel, keyboard, audio, battery,
backlight, WiFi/Bluetooth and boot splash. The terminal session replaces the
old APPLaunch/desktop UI. See [docs/CPZ-KMSCON.md](docs/CPZ-KMSCON.md) for the
boot path, output policy and recovery/debug image details.

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
starting the CPZ session:

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
| `DEPLOY_COMPRESSION` | `xz`, `gz`, `zip`, or `none` |
| `TARGET_HOSTNAME` | Hostname written into the image |
| `FIRST_USER_NAME` / `FIRST_USER_PASS` | First user account. The first local console login requires a new password while the factory one is unchanged |
| `ENABLE_SSH` | Enable the SSH server (`0` by default) |
| `PASSWORDLESS_SUDO` | Give the first user passwordless sudo |
| `LOCALE_DEFAULT`, `KEYBOARD_KEYMAP`, `KEYBOARD_LAYOUT`, `TIMEZONE_DEFAULT` | System defaults |
| `WPA_COUNTRY` | Wi-Fi regulatory domain (ISO 3166-1 alpha-2). Empty keeps Wi-Fi off until enabled in Settings |
| `CPZ_DEBUG_BOOT` | `1` builds the verbose recovery image |
| `CPZ_DTOVERLAYS_REF` | Pinned CardputerZero driver commit/tag; use `main` to track upstream |
| `CPZ_HDMI_VIDEO` | Optional stable HDMI mode, e.g. `HDMI-A-1:1920x1080@60`; empty uses EDID. A pin also lets auto stay on HDMI when the monitor's EDID is unreadable |

Additional pi-gen options such as `APT_PROXY`, `PUBKEY_SSH_FIRST_USER`,
`PUBKEY_ONLY_SSH`, `USE_QEMU`, `WORK_DIR`, `DEPLOY_DIR` and `CLEAN` are still
supported by `build.sh`.

`STAGE_LIST` defaults to `stage*`, which builds `stage0`, `stage1`, `stage2`
and `stage3` in order.

### Kernel updates

The CardputerZero display, touch and keyboard modules are built out-of-tree
against the kernel installed in the image. Updating the kernel without
rebuilding those modules leaves the panel and keyboard without drivers, so
`rpi-update` is not installed, is purged from the image during the build, and
is pinned out of apt (`/etc/apt/preferences.d/99-cpz-no-rpi-update.pref`).
Kernel updates should come from `apt` together with a new image built from this
branch: `CPZ_DTOVERLAYS_REF` records the driver commit, and
`/etc/cardputerzero-dtoverlays.commit` records the commit that was actually
built into a running system.

## Layout

```text
stage0/                      bootstrap and firmware pinning
stage1/                      boot files, network, base packages
stage2/05-cardputerzero/     CM0 hardware, splash, audio, kernel modules
stage3/                      kmscon and tmux session
export-image/                image finalisation
scripts/                     pi-gen helpers
tools/verify-stage.sh host-side structural checks (no root)
tools/verify-image.sh        full image content checks (Linux, root)
docs/                        CPZ boot path and M5 Imager notes
```

## Verify before flashing

Run the host-side checks after changing stages:

```bash
./tools/verify-stage.sh
```

Unit tests and linters (no root or device needed):

```bash
./tests/run.sh    # cpz-settings unit tests
./tests/lint.sh   # shellcheck + ruff + mypy
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
