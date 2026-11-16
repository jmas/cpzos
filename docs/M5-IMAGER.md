# M5 Imager compatibility

`CardputerZero/m5stack-imager` is an M5Stack-branded fork of
`raspberrypi/rpi-imager`. It is **not required to write a raw image**, but it
is the intended flashing app for the M5Stack device picker and the default M5
OS repository:

```text
https://cardputer-zero-repo.oss-cn-shenzhen.aliyuncs.com/os-list.json
```

## Do we need it?

| Situation | Recommendation |
|---|---|
| Just flash a local `.img.xz` | Any imager that writes raw images works. M5 Imager is convenient but not mandatory. |
| Use the M5Stack device picker and default OS list | Use M5 Imager. |
| Use the Imager customisation wizard | The image must be offered through a manifest entry with a **supported** `init_format`. A local file alone does not reliably enable customisation. |

## Critical: `rpi-preseed` is not supported by M5 Imager

The fork validates manifest entries in `src/oslistmodel.cpp`. The accepted
values are currently:

```text
""                 no customisation
"systemd"          systemd firstrun.sh
"cloudinit"
"cloudinit-rpi"
"none"
```

`rpi-preseed` is **not** in that list. An entry with
`"init_format": "rpi-preseed"` is pruned from the OS list. The imager also
routes every non-`systemd` format through its cloud-init generator, so simply
adding the string would not be enough.

Therefore:

- **M5 Imager + customisation:** publish the CPZ image with
  `"init_format": "systemd"`.
- **Upstream Raspberry Pi Imager / rpi-preseed:** keep a separate entry with
  `"init_format": "rpi-preseed"` if that workflow is also wanted.
- Do not expect M5 Imager to write `rpi-preseed.toml`.

The CPZ image can support both first-boot mechanisms:

- M5 Imager writes `/boot/firmware/firstrun.sh` and appends `systemd.run=...`
  to `cmdline.txt`.
- Upstream imager writes `/boot/firmware/rpi-preseed.toml`.
- `cpz-login` resolves uid 1000 dynamically, so either user-renaming path works.

## Image requirements for M5 Imager `systemd` customisation

The image must contain:

```text
/usr/lib/userconf-pi/userconf
/usr/lib/raspberrypi-sys-mods/imager_custom
/usr/bin/raspi-config
```

and must use the Trixie boot layout:

```text
/boot/firmware/firstrun.sh
/boot/firmware/cmdline.txt
```

The manifest `release_date` must be `2023-10-11` or newer. Otherwise M5 Imager
uses the old `/boot/firstrun.sh` and `/boot/cmdline.txt` paths. A current
Trixie image satisfies this; still set a correct release date.

## Example manifest entry

```json
{
  "name": "CardputerZero CPZ (Trixie arm64)",
  "description": "Terminal-first kmscon + tmux image for CardputerZero.",
  "icon": "https://cardputer-zero-repo.oss-cn-shenzhen.aliyuncs.com/icons/cardputerzero.png",
  "url": "https://example.invalid/cardputerzero-cpz-trixie-arm64-YYYYMMDD.img.xz",
  "extract_size": 0,
  "extract_sha256": "FILL_ME",
  "image_download_size": 0,
  "image_download_sha256": "FILL_ME",
  "release_date": "YYYY-MM-DD",
  "init_format": "systemd",
  "devices": ["m5-cardputerzero", "pi3-64bit"],
  "architecture": "armv8",
  "capabilities": ["i2c", "spi", "serial", "usb_otg"]
}
```

`extract_size` is the decompressed image size. `image_download_size` is the
compressed artifact size. Both hashes must be filled for verification and for
the imager to show accurate metadata.

Generate the entry from a built image with:

```sh
./tools/make-m5stack-entry.py \
  --image deploy/image_2026-11-16-cardputerzero-trixie-arm64.img.xz \
  --url https://example.invalid/cardputerzero-cpz-trixie-arm64-20261116.img.xz \
  --release-date 2026-11-16
```

The tool defaults to `init_format: "systemd"` and rejects release dates before
2023-10-11, when M5 Imager would use the old `/boot` paths.

## Imager version

Use the latest M5 Imager release (`v3.0.0` at the time of writing) or a build
from current `main`. Older versions may support `systemd` customisation, but
verify `src/oslistmodel.cpp` before relying on them. Do not use a version whose
manifest validator still lacks the `systemd` format or whose firstrun path
logic predates the Trixie `/boot/firmware` layout.

## Image version

There is no special OS version required by M5 Imager. It needs a manifest entry
that matches the actual artifact:

- correct `release_date`
- non-zero sizes
- valid SHA-256 values
- `init_format: "systemd"`
- `devices` including `m5-cardputerzero`

A `latest` alias is fine, but update the manifest atomically with the artifact.
For reproducible builds, prefer versioned filenames and add a new manifest entry
instead of overwriting `latest`.
