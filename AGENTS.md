# Agent rules — cpz-arch

Read `README.md` and `config.sh` before changing the system. These rules are
part of the architecture, not suggestions. If a change needs to break one, stop
and ask the product owner.

## What this tree is

1. **A base distribution.** The image contains the kernel, firmware, hardware
   drivers, networking and a login path. A display or session layer is added
   separately.
2. **Hardware enablement only.** The base may enable the DRM/HDMI/panel
   overlays so a UI package can use them. Do not add a compositor, terminal,
   backlight control, splash or display module-loading policy to the base;
   those belong to the UI package.
3. **Drivers are available; the UI loads them.** Vendor modules and overlays
   are installed, and the hardware paths are enabled. The base does not
   autoload display modules; the UI package does.
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
10. **Hardware description.** The board overlay describes the keypad, PMIC,
    battery gauge, audio codec and IMU. Display enablement is limited to the
    documented `vc4`/`cpz-spi` overlays; it is not a UI configuration.
11. **One kernel.** `linux-rpi` is pinned by the package set. Do not add a
    second kernel or a package that replaces the boot firmware.
12. **Identity is explicit.** Hostname, user, locale and timezone come from
    `config.sh`. `root` stays locked and `sudo` is the only escalation path.
13. **Small image.** Keep `ROOT_MB` honest; `make image` refuses to build when
    the rootfs does not fit.

## Security

14. **No shell for launches.** Use argv arrays, not a shell, for process
    launches.
15. **No secrets in the image.** Only the public UI signing key ships. The
    private signing key lives in CI secrets and never enters the tree. The
    default login password is a development convenience; document it and
    change it on real devices.
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
- `scripts/35-ui-repo.sh` — UI signing key and pacman repository config.
- `scripts/40-image.sh` — FAT32 + ext4 + MBR without loop devices.
- `scripts/50-verify.sh` — base-image invariants.
- `tools/ui-repo.sh` — sign packages and build the static UI repository.
- `keys/` — public UI signing key.
- `.github/workflows/` — base verify and UI repository publishing.
