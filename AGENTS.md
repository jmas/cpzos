# Agent rules — cpz-arch

Read `README.md` and `config.sh` before changing the system. These rules are
part of the architecture, not suggestions. If a change needs to break one, stop
and ask the product owner.

## What this tree is

1. **A base distribution, not a UI.** The image contains the kernel, firmware,
   hardware drivers, networking and a login path. It defines no display stack,
   no terminal session and no application layer.
2. **No display policy.** Do not add DRM, HDMI, panel selection, backlight,
   splash, framebuffer-console or module-loading decisions to this base. A new
   stack is added as a separate stage later.
3. **Drivers stay available, not enabled.** Vendor modules and overlays are
   installed so a future stack can use them. Do not autoload or configure them
   in the base.
4. **One build path.** `make image` and `make verify` are the only supported
   entry points. Do not add host-root or loop-device requirements.
5. **No initramfs.** The kernel and ext4 root must stay directly bootable from
   the firmware.
6. **No hidden services.** The base enables systemd, networking, SSH (when
   configured), the serial getty and the watchdog. Anything else needs a
   reason and the owner's approval.
7. **Minimalism.** Prefer removing a package or a file over adding a fallback.
   There is no backward compatibility: git history is the archive.

## Architecture

8. **Rootfs is installed by pacman.** `scripts/10-rootfs.sh` builds it from an
   empty directory; do not reintroduce a distro tarball as the image source.
9. **Boot files are generated.** `scripts/30-configure.sh` owns
   `/boot/config.txt` and `/boot/cmdline.txt`; edit `config.sh`, not the image.
10. **Hardware description only.** The board overlay describes the keypad,
    PMIC, battery gauge, audio codec and IMU. It must not become a display
    configuration.
11. **One kernel.** `linux-rpi` is pinned by the package set. Do not add a
    second kernel or a package that replaces the boot firmware.
12. **Identity is explicit.** Hostname, user, locale and timezone come from
    `config.sh`. `root` stays locked and `sudo` is the only escalation path.
13. **Small image.** Keep `ROOT_MB` honest; `make image` refuses to build when
    the rootfs does not fit.

## Security

14. **No shell for launches.** Use argv arrays. The base has no launcher, but
    any future helper follows the same rule.
15. **No secrets in the image.** The default password is a development
    convenience; document it and do not add keys or tokens.
16. **Network is opt-in by flag.** `ENABLE_SSH=1` is the only reason networkd,
    resolved and sshd are enabled.

## Process

17. **Ask when unsure.** Ask about product scope before deleting or adding a
    subsystem.
18. **Serious changes are loud.** If a change alters boot, hardware support,
    persistence, login or security, say so and record the trade-off in the
    README.
19. **Verify, then commit.** `make verify` must pass. Update README, `config.sh`
    comments and `scripts/50-verify.sh` with every architectural change.
    Hardware-only gaps must be stated explicitly.

## Current map

- `config.sh` — board, packages, identity, image geometry.
- `scripts/10-rootfs.sh` — pacman rootfs, no initramfs.
- `scripts/20-device.sh` — vendor modules, overlays, firmware, keymaps.
- `scripts/30-configure.sh` — identity, boot files, login paths, pruning.
- `scripts/40-image.sh` — FAT32 + ext4 + MBR without loop devices.
- `scripts/50-verify.sh` — base-image and no-UI invariants.
