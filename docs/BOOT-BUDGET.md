# CPZ boot budget assessment

This document estimates whether CPZ can boot to the visible terminal in about
10 seconds, and which architectural changes would be required. It is an
estimate: the repository contains no boot-time measurements from the CM0.
Measure first, then use the budgets below to decide which changes are worth
their risk.

## 1. What "boot" means

Use separate targets; they have very different floors:

| Target | Definition | Realistic? |
| --- | --- | --- |
| `kernel-ready` | kernel has mounted the root filesystem | comfortably below 5 s |
| `systemd-ready` | `multi-user.target` reached | 8–12 s is realistic |
| `first-frame` | cage + foot + tmux show the shell on the panel/HDMI | 10–14 s is realistic; 10 s is a stretch |
| `first-boot` | first power-on after flashing, including resize and preseed | 15–30 s; not a useful 10 s target |

The rest of this document uses **cold power-on to the first visible shell
frame** (not a reboot, not the first boot after flashing).

## 2. Verdict

- **10 seconds is achievable, but at the aggressive end.** It should be
  treated as a stretch goal, not as the default release budget.
- A safe target after low-risk cleanup is **12–14 seconds**.
- With aggressive but reversible changes (no initramfs or a faster
  decompressor, a shorter login chain, parallel session startup) **10–11
  seconds** is plausible.
- **Below 9 seconds is not realistic** without replacing the current
  getty + cage + foot + tmux chain or tailoring the initramfs per board.
- The result depends heavily on the SD card. A slow card can add several
  seconds of firmware/kernel/rootfs reads; an A1/A2 card is part of the
  budget, not a detail.
- First boot is a different problem: `rpi-resize`, `rpi-preseed`, a possible
  user/home rename and SSH host-key generation can add many seconds, and the
  device may reboot once. Do not mix first-boot numbers into the 10 s goal.

## 3. A 10-second allocation

A useful way to test the goal is to allocate the 10 seconds before optimizing:

| Segment | Budget for 10 s | Notes |
| --- | --- | --- |
| Firmware / bootloader / SD init | 1.5–2.0 s | fixed by the Pi firmware and card; limited control |
| Kernel load + decompress | 0.6–1.0 s | kernel image size and SD read speed |
| Initramfs load + decompress | 0.2–0.6 s | the current xz initramfs is below 8 MiB; removing it or changing the compressor is a large lever |
| systemd to `multi-user.target` | 2.0–2.5 s | depends on the service set and parallelism, not on cage |
| getty / login / PAM | 0.4–0.6 s | current chain is deliberately getty-based for the seat |
| cage + foot + tmux to first frame | 1.5–2.0 s | includes DRM mode set, foot start, tmux attach |
| Contingency | 0.5–1.0 s | SD variance, udev, entropy |

If any segment regularly exceeds its allocation, the 10 s goal moves to
11–12 s. The current image has several places that can exceed these numbers:

- `cpz-battery boot` may wait up to 3 s for the fuel gauge
  (`cpz-battery` boot check: 15 × 0.2 s);
- `cpz-cage-output --prepare` may wait up to ~3 s for DRM cards/EDID;
- `cpz-cage-session` sleeps 0.5 s between the anchor and the visible foot;
- `cpz-tmux.service` is ordered `Before=getty@tty1.service`, so the tmux
  server must be ready before login starts;
- `cpz-first-login` runs in a client-attached popup after the first frame. It
  shows on every boot while the factory password is still in use, but no
  longer sits before `tmux attach`;
- cage starts only after login/PAM, not in parallel with systemd startup.

None of these alone prevents 10 s, but together they explain why a naive
measurement can land at 15–18 s.

## 4. Levers, ranked by expected gain and risk

### 4.1 Measure first (no boot-time change)

```sh
systemd-analyze
systemd-analyze blame
systemd-analyze critical-chain getty@tty1.service
journalctl -b -o short-monotonic
dmesg | head -n 40
```

