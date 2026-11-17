# CPZ site

Static site for the CPZ image: why CPZ, install and first-boot steps, key
reference, Settings and help. It is published with GitHub Pages by
`.github/workflows/pages.yml`; there is no build step.

## Preview

```sh
python3 -m http.server 8000 --directory site
```

Then open <http://localhost:8000/>. The language files are loaded with
`fetch()`, so open the page through a server rather than `file://`.

## Languages

`index.html` contains the English text. `i18n/<code>.json` holds the full string
table for each language; `assets/app.js` applies it and keeps the choice in
localStorage and `?lang=`. The current set is English, Ukrainian, Polish,
German, French, Spanish, Italian, Portuguese (Brazil), Turkish, Japanese and
Simplified Chinese.

To add a language:

1. Copy `i18n/en.json` and translate the values. Keep every key and the
   `{shown}` / `{total}` placeholders.
2. Add an `<option value="xx">` to `#lang-select` in `index.html`.
3. Add the code to the `supported` array in `assets/app.js`.
4. Run `python3 site/check.py` from the repository root.

`check.py` rejects missing or extra keys, empty values, placeholder changes and
keys referenced from the HTML that do not exist. CI and the Pages workflow run
it before deploying.

## Release version

The site does not print a version number. The hero, install section and footer
link to GitHub Releases (`releases/latest` and the full list), so the page
cannot drift from `VERSION`.

## Design rules

- Plain HTML, CSS and a small script. No frameworks, fonts or trackers.
- English text lives in the HTML so the page is readable without JavaScript.
- Key combinations stay literal; only their descriptions are translated.
- Keep it short: why CPZ, install, keys, Settings and help. Link out for details.
- Write for someone who has never used Linux. Explain or drop jargon such as
  `kmscon`, `tmux`, `TUI`, `apt` and `PipeWire`; keep it in the documentation.
- In translations, translate the site chrome and descriptions but keep
  on-device menu names in English (`Settings`, `Network`, `Power`, ...), so they
  match what the device shows.
- Keep the first-boot facts in sync with `config.cpz.example`: default login
  `cpz` / `cpz` and Wi-Fi off until it is enabled in Settings.
