# Application platform

Status: agreed on `design/app-platform` (2026-11-26). The repository name, the
stack, Home semantics, the update policy and the product names are decided.
An MVP is implemented in `jmas/cpzos-apps` (Go 1.24, Bubble Tea 1.3): the four
system apps, the catalog generator, the helper and the packaging. Signing,
publishing and device validation are still pending.

Decided: `jmas/cpzos-apps` with curated pull requests; Go + Bubble Tea; Home
replaces the tab with the chosen app; installs run a full `pacman -Syu`; the
four system apps are preinstalled with the UI and are named **Home**, **Apps
Manager**, **Settings** and **Terminal**; the default UI language is `en`; the
UI image bakes the current app catalog at build time and Apps Manager refreshes
it in the background.

First release: catalogs ship `en` and `uk`; the other nine codes resolve to
`en` until translated. Home is tracked in Apps Manager's **System** category
but omitted from its own list.

Related: [APP-CONTRACT.md](APP-CONTRACT.md) (desktop entries),
[TUI-CONTRACT.md](TUI-CONTRACT.md) (console UI rules),
[LANGUAGE.md](LANGUAGE.md) (translations and the system language),
[UI-QUALITIES.md](UI-QUALITIES.md) (product budgets),
[UI-DECISIONS.md](UI-DECISIONS.md) (session stack).

## 1. Decision in one paragraph

Applications live in a separate signed repository, `cpzos-apps`, built and
published like the UI. A package installs one or more freedesktop desktop
entries; CI generates the catalog entry from those entries. The system ships
four preinstalled apps in one protected package (`cpz-system-apps`): **Home**
(what a new tab shows), **Apps Manager** (browse, install, remove, open),
**Settings** and **Terminal**. Home, Apps Manager and Settings are one Go
binary built on the shared `internal/tui` kit; Terminal is a desktop entry
that starts a login shell. Apps Manager browses a signed catalog, installs and
removes packages through one narrow privileged helper, and never evaluates a
shell.
The same operations are available headless with flags for scripts and tests.
The desktop entry stays the single source of truth for name, description,
category, keywords and launch line; translations follow
[LANGUAGE.md](LANGUAGE.md).

## 2. Why a separate repository

- Application release cadence is independent of the platform image and of the
  UI core. Installing an app must not rebuild the image or restart the session.
- The app tree is mostly packaging and UI code; keeping it out of the base
  distribution keeps `cpz-arch` about hardware enablement (see `AGENTS.md`).
- CI for apps needs Go and `makepkg`, not a kernel or an image build.
- The trust root stays the existing CPZ UI key: one public key, one rotation
  story, no second key to ship in the base image.

Repository name: `jmas/cpzos-apps`. Only curated pull requests are merged:
the catalog of a shipped image is reviewed code and packaging, not an open
marketplace. Product name in the UI: **Apps Manager**; the binary token stays
`apps`.

## 3. What an application is

Unchanged from `APP-CONTRACT.md`: a normal pacman package plus one or more
`.desktop` entries in `/usr/share/applications`. The desktop entry carries the
name (`Name`, `Name[uk]`), description (`Comment`), category (`Categories`),
search words (`Keywords`), icon, `Terminal=true|false` and `Exec`.

Two additions:

| Field | Meaning |
| --- | --- |
| `X-CPZ-System=true` | Provided by the system package; Apps Manager never removes it |
| `X-CPZ-Contract=1` | App-contract version the entry was built for |

The package name is not stored in the entry. It is resolved from the catalog
(for available apps) or with `pacman -Qo <entry>` for installed apps that are
not in the catalog. One lookup per selected app, never per row.

One package may ship several entries; Apps Manager treats a package as the
install/remove unit and shows the entries it provides in the confirmation.

## 4. Repository layout

