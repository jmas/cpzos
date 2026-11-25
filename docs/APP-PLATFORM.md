# Application platform

Status: agreed on `design/app-platform` (2026-11-26). The repository name, the
stack, Home semantics, the update policy and the product names are decided.
Implementation has not started; the existing launcher (`fzf` +
`j4-dmenu-desktop`) and the two desktop entries are the current state.

Decided: `jmas/cpzos-apps`; Go + Bubble Tea; Home replaces the tab with the
chosen app; installs and catalog refreshes run a full `pacman -Syu`; the three
system apps are preinstalled with the UI and are named **Home**, **Apps
Manager** and **Settings**.

Related: [APP-CONTRACT.md](APP-CONTRACT.md) (desktop entries),
[TUI-CONTRACT.md](TUI-CONTRACT.md) (console UI rules),
[LANGUAGE.md](LANGUAGE.md) (translations and the system language),
[UI-QUALITIES.md](UI-QUALITIES.md) (product budgets),
[UI-DECISIONS.md](UI-DECISIONS.md) (session stack).

## 1. Decision in one paragraph

Applications live in a separate signed repository, `cpzos-apps`, built and
published like the UI. A package installs one or more freedesktop desktop
entries; CI generates the catalog entry from those entries. The system ships
three preinstalled console apps in one protected package (`cpz-system-apps`):
**Home** (what a new tab shows), **Apps Manager** (browse, install, remove,
open) and **Settings**. All three are one Go binary built on the shared
`internal/tui` kit. Apps Manager browses a signed catalog, installs and removes
packages through one narrow privileged helper, and never evaluates a shell.
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

Repository name: `jmas/cpzos-apps`. Product name in the UI: **Apps Manager**;
the binary token stays `apps`.

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
  internal/tui/                shared kit: theme, list, detail, search,
                               dialog, keymap (us/ua), status line
  internal/catalog/            catalog types, loader, merge with installed
  internal/apps/               XDG discovery, desktop parsing, ownership
  internal/pacman/             read-only queries and helper client
  cmd/cpz-app/                 multicall entry: home | apps | settings
  system/                      the three system apps and their desktop files
  apps/<name>/                 one directory per application package
  packaging/                   PKGBUILD helpers, catalog generator
  .github/workflows/           build, test, catalog, sign, publish
