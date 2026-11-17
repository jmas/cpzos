# Applications and the Terminal Trove catalog

Settings → Applications is a local catalog browser backed by
[Terminal Trove](https://terminaltrove.com/). The catalog is not fetched from
the live site while the TUI is open. Instead:

1. The separate [terminal-trove-index](https://github.com/jmas/terminal-trove-index)
   project crawls the A-Z list and each tool page.
2. Its GitHub workflow commits `index/trove.json` and `index/trove.json.gz`.
3. The image build downloads the gzip index to
   `/usr/share/cpz/trove-index.json` and records the source URL in
   `/etc/cpz/trove-index.url`.
4. Applications reads the local snapshot. `u` downloads a newer snapshot to
   `~/.cache/cpz/trove-index.json`; the user copy takes precedence.

`CPZ_TROVE_INDEX_URL` overrides the download source for a build. An empty value
uses the hosted default. Pin a tag or commit in the URL if an image must be
reproducible. If the default repository is not published yet, the build prints
a warning and the image starts without a catalog; press `u` in Applications
after pointing the runtime URL at a reachable copy.

## Keys

| Key | Action |
| --- | --- |
| `Up` / `Down` (or `k` / `j`, `f` / `x`) | move |
| `/` or `s` | search the current list |
| `t` | category picker |
| `g` | language picker |
| `Left` / `Right` | cycle categories |
| `Enter` | details / install instructions |
| `i` | install the selected apt package |
| `Tab` | switch Browse / Installed |
| `d` (Installed) | uninstall a managed app |
| `u` | download the newest catalog |
| `r` | reload the local catalog and manager state |
| `q` / `Esc` | back |

## Install policy

The catalog is a discovery source, not a package-manager abstraction. CPZ only
installs what apt can provide:

- If Terminal Trove publishes a Debian/Ubuntu `apt install` command, that
  package is authoritative.
- If there is no Debian/Ubuntu cell, the tool slug and then its display name are
  checked in apt. This catches tools such as `lazygit` that are packaged by
  Debian without an explicit apt command on Terminal Trove.
- If neither check finds a package, the tool is shown with the install
  instructions published on Terminal Trove and is **not** tracked. The TUI
  never executes those strings.

Installs use:

```sh
sudo apt-get install -y --no-install-recommends PACKAGE
```

Removal uses the same protection as the rest of Settings:

```sh
sudo apt-get purge -y PACKAGE
```

A removal is simulated first and refused if it would remove core CPZ packages
(`kmscon`, `tmux`, `systemd`, etc.). Core package names are listed in
`PKG_CORE` in `cpz-settings`.

Only apps installed through Applications are tracked. A package that was
already installed by the image or by the user is reported as
"installed (system)" and is not offered for removal through the manager.

## State

Tracked installs are stored per user:

```text
~/.local/state/cpz/trove-apps.json
```

Each record contains the catalog slug, display name, apt package, installed
version, timestamp and the install/remove commands that were used. If the apt
package disappears externally, the Installed tab still lists the record and `d`
removes the stale tracking entry.

The catalog cache and image snapshot are read-only data:

```text
~/.cache/cpz/trove-index.json       user-updated snapshot
/usr/share/cpz/trove-index.json     image snapshot
/etc/cpz/trove-index.url            build-time source URL
```

## Index schema

`schema` is `1`. The top level contains `generated_at`, `count`, `categories`,
`languages` and `tools`. Every tool has `slug`, `name`, `summary`,
`description`, `language`, `categories`, `platforms`, `install`, `apt`,
`url`, `website`, `source` and `license`.

`install` mirrors Terminal Trove's `data-install` object: platform → package
manager → display command. `apt` is derived only from the Debian/Ubuntu cell:

```json
{
  "apt": {"command": "apt install tmux", "package": "tmux"}
}
```

## Search integration

The same catalog powers the `@` provider in `cpz-search` (Alt+O). The search
calls `cpz-settings --list-tools` for a compact JSON list and launches an
installed tool's detected command directly. A tool without a detected command
opens this Applications screen at that tool through
`cpz-settings --tool <slug>`, so installation still goes through the apt
policy above. The search never fetches the catalog from the network.

## Updating the index

Run the collector locally:

```bash
cd terminal-trove-index
python3 scripts/build_index.py
```

Or start the `update-index` GitHub workflow. The free reader tier is rate
limited; the default delay is 3.2 seconds. Set `JINA_API_KEY` for the
authenticated reader tier, or use `--via direct` where the site accepts direct
HTML requests.