```text
cpzos-apps/
  go.mod                       module cpz.apps, Go 1.24
  internal/tui/                shared kit: theme, list, screen, input,
                               confirm, keymap (us/ua), status line
  internal/i18n/               language resolver and en/uk catalogs
  internal/catalog/            catalog schema and loader
  internal/apps/               XDG discovery, desktop parsing, merge
  internal/pacman/             read-only queries and the helper client
  internal/launch/             argv expansion, tmux tab, window replacement
  internal/home/               Home (new-tab launcher)
  internal/store/              Apps Manager
  internal/settings/           Settings and About
  internal/about/              system facts
  cmd/cpz-app/                 multicall entry: home | apps | settings
  system/                      desktop entries, helper, sudoers, protected list
  apps/<name>/                 one directory per application package
  packaging/                   PKGBUILDs for the system apps and the catalog
  tools/                       catalog generator and local repository builder
  .github/workflows/           build, test, catalog, sign, publish
```

- `internal/tui` is the only place that knows the theme, the keymap and the
  screen anatomy. An app that reimplements a list is a review failure.
- Apps contributed by pull request use the kit directly; a second list or
  dialog implementation is a review failure. An app that cannot use Go still
  follows `TUI-CONTRACT.md` and the desktop-entry contract.

## 5. Package and channel layout

| Package | Contents |
| --- | --- |
| `cpz-system-apps` | `cpz-app` binary, Home, Apps Manager, Settings, Terminal entry, helper client, sudoers rule |
| `cpz-apps-catalog` | data-only catalog: generated `/usr/share/cpz/catalog/apps.json`; regenerated per release |
| `cpz-app-<name>` | first-party apps (convention, not a requirement) |
| any | third-party apps, `groups=('cpz-apps')` recommended |

- The four system apps are preinstalled: `cpz-ui` depends on
  `cpz-system-apps`. The clean base image still has no UI at all, by design;
  any image or system with the UI gets Home, Apps Manager, Settings and
  Terminal.
- That same dependency is what makes the system apps non-removable through
  pacman, not just a UI rule.
- `cpz-system-apps` depends on `cpz-apps-catalog`, so browsing works offline
  from the installed copy.
- The apps release is published as a new pacman repository `[cpz-apps]` in a
  separate GitHub release (`apps-stable`), signed with the existing CPZ UI
  key. `Server` points at that release; pacman picks up `cpz-apps.db` there.
- The base image adds one `Include` stanza for `[cpz-apps]` in a platform
  release. No kernel, boot or session change is involved.
- Sequencing: the apps repository and its first signed catalog are published
  *before* the stanza ships. A stanza pointing at a missing release would make
  `pacman -Sy` fail on every device.
- The UI image bakes the catalog: stage 45 installs `cpz-system-apps` and
  `cpz-apps-catalog` from the signed repository, so the first Apps Manager
  start has a list without network or root. The build report records the
  package version, its sha256 and the catalog `generated` date.
- Release builds pin `UI_APPS_CATALOG_VERSION` and `UI_APPS_CATALOG_SHA256` in
  `config.sh` and fail on a mismatch; test builds take the current repository
  version. The clean base image installs neither package and stays UI-free.

## 6. The catalog

The catalog is Apps Manager's view of *available* apps. It is generated by
CI from the built packages, so it cannot drift from the desktop entries:

```json
{
  "version": 1,
  "generated": "2026-11-26T10:00:00Z",
  "contract": 1,
  "apps": [
    {
      "id": "cpz-player.desktop",
      "package": "cpz-app-player",
      "version": "0.4.1",
      "name": {"en": "Player", "uk": "Плеєр"},
      "comment": {"en": "Play music from the library", "uk": "Відтворення музики"},
      "categories": ["AudioVideo"],
      "keywords": ["music", "audio"],
      "terminal": true,
      "system": false,
      "size": 12582912,
      "icon": "media-playback-start",
      "contract": 1
    }
  ]
}
```

- At build time CI validates every entry with `desktop-file-validate`, rejects
  duplicate ids, and fails if an entry has no `Name`, `Exec` or `Categories`.
- Categories are freedesktop main categories (`AudioVideo`, `Game`, `Network`,
  `Office`, `Settings`, `System`, `Utility`, `Development`, `Graphics`,
  `Education`, `Science`). One entry has exactly one category: the first main
  category in `Categories`. Subcategories are not a second taxonomy.
- Apps Manager shows two synthetic groups: **Installed** (XDG scan, including
  apps installed by hand) and **System** (`X-CPZ-System=true`).
- Installed apps are read from `$XDG_DATA_HOME/applications` and
  `$XDG_DATA_DIRS/applications` as today; the catalog only fills in available,
  not-yet-installed apps. An installed app never depends on the catalog.
