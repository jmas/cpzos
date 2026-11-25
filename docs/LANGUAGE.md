# Language and translations

Status: agreed on `design/app-platform` (2026-11-26). This is the language
model for the UI core and for every app that follows
[TUI-CONTRACT.md](TUI-CONTRACT.md). Keyboard layouts are a different concern:
they switch the letters a key produces and are documented in the TUI contract.

## 1. What "system language" means

One product language per device, independent of the glibc locale. The base
image ships `LOCALE=C.UTF-8` and no generated locales, so a POSIX locale name
is not a usable source of translated strings. The UI owns a small language
code instead.

Supported codes (base language only, no regional variants yet):

```text
en  de  es  fr  it  ja  pl  pt  tr  uk  zh
```

`pt-BR` resolves to `pt`, `zh-Hans`/`zh-CN` to `zh`; an unknown code falls back
to `en` and logs one line. The product never refuses to start because of a
language.

## 2. Where the language lives

| Priority | Source | Purpose |
| --- | --- | --- |
| 1 | `CPZ_LANG` environment variable | tests, SSH troubleshooting, one-off runs |
| 2 | `~/.config/cpz/language` | per-user choice, one line, e.g. `uk` |
| 3 | `/etc/cpz/language` | system default, one line, written at build time |
| 4 | `LANG` / `LC_ALL` | honoured only if the value maps to a supported code |
| 5 | `en` | final fallback |

- `/etc/cpz/language` is generated from `config.sh` (`UI_LANGUAGE`, default
  `en`) by `scripts/30-configure.sh`, like `HOSTNAME` and `TIMEZONE`.
- A per-user file is optional; the UI never creates it until the user changes
  the language.
- `LANG` stays `C.UTF-8`. A translated UI does not require `locale-gen`, and
  apps do not call `setlocale`; translation is application data, not libc
  state.
- Resolution happens once per process at start. A new app instance sees a
  changed language; a running app does not need to re-render. This is not the
  keyboard layout switch from `UI-QUALITIES.md`, which is live.

## 3. One resolver

The apps repository has one package, `internal/i18n`:

```go
lang := i18n.System()        // CPZ_LANG, user file, /etc/cpz/language, LANG, en
tr := i18n.For(lang)         // embed.FS of locales/*.json, en fallback
tr.T("apps.remove", "name", entry.Name)
tr.N("apps.count", n)        // plural bucket via x/text
```

- No app parses the files itself and no app hardcodes a string.
- The resolver is pure: reads at most two small files, no subprocess, no
  network, no D-Bus. It fits the 100 ms first-frame budget.
- `internal/i18n` is part of `cpz-system-apps`; third-party apps may copy it
  or reimplement the same precedence and file names.

## 4. Catalog format

Per app, `locales/<code>.json`, embedded into the binary:

```json
{
  "language": "uk",
  "strings": {
    "apps.remove": "Видалити {name} і його пакет?",
    "apps.count": {
      "one": "{n} додаток",
      "few": "{n} додатки",
      "many": "{n} додатків",
      "other": "{n} додатку"
    }
  }
}
```

Rules:

- Flat keys, dotted namespaces per app (`home.`, `apps.`, `settings.`).
- `{name}` placeholders; the same placeholders must exist in every language.
- A plural value is an object keyed by CLDR categories (`one`, `few`, `many`,
  `other`) and selected with `golang.org/x/text`; never `n > 1`.
- Missing key in a translated file falls back to `en` at runtime. A missing
  `en` key is a build failure, not a runtime fallback.
- CI checks key parity, placeholder parity and valid JSON for every shipped
  language; a translation cannot silently rot.
- Catalogs are versioned with the app package. There is no separate language
  pack and no download at runtime.

## 5. Desktop entries and the catalog index

- `Name`, `GenericName`, `Comment` and `Keywords` keep their standard
  `[lang]` variants; this is the translation mechanism for the entry itself.
- The catalog generator copies every available `name[lang]`/`comment[lang]`/
  `keywords[lang]` into `apps.json`, so Apps Manager and Home show the system
  language before the app is installed.
- Lookup is `system language → en → untranslated field`. A missing translation
  never blanks a row.
- Search matches the system language and the English original; keywords from
  every language are searchable.
- Category names are Apps Manager's own strings, translated through its catalog;
  the `Categories` values stay English identifiers.

## 6. Formatting and sorting

- Numbers, dates and times use `golang.org/x/text/message` with the resolved
  language. Timezone comes from the platform (`UTC` by default).
- Lists sort by the displayed name using `golang.org/x/text/collate` (primary
  strength) after case folding; never byte order and never `strings.ToLower`
  on Cyrillic alone.
- Width is counted in terminal cells (`go-runewidth`), not bytes. Ukrainian is
  the width test: if a label does not fit at 40 columns, it is too long. Values
  may be truncated with `…`; labels may not.

## 7. Definition of done for a translated app

- [ ] Every visible string is in `locales/en.json`; no literals in `cmd/` or
      `internal/` outside the catalogs (review check).
- [ ] Ukrainian catalog is complete and passes the 40-column check.
- [ ] `go test` covers: fallback for an unknown code, missing-key fallback,
      plural buckets (`1`, `3`, `5` in uk), placeholder substitution.
- [ ] Golden frames run with `CPZ_LANG=en` and `CPZ_LANG=uk`.
- [ ] Desktop entry has `Name[uk]`, `Comment[uk]`; `desktop-file-validate`
      passes.
- [ ] Search matches a Ukrainian name and an English keyword.

## 8. Base integration (follow-up in this tree)

1. `config.sh`: `UI_LANGUAGE="en"` with a comment about the supported codes.
2. `scripts/30-configure.sh`: write `/etc/cpz/language` from it.
3. `scripts/50-verify.sh`: assert the file exists and contains a supported
   code.
4. `docs/HARDWARE-TEST.md`: check that Home and Apps Manager follow
   `CPZ_LANG=uk` live, without a session restart.

## 9. Later

- A language item in Settings (the only setting today is About system).
- Regional variants (`pt-BR`, `zh-Hans`) if a translator asks for them; the
  codes then become BCP-47 tags and the fallback chain grows one level.
- Right-to-left layouts: none of the supported languages needs it; adding one
  is a layout project, not a catalog entry.
