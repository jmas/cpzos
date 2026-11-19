# CPZ OS architecture and performance review

Status: static review of the `v0.6.1` tree, before the first implementation
batch. No measurements were taken on a live CM0. Every effect estimate below
is a hypothesis to confirm on hardware (`systemd-analyze`, `strace -c`,
`/proc/stat` samples). File and line references describe the reviewed tree
before that batch.

## 1. Executive summary

The system already has the right overall shape:

- clear build stages `stage0..stage3` plus `export-image`;
- an independent tmux server that survives compositor restarts;
- an event-driven display model: udev hotplug + path unit + timer as fallback;
- atomic state writes, separate `/run` files and tests for most helpers.

Most performance is lost **not in cage/foot**, but in small shell/Python
helpers that:

1. run on a 5–10 second timer and perform the full job even when nothing
   changed;
2. re-parse the same `settings.conf`, `themes/*.conf` and `keys.conf` in
   8–10 places, often with `sed`/`getent` per key;
3. start a full Python interpreter per keystroke in Search, or per
   highlighted row;
4. fork once per file in a media directory.

The biggest architectural lever is to **separate the control plane (rare
writes and validation) from the read plane (frequent, cheap reads)** by
compiling configuration into flat `/run` files once per change. That removes
most parsing and forks from hot paths.

## 2. Hot path map

### 2.1 Build

| Stage | Expensive part | Files |
| --- | --- | --- |
| `stage0` | debootstrap, kernel/firmware download | `stage0/prerun.sh`, `stage0/02-firmware/01-run.sh` |
| `stage1..2` | one large `apt-get install`, module compilation | `stage2/01-sys-tweaks/00-packages`, `stage2/05-cardputerzero/01-run.sh` |
| `stage3` | separate `apt` for graphics and for session; Trove download; cleanup | `stage3/00-graphics/00-run.sh`, `stage3/01-session/00-packages`, `stage3/01-session/01-run.sh`, `stage3/03-cleanup/00-run.sh` |
| `export` | `apt-get update && dist-upgrade` after all stages, `update-initramfs`, xz | `export-image/02-set-sources/01-run.sh`, `export-image/05-finalise/01-run.sh` |

### 2.2 Boot to the first frame

```text
firmware splash
  → kernel + initramfs (xz, < 8 MiB)
  → systemd multi-user
      → cpz-tmux.service
          → tmux start-server (+ /etc/tmux.conf)
              → cpz-keys write          (Python, synchronous!)
              → cpz-apply-settings      (shell, in background)
      → getty@tty1
          → cpz-getty-prepare
              ├─ cpz-battery boot            (shell, up to 3 s for the gauge)
              └─ cpz-cage-output --prepare   (up to ~3 s for DRM/EDID)
          → agetty + login + PAM
          → cpz-session-supervise
              → cpz-cage (foot-config, layout lookup)
                  → cage
                      → cpz-cage-session (anchor + sleep 0.5)
                          → foot
                              → cpz-tmux
                                  → tmux attach
                                      → client-attached: hint, Settings tab,
                                        first-login popup (after the frame)
```

### 2.3 Steady state (idle)

| Work | Period | Cost per tick |
| --- | --- | --- |
| `cpz-cage-output.timer` | 5 s | full DRM probe, `cpz-foot-config`, Python `cpz-panel-backlight`, state write |
| `cpz-status` (tmux `#()`) | 5 s | shell + `head`/`tr`/`date`; `wpctl` when enabled |
| `cpz-battery guard` | 10 s | shell loop + several `tr` calls on sysfs |
| `cpz-conn-status.timer` | 30 s | `nmcli` + `bluetoothctl` (timeouts up to 5 s) |
| `cpz-media-keys` | 2 s | `select()` timeout + `glob` over `/dev/input` |
| `cpz-session-save.timer` | 5 min | tmux list + write |
| tmux hooks | every window change | `cpz-session-save`, `cpz-session-ensure` |

That is roughly **60+ CPU wakeups per minute** even when nothing happens. On a
battery device this matters more than peak boot time.

## 3. Findings

### P0-1. The display reconciler does full work every 5 seconds

**Evidence**

- `stage3/01-session/files/cpz-cage-output.timer:9-10` — `OnBootSec=5s`,
  `OnUnitActiveSec=5s`.
