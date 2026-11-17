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
stage3       kmscon + tmux login session, build-only package cleanup
export-image final image export
```

There is no desktop, launcher, NOOBS, cloud-init, Mathematica, or desktop/full
image stage. Those paths were removed so the build is shorter and the boot
surface is limited to the CPZ terminal session.

kmscon owns tty1 and starts tmux with a top status bar (`current / total`
working tabs, language layout, optional volume/brightness, battery, clock),
window 1 as the shell and the last window as the `cpz-settings` TUI. The tab
counter includes Settings; closing a tab (Alt+W) keeps Settings and the last
terminal tab open, so a shell is always available. Text is rendered by
kmscon from the Terminus OTB font; the panel uses a 12px cell (53x14) by
default and 16px (40x10) is selectable in Settings. kmscon keeps the panel
grid and scales the font up on HDMI, so the same layout fits both screens.
Themes are switchable from Settings: Campbell (default), Homebrew, Ocean, Red
Sands, Terminal Basic, Man Page, Novel and PaperColor Light, plus Mono and
Light High Contrast for accessibility.

There is exactly one working output at a time. kmscon uses
`multi-monitor=largest`: the session is drawn on HDMI and the panel screen is
disabled when a usable monitor is attached, and the panel backlight is
switched off. Unplugging HDMI restores the panel without restarting the
session, so the monitor does not renegotiate its link. `Alt+D` switches to
clone mode and forces the panel back (useful when a monitor keeps HPD asserted
in standby). Settings changes that kmscon can only read at startup (font,
theme, timeout, forced panel) restart the session; tmux runs as a detached
server, so tabs, panes and running programs survive the restart.

The internal panel is a pure DRM display (`/dev/dri/card1`, `SPI-1`): the
driver's fbdev emulation is disabled, so there is no `/dev/fb1`, and fbcon is
off (`fbcon=map:off`). kmscon sets the panel mode through KMS itself.
`getty@tty1` is masked; tty2/tty3 stay as getty fallbacks (not drawn while
fbcon is off). SSH, serial and the debug image remain available for recovery.

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

## Release

`VERSION` is the single source of truth for the release version. It is written
into the image as `/etc/cpz-version` and shown in *Settings → About*. A release
is a `vX.Y.Z` tag whose version matches `VERSION`.

```bash
./tools/release.sh patch         # 0.1.0 -> 0.1.1
./tools/release.sh minor         # 0.1.1 -> 0.2.0
./tools/release.sh major         # 0.2.0 -> 1.0.0
./tools/release.sh 0.3.0-beta.1  # explicit prerelease
./tools/release.sh patch --dry-run
```

For the first release, `./tools/release.sh 0.1.0` tags the current commit
without creating an empty bump commit (`VERSION` already contains `0.1.0`).

The command refuses to run on a dirty or outdated branch, bumps `VERSION`,
creates a `chore(release): vX.Y.Z` commit, adds an annotated tag and pushes
both. It runs `tools/verify-stage.sh` and `tests/run.sh` before tagging; use
`--skip-checks` to bypass that or `--no-push` to keep the commit and tag local.

Pushing a tag does not build anything. Publishing the GitHub Release for the
tag (`Releases → Draft a new release`, pick the tag, write the notes, then
*Publish release*) starts `.github/workflows/build.yml`, which:

- builds `cardputerzero-trixie-arm64-<tag>.img.xz`;
- verifies the image contents;
- attaches the image to the published GitHub Release without rewriting the
  notes you wrote there;
- uploads the image to OSS and refreshes the `-stable.img.xz` alias for stable
  tags;
- updates `os-list.json` for M5 Imager.

The release's *pre-release* checkbox decides the channel when the build comes
from a published release. Manual rebuilds derive it from the tag: a tag with a
prerelease suffix (`v0.2.0-beta.1`) is treated as a prerelease. To rebuild an
existing tag, run the workflow manually (`workflow_dispatch`) and pass the tag.

## Configuration

`build.sh` sources `config` from the repository root. The important settings:

| Variable | Purpose |
| --- | --- |
| `IMG_NAME` | Image name used by the work directory |
| `IMG_FILENAME` / `ARCHIVE_FILENAME` | Output file names |
| `CPZ_VERSION` | Version written to `/etc/cpz-version`; defaults to `VERSION` |
| `RELEASE` | Debian release (`trixie` for this branch) |
| `DEPLOY_COMPRESSION` | `xz`, `gz`, `zip`, or `none` |
| `TARGET_HOSTNAME` | Hostname written into the image |
| `FIRST_USER_NAME` / `FIRST_USER_PASS` | First user account (`cpz` / `cpz` by default). The first local console login recommends a new password but does not block the session |
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
VERSION                      release version (source of truth)
tools/release.sh             bump VERSION, commit, tag and push
tools/verify-stage.sh        host-side structural checks (no root)
tools/verify-image.sh        full image content checks (Linux, root)
tests/                       unit tests and linter entry points
.github/workflows/           build/publish, CI and os-list workflows
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

This repository lives at [jmas/cpzos](https://github.com/jmas/cpzos).

This branch is derived from
[RPi-Distro/pi-gen](https://github.com/RPi-Distro/pi-gen). The generic pi-gen
workflow is unchanged: each stage is built in order, and the last stage with an
`EXPORT_IMAGE` file produces the deployable image.
