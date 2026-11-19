# CardputerZero image

This branch builds the **CardputerZero CPZ** image: a small Raspberry Pi OS
system with the CardputerZero hardware enablement and a **graphics-first CPZ
session**. This is the regular image; there is no separate desktop or lite
variant.

It is intentionally small:

```text
stage0       debootstrap / apt / firmware
stage1       minimal bootable system
stage2       Raspberry Pi OS base + CardputerZero hardware
stage3       cage + foot + tmux session, build-only package cleanup
export-image final image export
```

The session is **cage** (a Wayland kiosk compositor) running **foot** (a
fullscreen terminal) with tmux inside it. It is not a desktop: there is no
launcher, panel, task switcher or window manager. Terminal programs run in
tmux; a graphical program opens a window on top of foot and returns to the
terminal when it closes. X11 programs use Xwayland, which cage provides.

tmux has the CPZ top status bar (numbered tabs, connected network tokens, input
layout, optional volume/brightness, battery and clock), the shell as window 1
while a terminal tab exists, and the last window as the `cpz-settings` TUI.
Closing the last terminal tab leaves Settings open so a new tab can be started
from there. Closing a tab (Alt+W) never closes Settings; any terminal tab,
including the last one, can be closed. Text is rendered by foot from the
Terminus OTB font; the panel uses a 12px cell (53x14) by default. The internal
panel and HDMI remember their own text size: Settings → Display → Text Size
(or `Alt+G` / `Alt+M`) changes the size of the active output, and switching
outputs restores the size saved for that screen. Both use 10 to 64 px and are
persisted across restarts. Daily tmux
actions are direct two-key `Alt+letter` bindings (`Alt+V` / `Alt+B` split,
`Alt+N` / `Alt+P` switch pane, `Alt+Z` zoom and so on), so no tmux prefix is
needed on the small CPZ keyboard. Volume is `Alt+U` / `Alt+I` and mute is
`Alt+0` (5% steps through the same `wpctl` sink as Settings → Sound). Every
binding can be reassigned in Settings → Input → Shortcuts; see
[docs/CPZ-KEYS.md](docs/CPZ-KEYS.md) for the complete default list and the
shortcut rules.

Settings confirms destructive actions and reports results in a centred modal
using the same frame as Search and the pickers: bold title in the border, one
blank row, and a muted hint. Successful results fade after a moment; errors
stay until `Enter`/`Esc`.
In-progress text such as `Scanning...` remains inline because the action is
already blocking.
Settings → System → Language switches both the CPZ interface and the system
locale between English, Ukrainian and German. The choice is persistent: the
helper writes `/etc/locale.conf` and `/etc/default/locale`, so new login
shells, recovery consoles and child apps use the same locale. Already running
programs may need a restart to pick it up.

Themes are switchable from Settings: Campbell (default), Homebrew, Ocean, Red
Sands, Terminal Basic, Man Page, Novel and PaperColor Light, plus Mono and
Light High Contrast for accessibility. The rules for labels, navigation and
new UI patterns are in [docs/CPZ-UI.md](docs/CPZ-UI.md).

There is exactly one working output at a time. `cpz-cage-output` selects the
active DRM card: the internal panel (`card1`, `SPI-1`) or HDMI (`card0`). cage
runs on **only the selected card**, as its primary DRM device, so HDMI is never
a secondary GPU. That matters on this hardware: the panel card has no render
node, and the pixman renderer cannot render on a secondary GPU. A panel:HDMI
device list made HDMI show only a cursor (the cursor plane worked while the
composited terminal never appeared) and flicker as page flips failed. Both
outputs use pixman and dumb buffers, which works for the SPI panel and for the
vc4 card as primary. When a usable monitor is attached, cage restarts onto the
HDMI card, the panel backlight is switched off, and unplugging it restarts
back to the panel. The switch costs a short blank frame but cannot fall into a
cursor-only output. `Alt+D` forces the panel back (useful when a monitor keeps
HPD asserted in standby). `display=panel` uses only the panel; it no longer
mirrors HDMI.

A font or theme change no longer restarts the compositor. `cpz-foot-reload`
renders the new `foot.ini` and the session supervisor replaces only the visible
terminal; an idle anchor window keeps cage and the current DRM mode alive while
the swap happens. tmux is a separate service, so tabs, panes and running
programs survive. A display-mode change is applied immediately through a
systemd path unit; a change of the target (HDMI or panel) restarts the session
because it changes the DRM card. Keyboard-layout changes still restart it.