- Only system entries (`X-CPZ-System=true`) and entries present in the catalog
  are user-facing apps. Desktop files shipped by the session or its
  dependencies (foot, foot-client, foot-server, help) are filtered out, so
  Home shows Apps Manager, Settings, Terminal and installed catalog apps.
- Localized fields are copied as `name[lang]`, `comment[lang]` and
  `keywords[lang]`; Apps Manager and Home pick the system language with an `en`
  fallback exactly as [LANGUAGE.md](LANGUAGE.md) defines.
- Browsing is instant and offline from the installed copy; the date on the
  `Update app list` row shows how stale it is. There is no second download
  channel and no separate language pack.

### 6.1 Baked at build, refreshed in the background

- The catalog is a signed, data-only package (`cpz-apps-catalog`) installed by
  the UI build, so a device that has never been online still shows apps.
- Entering Apps Manager starts one best-effort `refresh-catalog` call *after*
  the first frame. The list is already interactive; the refresh never blocks a
  keystroke and never shows a modal.
- On success the screen re-reads the catalog in place, keeps the cursor and
  the category, and updates the date. On failure it keeps the cached list and
  shows a two-second dim note (`Offline, showing the saved list`).
- Rate limit: at most one attempt per 10 minutes, tracked by the marker file
  `/var/lib/cpz/refresh`. A busy pacman lock or a missing network is a no-op,
  not an error dialog and not a retry loop.
- Home does not refresh: it lists installed apps only.
- If a package operation already holds the lock (including the background
  refresh), an install or remove changes nothing and reports
  `Another package operation is running; try again`.
- `Install` refreshes the sync database itself, so a catalog that is a few
  minutes stale cannot hide a freshly published app.
- The background refresh updates the catalog only. It never upgrades installed
  apps without a confirmed transaction.

## 7. The four system apps

The three `cpz-app` screens obey `TUI-CONTRACT.md`: plain `F`/`X`/`Z`/`C`
navigation, `Enter`, `Esc`, one focus bar, no footer, no borders, panel-first;
all strings come from their catalogs per [LANGUAGE.md](LANGUAGE.md). Terminal
is a plain login shell.

### 7.1 Apps Manager

The product name is **Apps Manager**; the binary token and desktop entry id
stay short (`cpz-app apps`, `cpz-apps-manager.desktop`).

- Header: `Apps Manager · <category>` and `n/total`. `Z`/`C` switch categories;
  `F`/`X` move; `Tab` focuses search; `Enter` opens the detail screen.
- Search is incremental over name, comment, keywords and package, in the
  active language plus the English original. `Esc` clears; `Tab` returns.
- Detail screen shows name, version, comment, categories, size and state, then
  a vertical action list: **Open** (installed), **Install** (available),
  **Remove** (installed, non-system), **Back**. System apps show
  `System app · cannot be removed` and no Remove row.
- Remove asks: `Remove Player and its package? User data is kept.` with
  **No** focused. Install always asks: it runs a full system upgrade, so the
  dialog names the package, the display size and that the system is updated
  too.
- The first row of the **All** category is `Update app list`, which forces the
  refresh now (the automatic one is rate-limited to once per 10 minutes). It is
  hidden inside the other categories to keep them short.
- Install/remove refresh the list in place; the removed entry disappears,
  installed entries get the installed marker.

```text
Apps Manager · All            2/12
> Update app list
  Player                      0.4.1   *
  Recorder                    0.2.0
  Weather                     1.1.0
```

### 7.2 Home

- Default command of a new tmux window
  (`set -g default-command "/usr/bin/cpz-app home"`).
- One list of system and installed catalog apps, same rows and search as Apps Manager, plus
  `Terminal` (the shell entry), `Apps Manager` and `Settings`. `Enter` launches
  the app **in the current window** (process replacement), so a tab is "the app
  you chose", not a launcher that stays behind. Before `exec`, Home renames the
  tmux window to the app name through argv (`tmux -L cpz rename-window`), so
  the tab strip stays truthful. When the app exits, the window closes and the
  tab disappears.
- Home omits its own desktop entry from the list, so it cannot relaunch
  itself. Apps Manager still shows Home under **System**, because the system
  apps are tracked like every other app.