- Every tick: `hdmi_probe` (cat/wc/tr over sysfs), `get_setting` (sed over two
  files), `cpz-foot-config` (render + `cmp`), `xkb_settings` (sed),
  `write_state` (tmp + mv), and several `date` calls.
- At the end of the script (lines 950–953) `cpz-panel-backlight on|off` is
  **always** called. That is a Python process (`cpz-panel-backlight:1`) which
  writes four I2C registers every time, even when the level did not change.
- `cpz-foot-config` (lines 782–783) is rendered every tick even though it only
  changes when theme/font/output changes.

**Consequences**

- ~17,000 Python starts per day from this timer alone;
- dozens of fork/exec calls per tick; on a Cortex-A53 this is roughly 5–10 %
  of one core continuously, and the CPU never gets a chance to enter deep
  idle;
- this is not the main source of SD wear, but it noticeably drains the
  battery.

**Safe solution (two steps)**

1. **Cheap fingerprint filter at the top** (before heavy work):
   - `stat -c %Y` for `settings.conf` (user + system), the theme file,
     `/run/cpz-layout.xkb`, `output.request`, `session.env`;
   - `cat` the `status`/`enabled` of DRM connectors plus the EDID size;
   - presence of `cage`/the supervisor.
   If the fingerprint is unchanged, there is no `--force`, `--hotplug`,
   `--prepare` or `output.request`, and the target is not in the
   "HDMI selected but not enabled" state, exit. Still run a full pass every
   N ticks (for example every 6th tick = 30 s) as a safety net.
2. **Backlight level cache**: `cpz-panel-backlight` stores the applied level in
   `/run/cpz-cage/backlight.level`; `panel_on/off` do not start Python when the
   level already matches. `cpz-brightness`/Settings update the same file.
   The timer can also be relaxed to 15–30 s, leaving udev/path as the primary
   triggers.

**Risk**: if the fingerprint misses an input, the worst case is a delay until
the next full tick (30 s) or until an event. For `target=hdmi & enabled=0` the
filter must be disabled, otherwise the failed-attempt counter breaks.

**Expected effect**: remove 80–95 % of the timer work; idle CPU from a few
percent to <1 %.

---

### P0-2. Search starts full Python + the key registry on every selection move

**Evidence**

- `cpz-search:213` — `ACTIONS = current_actions()` runs at module import. That
  loads `cpz-keys` (804 lines) and `cpz-i18n`, reads the JSON catalog and
  translates every action label.
- `cpz-search:1464-1466` — the preview for every row:
  `f"{executable} --hint {{}}"`; i.e. **a new Python process on every arrow
  key**.
- `mode_bind()` for the calculator calls
  `reload-sync(<cpz-search> --calc-file ...)` on **every keystroke** (lines
  ~1370–1380). The calculator does not need `cpz-keys`/i18n, but pays for them
  through the module-level `ACTIONS`.
- `--hint` does not need `ACTIONS` at all; neither does `--calc` (lines
  941–951 only use `make_item`).

**Solution**

1. Make `ACTIONS` lazy: `def actions(): ...` plus a cache; call it only from
   `action_items()`/`action_rows()`.
2. Return early for `--calc`, `--calc-file` and `--hint` **before** loading
   i18n/keys.
3. For the hint, add a small `/bin/sh` helper (parse the five fields with
   `cut`/`case`) or embed the rendered hint in a sixth item field so the
   preview never starts Python. This is the biggest win for perceived UI
   responsiveness.

**Expected effect**: roughly 0.3–0.6 s → 0.02–0.05 s per move/keypress
(measure with `time` on the device).

---

### P0-3. Media directories are scanned with one fork per file

**Evidence**

- `cpz-open:48-49` — `media_of_kind` runs `tr` for every file.
- `cpz-open:74-80` — `find | sort | while read` plus `media_of_kind` per file.
- `cpz-music:44-54` — the same for audio: `tr` + `case` per file.

**Consequence**: a directory with 1000 photos/tracks means 1000+ forks;
opening a gallery can take seconds.

**Solution**: one `awk` (or `find` with `-iname` grouping) for the whole list:
`find ... -print | LC_ALL=C awk` with `tolower()` and an extension table; keep
sorting with `sort`. One process instead of a thousand.

**Risk**: low; preserve ordering (the opened file first) and hidden-file
filtering.