```

- `internal/tui` is the only place that knows the theme, the keymap and the
  screen anatomy. An app that reimplements a list is a review failure.
- Third-party authors can copy the kit or follow `TUI-CONTRACT.md`; Apps Manager
  does not enforce the toolkit, only the desktop-entry contract.

## 5. Package and channel layout

| Package | Contents |
| --- | --- |
| `cpz-system-apps` | `cpz-app` binary, Home, Apps Manager, Settings, desktop entries, helper client, sudoers rule |
| `cpz-apps-catalog` | generated `/usr/share/cpz/catalog/apps.json`; regenerated per release |
| `cpz-app-<name>` | first-party apps (convention, not a requirement) |
| any | third-party apps, `groups=('cpz-apps')` recommended |

- The three system apps are preinstalled: `cpz-ui` depends on
  `cpz-system-apps`. The clean base image still has no UI at all, by design;
  any image or system with the UI gets Home, Apps Manager and Settings.
- `cpz-ui` depends on `cpz-system-apps`; the dependency is what makes the
  system apps non-removable through pacman, not just a UI rule.
- `cpz-system-apps` depends on `cpz-apps-catalog`, so browsing works offline
  from the installed copy.
- The apps release is published as a new pacman repository `[cpz-apps]` in a
  separate GitHub release (`apps-stable`), signed with the existing CPZ UI
  key. `Server` points at that release; pacman picks up `cpz-apps.db` there.
- The base image adds one `Include` stanza for `[cpz-apps]` in a platform
  release. No kernel, boot or session change is involved.

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
- Localized fields are copied as `name[lang]`, `comment[lang]` and
  `keywords[lang]`; Apps Manager and Home pick the system language with an `en`
  fallback exactly as [LANGUAGE.md](LANGUAGE.md) defines.
- Refreshing the catalog is a normal package update of `cpz-apps-catalog`
  (`pacman -Syu`), not a second download channel. Browsing is instant and
  offline from the installed copy; the date on the `Update app list` row shows
  how stale it is.

## 7. The three system apps

All three obey `TUI-CONTRACT.md`: plain `F`/`X`/`Z`/`C` navigation, `Enter`,
`Esc`, one focus bar, no footer, no borders, panel-first; all strings come from
their catalogs per [LANGUAGE.md](LANGUAGE.md).

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
  **No** focused. Install asks for confirmation when it pulls dependencies or
  performs a system upgrade, and always names the package and total size.
- The first row of the **All** category is `Update app list`, which runs the
  refresh transaction. It is hidden inside the other categories to keep them
  short.
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
  (`set -g default-command /usr/bin/cpz-app home`).
- One list of installed apps, same rows and search as Apps Manager, plus
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

## 8. Privileged operations

The session runs as `cpz`. One helper does all package work:

```text
/usr/lib/cpz/app-install refresh
/usr/lib/cpz/app-install install <package>
/usr/lib/cpz/app-install remove  <package>
```

- Installed through `/etc/sudoers.d/20-cpz-apps` as
  `cpz ALL=(root) NOPASSWD: /usr/lib/cpz/app-install`. No wildcard arguments,
  no `pacman` rule, no shell.
- `install`: the package must be present in the installed catalog and in the
  `[cpz-apps]` sync database. The helper runs
  `pacman -Syu --needed --noconfirm -- <package>`.
- `remove`: the package must be installed, must not be in the protected list
  and must not be required by `cpz-ui`/`cpz-system-apps`. The helper runs
  `pacman -Rns --noconfirm -- <package>`.
- `refresh`: `pacman -Syu --noconfirm`. It updates the catalog and the system
  together.
- Every invocation is validated with an anchored package-name regex, logged to
  the journal, and returns the transaction output on stderr. The TUI shows a
  short message and the log location, never untrusted raw output as a command.
- No `-Sy` without `-u`: a partial upgrade on a rolling distribution breaks
  libraries. A full `-Syu` is the price of installing on Arch; the UI says so
  before running it.

Protected list: `/usr/share/cpz/protected-packages` in `cpz-system-apps` plus a
hard-coded package check in the helper. `pacman -Rdd` can still break it; that
is unsupported and not defended against.

## 9. Launch semantics

- Terminal apps launch with argv, never through a shell:
  `tmux -L cpz new-window -- <exec...>` from Apps Manager, or process
  replacement from Home.
- Field codes `%f`, `%u`, `%F`, `%U` have no document source in this UI; the
  Apps Manager refuses entries that require one and shows the reason. `%i`, `%c`,
  `%k` expand as usual.
- `Terminal=false` entries are out of scope for the three system apps; the
  Apps Manager still lists them but its Open action uses the session launcher path,
  not tmux.
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
  contract is newer than the running system apps and says why in the detail
  screen.
- The catalog carries its own schema version. An unknown schema is ignored;
  Apps Manager falls back to the built-in list of system apps.
- Rollback is `pacman -U` from the local cache, as with the UI. The catalog
  package is versioned with the repo and rolls back with it.

## 12. What changes in this tree

Not implemented on this branch, listed for the platform follow-up:

1. `config.sh`: `UI_APPS_REPO_STABLE` (and beta, unused) and `UI_LANGUAGE`.
2. `scripts/30-configure.sh`: write `/etc/cpz/language` from `UI_LANGUAGE`.
3. `scripts/35-ui-repo.sh`: write `/etc/pacman.d/cpz-apps.conf` and include it.
4. `scripts/50-verify.sh`: assert the apps repo config, the protected list, the
   language file and the `cpz-ui` → `cpz-system-apps` dependency when the UI
   package is built.
5. `ui/cpz-ui`: add the dependency; `Alt+O` opens `cpz-app apps` in the tmux
   popup instead of the `fzf` list; `default-command` becomes Home; the
   `cpz-launcher`/`fzf`/`j4-dmenu-desktop` path is removed once Apps Manager
   passes hardware tests. `cpz-help` stays until the Help overlay covers its
   content.
6. `docs/HARDWARE-TEST.md`: add Apps Manager install/remove, Home launch,
   system-app protection, `CPZ_LANG=uk` and offline browse to the checklist.

## 13. Open questions for the owner

Only two remain:

1. Third-party apps: curated pull requests into `cpzos-apps`, or any signed
   repository may publish into `[cpz-apps]`?
2. Default `UI_LANGUAGE` for the image: `en` or `uk`? Both catalogs ship either
   way; the user can override per account.

Settled for the first release: catalogs ship `en` and `uk`; the other nine
codes resolve to `en` until translated, and adding one is a package update,
not a schema change. Home is tracked in Apps Manager's **System** category but
omitted from its own list.

## 14. Implementation plan

| Phase | Result |
| --- | --- |
| 1 | Repo skeleton, `internal/tui` + `internal/i18n` kits, catalog generator, CI |
| 2 | Home and Settings (About), language resolver with en/uk, panel/key tests |
| 3 | Apps Manager browse, search, detail screens over the installed catalog |
| 4 | Helper, sudoers, install/remove/update, headless CLI, failure paths |
| 5 | `cpz-ui` integration: preinstalled dependency, Home as default command |
| 6 | Base language file and repo stanza, verify checks, hardware checklist |

Phase 4 does not ship until the helper has tests for name validation, protected
packages and partial-upgrade refusal.