- `Esc` at the Home root does nothing; `Alt+W` closes the tab. This avoids
  killing the last window by accident while keeping one meaning per key.
- The 50 ms budget means Home must not query pacman; it reads XDG entries and
  the catalog's entry-to-package map only. An entry with no owner there is
  resolved with `pacman -Qo` when selected.

### 7.3 Settings

- Root list, currently one item: **About system**. The structure exists for
  later sections, but no placeholder rows and no empty "coming soon" screens.
- About shows: platform version and contract, UI version, system-apps version,
  board, kernel, hostname, language, output (panel/HDMI), uptime, memory. Read
  from `/etc/cpz/platform.conf`, `/etc/cpz/language`, `/run/cpz/output`,
  `/proc`, `/sys`; one `pacman -Q` for the three versions, done after the first
  frame.
- Read-only screen. `Esc` returns to the list.

### 7.4 Terminal

- A desktop entry from the same package: `Exec=bash -l`, `Terminal=true`,
  `Categories=System;TerminalEmulator;`, `X-CPZ-System=true`.
- From Home it replaces the tab with a login shell and renames it `Terminal`;
  from Apps Manager it opens a new tab. Closing the shell closes the tab; when
  it was the last tab, the session recreates Home.
- No wrapper and no settings: the shell is the application. The entry is in
  the **System** category and cannot be removed without removing the system
  apps package.

## 8. Privileged operations

The session runs as `cpz`. One helper does all package work:

```text
/usr/lib/cpz/app-install refresh-catalog
/usr/lib/cpz/app-install install <package>
/usr/lib/cpz/app-install remove  <package>
```

- Installed through `/etc/sudoers.d/20-cpz-apps` as
  `cpz ALL=(root) NOPASSWD: /usr/lib/cpz/app-install`. No wildcard arguments,
  no `pacman` rule, no shell.
- `install`: validate the name shape, run `pacman -Syu --noconfirm`, then
  require the package to come from the `[cpz-apps]` repository (`pacman -Si`
  must print `Repository : cpz-apps`), then run
  `pacman -S --needed --noconfirm -- <package>`. The system is fully upgraded
  before a single app is added, so no partial-upgrade state exists; an app that
  is not in the repository installs nothing.
- `remove`: the package must be installed, must not be in the protected list
  and must not be required by `cpz-ui`/`cpz-system-apps`. The helper runs
  `pacman -Rns --noconfirm -- <package>`.
- `refresh-catalog`: rate-limited, runs `pacman -Sy` and then
  `pacman -S --needed --noconfirm cpz-apps-catalog`. It is the only `-S`
  without `-u`, allowed because the catalog package is data-only, has no
  dependencies and installs no library or binary. A package test enforces
  `depends=()`; if that ever changes, the exception is removed.
- Every invocation is validated with an anchored package-name regex, logged to
  the journal, and returns the transaction output on stderr. The TUI shows a
  short message and the log location, never untrusted raw output as a command.
- No other `-Sy` without `-u`: a partial upgrade on a rolling distribution
  breaks libraries. A full `-Syu`/`-Su` is the price of installing on Arch;
  the UI says so before running it.

Protected list: `/usr/share/cpz/protected-packages` in `cpz-system-apps` plus a
hard-coded package check in the helper. `pacman -Rdd` can still break it; that
is unsupported and not defended against.

## 9. Launch semantics

- Terminal apps launch with argv, never through a shell:
  `tmux -L cpz new-window -- <exec...>` from Apps Manager, or process
  replacement from Home.
- Field codes `%f`, `%u`, `%F`, `%U` have no document source in this UI;
  Apps Manager refuses entries that require one and shows the reason. `%i`,
  `%c`, `%k` expand as usual.
- `Terminal=false` entries are out of scope for the four system apps;
  Apps Manager still lists them but its Open action uses the session launcher
  path, not tmux.
- Opening an app from Apps Manager does not close it. It stays on its tab
  and the app gets a new tab (`X-CPZ-Tab=new` is the default for Apps Manager
  launches).
- Failures are reported in Apps Manager's status line; it never exits on a
  failed launch.

## 10. Headless mode