---

### P1-1. Synchronous Python in tmux.conf on the path to the first frame

**Evidence**

- `stage3/01-session/files/tmux.conf:68` —
  `run-shell '/usr/local/bin/cpz-keys write >/dev/null'` without `-b`. tmux
  waits for it and only then runs `source-file` (line 69).
- That is a Python start (hundreds of ms on ARM) during tmux server startup.

**Solution**

- Generate `tmux-keys.conf` at build time for the default bindings (for
  example `/etc/cpz/tmux-keys.conf`) and have `tmux.conf` source it plus the
  user cache.
- `cpz-keys apply` still regenerates the user file when settings change; the
  normal path no longer pays for a Python start.
- Fallback: `if-shell '[ ! -s ... ]' 'run-shell ...'` so older/custom images
  still get bindings.

**Expected effect**: ~0.2–0.5 s off the first frame; removes one Python start
from the critical path.

---

### P1-2. Heavy tables in cpz-settings are built at import time

**Evidence**

- `cpz-settings:188` — `LAYOUTS = read_layouts()` (reads
  `/usr/share/X11/xkb/rules/evdev.lst`).
- `cpz-settings:239` — `TIMEZONES = read_timezones()` (reads
  `/usr/share/zoneinfo/zone.tab`).
- This happens for **any** invocation, including `--list-tools` (called by
  `cpz-search`) and `--list-pages`.

**Solution**: make both tables lazy (`functools.cache` or
`if _LAYOUTS is None`), compute them only on the Input/Date & Time pages.
Do not touch them at all for `--list-tools`/`--list-pages`.

**Additional**: cache the `--list-tools` payload in
`~/.cache/cpz/trove-tools.json`, invalidated by the Trove index mtime and a
`PATH` hash; currently every call rereads the whole index and scans `PATH`.

---

### P1-3. Duplicated settings parsing (8 implementations)

The same `get()`/`get_setting()` built on
`sed -n "s/^$1=//p" | tail -1` exists in:

- `cpz-cage-output:138`
- `cpz-foot-config:31`
- `cpz-brightness:10`
- `cpz-display-toggle:15`
- `cpz-font:31`
- `cpz-layout-next:16`
- `cpz-apply-settings:22`
- plus separate parsers in `cpz-status`, `cpz-settings`, `cpz-i18n` and
  `cpz-search`.

This is not only about forks: precedence semantics (user → system) and the
legacy `font_size`/`font_panel` migration are spread across several places and
can already diverge.

**Solution (unification)**: one configuration layer, see section 4.

---

### P1-4. The status bar makes unnecessary forks every 5 seconds

**Evidence**

- `tmux.conf:19` — `status-interval 5`; `tmux.conf:28` —
  `status-right "#(/usr/local/bin/cpz-status) "`.
- `cpz-status` is a separate shell process using `head`, `tr`, `date` and
  `cat` on sysfs. Clock/date/battery/network update every 5 s.

**Solution**

1. Create one state publisher: `cpz-battery guard` already reads the gauge
   every 10 s — have it write `capacity/status` to `/run/cpz/status.env`;
   `cpz-conn-status` writes there too; `cpz-media-keys`/`cpz-volume` publish
   volume/mute. Then `cpz-status` only reads 1–2 files and formats (no sysfs,
   no `wpctl`).
2. The clock/date can be handled by native tmux `#{strftime:%H:%M}` (no
   fork), and `status-interval` can move to 15–30 s. If the locale and
   user-selected 12/24-hour format matter, keep `cpz-status` but without
   external commands.
3. Do not read volume through `wpctl` in the status bar; refresh the token
   after `cpz-volume`/Settings.

**Expected effect**: ~12 fewer forks/min, and the status bar no longer prevents
idle.

---

### P1-5. The boot chain contains fixed waits and repeated starts

- `cpz-cage-session:73` — `sleep 0.5` between the anchor and the visible foot
  on **every** start/restart of foot. 0.15–0.2 s may be enough; verify the
  cage layer ordering.
- `cpz-cage-output:515-531` — `--prepare` waits up to 2 s for DRM cards and up
  to 1 s for EDID; `cpz-cage:34-46` has its own 20×0.2 s wait. Two waits in
  sequence on the critical path; `--prepare` could be shortened to ~0.4–0.6 s
  and let cage do the rest (it already knows how to wait).
