# CPZ Menu & Status RFC

Status: draft 2 · scope: `cpz-menud`, `cpz-ui`, app manifests, providers,
status bar, core UI states

This revision replaces the "files only" draft with the smallest architecture
that still behaves like a real system: a tiny menu daemon that owns a merged,
atomic model, a thin shell that renders it, static manifests for installed
apps, and typed runtime providers for live state.

## 1. How iOS does it (reference, not a port)

iOS is a useful map because it separates the shell, the app registry and live
widgets:

| iOS | Role | CPZ equivalent |
| --- | --- | --- |
| SpringBoard | owns the home screen, icons, transitions, system overlays; apps never draw the home screen | `cpz-ui` |
| LaunchServices / installerd | registry of installed app bundles, names and icons | static manifests scanned by `cpz-menud` |
| WidgetKit host | asks widget extensions for timeline entries and renders them itself | `cpz-menud` + typed status widgets |
| WidgetKit / ActivityKit providers | supply data, not pixels or layout | provider apps (battery, clock, network, BT) |
| System status bar | system-owned; apps choose style, system services own the items | typed widgets rendered by the shell; battery/clock are system providers |
| UIAlertController | system-rendered alerts, confirmations, action sheets, text input | core states: `info`, `error`, `confirm`, `choice`, `input` |
| XPC + entitlements | isolation between shell and apps | one Unix socket, root-only appliance; limits instead of sandbox |

What we borrow: **the shell owns presentation; apps own data; installed apps
have a persistent registry; live widgets are typed and system-rendered.** What
we deliberately skip: XPC, entitlements, Objective-C plumbing, a full widget
gallery, and arbitrary drawing in the status bar.

One deliberate deviation: iOS does not let third-party apps add status-bar
items. CPZ does, but only through the five typed widget kinds below, so the
shell still controls layout and style.

## 2. Summary

```
/usr/share/cpz/apps/<id>/app.json     static manifests (installed, root)
                 │ scan / rescan
                 ▼
 provider apps ── register/update/heartbeat ──▶ cpz-menud
 (battery, clock,                               │  merged model + generation
  network, BT, music)                           │  snapshot + subscribe
                                                ▼
                                            cpz-ui (thin shell)
                                                │ action (exec/run)
                                                ▼
                                            cpz-session
```

- **`cpz-menud`** is the single source of truth for the menu tree and status
  widgets. It is stateless on disk: static manifests + live registrations.
- **`cpz-ui`** renders the snapshot, owns navigation, transitions, the status
  bar layout and every core state. It never knows what "Settings" or "Music"
  is.
- **Providers** register typed menu overrides and status widgets. A daemon
  keeps one connection open; a one-shot CLI uses TTL + heartbeat.
- **`cpz-session`** remains the only process that starts foreground apps.
- If `cpz-menud` is down, the shell keeps its last snapshot and falls back to a
  compiled-in emergency menu; it does not crash and does not block input.

Why a small daemon instead of the previous file-only draft: the snapshot is
atomic, menu changes arrive immediately (subscription) with a 1 s fallback,
dead providers are reaped on connection close, and icons/limits/priority are
validated in one place. That is the "not too poor" middle ground.

## 3. Components

| Component | Owns | Does not own |
| --- | --- | --- |
| `cpz-menud` | merge, ordering, TTL/liveness, validation, icon cache, generation, subscriptions | drawing, app launch |
| `cpz-ui` | menu tree rendering, navigation, transitions, status slotting, core states, icon cache | menu content, provider data |
| `cpz-session` | stop/start the shell and foreground apps, `exec` and `run` | menu model |
| static app | `app.json`: identity, static menu items | live state |
| provider | runtime menu overrides, typed status widgets, notices | layout, pixels, ordering policy |

`cpz-menud` is a separate systemd unit rather than a module of `cpz-session`:
the session is allowed to die/restart with every app, while the menu model must
not. The daemon is stateless and cheap; folding it into the session later would
keep the same API.

## 4. Static manifests

One directory per app:

```
/usr/share/cpz/apps/<id>/app.json
/usr/share/cpz/apps/<id>/icon.png       menu artwork, owned by the app
```

```json
{
  "id": "terminal",
  "name": "Термінал",
  "menu": [
    {
      "id": "terminal",
      "label": "Термінал",
      "detail": "bash, vim, tmux",
      "parent": "root",
      "order": 100,
      "icon": "icon.png",
      "action": { "exec": ["/usr/local/bin/cpz-term"] }
    }
  ]
}
```

