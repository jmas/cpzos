# Release rules

There is exactly **one** release format. A release is a published GitHub
Release for a SemVer tag, built and uploaded by `.github/workflows/build.yml`.
No other tag shape, title, notes layout or asset name is valid.

`MUST`, `SHOULD` and `MAY` are used as in RFC 2119.

## 1. Version and tag

- `VERSION` is the single source of truth. It contains the version **without**
  the `v` prefix and nothing else.
- The version is SemVer: `MAJOR.MINOR.PATCH` or
  `MAJOR.MINOR.PATCH-prerelease`. Build metadata (`+...`) is not allowed.
- The git tag is the version with a lowercase `v`: `vX.Y.Z` or
  `vX.Y.Z-prerelease`. It MUST be an annotated tag created by
  `tools/release.sh`.
- `VERSION` on the tagged commit MUST equal the tag without `v`.
  `.github/workflows/build.yml` refuses a mismatch.
- Tags are immutable. Never move, force-push or reuse a published tag; rebuild
  an existing tag with `workflow_dispatch`.

Bump rules:

| Bump | Use for |
| --- | --- |
| `major` | incompatible changes to the image, user data or on-disk format |
| `minor` | new user-visible behaviour, screens or applications |
| `patch` | fixes and internal/tooling changes with no new feature |

A prerelease keeps a suffix (`-beta.1`, `-rc.1`) and is marked *pre-release* on
GitHub. Promoting it to stable removes the suffix and publishes a normal
release; do not create a second tag for the same commit unless that commit is
the release.

Legacy timestamp tags (`YYYYMMDD-HHMMSS-<sha>`) exist in history from before
`v0.1.0`. They are **not** a release format and MUST NOT be created again.

## 2. Title

The GitHub Release title MUST be exactly:

```text
CardputerZero CPZ vX.Y.Z
```

A prerelease adds its suffix to the version and still uses the same title:

```text
CardputerZero CPZ v0.5.0-rc.1
```

Do not use a bare tag, a date, or a different product name as the title.

## 3. Release notes

Notes are written by hand from the commits since the previous release; they
are not a raw git log. Save them outside git control (for example
`deploy/release-notes-vX.Y.Z.md`) and pass the file to `tools/release.sh`.

The body MUST start with the title as an `##` heading, then one summary
sentence, then these sections in this order: `### Highlights`,
`### Changes`, `### Install`.

```markdown
## CardputerZero CPZ vX.Y.Z

One sentence describing what changed for someone flashing this image.

### Highlights

- **Short name.** The user-visible outcome, in one or two sentences.
- **Short name.** The next outcome.

### Changes

- User-visible fixes and new behaviour.
- Tooling, build or documentation changes worth knowing about.

### Install

Download `cardputerzero-trixie-arm64-vX.Y.Z.img.xz` from this release and
write it to a microSD card with Raspberry Pi Imager, balenaEtcher, `dd` or
M5 Imager.

Default login: `cpz` / `cpz`. Wi-Fi is off until it is enabled in Settings.

Documentation: https://github.com/jmas/cpzos/tree/master/docs
```

Rules for the body:

- `Highlights` has 1–6 bullets and describes outcomes, not commit subjects.
- `Changes` lists every notable fix and tooling change, including migration or
  recovery notes when they matter.
- `Install` keeps the boilerplate above; only the asset version changes.
- A prerelease adds a warning line directly under the summary:
  `> Beta release: expect rough edges and keep a known-good card.`

## 4. Assets and channels

The build workflow produces and attaches exactly these names; never rename or
hand-upload release images:

| Asset | Name |
| --- | --- |
| compressed image | `cardputerzero-trixie-arm64-vX.Y.Z.img.xz` |
| image metadata | `cardputerzero-trixie-arm64-vX.Y.Z.info` |
| build metadata | `build-info.json` |
| optional | `cardputerzero-trixie-arm64-vX.Y.Z.sbom[.xz]`, `...bmap` |

The image is also copied to
`oss://cardputer-zero-repo/cardputerzero-trixie-arm64-vX.Y.Z.img.xz`. Stable
releases additionally refresh the moving alias
`cardputerzero-trixie-arm64-stable.img.xz`; prereleases never touch it.

`scripts/update_os_list.py` writes the M5 Imager entry as
`CardputerZero CPZ (Trixie arm64) vX.Y.Z` (plus ` (Beta)` for a prerelease).
That name is generated; do not edit `os-list.json` by hand.

A stable release is a tag without a prerelease suffix and a GitHub Release with
the *pre-release* checkbox clear. A prerelease has both the suffix and the
checkbox set. This flag, not the title, selects the channel.

## 5. Procedure

1. Start from a clean `master` that is not behind `origin`.
2. Write the notes file using the template above.
3. Check the version and tag without changing anything:

   ```bash
   ./tools/release.sh minor --notes deploy/release-notes-v0.5.0.md --dry-run
   ```

4. Run the release from the repository root:

   ```bash
   ./tools/release.sh minor --publish --notes deploy/release-notes-v0.5.0.md
   ```

   The script runs `tools/verify-stage.sh` and `tests/run.sh`, bumps `VERSION`,
   commits `chore(release): vX.Y.Z`, creates the annotated tag, pushes both and
   publishes the GitHub Release with the standard title and the notes file.
   Publishing starts `.github/workflows/build.yml`.

5. Watch the **Build and publish CPZ image** workflow. It verifies the image,
   attaches the assets, uploads to OSS and refreshes `os-list.json`.
6. Verify the release page: title, notes, `.img.xz`, `.info`,
   `build-info.json`, channel and stable alias.

To rebuild an already published tag, run the workflow manually
(`workflow_dispatch`) with that tag; do not create a new tag or release. A
release created without `--publish` MAY be published by hand only with the same
title, notes template and prerelease flag.

## 6. Checklist

- [ ] `VERSION` equals the tag without `v` and is valid SemVer.
- [ ] Tag is annotated, pushed, and matches the release commit.
- [ ] Title is `CardputerZero CPZ vX.Y.Z`.
- [ ] Body has the title, summary, `Highlights`, `Changes`, `Install`.
- [ ] Channel is correct (`-beta.N` / `-rc.N` and pre-release flag, or stable).
- [ ] Workflow finished and attached all assets.
- [ ] OSS copy and `os-list.json` entry exist; stable alias updated only for a
      stable release.
