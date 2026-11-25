# Application contract v1

Status: agreed on the `ui/qualities` branch. This is the UI-owned contract for
applications. It deliberately uses the freedesktop Desktop Entry standard
instead of a new manifest format.

## 1. What an application is

An application is a subset of a normal pacman package:

```text
package
  ├─ program / library / data
  ├─ /usr/share/applications/<id>.desktop   (one or more apps)
  └─ optional icons, locales
```

- The package is the install/remove unit.
- Each `.desktop` entry is one app in the launcher.
- One package may provide several apps.
- There is no app registry, no JSON manifest and no app daemon.

## 2. Discovery

The UI reads the XDG application directories, in order:

```text
$XDG_DATA_HOME/applications          (usually ~/.local/share/applications)
$XDG_DATA_DIRS/applications          (usually /usr/local/share:/usr/share)
```

A package installs into `/usr/share/applications`. User overrides go into
`~/.local/share/applications`. `NoDisplay=true`, `OnlyShowIn` and `NotShowIn`
are honoured by the launcher.

## 3. Desktop entry fields

Required:

```ini
[Desktop Entry]
Type=Application
Name=...
Exec=...
```

Recommended:

| Field | Meaning in CPZ |
| --- | --- |
| `Name[lang]`, `Comment[lang]` | localization; 11 languages |
| `Terminal=true` | run in a tmux window |
| `Terminal=false` | run as a graphical client |
| `Categories` | freedesktop categories |
| `Keywords` | search terms |
| `Icon` | hicolor icon name |
| `Actions` | extra commands |
| `StartupWMClass` | focus an existing window |
| `DBusActivatable` | standard single-instance activation |
| `X-CPZ-Tab=new\|keep` | open a new tab or reuse the current one |
| `X-CPZ-Single=0\|1` | focus an existing app instead of a second instance |
| `X-CPZ-System=true` | system app: shown in the list, never removable |
| `X-CPZ-Contract=1` | app-contract version the entry expects |

`X-CPZ-*` is used only where the Desktop Entry standard has no equivalent.
Unknown keys are ignored by other desktops and by the launcher.

## 4. Launch semantics

- The launcher uses `j4-dmenu-desktop` (or another Desktop Entry parser); it
  never evaluates `Exec` through a shell.
- Field codes `%f`, `%u`, `%U`, `%F`, `%i`, `%c`, `%k` are expanded according
  to the specification.
- `Terminal=true` entries are passed to `cpz-term-launch`, which opens a new
  tmux window in the persistent session. The Home app instead replaces its own
  window with the chosen app, so a new tab becomes the app it launches.
- `Terminal=false` entries are launched as child processes with
  `WAYLAND_DISPLAY` / `DISPLAY` / `XAUTHORITY` from the session.
- A missing binary, an invalid `Exec` or a failed launch is reported in the
  tmux message line; it never takes the session down.
- Apps run as `cpz`; none of them needs root.

## 5. Tabs and single instance

- The UI is one visible app plus tmux tabs, not a desktop.
- `Terminal=true` starts in a new tmux window by default.
- `X-CPZ-Single=1` means the launcher should focus an existing instance
  instead of starting another. Use `DBusActivatable=true` or
  `StartupWMClass` where the app supports it.
- Closing a foreground app returns to the same tab and working directory.

## 6. Status and notifications

- Apps do not draw the status bar or the shell chrome.
- An app may set its terminal title (`OSC 0/2`) or use `tmux display-message`.
- System notifications use `cpz-notify` (a wrapper around the tmux message
  line); there is no custom notification socket.
- A desktop notification daemon is optional. If present, it follows the
  standard D-Bus `org.freedesktop.Notifications` interface.

## 7. Localization

- All visible strings use `Name[lang]`, `Comment[lang]`, `Keywords[lang]` and
  the package's locale catalogs.
- Target languages: en, de, es, fr, it, ja, pl, pt, tr, uk, zh. Resolution
  order (`CPZ_LANG`, `~/.config/cpz/language`, `/etc/cpz/language`, `LANG`,
  `en`), catalog file format and fallbacks are defined in
  [LANGUAGE.md](LANGUAGE.md).
- Translations must fit the panel; truncated labels are a bug.
- Keyboard layouts switch live; an app must not require a session restart.

## 8. Packaging

- A normal pacman package; no special package type.
- Runtime dependency on the UI contract, e.g. `depends=('cpz-ui>=0.1')`.
- Install the desktop entry, binary and icons; do not edit `/etc`.
- Removing the package removes its entries; user state under
  `~/.local/state/cpz` may remain.
- `desktop-file-validate` must pass; run `update-desktop-database` after
  install when the package provides MIME types.

## 9. Validation and tests

- `desktop-file-validate <entry>`.
- Launcher smoke test: entry appears, `Terminal=true` opens a tmux window,
  `Terminal=false` launches a client, invalid `Exec` shows an error.
- No app name is hardcoded in the session or launcher.

## 10. Examples

```ini
[Desktop Entry]
Type=Application
Name=Terminal
Name[uk]=Термінал
Comment=Open a shell in a new tab
Exec=bash -l
Terminal=true
Categories=System;TerminalEmulator;
Keywords=shell;console;
X-CPZ-Tab=new
X-CPZ-Contract=1
```

```ini
[Desktop Entry]
Type=Application
Name=Help
Comment=Keys and session help
Exec=/usr/lib/cpz/help
Terminal=true
Categories=System;Documentation;
```

## 11. System apps and the catalog

- A system app is an ordinary entry shipped by `cpz-system-apps` with
  `X-CPZ-System=true`. It appears in Apps Manager like any other app, is
  marked non-removable and never offers Remove.
- Home, Apps Manager and Settings are preinstalled with the UI: `cpz-ui`
  depends on `cpz-system-apps`. The clean base image stays UI-free by design.
- Protection is enforced twice: `cpz-ui` depends on `cpz-system-apps`, and the
  install helper refuses to remove protected packages. The field alone is a
  label, not a security boundary.
- The desktop entry does not name its package. The catalog maps entry id to
  package for available apps; for an installed app Apps Manager resolves the
  owner with `pacman -Qo <entry>` when the detail screen opens.
- Available-app metadata is generated at package build time from these entries
  into `/usr/share/cpz/catalog/apps.json` (`cpz-apps-catalog`). The XDG
  directories remain authoritative for installed apps; the catalog only adds
  the not-yet-installed ones.
- Category grouping in Apps Manager uses the first main freedesktop category.
  Every entry needs at least one main category.
- A catalog entry whose contract is newer than the running system apps is
  listed but not installable until the system is updated; the reason is shown.

## 12. Console interface

Every console application follows [TUI-CONTRACT.md](TUI-CONTRACT.md): the
shared toolkit, the plain-`F`/`X`/`Z`/`C` navigation, panel-first layout and
the latency budgets. That document is binding for system and third-party apps.

The repository, catalog, Apps Manager, Home, Settings and privileged helper are
described in [APP-PLATFORM.md](APP-PLATFORM.md).
