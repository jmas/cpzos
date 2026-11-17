# USB storage

CPZ mounts USB hard disks, sticks and card readers automatically when they are
plugged in. Filesystems appear under `/media/<label>` and are available to the
console user immediately; unplugging unmounts them.

## What happens on hotplug

1. udev sees a new USB block device and starts `cpz-automount@<dev>.service`
   through `99-cpz-automount.rules`. The rule matches the parent chain
   (`SUBSYSTEMS=="usb"`) rather than `ID_BUS`, so USB-SATA bridges that are
   identified as `ata`/`scsi` are covered too.
2. `cpz-automount` probes the filesystem (`blkid`) with a few retries. This
   second probe matters for a spinning hard disk, where udev's first `blkid`
   can run before the media is readable.
3. The helper mounts the filesystem at `/media/<label>` (the label is
   sanitised; an unlabelled filesystem uses `usb-<first UUID group>`). A second
   filesystem with the same label gets a `-2`, `-3`, ... suffix.
4. The mounted directory is opened as a new tab in the console session and the
   attached client switches to it, so the disk can be used immediately.
5. Unplugging the disk deactivates the device unit. `BindsTo=dev-<dev>.device`
   stops the service, and its `ExecStop` unmounts the filesystem (lazy detach
   if a process still holds it open).

A partitioned disk is mounted per partition, so all data partitions of one
drive are available. Empty partitions, LUKS, LVM, RAID and swap are skipped.
The running system's disk is refused even if it is USB. Anything listed in
`/etc/fstab` is left to systemd and is not mounted a second time.

## Supported filesystems

| Type | Notes |
| --- | --- |
| vfat / FAT32 | owned by the console user (`uid`/`gid`/`umask`), UTF-8 names |
| exFAT | owned by the console user (`uid`/`gid`/`umask`), UTF-8 names |
| NTFS | `ntfs3`, falls back to `ntfs-3g`; owned by the console user |
| ext2/3/4, btrfs, xfs | on-disk ownership is preserved |
| ISO9660, UDF | mounted read-only (USB disk images) |

If a read-write mount fails (dirty NTFS, filesystem errors), the helper retries
read-only and logs why. It does not run `fsck`: repair the filesystem
explicitly with `sudo fsck /dev/sdXN` first.

FAT/exFAT/NTFS have no Unix ownership, so those files are created as `cpz`.
ext4 and other native filesystems keep the UID/GID stored on the disk; files
owned by another user stay read-only without `sudo`. The helper does not
recursively `chown` a filesystem.

## Using a drive

```bash
ls /media                          # mount points
cpz-automount list                 # drives mounted by the helper
cpz-automount umount /dev/sda1     # flush and unmount before unplugging
```

Every hotplug mount opens a tab named after the label, with the shell already
in `/media/<label>`. A tab that was moved somewhere else is left open, so its
contents are not lost. Mount tabs are not part of the saved session layout:
after a reboot they only come back when the disk is plugged in again.

A manual mount (`sudo cpz-automount mount /dev/sda1`) opens a tab too, as long
as the console session is running. At boot, udev coldplug runs before the
console user logs in, so disks that are already attached are mounted without a
tab.

Mounted paths are included in the `Alt+O` omnisearch file provider, so a data
directory can be opened without leaving the keyboard.

## Safe removal

Automatic unmount on unplug removes the mount from the mount table, but it
cannot flush writes that the kernel has not sent to the disk yet. Before
unplugging a drive that was written to, run:

```bash
sync
cpz-automount umount /dev/sda1
```

The tab opened for the disk is closed before the filesystem is unmounted: its
shell has the mount point as its working directory, and a busy mount would fall
back to a lazy detach. A manual `cpz-automount umount` runs through the
`cpz-automount@<dev>.service` unit, so closing the tab cannot interrupt the
unmount, even when the command was typed in that tab. A tab that was moved out
of the disk stays open. Removing the cable without this step can lose the last
few seconds of writes.

## Troubleshooting

```bash
lsblk -f
sudo blkid /dev/sda1
udevadm info --query=property --name=/dev/sda1 | grep -E 'ID_BUS|ID_FS'
systemctl status 'cpz-automount@sda1.service'
journalctl -b -u 'cpz-automount@*'
```

- Nothing appeared under `/media`: the journal explains why. A blank partition,
  LUKS, RAID and swap are skipped by design; a damaged superblock makes
  `blkid` report no filesystem.
- The unit failed: the journal has the mount error, for example
  `wrong fs type` (kernel driver missing) or `Volume is dirty` (NTFS).
- `umount` reports the mount is busy: a shell or program is using the drive.
  Leave it plugged in, exit that program, and retry; the helper also falls
  back to a lazy detach on unplug.
- Manual mounting still works: `udisksctl mount -b /dev/sda1` or
  `sudo mount /dev/sda1 /mnt`. `udisks2` is installed but is a D-Bus service
  that mounts on request; it never auto-mounted anything by itself.

## Files

```text
/usr/local/bin/cpz-automount                    # mount/umount/list helper
/usr/local/bin/cpz-tab-mount                    # open/close the disk tab
/etc/systemd/system/cpz-automount@.service      # one instance per device
/etc/udev/rules.d/99-cpz-automount.rules        # hotplug trigger
/media/<label>                                  # mount points
/run/cpz-automount/<dev>.mountpoint             # what the helper mounted
```