- `cpz-first-login:22-23` calls `cpz-i18n` up to 4 times (one Python per line).
  Add a batch mode `cpz-i18n get-many` or cache the lines.
- `cpz-cage:76-86` calls `localectl` only when `XKB_DEFAULT_LAYOUT` is absent;
  that is already good. Make sure `/run/cpz-layout.xkb` is created before cage
  starts (otherwise +5 s timeout).

**Expected effect**: roughly 0.5–1.5 s off the first frame without changing
behavior; measure with `systemd-analyze critical-chain getty@tty1.service`.

---

### P1-6. Build: extra apt cycle, network and unneeded kernel headers

**Evidence**

- `stage3/00-graphics/00-run.sh` and `stage3/01-session/00-packages` — two
  separate `apt-get install` calls; merge them into one transaction (just add
  the graphics packages to `00-packages`) to save ~15–40 s on every stage3
  rebuild.
- `stage3/01-session/01-run.sh:131-150` — the build downloads the Trove index
  (up to 120 s timeout). Offline/fast builds need an explicit switch
  (`CPZ_TROVE_INDEX_URL=none` or `CPZ_OFFLINE=1`).
- `export-image/02-set-sources/01-run.sh:7-8` — after all stages, another
  `apt-get update` plus a full `dist-upgrade`. That is correct for a release,
  but for local fast builds it costs 10–60 s and makes the result
  non-deterministic. Make it optional (`CPZ_EXPORT_DIST_UPGRADE=0`).
- `linux-headers-*` remain in the final image (visible in
  `deploy/2026-11-19-cardputerzero-trixie-arm64.info`) even though
  `stage3/03-cleanup` removes the compiler, `git` and `device-tree-compiler`.
  Headers without a compiler are useless; they cost tens to hundreds of MB on
  disk. Either remove them in cleanup or document that on-device module builds
  are supported (then restore the toolchain — the current logic is
  contradictory).
- `linux-image-rpi-2712`/`linux-headers-rpi-2712` are also in the image; for
  CardputerZero (v8) that is probably dead weight. Verify before removing.

**Expected effect**: faster local builds, a smaller image, faster first
resize/write to the SD card.

---

### P2-1. Excess wakeups and sleeps

- `cpz-media-keys:31` — `RESCAN = 2.0`; the process wakes every 2 s. Consider
  inotify on `/dev/input` or a slower rescan (5–10 s) plus a mandatory rescan
  after an event.
- `cpz-battery:31` — `poll_interval=10`. The gauge emits `power_supply`
  uevents; listen to them and keep a slow poll (30–60 s) as a safety net.
- `cpz-conn-status.timer` — 30 s; 60 s is enough for an indicator, or use
  D-Bus/`nmcli monitor`.
- `cpz-session-save` is attached to `after-select-window` (`tmux.conf:122`) and
  runs on every tab switch. `after-new-window`, `after-kill-pane`,
  `client-detached` plus the timer are enough; the active tab can be saved more
  cheaply.
- `cpz-apply-settings:119` unconditionally touches
  `/run/cpz-pointer/request` on every tmux config load. That starts
  `cpz-pointer` (Python) plus a nudge for nothing. Touch the file only when the
  `mouse` value actually changed.

### P2-2. Memory and graphics

- `gpu_mem=64` (`stage2/05-cardputerzero/02-run.sh`) plus `cma-128`
  (`stage2/05-cardputerzero/01-run.sh`) reserve up to 192 MB out of 512 MB.
  For a pixman session without GL clients that is too much. Careful
  experiment: `gpu_mem=32`, `cma=96` or `cma=64` for a "panel/pixman only"
  profile; keep a separate `cma-128` profile for HDMI + GL. Measure `free -m`,
  splash, HDMI 1080p and Crispy Doom.
- cage always uses `WLR_RENDERER=pixman`, even on HDMI where vc4 has a render
  node. That was done for a known `GL_OUT_OF_MEMORY`/dmabuf bug. Careful
  experiment: an **optional** `WLR_RENDERER=gles2` for HDMI only, with an
  automatic fallback to pixman if startup fails. The terminal (foot, wl_shm)
  will not get faster, but GL applications/games can improve significantly.