`systemd-analyze` does not include firmware time and does not know when the
first frame appeared. Add temporary journal markers around the session chain
(`cpz-getty`, `cpz-cage`, `cpz-cage-session`, `cpz-tmux`) and correlate them
with `journalctl -b -o short-monotonic`; record the first frame with a camera
or an HDMI capture. Run at least 5 cold boots and 2–3 SD cards.

### 4.2 High gain, low/medium risk

| Change | Expected saving | Risk |
| --- | --- | --- |
| Drop the initramfs where the root drivers are built in, or replace xz with a faster decompressor (zstd) if the size budget allows | 0.5–1.5 s | medium: CM5 eMMC/USB boot may need the initramfs; make it board-specific |
| Run `cpz-battery boot` and `cpz-cage-output --prepare` concurrently instead of sequentially in `ExecStartPre` | 0.3–1.5 s (worst case more) | low: the battery guard must still veto startup before cage |
| Shorten the DRM/EDID wait in `--prepare`; let cage's own wait loop finish the job | 0.2–1.0 s | low: cage already retries with `WLR_DRM_DEVICES` |
| Reduce the anchor-to-visible-foot `sleep 0.5` to 0.15–0.2 s, or replace it with a surface-ready check | ~0.3 s | low/medium: verify view stacking on both panel and HDMI |
| Remove `Before=getty@tty1.service` from `cpz-tmux.service` and let login and tmux start in parallel; `cpz-tmux` already has a `cpz-tmux-start` fallback | 0.2–0.8 s | low: test the race on a slow card |
| Batch the `tmux set-environment` calls in `cpz-tmux` into one tmux invocation | 0.1–0.3 s | low |
| Skip `cpz-tmux`'s `has-session` check when the service is already active | small | low |

Implemented in the current low-risk batch: the concurrent getty preparation
(`cpz-getty-prepare`), the shorter no-card wait in
`cpz-cage-output --prepare`, and moving the factory-password prompt to a
client-attached popup (`cpz-first-login-popup`).

### 4.3 systemd service set

The exact effect depends on parallelism: removing a service that runs
concurrently with the critical path may not move the first frame at all.
Measure `systemd-analyze critical-chain` before removing anything.

- `avahi-daemon`: not needed by CPZ; mask or socket-activate. Saves CPU and a
  small amount of startup work.
- `bluetooth.service`: can be activated from Settings/`bluetoothctl`; disabling
  it at boot also saves battery. `cpz-conn-status` must then read sysfs/rfkill
  first instead of calling `bluetoothctl` every 30 s, otherwise it will start
  BlueZ again.
- `getty@tty2`/`getty@tty3`: not visible with `fbcon=map:off`; keep only if
  the recovery story requires them. SSH/serial/debug image may be enough.
- `rpi-resize`/`rpi-preseed`: add systemd conditions so the units are skipped
  entirely after their first-boot markers; currently they still start and
  exit.
- `regenerate_ssh_host_keys`: if SSH is disabled, it can still generate host
  keys on first boot. Mask it when `ENABLE_SSH=0`, or generate keys at build
  time (security trade-off: identical host keys across images).
- `ssh.service`: socket activation (`ssh.socket`) starts sshd only when a
  connection arrives. Keep the service if the recovery policy requires a
  listener immediately.
- PipeWire/WirePlumber user units: socket activation reduces CPU contention
  during the first frame, but the first sound may arrive later. Measure both.

### 4.4 Architectural changes (aggressive)

- **Remove getty/login/PAM from the hot path.** A systemd service with
  `User=1000`, `TTYPath=/dev/tty1`, `StandardInput=tty`, `PAMName=login`
  can create a logind session and run cage directly. This can save roughly
  0.4–1 s and removes agetty/login, but the seat/VT/recovery behavior must be
  tested carefully. The current getty design is deliberate.
- **Start cage as early as possible.** The current chain is
  systemd → getty → login → profile → cage. Starting cage directly after the
  DRM devices appear lets the compositor initialize while the rest of
  `multi-user.target` is still starting. This is the largest remaining
  session-side win.
- **Per-board initramfs policy.** The image carries both `initramfs8` and
  `initramfs_2712`. If CM0 uses built-in SD and ext4, a no-initramfs boot is
  viable; CM5 eMMC needs `sdhci_of_dwcmshc`. Build a CM0 profile with
  `auto_initramfs=0` and keep the current initramfs for CM5.
