# Repository rules

## Documentation language

- All documentation MUST be written in English. This includes `README.md`,
  every file under `docs/`, design notes, changelogs, release notes and any new
  Markdown document.
- Write new documents in English and translate existing non-English
  documentation when touching it.
- User-facing localization is not documentation. Keep the UI catalogs in
  `stage3/01-session/files/i18n/*.json`, `site/i18n/*` and other translation
  resources in their target languages.
- Code comments are part of the source and should be English as well.

## Persistent state

- `/home` is the only persistent store for user-specific data. The OS image is
  replaceable; `/etc` and `/var` are image-owned and MUST NOT receive
  user-changeable state at runtime.
- Any new persistent user file MUST be schema-versioned and migrated
  forward-only. Data written by an older release MUST keep loading; never
  remove a migration or a legacy key alias.
- `docs/STATE.md` is the normative contract. Read it before adding state, and
  update its map and deviation register with every new persistent path.
- `tests/test_state_contract.py` guards runtime shell writes. A new exception
  needs a justified allowlist entry.