- Root-owned, read-only. Scanned at startup and on `rescan` (package install,
  SIGHUP). A rescan is also triggered by inotify on the directory.
- **Icons belong to apps.** A menu item points at a relative PNG inside its
  own bundle (12–96 px square, 8-bit RGBA, ≤16 KiB, no `..`), and the same
  rule applies to `info.icon` and `choice[].icon`. The shell has no table of
  application glyphs, so installing an app never means editing `cpz-ui`.
  `builtin:<name>` remains for shell-owned marks only: status widgets
  (`wifi`, `ethernet`, `bluetooth`, `clock`, media) and the `info`/`success`/
  `warning` severity icons of shell-rendered pages.
- `cpz-ui` draws an app PNG as an alpha mask tinted with the current row
  colour, so one file works on the white list and on the azure selection bar.
- A provider may also have a manifest (e.g. Music: static submenu) and a
  daemon that supplies live badges/status.

## 5. Provider protocol

Unix stream socket `/run/cpz/menu.sock`, NDJSON, v1, max 64 KiB per message.

Roles:

- **UI**: `hello` → `snapshot` → `subscribe` → snapshots on change.
- **Provider**: `hello` with app id + token, then `register` / `update` /
  `heartbeat` / `unregister`.
- **Admin**: `rescan` (package manager, root).

```json
{"v":1,"op":"hello","role":"provider","app":"battery","token":"..."}
{"v":1,"op":"register","ttl_ms":5000,"menu":[...],"status":[...]}
{"v":1,"op":"update","menu":[{"id":"music","badge":"4"}],"status":[...]}
{"v":1,"op":"heartbeat"}
{"v":1,"op":"unregister"}
```

```json
{"v":1,"op":"snapshot"}
{"v":1,"op":"subscribe"}
```

Daemon → client:

```json
{"v":1,"generation":42,"menu":[...],"status":[...]}
{"v":1,"event":"changed","generation":43}
{"v":1,"event":"icon","hash":"ab12...","png":"<base64>"}
{"v":1,"error":"..."}
```

Rules:

- **Liveness.** A daemon holds its connection open; closing it removes that
  app's runtime registrations immediately. One-shot providers declare
  `ttl_ms` (default 10 000) and call `heartbeat`; expiry removes their data.
- **Tokens.** `/run/cpz/menu/<id>.token` is created by the installer or the
  daemon; a provider may update only its own id. `SO_PEERCRED` is logged.
- **Coalescing.** The daemon applies updates immediately but notifies
  subscribers at most every 250 ms. The UI also polls `snapshot` at 1 Hz as a
  fallback. A burst of widget updates cannot storm the renderer.
- **Icons.** Snapshots carry `builtin:name` (shell marks only) or
  `{"png":"<hash>"}` for app artwork. The UI asks for an unknown hash once and
  caches it. The daemon validates dimensions and size. This keeps snapshots
  small.
- **Limits.** 64 items per app, depth 4, label ≤80 bytes, badge ≤4 chars,
  status text ≤8 chars, 10 updates/s per app, 64 KiB messages.

## 6. Menu model

```json
{
  "id": "music",
  "label": "Музика",
  "detail": "пісні, альбоми",
  "parent": "root",
  "order": 300,
  "icon": "icon.png",
  "badge": "3",
  "enabled": true,
  "visible": true,
  "confirm": "Почати відтворення?",
  "action": { "exec": ["/usr/local/bin/cpz-music"] }
}
```

| Field | Meaning |
| --- | --- |
| `id` | globally unique, `<app>.<item>` |
| `label`, `detail` | final display strings |
| `parent` | item id or `root`; children make a submenu |
| `order` | integer, gaps recommended (100/200/300) |
| `icon` | relative PNG in the app bundle (`builtin:` for shell marks) |
| `badge` | short string, max 4 characters |
| `enabled`, `visible` | default true |
| `confirm` | optional question shown by the core before acting |
| `action` | `exec`, `run`, `info`, `choice`, or omitted for a submenu |

Merge:

1. Static manifests are the base.
2. Runtime registrations override fields by `id`; runtime-only items are added.
3. Unknown parent or a cycle attaches to `root` and is logged once.
4. Siblings sort by `order`, then `id`; deterministic across boots.
5. Expired providers and their overrides disappear automatically.

### Actions

- `exec`: foreground app. The UI sends `launch` to `cpz-session`; the shell
  exits. This is the only path that owns the display.
- `run`: short background command (`cpz-session run`); the shell stays
  visible. For toggles.
- `info`: shell-rendered page (title, text, icon, optional action). Used for
  About, "no music", first-run tips, without a separate app.
