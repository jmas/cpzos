# Architecture

## Goal

A pocket terminal for the Cardputer Zero: one DRM owner, one fast terminal,
tmux persistence and TUI apps. No compositor, no X/Wayland, no SDL/Mesa/Cairo
or Pango in the base image.

## Boot

```text
firmware splash
  → kernel (no initramfs)
  → cpz-shell.service   registry + provider broker + tmux panel
  → cpz-tmux.service    tmux server, /run/user/1000
  → cpz-session.service DRM broker
      → cpz-term        unprivileged renderer/input/pty
```

The shell and tmux do not need DRM and start early. `cpz-session` waits for a
connected connector, sets the mode, creates two dumb buffers and starts
`cpz-term` as `cpz` with the DRM fd inherited. `cpz-session` is the only root
process on the display path.

## DRM ownership

- `cpz-session` opens `/dev/dri/cardN`, calls `drmSetMaster`, selects the
  connector and mode, creates two dumb buffers and framebuffers, fills the
  first with the shell background and sets the CRTC.
- It passes `CPZ_DRM_FD`, `CPZ_FB*_ID`, `CPZ_FB*_OFFSET`, `CPZ_FB_STRIDE`,
  `CPZ_FB_SIZE`, `CPZ_CRTC_ID`, `CPZ_FB_WIDTH/HEIGHT` and `CPZ_FONT_PX` to
  `cpz-term`.
- `cpz-term` maps the buffers, renders, page-flips and handles flip events. It
  never calls `drmSetMaster`, never opens a card and runs as `cpz`.
- Output switch: stop terminal, destroy old buffers, select the new card,
  create new buffers, restart the terminal. tmux and its apps survive.
- GUI handover: stop terminal, release DRM, run the GUI command, then recreate
  the session and restart the terminal.

## Panel and HDMI

The SPI panel has no render node. The terminal uses CPU rendering into dumb
buffers; there is no GPU dependency. HDMI uses the same path. Font size is
per-output (`font_size_panel`, `font_size_hdmi`), so the panel keeps a 53×14
grid while HDMI can use a larger cell.

## Privileges

- `cpz-session`: root, DRM/master, mode set, backlight, control socket.
- `cpz-term`: `cpz`, inherited DRM fd, evdev (`input` group), pty, tmux.
- `cpz-shell`, launcher, providers, settings: `cpz`.
- GUI apps may need root only if they cannot accept the inherited DRM path;
  they are optional and trusted local software.

## Process lifetime

- tmux server and `cpz-shell` are independent services.
- `cpz-session` restarts `cpz-term` if it exits.
- `cpz-term` attaches `tmux -L cpz`; if tmux is absent it starts a new server.
- systemd watchdog: session 10 s; terminal writes its own liveness through the
  session's child lifecycle. A hung terminal is replaced on exit/crash.

## Recovery

No getty on the panel. Serial (`ttyAMA0`) and SSH remain. `cpz-report` writes
DRM/connector/session state to the FAT boot partition for a dark-panel boot.
