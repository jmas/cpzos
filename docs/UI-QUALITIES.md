# UI qualities

Status: requirements agreed for the `ui/qualities` branch. The implementation
stack is not chosen yet.

## 1. Product context

- Device: Cardputer Zero CM0, 512 MB RAM, matrix keyboard, battery.
- Outputs: 320×170 internal panel and HDMI. Each output mode has its own UI
  scaling; both use the same interaction model.
- Use: terminal work, media playback and games, with frequent switching
  between them.
- The terminal is a first-class, standards-compliant terminal. Terminal
  programs must work fully, not through a reduced escape-code subset.
- The UI is a separate layer from the platform so it can be updated without
  rebuilding the system image.

## 2. Interaction model

- One visible application at a time.
- Tabs persist sessions; switching tabs does not restart applications.
- A media player or game takes the foreground, receives input, and returns to
  the same tab when it closes.
- The model is deliberately not a desktop: no overlapping windows, no window
  manager, no task switcher.

## 3. Quality attributes

### Q1. Responsiveness

The UI answers input before the user can perceive a delay.

- A key press produces a visible change within 50 ms typical and 100 ms at
  p95 on the panel.
- A tab or application switch completes within 100 ms.
- A language/layout switch completes within 50 ms.
- No input waits on network, disk or a background task.
- No polling loop drives the interface; redraws are event-driven.

### Q2. Predictability and simplicity

- One visible focus. The same key does the same thing in the same context.
- No hidden modes and no invisible state changes. The current mode is visible
  where it matters.
- Errors say what failed and what to do next.
- Destructive actions confirm, name the object and default to "no".
- No permanent footer, hint bar or key legend. Shortcuts live in Help.
- A broken application or manifest is skipped and logged; it does not take
  the session down.

### Q3. Readability and scaling

- The panel is 320×170. Primary text must be readable without zooming. The
  baseline grid is 53×14 cells at 6×12; 8×16 is an alternative.
- One monospace family in lists and status surfaces. No proportional text in
  columns.
- Each output has its own cell size and scale. The information architecture
  and layout do not fork between panel and HDMI.
- Colour is never the only signal; pair it with text or a token.
- Contrast and focus are visible in every theme, including light and
  high-contrast themes.

### Q4. Keyboard first

- Every primary flow is complete with the matrix keyboard alone.
- The mouse is optional and never required. Adding it must not change the
  keyboard model.
- Daily actions use direct keys; there is no mandatory prefix chord.
- Focus moves predictably with the arrow keys; Enter opens or applies; Esc/q
  goes back without changing data.

### Q5. Extensibility

- Applications register declaratively; the UI core contains no application
  names.
- Applications own their data; the shell owns presentation. An application
  never draws the shell's chrome or status bar.
- The application contract is versioned. Unknown fields are ignored; an
  incompatible application is skipped with a clear reason.
- Applications are separate packages. The UI core is the `cpz-ui` package set;
  applications depend on its contract and are versioned independently.
- New applications do not require a change to the session or the terminal.

### Q6. Localization and accessibility

- Every user-visible string comes from a catalog; no hardcoded English in the
  interface.
- Layouts switch live, including inside a terminal session. No terminal or
  session restart, no visible delay.
- Translated strings fit the panel and the label columns; truncation is a
  bug.
- Keyboard focus is always visible. Colour is not the only carrier of state.
- A high-contrast theme and a colour-independent mode are supported.
- Target languages (confirmed): en, de, es, fr, it, ja, pl, pt, tr, uk, zh.
- Input method: layout switching only. IME composition is out of scope.
- Accessibility floor (confirmed): high-contrast theme, colour-independent
  state, visible focus and complete keyboard operation. A screen reader is out
  of scope.

### Q7. Autonomy and efficiency

- Idle work is near zero: no busy loops, no continuous redraw, no periodic
  shell polls.
- Confirmed budgets: first usable frame ≤ 12 s from cold power-on (stretch
  goal 10 s), UI core RSS ≤ 64 MB, idle wakeups ≤ 5/min, and no more than 2%
  of one core averaged over 60 s idle.
- Status updates are event-driven; a status surface reads a cache rather than
  waking a daemon.
- A session restart or output switch does not cost more than a screen blink.

### Q8. Terminal fidelity

- UTF-8, 256-colour and true-colour output, alternate screen, scrollback,
  resize, bracketed paste, mouse reporting and the correct terminfo entry.
- Standard terminal applications (shell, editor, pager, file manager, tmux,
  htop) work unmodified.
- The terminal is an existing standard emulator. The emulator choice belongs to
  the stack; the capabilities above are mandatory. A custom reduced terminal is
  not acceptable.
