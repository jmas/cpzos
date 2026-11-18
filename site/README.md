# CPZ site

Static site for the CPZ image: why CPZ, install and first-start steps, keys,
Settings and help. It is published with GitHub Pages by
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
Simplified Chinese. The site languages are independent of the device: the
device UI ships in English, Ukrainian and German.

To add a language:

1. Copy `i18n/en.json` and translate the values. Keep every key.
2. Add an `<option value="xx">` to `#lang-select` in `index.html`.
3. Add the code to the `supported` array in `assets/app.js`.
4. Run `python3 site/check.py` from the repository root.

`check.py` rejects missing or extra keys, empty values, placeholder or
`aria-label` changes, keys referenced from the HTML that do not exist, and a
short list of banned phrases from the sentence-shape rules. CI and the Pages
workflow run it before deploying.

## Release version

The site does not print a version number. The hero, navigation and install
section link to GitHub Releases (`releases/latest` and the full list), so the
page cannot drift from `VERSION`.

## Design rules

The canonical product-wide rules live in
[`docs/CPZ-UI.md`](../docs/CPZ-UI.md). The site-specific rules below are a
short version of that document.

- Plain HTML, CSS and a small script. No frameworks, fonts or trackers.
- English text lives in the HTML so the page is readable without JavaScript.
- Key combinations stay literal; only their descriptions are translated.
- Keep it short: why CPZ, install, keys, Settings and help. Link out for details.
- Write for someone who has never used Linux. Explain or drop jargon such as
  `cage`, `foot`, `tmux`, `Wayland`, `X11`, `TUI`, `apt` and `PipeWire`; keep
  it in the documentation.
- Write sentences that stand on their own in the target language. Name what
  appears on screen (`opens a terminal`), keep noun phrases complete, keep
  contrasts parallel and do not translate English word order (rules 45-52 in
  `docs/CPZ-UI.md`).
- Use one grammatical form per list or table column. A column headed `Includes`
  holds noun phrases; a column headed `What you can do` holds verbs.
- Keep one fact in one place. The hero makes the promise; each section adds a
  new fact, not a paraphrase. Delete an introduction that only repeats the
  heading or the controls. One primary download call to action (rules 53-58 in
  `docs/CPZ-UI.md`).
- Describe graphical apps by what they do (`game`, `video`), not by how they
  are built.
- In translations, translate the site chrome and descriptions but keep
  on-device menu names in English (`Settings`, `Connections`, `Power`, ...), so they
  match what the device shows.
- Keep the first-start facts in sync with `config.cpz.example`: log in with the
  name `cpz` and the password `cpz`, Wi-Fi is off until it is enabled in
  Settings → Connections, and the device language is in
  Settings → System → Language.
