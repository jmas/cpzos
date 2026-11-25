# UI qualities

Status: draft for the `ui/qualities` branch. This document defines the
properties the UI must have. It does not choose or prescribe an
implementation.

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
- Target languages: to be confirmed (the previous project shipped en, de, es,
  fr, it, ja, pl, pt, tr, uk, zh).

### Q7. Autonomy and efficiency

- Idle work is near zero: no busy loops, no continuous redraw, no periodic
  shell polls.
- Proposed budgets, to confirm on hardware: UI layer RSS ≤ 64 MB, boot to a
  usable prompt ≤ 8 s, idle wakeups ≤ 1/min.
- Status updates are event-driven; a status surface reads a cache rather than
  waking a daemon.
- A session restart or output switch does not cost more than a screen blink.

### Q8. Terminal fidelity

- UTF-8, 256-colour and true-colour output, alternate screen, scrollback,
  resize, bracketed paste, mouse reporting and the correct terminfo entry.
- Standard terminal applications (shell, editor, pager, file manager, tmux,
  htop) work unmodified.
- The terminal is a standard implementation or a full-compatible one; a
  custom reduced terminal is not acceptable.
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
- **UI:** session, compositor/terminal, status surfaces, launcher, themes,
  catalogs and applications.
- The UI depends on a documented, versioned platform contract: application
  launch, status/notifications, input/layout events, theme tokens, locale
  catalogs and session persistence.
- A UI update is a package/overlay update. It must not require rebuilding the
  system image.
- A platform update must not require UI source changes within the same
  platform major.
- Proposed versioning: platform major `P` and UI release `U`, shown as
  `P.U`. A platform major change may break the contract; a UI update changes
  only `U`.
- The UI declares the platform contract range it supports. The platform
  refuses an incompatible UI and reports why.
- The previous UI version remains available for rollback.
- User settings, layouts, themes and session data survive UI updates.

## 4. Non-goals

- A desktop environment, overlapping windows or a window manager.
- A permanent status bar full of chrome, or icon-only navigation.
- A mouse-first or touch-first interaction model.
- A custom terminal that implements only the escape codes the UI needs.
- Rebuilding the OS image to ship a UI fix.

## 5. Open decisions

1. Confirm the language list and whether IME (not only layouts) is in scope.
2. Confirm the latency, RAM, boot and wakeup budgets on hardware.
3. Choose the UI update mechanism: package repository, signed bundle or A/B
   image.
4. Confirm whether the terminal is an existing standard emulator or a
   compatible implementation, and which terminal capabilities are mandatory.
5. Confirm whether panel and HDMI share one layout model with per-output
   metrics or may have separate layouts.
6. Define the accessibility floor: high contrast, colour independence, and
   whether a screen reader is in scope.
7. Decide whether applications are part of the UI layer or separate packages
   on top of it.
