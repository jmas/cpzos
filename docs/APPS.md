# Applications and the CPZ Hub catalog

Settings → Applications is a small, curated catalog of CLI/TUI applications
that are expected to work on CPZ. An entry must be installable from the
Debian suite used by the image or from a pinned arm64 `.deb`. The catalog lives
in the separate
[cpzos-hub](https://github.com/jmas/cpzos-hub) repository:

```text
https://raw.githubusercontent.com/jmas/cpzos-hub/main/index/hub.json
```

The image downloads `index/hub.json` during the build and stores it at
`/usr/share/cpz/hub.json`. Opening Applications reads that local file
immediately; the screen never waits for the network.

A refresh runs in the background at most once a day and writes a newer snapshot
to `~/.cache/cpz/hub.json`. The cache wins over the image copy when its
`generated_at` is newer. Press `u` to request an update explicitly; it also runs
in the background and the list reloads when it finishes.

## Scope

The hub only contains applications that CPZ can install and then remove
cleanly. Every entry is one of two kinds:

| Kind | Install | Remove |
| --- | --- | --- |
| `apt` | `apt-get install -y --no-install-recommends PACKAGE` | `apt-get purge -y PACKAGE` |
| `deb` | download the pinned `.deb`, verify SHA-256, `apt-get install ./file.deb` | `apt-get purge -y PACKAGE` |

`apt` entries reference the Debian suite used by the image. `deb` entries are
arm64 packages hosted over HTTPS and pinned in the index. `dpkg` owns the file
list in both cases, so removal does not need a custom uninstaller.

The catalog is a closed scope. Applications does **not** search the apt package
list and does not offer tools that are missing from the hub index. An
application installed outside the manager is shown as `installed (system)` and
is not offered for removal. It is also not tracked by CPZ Search.

## Keys

| Key | Action |
| --- | --- |
| `Up` / `Down` (or `k` / `j`, `f` / `x`) | move |
| `/` or `s` | search the loaded hub index |
| `Tab` | switch Browse / Installed |
| `Enter` | details |
| `i` | install the selected app |
| `e` | run an installed app |
| `d` (Installed) | uninstall a managed app |
| `u` | refresh the index in the background |
| `q` / `Esc` | back |

## Install policy

- Only applications present in the loaded hub index are shown and installable.
- An app installed through the manager is tracked. An app installed by the
  image or by plain `apt` is reported as `installed (system)` and is not
  tracked.
- A removal is simulated first and refused if it would remove a core CPZ
  package or another managed hub app.
- `apt-get purge` is used without `autoremove`, so shared dependencies are not
  silently removed.
- User configuration under `/home` is not touched by removal.

## State

The manager records only hub applications installed through Applications:

```text
~/.local/state/cpz/hub-apps.json
```

The file has `schema: 1` and stores the application id, kind, package, version,
install time and the install/remove commands. The first Applications read migrates the old
Trove-era manifest `~/.local/state/cpz/trove-apps.json` and keeps only records
that exist in the current hub index; tools installed outside the hub scope are
dropped.

Read-only catalog data:

```text
/usr/share/cpz/hub.json     image snapshot, installed at build time
~/.cache/cpz/hub.json       newer user copy from a background refresh
/etc/cpz/hub.url            build-time source URL
```

## Index schema

`index/hub.json` has `schema: 1`, `generated_at`, `count` and `apps`. Every app
has `id`, `name`, `summary`, `kind`, `package`, `categories`, `license`,
`homepage`, `source` and `source_url`. A `deb` app also has `version` and:

```json
{
  "deb": {
    "url": "https://example.com/app-1.0-arm64.deb",
    "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    "size": 2388416
  }
}
```

The index is generated from `apps/<id>.json` files in the hub repository. CI
validates the files, compiles the flat index and commits it. The initial index
was seeded from Terminal Trove and filtered to apt packages that exist in
Debian trixie arm64; later entries are expected to be checked on a device.

## Trove sync

The hub repository runs a daily workflow that imports apt-backed CLI/TUI tools
from the existing [terminal-trove-index](https://github.com/jmas/terminal-trove-index)
catalog. The sync only adds missing applications; hand-curated entries, `deb`
packages and deliberate delistings are never overwritten.

Trove is a maintainer-side discovery source. The device no longer downloads or
searches the Trove catalog, and it no longer carries an apt package-name
snapshot.

## Updating the build source

Set `CPZ_HUB_INDEX_URL` to use another index, or `CPZ_HUB_INDEX_PATH` to copy a
local checkout during development. Pin a tag or commit in the URL when a build
must be reproducible. A normal build fails when the index cannot be downloaded,
because an image without it would show an empty Applications screen.
`CPZ_OFFLINE=1` skips the download for developer builds.