The mouse cursor follows the device, not just the compositor: it appears only
when a real USB/Bluetooth mouse is connected and **Settings → Input → Mouse
Support** is on. Phantom pointers exposed by HDMI CEC and the internal keyboard
are stripped, and a pure pointer that must not be visible is moved to a seat
cage does not watch, so libinput drops it before device classification. A
libinput quirk also removes the relative/absolute axes from the internal
keyboard and the CEC node. Changing the setting reopens the input devices
without restarting cage; when the cursor disappears, the visible terminal is
replaced so a delayed client cursor cannot remain as a ghost.
`cpz-pointer --status` reports the effective state.

The internal panel is a pure DRM display (`/dev/dri/card1`, `SPI-1`): the
driver's fbdev emulation is disabled, so there is no `/dev/fb1`, and fbcon is
off (`fbcon=map:off`). cage sets the panel mode through KMS itself.
`getty@tty1` autologins uid 1000 and its login shell is replaced by
`cpz-cage`; tty2/tty3 stay as getty fallbacks (not drawn while fbcon is off).
SSH, serial and the debug image remain available for recovery.

The hardware stage still supports the CM0 panel, keyboard, audio, battery,
backlight, WiFi/Bluetooth and boot splash. The graphics session replaces the
old APPLaunch/desktop UI. See [docs/CPZ-CAGE.md](docs/CPZ-CAGE.md) for the boot
path, output policy and recovery/debug image details, and
[docs/CPZ-GRAPHICS.md](docs/CPZ-GRAPHICS.md) for how graphical applications
are launched.

On battery, `cpz-battery-guard.service` polls the BQ27220 fuel gauge. It shows
a low-battery notice at 20% and powers off cleanly at 10% (or at 3.35 V if the
pack collapses earlier); running the pack down to the gauge's 3.15 V hardware
cutoff makes the voltage sag under load and the board resets, which looks like
an unexpected reboot. The tty1 getty also runs `cpz-battery boot` before
starting the session: if the pack is too low, it prints the charge and a
countdown on the panel and powers off unless the charger is connected. The
thresholds live in
`/etc/cpz/battery.conf`; `cpz-battery status` and `cpz-battery check` show the
current state.

USB hard disks, sticks and card readers are mounted automatically when they are
plugged in, appear under `/media/<label>` in a new tab, and are ready to use
(see [docs/CPZ-STORAGE.md](docs/CPZ-STORAGE.md)); unplugging unmounts them, and
`cpz-automount list` shows what is mounted.

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

Results are written to `deploy/`. With the example configuration the file
name includes the build date, so repeated local builds do not overwrite each
other.

### Fast local iterations

A full build is needed for a release, but day-to-day changes usually touch only
`stage2`, `stage3` or `export-image`. Keep the Docker work volume between runs
and rebuild just the changed stage:

```bash
# once: full build into a named volume
PIGEN_DOCKER_OPTS="--volume cpz-pigen-work:/pi-gen/work" ./build-docker.sh
# (or ./tools/build-fast.sh stage0, which does the same into that volume)

# after a stage3/export change: stage3 + export, from the cached stage2
./tools/build-fast.sh stage3

# after a stage2 change: stage2 + stage3 + export
./tools/build-fast.sh stage2
```

`tools/build-fast.sh` removes only the rootfs directories it is about to
rebuild, copies the previous stage fresh, and keeps `work/<IMG_NAME>/cache/`
(including the pinned kernel `.deb` cache). It uses `DEPLOY_COMPRESSION=gz`
for faster local exports; set `FAST_COMPRESSION=xz` for a release-shaped
archive or `FAST_COMPRESSION=none` for a raw `.img`.

For a release, do a clean full build without the cached work volume (or with
`CLEAN=1`) and keep `DEPLOY_COMPRESSION=xz`; the fast profile is only for
iteration. An `apt-cacher-ng` on the host (`APT_PROXY` in `config`) also
removes repeated package downloads without changing package contents.

## Release

`VERSION` is the single source of truth for the release version. It is written
into the image as `/etc/cpz-version` and shown in *Settings → About*. The one
valid release format is defined in [docs/RELEASE.md](docs/RELEASE.md): a
SemVer tag `vX.Y.Z[-prerelease]`, the title
`CardputerZero CPZ vX.Y.Z`, hand-written notes with `Highlights`, `Changes` and
`Install`, and the assets produced by the release workflow.

```bash
./tools/release.sh patch         # 0.1.0 -> 0.1.1
./tools/release.sh minor         # 0.1.1 -> 0.2.0
./tools/release.sh major         # 0.2.0 -> 1.0.0
./tools/release.sh 0.3.0-beta.1  # explicit prerelease
```

