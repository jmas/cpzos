# Persistent state contract

This document is normative. It defines what CPZ treats as user data, where that
data lives, and how it may change between releases. OTA updates, factory
resets and feature work must all follow these rules.

The short version:

> The OS image is replaceable. `/home` is the only persistent store for
> user-specific state. `/etc` belongs to the image and is never edited at
> runtime.

The image keeps only factory defaults. A new release replaces the whole system
slot; it must not need to preserve anything outside `/home`.

## 1. State classes

| Class | Location | Survives an OTA | Examples |
| --- | --- | --- | --- |
| User data | `/home/<user>/**` | yes | files, shell and tmux history, media, user SSH keys |
| User configuration | `/home/<user>/.config/cpz/**` | yes | `settings.conf`, `keys.conf`, `system.json` |
| User state | `/home/<user>/.local/state/cpz/**` | yes | session layout, CPZ Hub manifest |
| User cache | `/home/<user>/.cache/cpz/**` | yes, may be cleared | Hub catalog, generated tmux bindings |
| Machine identity | system slots | inherited from the previous slot | `/etc/shadow`, `/etc/machine-id`, SSH host keys |
| System packages | rootfs | no | apt packages installed through CPZ Hub |
| System configuration | `/etc` | no, replaced by the image | unit files, udev rules, sudoers |
| Runtime state | `/run`, `/tmp` | no | cage output, foot config, XKB cache |
| Derived system files | `/usr/share/X11/xkb/symbols/cpz_*` | no, regenerated | generated keyboard layouts |

"User-specific" means a value the user can change from Settings, a shortcut or
a normal application. Such a value must live under `/home`. It must not be
stored in `/etc` or `/var`, because those are replaced or reset by an update.

Machine identity is the one deliberate exception. It is not configuration and
must not be copied into a user home, where it would end up in backups. On an
A/B system the new slot inherits it from the slot that is being replaced.

## 2. Current audit (CPZ 0.9.0)

### Already in `/home`

- **Settings** — `~/.config/cpz/settings.conf`, written by `cpz-settings`
  (`save_settings`); `/etc/cpz/settings.conf` is a read-only factory fallback.
- **Key bindings** — `~/.config/cpz/keys.conf`; generated tmux bindings in
  `~/.cache/cpz/tmux-keys.conf`, both owned by `cpz-keys`.
- **Session layout** — `~/.local/state/cpz/session.tsv`, written by
  `cpz-session-save` and read by `cpz-session-restore`.
- **CPZ Hub** — catalog cache in `~/.cache/cpz/hub.json`, the installed-app
  manifest in `~/.local/state/cpz/hub-apps.json`. The first read migrates the
  old `~/.local/state/cpz/trove-apps.json` manifest and keeps only records that
  exist in the current hub index.
- **Audio** — PipeWire/WirePlumber volume, mute and default-device state live
  in `~/.local/state/wireplumber`.
- **Application state** — Midnight Commander, cmus and mpv keep their own state
  under `/home`; foot and tmux use generated runtime config plus home state.

### Not in `/home` today

These are the known deviations. They block a clean OTA because replacing the
system slot loses them.

| Priority | State | Current location | Written by | Target |
| --- | --- | --- | --- | --- |
| P0 | Wi-Fi credentials (PSK) | `/etc/NetworkManager/system-connections/*.nmconnection` | `nmcli` from `cpz-settings` | declarative network config in `/home` plus a root projection, or root-only keyfiles under `/home/.cpz/machine/network` |
| P0 | Bluetooth pairings and link keys | `/var/lib/bluetooth/<adapter>/` | BlueZ via `bluetoothctl` | root-only snapshot under `/home/.cpz/machine/bluetooth`, restored before `bluetooth.service` |
| P0 | Password hash | `/etc/shadow` | `passwd` from `cpz-first-login` and Settings | slot-to-slot identity inheritance |
| P0 | Machine identity | `/etc/machine-id`, `/etc/ssh/ssh_host_*` | systemd, `ssh-keygen -A` | slot-to-slot identity inheritance |
| P1 | SSH enabled flag | `ssh.service` / `ssh.socket` unit state | `cpz-settings` | `system.json`, applied at boot |
| P1 | Locale | `/etc/locale.conf`, `/etc/default/locale` | `cpz-locale-apply` | `language` in `settings.conf`; all locales pre-generated in the image; session environment applied by `10-cpz-locale.sh` |
| P1 | Time zone and NTP | `/etc/localtime`, `/etc/timezone`, timesyncd | `timedatectl` from `cpz-settings` | `system.json`, applied at boot; per-session `TZ` |
| P1 | Radio on/off | `/var/lib/systemd/rfkill/`, `NetworkManager.state` | `nmcli radio`, `cpz-wifi`, `cpz-bt-unblock` | `system.json`, applied at boot |
| P2 | User themes | `/etc/cpz/themes` only | build | `~/.local/share/cpz/themes`, with the image directory as fallback |
| P2 | First-login marker | `/etc/cpz/shadow-mtime` | build, read by `cpz-first-login` | identity handling; the user-visible marker moves to `~/.local/state/cpz` |
| — | Installed apt packages | rootfs | `cpz-settings` (Hub) | not data: keep the manifest in `/home` and restore after a slot switch |
| — | System journal | `/var/log/journal` | journald | not data; document the retention policy separately |