- `choice`: shell-rendered list of labelled actions (e.g. output auto/panel/
  HDMI); each option carries `exec` or `run`.
- Commands are argv arrays, absolute paths from an allowlist, never a shell.

## 7. Status widgets

The right cluster is composed from provider widgets; the shell owns layout.

```json
{"id":"battery","kind":"battery","level":82,"charging":false,
 "order":100,"priority":90,"system":true}
{"id":"clock","kind":"text","text":"14:32","order":30,"priority":40}
{"id":"wifi","kind":"glyph","name":"wifi","order":20,"priority":50}
```

| Kind | Data | Drawing |
| --- | --- | --- |
| `battery` | `level` 0–100, `charging` | iPod-style battery, drawn by the shell |
| `clock` | `text` ≤5 chars | shell text |
| `glyph` | `name` | built-in monochrome glyph |
| `png` | `hash` / custom icon | validated, cached, drawn as a tinted mask in the status colour |
| `text` | `text` ≤8 chars | short label |

Layout policy:

- Right cluster. A `system:true` battery is always rightmost; other widgets
  to its left.
- 16 px logical status glyphs, 2 px gaps; at most 3 widgets on 320 px.
- Sort by `order`, then `id`; hide the lowest `priority` when space runs out.
- The title is left-aligned in the space that remains after the status
  cluster; it shares one text column with every menu label. A 20 px app icon
  sits in the gutter to the left of that column, whether a row has an icon or
  not, and the back chevron occupies the same slot.
- Widgets are informational. With no pointer, interaction belongs in a menu
  item or an app screen.
- Provider updates are pushed on change (not polled); the daemon coalesces to
  4 Hz, so battery/clock once per second is cheap and the renderer never
  spins.

Battery, clock, network and Bluetooth are **system providers**: ordinary
daemons using the same API, shipped with the image, with reserved slots and
higher priority. This satisfies "all icons come from apps" without letting a
third-party app push the battery out of the bar.

## 8. Core UI states

The shell is a state machine. Foreground apps are not shell states: when an app
runs, the shell has exited. These states belong to `cpz-ui` and are triggered by
core events or by declarative data from the menu model.

| State | Trigger | Interaction | Exit |
| --- | --- | --- | --- |
| `boot` | process start / boot splash | none | automatic |
| `menu` | normal | Z/F/X/C, Enter/Esc | transitions |
| `empty` | no menu items | Enter = rescan, C = Terminal | when items appear |
| `degraded` | `cpz-menud` unreachable | fallback menu, retry | auto-recover |
| `loading` | launch requested | none; 10 s timeout | app starts or `error` |
| `busy` | shell action (output switch, reboot) | none | action completes |
| `progress` | determinate task | cancel if allowed | done or `error` |
| `info` | `info` action, About, tips | Enter/any key | back to menu |
| `error` | launch/session failure | Enter = retry, Esc = back | retry/menu |
| `confirm` | item `confirm` | F/X or Z/C choose, Enter, Esc | action or cancel |
| `choice` | `choice` action | list navigation, Enter, Esc | option or cancel |
| `input` | reserved (Wi-Fi password, search) | keyboard, Enter, Esc | submit or cancel |
| `toast` | core notice / provider notice | none (non-blocking) | 2.5 s timeout |

Notes:

- `info` has a severity icon: info, success, warning. It is **not** an error;
  it never blocks recovery. `error` is a blocking failure with an explicit way
  out.
- `confirm` defaults to the safe choice (No for destructive actions). `choice`
  defaults to the first option. Both preserve the menu selection behind them.
- `busy` and `loading` look similar (full-screen wait) but differ: `loading`
  names the app being launched, `busy` names a shell operation and never times
  out into "retry".
- `progress` is determinate; a cancel action is optional. `loading`/`busy` are
  indeterminate.
- `toast` overlays every state except `boot`; only one toast at a time.
- Provider notices are toasts only. Providers cannot force a full-screen
  `error`; full-screen errors are core-owned, so a misbehaving app cannot
  hijack the display.
- Shell states have a small stack: `menu` → `info`/`error`/`confirm`/`choice`/
  `input` push, back pops; `loading`/`busy`/`progress` replace the base and
  return to it. `toast` is an overlay.
- `boot` and `degraded` are base states; `empty` is a base state with an info
  page. A base state is never combined with another base state.

Key mapping (all states): `Z` back/cancel, `C` open/confirm, `F`/`X` move
selection, `Enter` confirm, `Esc` back/cancel. `loading` and `busy` ignore
keys. `info` and `error` accept any key to return (error's Enter retries if a
retry action exists).