Write the notes file first, then choose between a dry run and the full release:

```bash
./tools/release.sh minor --notes deploy/release-notes-v0.5.0.md --dry-run
./tools/release.sh minor --publish --notes deploy/release-notes-v0.5.0.md
```

For the first release, `./tools/release.sh 0.1.0` tags the current commit
without creating an empty bump commit (`VERSION` already contains `0.1.0`).

The command refuses to run on a dirty or outdated branch or with notes that do
not follow the template. It runs `tools/verify-stage.sh` and `tests/run.sh`,
bumps `VERSION`, creates a `chore(release): vX.Y.Z` commit, adds an annotated
tag, pushes both and, with `--publish`, creates the GitHub Release with the
standard title and channel. Publishing starts `.github/workflows/build.yml`,
which:

- builds `cardputerzero-trixie-arm64-vX.Y.Z.img.xz`;
- verifies the image contents;
- attaches the image, `.info` and `build-info.json` to the release;
- mirrors the image to OSS, refreshes the `-stable.img.xz` alias for stable
  releases and updates `os-list.json` when OSS credentials are configured;
  without them those mirror steps are skipped and the GitHub release remains
  the canonical download.

The release's *pre-release* checkbox decides the channel when the build comes
from a published release. Manual rebuilds derive it from the tag: a tag with a
prerelease suffix (`v0.2.0-beta.1`) is treated as a prerelease. To rebuild an
existing tag, run the workflow manually (`workflow_dispatch`) and pass the tag;
never retag a published release. Use `--no-push` to keep the commit and tag
local or `--skip-checks` only for recovery.

## Website

`site/` is the static feature reference. It has no build step and ships the
English page plus translations in `site/i18n/` (Ukrainian, Polish, German,
French, Spanish, Italian, Portuguese, Turkish, Japanese and Simplified
Chinese). The device UI itself ships in English, Ukrainian and German.
`.github/workflows/pages.yml` validates the translations and deploys
the folder with GitHub Pages. Enable Pages once in *Settings → Pages → Source:
GitHub Actions*, then push a change under `site/`. Preview it locally:

```bash
python3 -m http.server 8000 --directory site
```

## Configuration

`build.sh` sources `config` from the repository root. The important settings:

| Variable | Purpose |
| --- | --- |
| `IMG_NAME` | Image name used by the work directory |
| `IMG_FILENAME` / `ARCHIVE_FILENAME` | Optional fixed output names. Leave unset to get the dated default; a fixed name is overwritten by the next build |
| `CPZ_VERSION` | Version written to `/etc/cpz-version`; defaults to `VERSION` |
| `RELEASE` | Debian release (`trixie` for this branch) |
| `DEPLOY_COMPRESSION` | `xz`, `gz`, `zip`, or `none` |
| `TARGET_HOSTNAME` | Hostname written into the image |
| `FIRST_USER_NAME` / `FIRST_USER_PASS` | First user account (`cpz` / `cpz` by default). The first local console login recommends a new password but does not block the session |
| `ENABLE_SSH` | Enable the SSH server (`1` by default; password login as the first user) |
| `PASSWORDLESS_SUDO` | Give the first user passwordless sudo |
| `LOCALE_DEFAULT`, `KEYBOARD_KEYMAP`, `KEYBOARD_LAYOUT`, `TIMEZONE_DEFAULT` | System defaults |
| `WPA_COUNTRY` | Wi-Fi regulatory domain (ISO 3166-1 alpha-2). Empty keeps Wi-Fi off until enabled in Settings |
| `CPZ_DEBUG_BOOT` | `1` builds the verbose recovery image |
| `CPZ_DTOVERLAYS_REF` | Pinned CardputerZero driver commit/tag; use `main` to track upstream |
| `CPZ_HDMI_VIDEO` | Optional stable HDMI mode, e.g. `HDMI-A-1:1920x1080@60`; empty uses EDID. A pin also lets auto stay on HDMI when the monitor's EDID is unreadable |
| `CPZ_TROVE_INDEX_URL` | Terminal Trove catalog index (JSON or gzip) for Settings → Applications; empty uses the hosted default |

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

## Applications