Keyboard layout is already a user setting (`settings.conf`). The runtime writes
to `/usr/share/X11/xkb/symbols/cpz_*` are derived files: they are regenerated
by `cpz-keyboard-layout` after every update and do not need to survive.

`README.md` still describes the locale helper as writing `/etc`; that text
describes 0.9.0, not the target contract.

## 3. Directory layout (target)

```text
/home/<user>/.config/cpz/settings.conf   UI and session settings
/home/<user>/.config/cpz/keys.conf       shortcut overrides
/home/<user>/.config/cpz/system.json     declarative system intent
/home/<user>/.local/state/cpz/           session.tsv, hub-apps.json, markers
/home/<user>/.cache/cpz/                 catalog and generated bindings
/home/.cpz/machine/                      root:root 0700, not a user home
```

`system.json` is the only place where a user asks for a system-level change.
It is declarative input; the system remains the executor. A first version can
look like this:

```json
{
  "schema": 1,
  "timezone": "Europe/Kyiv",
  "ntp": true,
  "ssh": false,
  "radios": {"wifi": true, "bluetooth": false},
  "network": {
    "connections": [
      {"id": "home", "ssid": "example", "psk": "..."}
    ]
  }
}
```

Secrets (Wi-Fi PSKs, Bluetooth link keys) belong in root-only storage under
`/home/.cpz/machine/`, not in a world-readable config file and not in a file
the UI prints.

`/home/.cpz` is inside `/home`, so it survives an update, but it is machine
state rather than a user home. Do not create files there from a user session,
and do not include it in a per-user backup.

## 4. Rules

### Where state may live

1. **MUST** store every user-changeable value under `/home`.
2. **MUST NOT** write user-changeable state to `/etc`, `/var/lib` or
   `/var/cache` at runtime. A new exception needs an entry in section 8 and an
   allowlist entry in `tests/test_state_contract.py`.
3. **MUST** treat `/etc/cpz/*` as read-only factory defaults. The user file is
   read first; the system file is only a fallback.
4. **MUST** treat files in `/run`, `/tmp` and generated XKB files as
   regenerable. Nothing may depend on them surviving a reboot or an update.
5. **MUST** keep system packages out of the data model. Record the user's
   intent (the Hub manifest) in `/home` and reinstall after a slot switch.

### File formats and compatibility

6. **MUST** version every persistent JSON file with an integer `schema`. Keep
   reading the legacy field name (`version`) where it already exists.
7. **MUST** migrate forward only. A loader that sees a newer schema than it
   understands must refuse to overwrite the file and tell the user to update
   the system.
8. **MUST** keep reading every schema that has ever shipped. Do not delete a
   migration because "nobody can have that version any more".
9. **MUST** keep legacy key aliases working. The existing `font_size` →
   `font_size_panel`/`font_size_hdmi` migration is the reference pattern:
   an explicit new key wins, a legacy key still loads, and the result is
   covered by a test.
10. **MUST NOT** remove or rename a persisted key without a migration that
    accepts the old name. Add the new key with a default first; remove the old
    one only in a later major release.
11. **SHOULD** preserve unknown keys when rewriting a JSON file, so a file
    written by a newer version is not silently damaged by an older one.