- **Kernel command line:** `quiet loglevel=3 nowatchdog` is already good.
  Add `systemd.show_status=0`/`udev.log_level=3` if not present, and verify
  that no `resize`/fsck work runs on every boot. `random.trust_cpu=on` can
  help first-boot SSH key generation.
- **SD card:** specify and test a fast A1/A2 card. This is not a software
  optimization, but it is often worth more than a service tweak.

## 5. What not to do for a 10 s number

- Do not disable fsck or recovery consoles just to win a second; a corrupted
  root filesystem is a much worse outcome.
- Do not remove the getty/login seat model without testing panel, HDMI,
  VT switching, SSH and logind session cleanup.
- Do not drop the initramfs globally; CM5 eMMC and USB boot paths depend on
  it. Make it board-specific.
- Do not move `/tmp` to tmpfs or remove the persistent journal as part of a
  boot optimization; those are memory/diagnostics decisions.
- Do not trust a single warm reboot. Measure cold boots on the target card.

## 6. If the target is 15 seconds

Fifteen seconds to the first visible shell frame is a comfortable, low-risk
target. It does **not** require removing the initramfs, replacing
getty/login/PAM, disabling recovery consoles or rewriting the session
architecture. The 15 s budget leaves enough room for the current design and
for the SD-card variance:

| Segment | 15 s budget |
| --- | --- |
| Firmware / bootloader / SD init | 2.5–3.0 s |
| Kernel load + decompress | 0.8–1.2 s |
| Initramfs load + decompress | 1.0–1.5 s |
| systemd to `multi-user.target` | 4.0–5.0 s |
| getty / login / PAM | 0.8–1.2 s |
| cage + foot + tmux to first frame | 2.5–3.5 s |
| Contingency (SD/udev/entropy) | 1.0–1.5 s |

What this means in practice:

- The low-risk items in section 4.2 are sufficient if the current baseline is
  roughly 15–18 s: removing the avoidable waits and serialization should save
  about 1.5–3.5 s.
- Keep `cpz-tmux.service` ordered before getty if that is simpler; removing
  the ordering is optional at 15 s.
- Keep the initramfs and the getty/login seat model. They are only needed for
  the 10 s stretch goal.
- `cpz-first-login` now runs in a popup after the first frame, so the password
  reminder no longer counts against the 15 s target.
- If the baseline is 18–22 s, add the service-set cleanup (mask optional
  services, socket-activate SSH/BlueZ/PipeWire) and verify the SD card before
  touching the session architecture.
- If the baseline is above 22 s, one outlier is likely. Read
  `systemd-analyze critical-chain` and `journalctl -b -o short-monotonic`
  before making changes.

A reasonable acceptance criterion is: **cold power-on to the first visible
tmux shell in under 15 s on the target SD card, in at least 5 runs, on both
the panel and HDMI, with first boot measured separately.** If "UI" also means
that Settings/Search open responsively, add the low-risk runtime work from
`docs/PERFORMANCE-REVIEW.md`; the first frame alone does not include those
latencies.

First boot is still a different case. `rpi-resize`, `rpi-preseed`, a possible
user/home rename and SSH host-key generation can exceed 15 s even when every
steady-state boot is below it. Promise 15 s for normal boots, not for the
first boot after flashing, unless those first-boot jobs are explicitly moved
or made conditional.

## 7. Suggested decision

1. Measure the current cold-boot first-frame time on the target SD card.
2. If the baseline is **12–14 s**, take the low-risk items in 4.2 and expect
   **10–12 s**.
3. If the baseline is **15–18 s**, the 10 s goal requires at least one
   architectural change (initramfs removal or direct cage startup) plus the
   low-risk items; budget **11–13 s** for the first iteration.
4. If the baseline is **above 18 s**, find the outlier with
   `systemd-analyze critical-chain` and `journalctl -b -o short-monotonic`
   before changing anything; a single slow service or a slow SD card is more
   likely than a general design problem.