- `journald` writes a persistent 50 MB journal to the SD card
  (`stage2/05-cardputerzero/02-run.sh`). For wear and speed, consider
  `Storage=volatile` + `RuntimeMaxUse=32M`, keeping persistence in the debug
  image. This is a trade-off with diagnostics.
- Verify whether `avahi-daemon`, `bluetooth.service`, `udisks2` and the
  PipeWire user units are really needed on every boot. For example,
  `pipewire.service`/`pipewire-pulse.service` can be socket-activated
  (`.socket`) only, and `filter-chain`/`mpris-proxy` can be disabled when
  unused. Measure first: lazy start can make the first sound worse than a
  parallel start.

## 4. Unification: target architecture

### 4.1 "Compile once, read cheap"

```text
writes (Settings, Alt keys, external editor)
        │
        ▼
  cpz-config set KEY VALUE        (single validation + atomic write)
        │
        ▼
  systemd path unit for settings/themes/keys
        │
        ▼
  cpz-render                      (one run)
        ├── /run/cpz/generated/settings.env     (KEY=value, ready to source)
        ├── /run/cpz/generated/theme.env        (bg, fg, palette_0..15)
        ├── /run/cpz/generated/foot.ini
        └── /run/cpz/generated/tmux-keys.conf
        │
        ▼
  hot consumers: . file / cat file   (0–1 fork)
```

What this gives:

- `cpz-status`, `cpz-cage-output`, `cpz-brightness`, `cpz-font` and
  `cpz-display-toggle` no longer parse `settings.conf` or run `sed` per key;
- the theme is parsed once instead of in `cpz-status`, `cpz-foot-config`,
  `cpz-apply-settings` and `cpz-settings`;
- `foot.ini` and `tmux-keys.conf` are not regenerated on every tick;
- there is one place for migrations (`font_size` → per-output) and
  validation.

Migration can be staged safely: add the generator and convert 1–2 hot readers
first, then the rest; keep the old parsers as a fallback for one release.

### 4.2 A single state namespace `/run/cpz`

State is currently spread across:

```text
/run/cpz-cage/*        /run/cpz-layout.active   /run/cpz-layout.xkb
/run/cpz-conn          /run/cpz-pointer/*       /run/cpz-automount/*
/run/cpz-battery.message
```

Proposal: `/run/cpz/{display,session,status,conn,layout,pointer,request,...}`
with a single `cpz-state get/set` and a documented schema. This does not have
to happen at once, but new files should go there and old ones can move
gradually.

### 4.3 A single apply pipeline

Today every helper decides what to do after a write:

- `cpz-display-toggle` — `awk` + touch `output.request`;
- `cpz-layout-next` — `awk` + `sudo cpz-layout-apply`;
- `cpz-font` — `awk` + `cpz-foot-reload`;
- `cpz-settings` — Python `save_settings` + `apply_live`;
- `cpz-brightness` — `sudo cpz-panel-backlight`.

Proposal: `cpz-config set KEY VALUE` plus a "key → action" map
(`display` → `cpz-cage-output`, `mouse` → `cpz-pointer`, `theme`/`font*` →
`cpz-foot-reload`, `brightness` → `cpz-backlight`, ...). One mechanism, less
duplication, easier testing.

### 4.4 A single theme and i18n model

- Theme: one parser in `cpz-render`; `theme.env` for shell, `foot.ini` for
  foot, `tmux source-file` for tmux. There are four different parsers today.
- i18n: `cpz-i18n get-many KEY...` (one Python start per set of strings) for
  `cpz-first-login` and other shell callers; Python TUIs already cache the
  module.

### 4.5 Batch tmux calls

`cpz-tmux-start` makes ~8 separate `tmux` calls; `cpz-session-ensure` calls
`list-windows` several times. tmux allows multiple commands in one client via
`\;`. This saves forks at startup, but less than the items above; do it after
measuring.

## 5. Implementation plan

### Phase 0 — measure (0.5 day)

```sh
systemd-analyze
systemd-analyze blame
systemd-analyze critical-chain getty@tty1.service
strace -f -c -w /usr/local/bin/cpz-cage-output
strace -f -c -w /usr/local/bin/cpz-search --hint '<item>'
strace -f -c -w /usr/local/bin/cpz-status
time /usr/local/bin/cpz-open /media/.../photo.jpg   # a directory with 1000 files
free -m; zramctl; swapon --show
vmstat 1 60          # idle CPU/wakeups
```