12. **MUST** write atomically: create a temporary file in the same directory,
    then `rename(2)`. Never leave a half-written config behind.
13. **MUST** use mode `0600` for secrets and `0755`/`0644` for ordinary config,
    and create directories explicitly.
14. **MUST** add a migration test fixture for every schema. Tests must load a
    file produced by the previous release, not only a freshly written one.
15. **MUST** add every new persistent path to the map in section 3 and to the
    review checklist in section 7.

### Root readers and security

16. **MUST NOT** `source`, `eval` or shell-interpolate a file from `/home` in a
    root process. Parse it with an allowlist of keys and values.
17. **MUST** open user files with `O_NOFOLLOW`, require a regular file owned by
    the expected UID, reject group/world-writable files and bound the size.
18. **MUST NOT** accept paths, commands or unit names from `/home`. A root
    helper maps a fixed key to a fixed action.
19. **MUST NOT** create root-owned files inside a user home. Machine state goes
    to `/home/.cpz/machine/`.
20. **MUST** treat a missing or unmounted data partition as an error for update
    and projection, never as "create a fresh home".

## 5. OTA mapping

With A/B slots:

1. The data partition is mounted at `/home` before `NetworkManager`,
   `bluetooth.service` and the user session.
2. The new slot boots with factory `/etc`.
3. `cpz-state-apply.service` (root, oneshot) reads the primary user's
   `settings.conf`/`system.json` and projects the system-level intent: locale,
   time zone, NTP, SSH, radios, Wi-Fi profiles, Bluetooth snapshot.
4. Identity is copied from the previous slot on the first boot of the new
   slot; a marker in `/home/.cpz/machine/slots/` records that it happened.
5. The user session starts normally. Session-only settings (theme, font,
   tmux, shortcuts) are applied by the session itself.

The same rules work for an apt-based interim update: user configuration is
already in `/home`, so package upgrades cannot overwrite it. The difference is
only that apt has no whole-slot rollback.

Backup is `tar` of `/home` (optionally excluding `~/.cache`). This is a feature
of the model and should stay true: if a user can copy `/home` to another card
and keep working, the contract is being followed.

## 6. Migration and import

A one-time import is needed when these rules first land on a device that still
has 0.9.0 state in `/etc`:

1. Read the current NetworkManager profiles, `/etc/default/keyboard`,
   `/etc/locale.conf`, `/etc/timezone` and the SSH unit state.
2. Write `system.json` (schema 1) in the primary user's home.
3. Snapshot `/var/lib/bluetooth` into `/home/.cpz/machine/bluetooth`.
4. Leave `/etc` untouched; it is now only the image default.
5. Record completion in `~/.local/state/cpz/import.json` so a second boot does
   not import stale values over newer user choices.

The import must be idempotent and must never overwrite a value that already
exists in `/home`.

## 7. Review checklist

Use this for every change, including changes made by an AI agent:

- Does the feature introduce mutable state? Where will it live?
- Is it user-changeable? If yes, it belongs in `/home`, not `/etc`.
- Is it a secret? Use the root-only machine area, not `settings.conf`.
- Does a new file need a schema and a migration?
- Does an old `/home` still load? Test with a fixture from the previous
  release, not only with the current writer.
- Does a downgrade refuse to overwrite instead of corrupting?
- Is the write atomic and the mode correct?
- Does a root helper read it? If so, is the input allowlisted and `O_NOFOLLOW`?
- Does the value survive an OTA and a factory reflash with a restored `/home`?
- Are installed packages recorded as intent rather than assumed to persist?
- Is this document updated, including the register in section 8?
- Does `tests/test_state_contract.py` still pass, or does its allowlist need a
  justified entry?

## 8. Deviation register

The static test in `tests/test_state_contract.py` scans runtime shell helpers
for writes to `/etc` and `/var/lib|/var/cache`. Every current match is listed
there with a reason. When a deviation is fixed, remove it from the allowlist;
the test fails if an allowlist entry no longer matches, so the list cannot rot.

Python helpers (`cpz-settings`, `cpz-keys`, `cpz-search`, `cpz-pointer`,
`cpz-idle`, `cpz-media-keys`) are audited manually against the table in
section 2. Their system mutations use `sudo` with explicit commands, which is
easier to review in one place than a path regex.