- Selection, copy and paste work without leaving the keyboard model.

### Q9. Session persistence

- Tabs and panes survive a UI restart, a terminal restart and an output
  switch.
- Closing a foreground application returns to the same tab and the same
  working directory.
- The UI layer can be updated or restarted without killing the session.

### Q10. Platform/UI separation and versioning

- **Platform:** kernel, firmware, hardware drivers, base system, network,
  login, update mechanism and security.
- **UI core:** session, compositor/terminal, status surfaces, launcher, themes
  and catalogs. It is delivered as the `cpz-ui` pacman package set.
- **Applications:** separate pacman packages on top of the UI core. They
  declare the UI app-contract range and are versioned independently. An
  application update is still a UI update and never changes the platform.
- **Platform contract (narrow):** the platform version and capabilities; the
  standard Linux interfaces (DRM/KMS, evdev, ALSA, sysfs, network); the user,
  logind session and runtime directories; one session entry point; and the
  pacman/update mechanism. Application manifests, status/notifications, theme
  tokens and locale catalogs are UI-owned, not platform.
- The UI is delivered as pacman packages: `cpz-ui` plus application packages.
  A UI update must not rebuild the system image or replace the kernel or boot
  path.
- **Versioning:** platform image `P`, platform contract `C`, UI release `U`;
  the system shows `P.U`. `P` increments with each platform image release, `C`
  only when the platform interface breaks, and `U` with UI changes.
- The UI declares the platform contract range it supports. The platform
  refuses an incompatible UI and reports why.
- **Rollback:** the last two UI core releases, and the application versions
  tested with them, remain installable. Rollback uses `pacman -U` from the
  repository or the local package cache.
- **Channels:** `stable` is the default; `beta` is opt-in. Both are signed
  repository directories, and a release is promoted from beta to stable.
- **Signing and hosting:** a dedicated PGP key signs the packages and the
  repository database. The public key ships in the base image, CI signs the
  release, and the static repository lives on GitHub Pages with `stable/` and
  `beta/` paths. Key rotation ships with a platform update; the old key stays
  while older UI releases remain installable.
- User settings, layouts, themes and session data survive UI updates.

## 4. Non-goals

- A desktop environment, overlapping windows or a window manager.
- A permanent status bar full of chrome, or icon-only navigation.
- A mouse-first or touch-first interaction model.
- Input methods/IME beyond layout switching.
- A screen reader.
- A custom terminal that implements only the escape codes the UI needs.
- Rebuilding the OS image to ship a UI fix.
- Rolling back a platform image through pacman; a platform rollback is a
  reflash.
- Unsigned UI packages or an unsigned repository.

## 5. Decisions on this branch

- **Update path:** `cpz-ui` core plus separate application packages from a
  signed pacman repository. No image rebuild; rollback with `pacman -U`.
- **Budgets:** first frame ≤ 12 s (stretch 10 s), UI core RSS ≤ 64 MB, idle
  wakeups ≤ 5/min, ≤ 2% of one core idle, key 50/100 ms, tab switch ≤ 100 ms.
- **Platform contract:** narrow. The platform exposes version, capabilities,
  standard Linux interfaces, user/logind/runtime and one session entry point;
  the UI owns the application, theme and locale contracts.
- **Rollback and channels:** last two UI core releases stay installable;
  `stable` is the default, `beta` is opt-in.
- **Signing and hosting:** a dedicated PGP key, a public key in the base image,
  and a static repository on GitHub Pages with `stable/` and `beta/` paths.
- **Languages:** en, de, es, fr, it, ja, pl, pt, tr, uk, zh; layout switching
  only, no IME.
- **Accessibility:** high contrast, colour-independent state, visible focus and
  complete keyboard operation; no screen reader.
- **Terminal:** an existing standard emulator with the capabilities in Q8; no
  custom reduced terminal.
- **Panel and HDMI:** one layout model with per-output cell metrics and
  scaling, not separate interfaces.

## 6. Implementation follow-ups

1. Measure the confirmed budgets on hardware and change them only with
   evidence.
2. Create the PGP key, choose the repository URL and add the CI signing job.
3. Write platform contract v1: capabilities, session entry point, paths and
   version metadata.
4. Define the UI app contract: manifest, launch, status/notifications, theme
   tokens, locale catalogs and package naming.
5. Choose the terminal emulator and the session stack.
6. Define the promotion/rollback checklist and how the last two releases are
   retained.
7. Add the public key and the stable/beta repository configuration to the base
   image in a new stage once the repository exists. **Done:** `scripts/35-ui-repo.sh`.