Record a baseline: cold boot to the first frame, idle CPU %, wakeups/min, RSS
after boot, `.img.xz` size, `tools/build-fast.sh stage3` time.

### Phase 1 — safe quick wins (low risk)

1. `cpz-search`: lazy `ACTIONS`, early exits for `--calc`/`--hint`, shell hint
   or a hint field in the item.
2. `cpz-settings`: lazy `LAYOUTS`/`TIMEZONES`; cache `--list-tools`.
3. `cpz-open`/`cpz-music`: one `awk` instead of a fork per file.
4. `tmux.conf`: remove the synchronous `cpz-keys write`; generate
   `tmux-keys.conf` at build time.
5. `cpz-first-login`: batch i18n.
6. `cpz-cage-output`: fingerprint + backlight cache; a 15–30 s timer as a
   fallback.
7. Build: merge graphics/session apt; `CPZ_OFFLINE`; optional `dist-upgrade`;
   remove headers if they are not needed.

Each item is a separate commit with a test/check; measure against the baseline
after each one so unmeasured changes do not accumulate.

### Phase 2 — unification (medium risk)

1. `cpz-config` + `cpz-render` + `/run/cpz/generated/*`.
2. Convert hot readers: `cpz-status`, `cpz-cage-output`, `cpz-brightness`,
   `cpz-foot-config` → read the generated files.
3. One `cpz-config set` and one apply map.
4. `/run/cpz` namespace + `cpz-state`.
5. Status publisher: battery/conn/volume → one `status.env`.

### Phase 3 — hardware experiments (high risk, separate branches)

- `gpu_mem`/CMA profiles; `WLR_RENDERER=gles2` on HDMI with fallback.
- Socket activation for PipeWire; disable avahi/BT/filter-chain when not
  needed.
- zram/swap and `journald` policy.
- Reduce the anchor `sleep 0.5` and the duplicate DRM wait.
- CPU governor (only after measuring; on battery use `schedutil`, not
  `performance` by default).

## 6. Proposed budgets (starting points, not dogma)

| Metric | Target |
| --- | --- |
| Cold boot to the first frame | < 12 s (record the baseline) |
| Idle CPU (one core, no clients) | < 2 % |
| CPU wakeups while idle | < 20 / min |
| RSS after boot (no applications) | < 200 MB |
| `.img.xz` | < 700 MB (or current baseline −10 %) |
| `build-fast.sh stage3` | < 90 s on Apple Silicon/Docker |
| `--hint` / `--calc` latency | < 50 ms on CM0 |

Add `tools/verify-image.sh` checks for the absence of
`linux-headers-*`/compilers, the rootfs size, and the expected `/run`
artifacts (after Phase 2). For boot/idle, add a separate
`tools/bench-boot.sh` for the device, with results in `deploy/`.

## 7. What not to change without a strong reason

- getty + PAM/logind as the seat source for cage: replacing it with a systemd
  service could save ~1 s but risks the seat/VT and recovery.
- One DRM card per session and `pixman`: this is the documented workaround for
  the wlroots secondary-GPU bug.
- `/tmp` on disk: tmpfs on 512 MB led to OOM.
- Initramfs < 8 MiB: do not bring back `MODULES=most`/zstd for the sake of
  "modernity".
- `--no-install-recommends` and the cleanup order: compile modules first, then
  remove the toolchain.
- Persistent journal: valuable for diagnostics; moving it to volatile is only
  acceptable together with the debug image.

## 8. Quick sketches

### 8.1 Fingerprint for cpz-cage-output

```sh
fingerprint() {
    {
        stat -c '%Y' /etc/cpz/settings.conf \
            "$first_home/.config/cpz/settings.conf" \
            "/etc/cpz/themes/$theme.conf" \
            /run/cpz-cage/output.request /run/cpz-layout.xkb 2>/dev/null
        cat /sys/class/drm/card*-*/status 2>/dev/null
        cat /sys/class/drm/card*-*/enabled 2>/dev/null
        wc -c /sys/class/drm/card*-*/edid 2>/dev/null
        pgrep -x cage >/dev/null && echo cage
    } | cksum
}
# ... if the fingerprint matches and target != broken HDMI -> exit 0
# (a full pass every 6th tick)
```