Every operation the screens offer is also a command, so an install works over
SSH, from a script or in a test. Headless means no TUI, no cursor control and
no prompts.

```text
cpz-app apps list    [--installed|--available] [--category C] [--query Q] [--json]
cpz-app apps install <package|desktop-id> [--yes] [--json]
cpz-app apps remove  <package|desktop-id> [--yes] [--json]
cpz-app apps update  [--yes] [--json]
cpz-app settings about [--json]
```

- A desktop id (`cpz-player.desktop`) is accepted wherever a package name is;
  it is resolved through the catalog and then `pacman -Qo`.
- `--json` prints one object (schema 1) on stdout and nothing else; errors go
  to stderr with the exit code.
- A mutation needs `--yes` when stdin is not a TTY, and always with `--json`.
  Without it the command exits 3 and touches nothing.
- `--yes` skips the confirmation only. The helper still validates the package,
  the catalog and the protected list; `cpz-app` never calls pacman directly.
- Exit codes: 0 ok, 1 operation failed, 2 usage, 3 confirmation required,
  4 unknown app/package, 5 protected or system package, 6 offline.
- `cpz-app apps` or `cpz-app home` without a TTY prints the plain list instead
  of starting Bubble Tea.
- This is the contract the hardware checklist uses:
  `cpz-app apps install cpz-app-player --yes` followed by
  `cpz-app apps list --installed`.

## 11. Versioning and compatibility

- `cpz-system-apps` and each app are versioned independently, like the UI.
- `X-CPZ-Contract=1` is the app contract. Apps Manager hides entries whose
  contract is newer than the running system apps.
- The catalog carries its own schema version. An unknown schema is ignored;
  Apps Manager falls back to the built-in list of system apps.
- Rollback is `pacman -U` from the local cache, as with the UI. The catalog
  package is versioned with the repo and rolls back with it.

## 12. Implemented in this tree

- `config.sh`: `UI_LANGUAGE="en"`, `UI_APPS_REPO_STABLE`, `UI_APPS_SIGLEVEL`
  and the optional `UI_APPS_CATALOG_VERSION` / `UI_APPS_CATALOG_SHA256` pins.
- `scripts/30-configure.sh`: validates the language and writes
  `/etc/cpz/language`.
- `scripts/35-ui-repo.sh`: writes `/etc/pacman.d/cpz-apps.conf` and its
  `Include` only when `UI_APPS_REPO_STABLE` is set, so a missing release never
  breaks `pacman -Sy`.
- `scripts/45-ui-test.sh`: requires the apps repository, installs
  `cpz-system-apps` and `cpz-apps-catalog`, checks the pinned sha256, and
  records the catalog version, hash and `generated` date in the build report.
- `scripts/40-image.sh`: appends the catalog record to the image report.
- `scripts/50-verify.sh`: asserts the language file, the apps repository
  config, the system apps, the helper, the protected list, the catalog schema,
  `depends=()`, the Home default command and the Apps Manager binding; the
  base image asserts the app files are absent.
- `ui/cpz-ui`: depends on `cpz-system-apps`; `Alt+O` opens Apps Manager;
  `default-command` is Home. The `fzf` launcher stays packaged as a fallback
  until Apps Manager passes the hardware checklist.
- `docs/HARDWARE-TEST.md`: checklist updated for Home, Apps Manager,
  Settings, Terminal, the catalog and the language.

## 13. Remaining work

| Item | State |
| --- | --- |
| Go apps, kit, i18n, catalog generator, helper, packaging | done |
| Local test repository (`tools/build-repo.sh`) | done, used for a local UI build |
| Base language file, repo stanza, baked catalog, verify checks | done |
| Sign and publish `apps-stable` with the CPZ UI key | pending |
| Pin the first published catalog in `config.sh` for release builds | pending |
| Device checklist: install/remove, refresh, protection, 40×10 layout | pending |
| Remove `fzf`/`j4-dmenu-desktop` after the hardware sign-off | pending |

Order matters: publish the signed `apps-stable` release, then ship a base image
with the `[cpz-apps]` stanza, and only then release a `cpz-ui` that depends on
`cpz-system-apps`. The helper must pass tests for name validation, protected
packages, the data-only catalog exception and partial-upgrade refusal before
the release.