## 9. Update, liveness, performance

- Providers push; the UI subscribes. Fallback snapshot poll: 1 s.
- Coalescing window: 250 ms; UI redraws at most 4 Hz for provider changes.
  Input handling is immediate and never waits for the daemon.
- Snapshot budget: ≤20 KiB for 50 items and 5 widgets (icons fetched by hash).
- Liveness: connection close = immediate cleanup; TTL for one-shot providers.
- A provider crash cannot leave stale CPU work: no callbacks into apps, only
  cached data.
- Static manifests are rescanned on install or SIGHUP; no polling of the app
  directory is required.

## 10. Failure handling

| Failure | Behaviour |
| --- | --- |
| `cpz-menud` down | UI keeps the last snapshot; `degraded` if none; auto-retry |
| provider crashes | connection close removes its data immediately |
| one-shot provider dies | TTL expiry (≤10 s) |
| malformed JSON | message rejected, provider connection closed, one log line |
| invalid PNG | icon rejected, placeholder shown |
| launch timeout | `error` with retry |
| menu changes while navigating | same id keeps selection; otherwise clamp |
| empty registry | `empty` state with rescan/Terminal |
| corrupt token | provider rejected |

## 11. Security and limits

- Static manifests are root-owned. Runtime writes require the app's token.
- The daemon runs as a system service, no DRM access. Apps remain root for DRM
  today; tokens/SO_PEERCRED prevent accidental cross-app updates, not a
  hostile root.
- Allowlisted executable paths; argv arrays; no shell.
- Message/icon/item limits above; rate limit per app; coalesced notifications.
- Icon paths resolved inside the app directory; `..` rejected.

## 12. Migration

1. `cpz-menud` with static manifests + snapshot; `cpz-ui` renders the tree and
   keeps a compiled-in emergency menu.
2. Move the current root/Music/Video/Photo/Games/Settings/About data into
   `app.json` files; no app names remain in `cpz-ui.c`.
3. Add `cpz-battery` and `cpz-clock` system providers; remove the sysfs read
   from the shell; the shell draws the battery widget from provider data.
4. Add `run` to `cpz-session`; turn Settings into a normal app.
5. Add `info`, `confirm`, `choice` actions/states; add provider notices as
   toasts.
6. Add network and Bluetooth providers; add `input` when a real text prompt is
   needed.
7. Add `cpz-menu` CLI (`list`, `status`, `rescan`, `register`) for scripts and
   debugging.

## 13. Examples

Static app:

```json
{ "id": "terminal", "name": "Термінал",
  "menu": [ { "id": "terminal", "label": "Термінал", "parent": "root",
              "order": 100, "icon": "icon.png",
              "action": { "exec": ["/usr/local/bin/cpz-term"] } } ] }
```

Battery provider:

```json
{ "v":1, "op":"register", "ttl_ms":5000,
  "status": [ { "id":"battery", "kind":"battery", "level":82,
                "charging":false, "order":100, "priority":90,
                "system":true } ] }
```

Music with live badge and status:

```json
{ "v":1, "op":"update",
  "menu": [ { "id":"music", "badge":"4" } ],
  "status": [ { "id":"music.play", "kind":"glyph", "name":"play",
                "order":10, "priority":50 } ] }
```

Shell-rendered info item:

```json
{ "id":"about.item", "label":"Про пристрій", "parent":"root", "order":800,
  "action": { "info": { "title":"Про пристрій", "icon":"icon.png",
                        "text":"Cardputer Zero CM0\ncpz-ui 1.0" } } }
```

## 14. Why this is the optimum

- One small daemon gives atomic snapshots, immediate updates, liveness and
  validation; the UI stays a pure renderer.
- Static manifests make installed apps persistent without running them; typed
  providers make live state cheap and consistent.
- The shell owns every pixel and every state, exactly like SpringBoard/WidgetKit
  do on iOS; apps never draw the home screen or the status bar.
- The protocol is one Unix socket and NDJSON; the data model is a flat menu
  list plus typed widgets. No XPC, entitlements, widget galleries or drawing
  APIs.
- The failure model is explicit: last snapshot, fallback menu, TTL, connection
  close, retry states. Nothing can freeze the menu.

## 15. Open questions

- Whether `input` should be exposed to apps or remain shell-only for Wi-Fi
  setup.
- Whether provider notices need a persistent notification center, not just
  toasts.
- Whether `progress` should support app-defined tasks or stay a shell state for
  output switching/updates.
- Localization: one string per manifest today; per-locale fields can be added
  without changing the merge model.