### 8.2 Lazy Search

```python
_ACTIONS = None

def actions():
    global _ACTIONS
    if _ACTIONS is None:
        _ACTIONS = current_actions()
    return _ACTIONS

def main():
    args = sys.argv[1:]
    if "--calc" in args or "--calc-file" in args or "--hint" in args:
        return fast_path(args)   # no ACTIONS/i18n
    ...
```

### 8.3 One awk for media

```sh
find "$dir" -maxdepth 1 -type f ! -name '.*' -print |
LC_ALL=C sort |
awk -v kind="$kind" '
    BEGIN { n=split("jpg jpeg png gif webp ...", a, " "); for (i in a) ok[a[i]]=1 }
    { ext=tolower($0); sub(/^.*\./,"",ext); if (ext in ok) print }
'
```

### 8.4 Backlight cache

```sh
want=${1:-on}; percent=${2:-100}
last=$(cat /run/cpz-cage/backlight.level 2>/dev/null || true)
if [ "$want:$percent" = "$last" ]; then exit 0; fi
/usr/local/bin/cpz-panel-backlight "$want" "$percent" && \
    printf '%s:%s\n' "$want" "$percent" >/run/cpz-cage/backlight.level
```

### 8.5 Pre-generated tmux keys

```tmux
# tmux.conf: no Python on the path to the first frame
source-file /etc/cpz/tmux-keys.conf
source-file -q ~/.cache/cpz/tmux-keys.conf
```

## 9. Side findings (not performance, but worth recording)

- `cpz-cage-output` unconditionally touches the pointer request on every tmux
  config load (`cpz-apply-settings:119`) — an unnecessary Python start and
  nudge; make it conditional.
- `cpz-settings` calls `cpz-pointer --json` (Python) once every 2 s on the
  Input page to render Mouse Support; read the state file written by
  `cpz-pointer` instead.
- `linux-headers-*` remain in the final image; the cleanup logic and the
  "build tools for the user" comment contradict each other.
- The 50 MB persistent journal on SD is a deliberate compromise, but it is
  worth revisiting for a battery device.

---

**Summary**: the cheapest and safest changes with the largest effect are
(1) a cheap `cpz-cage-output` tick, (2) fast Search `--hint/--calc`,
(3) batched media scanning, (4) removing synchronous Python from `tmux.conf`,
and (5) merging apt stages and removing headers. Unifying configuration in
`cpz-render`/`cpz-config` is the next big step that makes the remaining
optimizations natural.

## 10. Implementation status (first safe batch)

Already done:

- `cpz-search`: lazy action registry; `--calc`/`--hint` do not load
  `cpz-keys` or the i18n catalog.
- `cpz-settings`: `LAYOUTS`/`TIMEZONES` are computed lazily.
- `cpz-open`/`cpz-music`: one `awk` instead of a fork per file.
- `cpz-foot-config`: the 16-colour palette is read with one `awk`.
- `cpz-cage-output`: `foot.ini` is not rendered when its inputs are unchanged;
  `output.state` is not rewritten without changes; the backlight level is
  cached and does not start Python/I2C when already applied (with a `--force`
  bypass).
- `cpz-panel-backlight`: updates the level cache itself, so direct calls from
  Settings/`cpz-brightness` do not desynchronize it.
- `tmux.conf`: the Python key generator runs only when the cache is missing or
  `keys.conf` is newer; the cache itself is created at build time for the first
  user.
- Boot: `cpz-getty-prepare` runs the fuel-gauge check and the DRM/EDID
  preparation concurrently; the no-card wait in `--prepare` is shortened and
  relies on cage's own retry loop. The factory-password prompt moved from
  before `tmux attach` to a client-attached popup.
- Build: graphics packages are merged with session in one apt transaction;
  `CPZ_OFFLINE`/`CPZ_TROVE_INDEX_URL=none` disable the network Trove download;
  `CPZ_EXPORT_DIST_UPGRADE=0` skips the final dist-upgrade; kernel
  headers/kbuild are removed in cleanup.

The next steps with the largest remaining effect: a shell/pre-rendered hint
for Search, the `cpz-config`/`cpz-render` pipeline, a single status publisher,
then the `gpu_mem`/CMA and HDMI GLES2 experiments. All effect estimates still
need to be confirmed by measurements on the CM0 using the method in section 5.
