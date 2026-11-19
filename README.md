# CPZ — CardputerZero OS

[![Release](https://img.shields.io/github/v/release/jmas/cpzos)](https://github.com/jmas/cpzos/releases/latest)
[![License](https://img.shields.io/badge/license-BSD--3--Clause-blue)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-CardputerZero%20%2F%20ARM64-lightgrey)](docs/CPZ-CAGE.md)

A small, fast operating system for the CardputerZero handheld. It boots into a
fullscreen terminal instead of a desktop: **cage** (Wayland kiosk compositor),
**foot** (terminal) and **tmux** (tabs, panes, status bar). Graphical programs
open over the terminal and return you to the same tab when they close.

- **Website:** <https://jmas.github.io/cpzos/>
- **Download:** [latest release](https://github.com/jmas/cpzos/releases/latest)
- **Docs:** [`docs/`](docs/)

![CPZ demo](https://img.youtube.com/vi/Q_ToN6c7plU/maxresdefault.jpg)

▶ **[Watch the demo on YouTube](https://www.youtube.com/watch?v=Q_ToN6c7plU)**

## Features

- **Terminal as desktop** — tmux tabs, splits, zoom and a CPZ status bar; no
  launcher, panel or window manager.
- **Two-key shortcuts** — every daily action is a direct `Alt+letter` binding,
  no tmux prefix, fully remappable in Settings.
- **One Settings app** — network, display, sound, input, time, power,
  applications and system in a single TUI.
- **Search everywhere** — `Alt+O` finds apps, files, settings, tmux buffers,
  mounted drives and evaluates `=` math.
- **Automatic USB storage** — drives mount on plug-in, open in a new tab, and
  unmount cleanly.
- **Media built in** — image gallery with camera RAW/PSD, mpv video with
  subtitles, cmus music playlists; headset and `Fn` media keys work.
- **App catalog** — Terminal Trove browser/installer with an apt-only,
  reversible install policy.
- **Graphical apps** — X11 and Wayland programs run over the terminal through
  Xwayland.
- **Panel and HDMI** — automatic output switching, per-output text size,
  themes and 12–32 px text on the Terminus bitmap strikes.
- **Battery aware** — low-battery warnings and a clean shutdown before the
  pack collapses.
- **Three languages** — English, Ukrainian and German for both the UI and the
  system locale.
- **Recoverable** — SSH, serial console, getty fallbacks and a verbose debug
  image.

## Install

1. Download the image from [Releases](https://github.com/jmas/cpzos/releases/latest).
2. Flash it to a microSD card with Raspberry Pi Imager, balenaEtcher or
   M5 Imager. This erases the card.
3. Boot the device. The first start takes a little longer.

Log in as `cpz` / `cpz`, then set a new password in
**Settings → System → Security**. Wi-Fi is off by default; enable it in
**Settings → Connections**. Power off from **Settings → Power**, not by
unplugging. For M5 Imager notes see [docs/M5-IMAGER.md](docs/M5-IMAGER.md).

## The session

The image is built in stages:

```text
stage0       debootstrap / apt / firmware
stage1       minimal bootable system
stage2       Raspberry Pi OS base + CardputerZero hardware
stage3       cage + foot + tmux session, build-only package cleanup
export-image final image export
```

tmux shows the CPZ top status bar (numbered tabs, network, input layout,
optional volume/brightness, battery, clock). The shell is window 1 while a
terminal tab exists, and `cpz-settings` is the last window. Closing the last
terminal tab leaves Settings open. Closing a tab with `Alt+W` never closes
Settings. Text is rendered by foot from the Terminus OTB font at a 12px cell
(53x14) by default.

The usual keys:

| Key | Action |
| --- | --- |
| `Alt+O` | Search |
| `Alt+S` | Settings |
| `Alt+H` | Help / key list |
| `Alt+T` / `Alt+W` | New / close tab |
| `Alt+Tab` / `Alt+1…9` | Switch tabs |
| `Alt+V` / `Alt+B` | Split vertically / horizontally |
| `Alt+N` / `Alt+P` | Next / previous pane |
| `Alt+Z` | Zoom pane |
| `Alt+C` / `Alt+Y` | Copy / paste |
| `Alt+G` / `Alt+M` | Bigger / smaller text |
| `Alt+U` / `Alt+I` / `Alt+0` | Volume up / down / mute |
| `Alt+D` | Force the internal panel |

The complete default list and the shortcut rules are in
[docs/CPZ-KEYS.md](docs/CPZ-KEYS.md). Every binding can be reassigned in
**Settings → Input → Shortcuts**.

Volume uses the same `wpctl` sink as Settings → Sound. USB headset buttons work
through `cpz-media-keys`, which watches evdev directly because cage never
forwards those keys to foot: the rocker changes volume, the side buttons skip
tracks, and the centre button toggles play/pause with a double press to skip.
The keyboard `Fn` layer is wired the same way (`Fn+W` previous, `Fn+E` next,
`Fn+Q` play/pause; `Fn+A`/`Fn+S`/`Fn+D` stay mute/volume down/volume up).

Settings confirms destructive actions in a centred modal shared with Search
and the pickers. Successful results fade; errors stay until `Enter`/`Esc`.
Blocking progress such as `Scanning...` stays inline.

**Settings → System → Language** switches both the CPZ interface and the system
locale between English, Ukrainian and German. The helper writes
`/etc/locale.conf` and `/etc/default/locale`, so login shells, recovery consoles
and child apps follow; already running programs may need a restart.

Themes: Campbell (default), Homebrew, Ocean, Red Sands, Terminal Basic,
Man Page, Novel, PaperColor Light, plus Mono and Light High Contrast for
accessibility. UI rules for labels, navigation and new screens are in
[docs/CPZ-UI.md](docs/CPZ-UI.md).

## Display and input

There is exactly one working output at a time. `cpz-cage-output` selects the
active DRM card: the internal panel (`card1`, `SPI-1`) or HDMI (`card0`). cage
runs on only the selected card as its primary DRM device, because the panel
card has no render node and the pixman renderer cannot render on a secondary
GPU. Both outputs use pixman and dumb buffers. When a usable monitor is
attached, cage restarts onto HDMI and switches the panel backlight off;
unplugging it restarts back to the panel. The switch costs a short blank frame
but cannot end up cursor-only. `Alt+D` forces the panel back (useful when a
monitor holds HPD asserted in standby). `display=panel` uses only the panel and
does not mirror HDMI.

Font and theme changes do not restart the compositor: `cpz-foot-reload`
renders the new `foot.ini` and the session supervisor replaces only the visible
terminal, with an idle anchor window keeping the DRM mode alive. tmux is a
separate service, so tabs, panes and programs survive. Display-mode changes
apply through a systemd path unit; changing the target card restarts the
session. Keyboard-layout changes also restart it.

The text size follows the output: **Settings → Display → Text Size** (or
`Alt+G` / `Alt+M`) changes the active screen from 12 to 32 px, and each output
remembers its own size across restarts.

The mouse cursor follows the device, not the compositor. It appears only when a
real USB/Bluetooth mouse is connected and **Settings → Input → Mouse Support**
is on. Phantom pointers from HDMI CEC and the internal keyboard are stripped,
libinput quirks remove their axes, and a pure pointer that must stay invisible
is moved to a seat cage does not watch. Changing the setting reopens input
devices without restarting cage; the visible terminal is replaced so a delayed
client cursor cannot remain. `cpz-pointer --status` reports the effective
state.

The internal panel is pure DRM (`/dev/dri/card1`, `SPI-1`): fbdev emulation is
disabled, there is no `/dev/fb1`, and fbcon is off (`fbcon=map:off`). cage sets
the mode through KMS. `getty@tty1` autologins uid 1000 and replaces its login
shell with `cpz-cage`; tty2/tty3 remain getty fallbacks (not drawn while fbcon
is off). SSH, serial and the debug image remain available for recovery.

See [docs/CPZ-CAGE.md](docs/CPZ-CAGE.md) for the boot path, output policy and
recovery details, and [docs/CPZ-GRAPHICS.md](docs/CPZ-GRAPHICS.md) for how
graphical applications are launched.

## Power

On battery, `cpz-battery-guard.service` polls the BQ27220 fuel gauge. It warns
at 20% and powers off cleanly at 10% (or 3.35 V if the pack collapses earlier).
Running the pack to the gauge's 3.15 V hardware cutoff makes the voltage sag
under load and resets the board, which looks like a surprise reboot. The tty1
getty also runs `cpz-battery boot` first: if the pack is too low, it shows the
charge and a countdown on the panel and powers off unless the charger is
connected. Thresholds live in `/etc/cpz/battery.conf`; use `cpz-battery status`
and `cpz-battery check` to inspect them.

## Storage and media

USB hard disks, sticks and card readers mount automatically at
`/media/<label>`, open in a new tab, and unmount when unplugged.
`cpz-automount list` shows what is mounted. Details are in
[docs/CPZ-STORAGE.md](docs/CPZ-STORAGE.md).

Three minimal players handle media files from both file managers:

- **`imv-wayland`** — images (JPEG, PNG, HEIC, TIFF, WebP, SVG, PSD and camera
  RAW such as CR2/NEF/ARW) as a gallery of the whole directory, starting at the
  opened file.
- **`mpv`** — video with the directory queued as a playlist. It uses
  `vo=wlshm` and `hwdec=no` because cage renders with pixman. Subtitles load
  automatically (`film.srt`, `film.en.srt`, `film.2020.srt`, or a
  `Subs/`/`subtitles/` folder); Ukrainian is preferred, then English.
- **`cmus`** — TUI music player. Opening a track loads the whole directory
  (recursively, audio only) in folder order rotated to the opened track
  (`04, 05, … 13, 01, 02, 03`). The playlist does not shrink while playing, the
  headset buttons move inside it, and playback ends with the folder. `._`
  sidecars from macOS drives are skipped.

`Enter` on a media file opens the right player from Midnight Commander and lf
through the same `/usr/local/bin/cpz-open` dispatcher (`MC_XDG_OPEN` and an lf
`cmd open`). Text files keep the usual editor. `q` returns to the file manager.

## Search

`Alt+O` opens CPZ Search in a centred tmux popup. It starts with mounted drives
(`Open <label>`, `Unmount <label>`), then New Tab, Close Tab, Mute, first-level
Settings pages and Help. Typing loads the remaining providers in the
background, so it is usable before the catalog and PATH scan finish:

| Input | Provider |
| --- | --- |
| no prefix | mounted media, installed apps, Settings pages, CPZ/power actions, catalog apps, PATH commands |
| `/` | files under `$HOME`, `/etc`, `/usr/local`, `/opt`, `/srv`, `/media`, `/mnt` |
| `=` | calculator |
| `apps` | Terminal Trove apps (installed first, others offer install) |
| `$` | tmux paste buffers, searchable by name or preview |

App rows carry a state tag: `[run app]`, `[install app]`, `[installed]` or
`[info]`. Only `[run app]` launches directly; other app rows open the
Applications details page where `i` installs, `e` runs and `d` removes. `Enter`
acts on the highlighted row, including the very first one. `Ctrl+Y` copies the
selection to the tmux buffer, `Ctrl+O` opens its directory in `lf` (or the app
details page). Settings targets are queued to the running Settings tab instead
of opening a second TUI.

Search has no daemon, database or background index: it runs only while the
popup is open, using `fzf`, `find`, `file`, `tmux` and `python3` from the image.
File search is scoped to user data and configuration; package trees such as
`/usr/lib` are excluded.

## Applications

**Settings → Applications** browses CLI/TUI programs from
[Terminal Trove](https://terminaltrove.com/) using a local catalog snapshot
generated by [terminal-trove-index](https://github.com/jmas/terminal-trove-index).
Browse shows apt-backed tools by default; `a` switches between apt-only and the
full catalog, `u` refreshes the snapshot. Set `CPZ_TROVE_INDEX_URL` at build
time to use another index.

Only packages that exist in apt are installed and tracked. The catalog's
Debian/Ubuntu command is preferred; otherwise the tool slug/name is checked in
apt. If no apt package exists, the screen shows the published instructions and
marks the tool as unmanaged — those commands are never run automatically.
Tracked apps appear in the Installed tab, run with `e`, and are removed with
one confirmation. State lives in `~/.local/state/cpz/trove-apps.json`.

## Build

Build on a Debian-based system newer than 2017; on other systems use Docker.
The `depends` file lists the required tools.

```bash
apt install coreutils quilt parted qemu-user-binfmt debootstrap zerofree zip \
  dosfstools e2fsprogs libarchive-tools libcap2-bin grep rsync xz-utils file \
  git curl bc gpg pigz xxd arch-test bmap-tools kmod
```

Copy an example configuration and build:

```bash
cp config.cpz.example config
sudo ./build.sh
```

On macOS or another non-Debian host:

```bash
./build-docker.sh
```

For the verbose recovery image that shows kernel/systemd logs instead of
starting the CPZ session:

```bash
./build-docker.sh -c config.debug.example
```

Results are written to `deploy/`. With the example configuration the file name
includes the build date, so local builds do not overwrite each other.

### Fast local iterations

Day-to-day changes usually touch only `stage2`, `stage3` or `export-image`.
Keep the Docker work volume and rebuild just the changed stages:

```bash
# once: full build into a named volume
PIGEN_DOCKER_OPTS="--volume cpz-pigen-work:/pi-gen/work" ./build-docker.sh

# after a stage3/export change: stage3 + export, from the cached stage2
./tools/build-fast.sh stage3

# after a stage2 change: stage2 + stage3 + export
./tools/build-fast.sh stage2
```

`tools/build-fast.sh` removes only the rootfs directories it is about to
rebuild, copies the previous stage fresh, and keeps `work/<IMG_NAME>/cache/`
(including the pinned kernel `.deb` cache). It uses `DEPLOY_COMPRESSION=gz` for
faster local exports; set `FAST_COMPRESSION=xz` for a release-shaped archive or
`FAST_COMPRESSION=none` for a raw `.img`.

Releases need a clean full build without the cached work volume (or with
`CLEAN=1`) and `DEPLOY_COMPRESSION=xz`. The fast profile is for iteration only.
An `apt-cacher-ng` on the host (`APT_PROXY` in `config`) also removes repeated
package downloads without changing package contents.

## Configuration

`build.sh` sources `config` from the repository root.

| Variable | Purpose |
| --- | --- |
| `IMG_NAME` | Image name used by the work directory |
| `IMG_FILENAME` / `ARCHIVE_FILENAME` | Optional fixed output names. Unset gives the dated default; a fixed name is overwritten by the next build |
| `CPZ_VERSION` | Version written to `/etc/cpz-version`; defaults to `VERSION` |
| `RELEASE` | Debian release (`trixie` for this branch) |
| `DEPLOY_COMPRESSION` | `xz`, `gz`, `zip`, or `none` |
| `TARGET_HOSTNAME` | Hostname written into the image |
| `FIRST_USER_NAME` / `FIRST_USER_PASS` | First user account (`cpz` / `cpz`). The first console login recommends a new password but does not block the session |
| `ENABLE_SSH` | Enable the SSH server (`1` by default; password login as the first user) |
| `PASSWORDLESS_SUDO` | Give the first user passwordless sudo |
| `LOCALE_DEFAULT`, `KEYBOARD_KEYMAP`, `KEYBOARD_LAYOUT`, `TIMEZONE_DEFAULT` | System defaults |
| `WPA_COUNTRY` | Wi-Fi regulatory domain (ISO 3166-1 alpha-2). Empty keeps Wi-Fi off until enabled in Settings |
| `CPZ_DEBUG_BOOT` | `1` builds the verbose recovery image |
| `CPZ_DTOVERLAYS_REF` | Pinned CardputerZero driver commit/tag; `main` tracks upstream |
| `CPZ_HDMI_VIDEO` | Optional fixed HDMI mode, e.g. `HDMI-A-1:1920x1080@60`; empty uses EDID |
| `CPZ_TROVE_INDEX_URL` | Terminal Trove catalog index (JSON or gzip); empty uses the hosted default, `none` skips the build-time download |
| `CPZ_OFFLINE` | `1` skips build-time network downloads (Trove catalog) |
| `CPZ_EXPORT_DIST_UPGRADE` | `0` skips the final export-image dist-upgrade for fast local builds |

Additional pi-gen options such as `APT_PROXY`, `PUBKEY_SSH_FIRST_USER`,
`PUBKEY_ONLY_SSH`, `USE_QEMU`, `WORK_DIR`, `DEPLOY_DIR` and `CLEAN` are still
supported. `STAGE_LIST` defaults to `stage*` (stage0 → stage3).

### Kernel updates

The display, touch and keyboard modules are built out-of-tree against the
installed kernel. Updating the kernel without rebuilding them leaves the panel
and keyboard without drivers, so `rpi-update` is not installed, is purged
during the build, and is pinned out of apt
(`/etc/apt/preferences.d/99-cpz-no-rpi-update.pref`). Update the kernel from
apt together with a new image from this branch: `CPZ_DTOVERLAYS_REF` records
the driver commit, and `/etc/cardputerzero-dtoverlays.commit` records what was
actually built into a running system.

## Release

`VERSION` is the single source of truth. It is written into the image as
`/etc/cpz-version` and shown in **Settings → About**. The format is defined in
[docs/RELEASE.md](docs/RELEASE.md): SemVer tag `vX.Y.Z[-prerelease]`, title
`CardputerZero CPZ vX.Y.Z`, notes with `Highlights`, `Changes` and `Install`,
and the assets produced by the release workflow.

```bash
./tools/release.sh patch         # 0.1.0 -> 0.1.1
./tools/release.sh minor         # 0.1.1 -> 0.2.0
./tools/release.sh major         # 0.2.0 -> 1.0.0
./tools/release.sh 0.3.0-beta.1  # explicit prerelease
```

Write the notes first, then dry-run or publish:

```bash
./tools/release.sh minor --notes deploy/release-notes-v0.5.0.md --dry-run
./tools/release.sh minor --publish --notes deploy/release-notes-v0.5.0.md
```

The command refuses a dirty or outdated branch or notes that do not follow the
template. It runs `tools/verify-stage.sh` and `tests/run.sh`, bumps `VERSION`,
creates a `chore(release): vX.Y.Z` commit, adds an annotated tag, pushes both
and, with `--publish`, creates the GitHub Release. Publishing starts
`.github/workflows/build.yml`, which:

- builds `cardputerzero-trixie-arm64-vX.Y.Z.img.xz`;
- verifies the image contents;
- attaches the image, `.info` and `build-info.json` to the release;
- mirrors the image to OSS, refreshes the `-stable.img.xz` alias for stable
  releases and updates `os-list.json` when OSS credentials are configured.
  Without them those steps are skipped and the GitHub release stays canonical.

The *pre-release* checkbox decides the channel for a published release. Manual
rebuilds derive it from the tag (`v0.2.0-beta.1` is a prerelease). To rebuild
an existing tag, run the workflow manually (`workflow_dispatch`) and pass the
tag; never retag a published release. `--no-push` keeps the commit and tag
local; `--skip-checks` is for recovery only.

## Website

`site/` is the static feature reference: no build step, an English page plus
translations in `site/i18n/` (Ukrainian, Polish, German, French, Spanish,
Italian, Portuguese, Turkish, Japanese and Simplified Chinese). The device UI
ships in English, Ukrainian and German. `.github/workflows/pages.yml` validates
translations and deploys the folder with GitHub Pages. Enable Pages once in
*Settings → Pages → Source: GitHub Actions*, then push a change under `site/`.

```bash
python3 -m http.server 8000 --directory site
```

## Verify before flashing

Host-side structural checks after changing stages:

```bash
./tools/verify-stage.sh
```

Unit tests and linters (no root or device needed):

```bash
./tests/run.sh    # settings + output policy unit tests
./tests/lint.sh   # shellcheck + ruff + mypy
```

After a build, verify the image on Linux:

```bash
sudo ./tools/verify-image.sh deploy/<image>.img
```

## Project layout

```text
stage0/                      bootstrap and firmware pinning
stage1/                      boot files, network, base packages
stage2/05-cardputerzero/     CM0 hardware, splash, audio, kernel modules
stage3/                      cage + foot + tmux session
export-image/                image finalisation
scripts/                     pi-gen helpers
VERSION                      release version (source of truth)
tools/build-fast.sh          rebuild one stage from cached work (local Docker)
tools/release.sh             bump VERSION, commit, tag and push
tools/verify-stage.sh        host-side structural checks (no root)
tools/verify-image.sh        full image content checks (Linux, root)
tests/                       unit tests and linter entry points
.github/workflows/           build/publish, CI and os-list workflows
docs/                        UI rules, cage session, graphics, storage, M5 Imager, release
```

## Upstream

This repository lives at [jmas/cpzos](https://github.com/jmas/cpzos). It is
derived from [RPi-Distro/pi-gen](https://github.com/RPi-Distro/pi-gen); the
generic workflow is unchanged: stages build in order and the last stage with an
`EXPORT_IMAGE` file produces the deployable image.