Settings → Applications discovers CLI/TUI programs from
[Terminal Trove](https://terminaltrove.com/). The image ships a local catalog
snapshot generated by the separate
[terminal-trove-index](https://github.com/jmas/terminal-trove-index) project;
the same index provides search, categories and a language filter. Browse shows
apt-backed tools by default; press `a` to switch between apt-only and the full
catalog. Press `u` to refresh the snapshot, or set
`CPZ_TROVE_INDEX_URL` at build time.

Install policy: only packages that exist in apt are installed and tracked by
the manager. The catalog's Debian/Ubuntu command is preferred; if Terminal
Trove does not publish one, the tool slug/name is checked in apt. When no apt
package exists, the screen shows the published install instructions and marks
the tool as not managed. Those commands are never executed automatically.
Tracked apps are listed in the Installed tab and can be run with `e` or
removed with one confirmation; the manager records its state in
`~/.local/state/cpz/trove-apps.json`.

## Images and video

Two minimal Wayland viewers are installed for the terminal file managers:

- `imv-wayland` shows images (PNG, JPEG, GIF, WebP, BMP, SVG) and browses a
  directory with the arrow keys;
- `mpv` plays video. It is configured with `vo=wlshm` and `hwdec=no`, because
  cage renders with pixman and cannot import the dmabuf/GL window a normal GPU
  video output would create.

Pressing `Enter` on a media file opens the right viewer from both file
managers. Midnight Commander is redirected with `MC_XDG_OPEN`, which its
`image.sh`/`video.sh` helpers already honour; lf gets a `cmd open` in
`~/.config/lf/lfrc` that calls the same `/usr/local/bin/cpz-open` dispatcher.
Text files keep the usual editor. `q` closes either viewer and returns to the
file manager; the player OSD is available with the mouse or the usual mpv
keys.

## Search

`Alt+O` opens CPZ Search in a centred tmux popup. It starts with a short
priority list: mounted USB drives, New Tab, Close Tab, Mute, the first-level
Settings pages and Help. Typing anything loads the rest of the searchable
providers in the background, so the popup is usable before the catalog and
PATH scan finish:

| Input | Provider |
| --- | --- |
| no prefix | mounted media, installed apps, Settings pages, CPZ actions, power actions, catalog apps and PATH commands |
| `/` | files under `$HOME`, `/etc`, `/usr/local`, `/opt`, `/srv`, `/media` and `/mnt` |
| `=` | calculator |
| `apps` | Terminal Trove apps (installed apps first, the rest show `[install app]`) |
| `$` | tmux paste buffers, searchable by name or content preview |

The result list uses one state tag per app: `[run app]` (installed),
`[install app]` (missing, apt-backed), `[installed]` (installed but no
runnable command) and `[info]` (missing without an apt package). `[run app]`
rows launch with `Enter`; every other app row opens its Applications details
page in the Settings tab, so the description, the install instructions and the
apt package are visible before anything changes. On that page `i` installs
through the same apt policy as Applications, `e` runs the app and `d` removes
a managed install. Apps installed through the manager are listed first and
stay runnable from Search after installation. The footer shows the keys that
apply to the highlighted row, and the match counter sits on the right of the
prompt line.

`Enter` acts on the highlighted row, including the first row before anything is
typed. It launches an installed app or command in a new tab, opens a
non-runnable app's Applications details page in the Settings tab, opens a file
in `vim` (or `lf` for a directory), opens the selected Settings page, pastes a
tmux buffer, unmounts a mounted USB drive after the `sudo` prompt, and asks tmux
to confirm before rebooting or shutting down. `Ctrl+Y` copies the selected
path/command/result to the tmux buffer, so `Alt+Y` pastes it; `Ctrl+O` opens
the containing directory in
`lf` (or the Applications details for an app). Settings targets are queued for
the running Settings tab instead of starting a second TUI inside the popup, so
the popup closes immediately and `q` behaves like normal Settings. A target
that names one app opens that app's page directly, so Search never drops you on
the catalog list and leaves you to find the app again.

The `apps` provider uses the local Terminal Trove snapshot that Applications
already maintains; the search itself never fetches from the network. The `$`
provider reads the same tmux buffers as `Alt+Y`, so older buffers can be
selected and pasted without leaving the keyboard.

The search runs only while the popup is open: there is no daemon, database or
background index. `fzf`, `find`, `file`, `tmux` and `python3` are already part
of the image. File search is scoped to user data and configuration; package
trees such as `/usr/lib` are deliberately excluded, and commands are covered
by the default provider instead.

## Layout

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
docs/                        UI rules, cage session, graphics mode, M5 Imager and Applications notes
```

## Verify before flashing

Run the host-side checks after changing stages:

```bash
./tools/verify-stage.sh
```

Unit tests and linters (no root or device needed):

```bash
./tests/run.sh    # settings + output policy unit tests
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
