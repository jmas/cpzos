# CPZ UI and text rules

Normative rules for every user-visible surface:

- the on-device TUI (`cpz-settings`), status bar, help, hints, first-login
  prompt and Search popup;
- the static site (`site/`);
- messages printed by helpers when a user action fails.

The goal is a small, predictable system: one place for settings, one way to
express each kind of control, and no text that exists only to fill space.

`MUST`, `SHOULD` and `MAY` are used as in RFC 2119. An exception is allowed
only through the process in [Exceptions](#9-exceptions).

---

## 1. Audit rules

These are the rules the UI review follows. An audit is not a style opinion:
every finding must be reproducible and tied to a file or a rendered state.

### A1. Inventory every surface

List every place that can show text:

- `site/index.html` and `site/i18n/*.json`;
- `stage3/01-session/files/cpz-settings` pages, dialogs, values, footers,
  empty states and loading text;
- `cpz-status`, `cpz-conn-status`, `tmux.conf` (status bar and tab strip);
- `cpz-help`, `cpz-hint`, `cpz-first-login`;
- `cpz-search` items, prompts and hints;
- helper output that reaches the user (`cpz-automount`, `cpz-font`, ...).

A review of only the happy-path screen is incomplete.

### A2. One finding, one piece of evidence

Every finding records:

```text
Surface:   TUI / site / status bar / help
Where:     file:line or URL section
Text:      the exact label or sentence
Purpose:   the decision or state it helps with
Problem:   duplicate / filler / ambiguous / dead / inconsistent
Severity:  P0 / P1 / P2 (see A10)
Fix:       the proposed replacement or removal
```

Do not report "the UI feels cluttered". Report the string, the reason and the
replacement.

### A3. Purpose test for every string

Each visible string MUST pass one of these tests:

- **Label** — names a destination, a control or a value.
- **Value** — states the current condition.
- **Hint** — names a key that works for the current selection.
- **Message** — reports the result of an action, or an error and the next step.
- **Explanation** — prevents a likely mistake (for example "This erases the
  card" or "Do not pull the power").

If a string passes none of these tests, delete it. Section counts, section
numbers, "Three things…" introductions and "This page does X" paragraphs are
usually filler.

### A4. Redundancy test

A fact appears once per surface. Before adding text, search for the same fact
elsewhere:

- login details, Wi-Fi state and the power-off instruction belong to the
  first-start checklist, not to both the hero and the checklist;
- `Download`, `Latest release` and `Documentation` must not appear in the
  header, a section and the footer at the same time;
- a success toast is redundant when the screen already shows the new value.

The same key list may exist in `cpz-help` and `cpz-search`, but it MUST be
generated from one source or checked for drift.

### A5. State and feedback test

For each action, check the whole loop:

1. Is the current value visible before the action?
2. Does the action explain what it will change?
3. Is the result visible without a message?
4. If a message is needed, is it the result and not a repetition?
5. On error, does the message say what failed and what to do next?
6. Does the modal wait for Enter on errors and disappear on routine success?

An action that produces a toast only to say "done" when the value already
changed is noise.

### A6. Navigation test

For each destination:

- How many key presses from `Settings`? Everyday actions SHOULD be reachable in
  at most two.
- How deep is the stack? More than three levels (main → page → detail) is a
  smell.
- Can the user always go back with `q`/`Esc` without changing data?
- Does the footer name only keys that work on the selected row?
- Is every focusable row either actionable or deliberately non-focusable?

### A7. Consistency and glossary test

Search the UI for alternate names of the same concept. The canonical terms are
in [Glossary](#10-glossary). A new synonym is a finding unless it describes a
different thing.

### A8. Width, state and locale matrix

Check the worst cases, not the default:

- panel `53x14` at the default 12 px cell;
- HDMI, where more columns are available;
- one tab and many tabs; one layout and several layouts;
- no adapter, adapter present but idle, connected;
- no battery, charging, low battery;
- each supported locale on the site (currently 11);
- dark and light themes, and `Mono` / `Light High Contrast`.
- a confirm, a picker and Search in each theme; the frame, title and muted
  hint must stay distinguishable.

Labels MUST fit the label column; the footer MUST fit the 51 content columns
(53 minus the one blank column on each side); a status token MUST remain
distinguishable from every other token.

### A9. Verify claims

A claim in UI text is a requirement, not marketing. Examples:

- "The same list is on the device" is false unless the site list and the device
  list really match.
- "No config files" is false if a user must edit one.
- "Scanning…" must be shown only while the action blocks.

Run the checks that can falsify text:

```bash
python3 site/check.py
python3 -m unittest discover -s tests -p 'test_*.py'
tests/lint.sh
bash tools/verify-stage.sh
```

### A10. Severity

| Severity | Meaning | Examples |
| --- | --- | --- |
| **P0** | The UI breaks its promise, hides state or prevents a task | `Enter open` on a row that does nothing; two status tokens using `B`; no way to find a time zone in hundreds of rows |
| **P1** | The user can finish but pays in time or trust | duplicated CTA targets; mixed terminology; success toast for an invisible no-op; implementation jargon |
| **P2** | Polish and future risk | decorative section numbers; slightly awkward wording; a second copy of a key list that can drift |

### A11. Fix order

1. P0 state and navigation bugs.
2. Delete or merge text before adding anything.
3. Rename to the glossary.
4. Add a pattern only if no existing pattern fits.
5. Re-run A3–A9 on the changed screens.

### A12. Audit output

The result is a list of findings plus a short "what is already good" section.
Do not rewrite working UI merely to match personal taste; if a rule is not
violated, leave it alone.

---

## 2. Product UI model

CPZ is a terminal-first graphics session:

```text
tabs ─ panes ─ status bar
   Alt+S → Settings (main → page → picker)
   Alt+H → key reference
   Alt+O → Search
   a game or video → opens over the terminal, then returns to the same tab
```

- Settings is the only configuration surface. A setting that requires editing
  a file is a bug.
- The main menu is a map of destinations, not a list of commands.
- The Settings TUI owns the same session that runs the shell. Leaving Settings
  must never close a terminal tab.
- Search is a shortcut into Settings, apps and the power actions, not a second
  settings system.
- A graphical app is not a second mode. It opens over the terminal and closing
  it returns to the same tab. There is no desktop, window manager or task
  switcher.

---

## 3. Hard invariants

### Text

1. Every label names a destination, control or value; otherwise it is removed.
2. Sentence case, no trailing colon, no "please", no "successfully".
3. One concept, one term (see the glossary).
4. No implementation jargon on daily surfaces: `cage`, `foot`, `tmux`, `apt`, `NTP`,
   `EDID`, `autologin`, `PipeWire`, catalog internals. Put it in `About` or
   the documentation.
5. Units are explicit: `px`, `%`, `s`, `lines`.
6. A value states the condition: `Never`, `Muted`, `Connected`, `Not
   available`. Do not make the user parse `On` to mean "mute is on".
7. A message names the object and the outcome: `Removed htop`, `Time zone set
   to Europe/Kyiv`. `Done` is not a result.
8. An error says what failed and what to do: `Install failed. Run Settings →
   System → Terminal and retry.` Raw logs belong in About.
9. Do not repeat the screen title in the first line of its body.
10. Do not use text as decoration. If a number or paragraph has no
    navigational or safety purpose, remove it.

The on-device UI ships in the same languages as the site; English is the
fallback. The language is selected in Settings → System → Language and also
sets the system locale for new logins. The site is available in more
languages; it keeps on-device menu names in their canonical English form and
translates only the explanation (see rule 34).

### Controls and navigation

11. The main menu MUST fit 9 rows and the panel. Full-screen pages keep one
    blank column on each side; all labels MUST fit the 16-character label
    column and footers MUST fit the remaining 51 content columns.
12. No dead focusable rows. An info row either has no cursor or its Enter opens
    details. The footer MUST NOT advertise `Enter` for a row that ignores it.
13. Footer keys MUST be valid for the current selection and context. Teach the
    keys that work now, not the whole keymap. Footer hints use palette slot 8,
    the theme's muted colour, so they match the Search footer in every theme.
14. `Enter` opens, confirms or applies. `Space` toggles. `q`/`Esc` goes back
    without changing data. `/` starts filtering.
15. Destructive actions MUST confirm, name the object and default to "no".
16. A new binding MUST be added to `cpz-help` and the relevant footer in the
    same change. No hidden destructive shortcuts.
17. A list with more than ~20 unrelated names MUST have type-to-filter. An
    ordered numeric scale MAY use a picker, but it MUST open on the current
    value.
18. Every list MUST have an empty state that names the next step, for example
    `No devices. Press r to scan.`
19. Values are changed with a toggle for exactly two states, a picker modal
    for every named set (three or more variants, or two named variants that are
    not `On`/`Off`), and a scale for an ordered numeric range (`Left`/`Right`
    step, `Enter` opens the same list). A named set MUST NOT change on
    `Left`/`Right`: the picker is the only way to choose one. Free-form device
    names and time zones use a picker or searchable list, never blind cycling.
20. Settings depth MUST NOT exceed three levels including the main menu.
21. Adding a top-level menu row requires removing or merging another; the
    nine-row budget is part of the design.

Mouse and wheel input is an optional accelerator, never the only way to reach
a control. A click selects a row, a double-click activates the same action as
`Enter`, and the wheel scrolls; every one of those actions MUST also work from
the keyboard. Text selection and copying belong to tmux/foot, not to the TUI.

### Status bar

22. A token is shown when it carries information. An enabled Wi-Fi or
    Bluetooth adapter is shown as `Wi` or `Bt`; a connected link adds `+`.
    Ethernet uses `Et+` only while a cable is connected and is hidden
    otherwise. An idle adapter is not a warning.
23. Two indicators MUST NOT use the same letter. Current tokens: `Wi`, `Wi+`,
    `Bt`, `Bt+`, `Et+`, `V0`–`V4`, `VM`, `L0`–`L10`, battery `%`, `+`, `!`,
    layout code.
24. Colour is never the only signal: low battery also has `!`, charging has
    `+`.
25. Every token MUST be explained in the status-bar section of `Alt+H`.

### Feedback

26. Do not show a toast when the changed value is already visible.
27. Success may disappear; errors and anything the user must act on wait for
    `Enter`/`Esc`.
28. Cancelling a confirmation is not a result and gets no message.
29. Loading text is inline and blocking; it must not pretend the UI is idle.

### Site

30. The header has at most five links and one primary download target.
31. One primary call to action per view. Secondary links must have a distinct
    destination, not the same URL under another name.
32. A fact appears once. Login, Wi-Fi state, key list and install steps are not
    repeated in three sections.
33. Navigation labels match the section headings (`Keys`, not "Key
    reference").
34. Keep on-device menu names and paths in the canonical English form inside
    site translations; translate the explanation, not the UI path. The device
    itself shows them in its selected language.
35. The site must stay readable without JavaScript and pass
    `python3 site/check.py`.

### Accessibility and i18n

36. Keyboard-only operation is the baseline; focus, skip link and contrast are
    not optional.
37. Meaning is not carried by colour alone.
38. New user-visible strings on the site require all locale files and
    `site/check.py`. New TUI strings must fit 51 columns in every supported
    layout of the panel and in every language catalog.
39. A translation may be longer than English; leave room in labels and
    footers.

### Modal chrome

40. Every CPZ modal uses the same frame: a single-line square border, a bold
    title in the top border with one space on each side, one blank row, body
    text one column inside the border, and a muted hint on the last row inside
    the frame. Confirm, result, picker, filter and Search all use it; no
    surface draws a second variant.
41. The title is drawn as `" title "` starting at column 2, so one space
    separates it from the corner; body text and the hint start at column 2.
    Only a destructive action reverses the title; all other titles are bold
    only.
42. A CPZ modal hosted in a tmux popup runs borderless (`display-popup -B`)
    and the application draws the frame. Do not pass `-T` to add a second
    title.
43. Search is a modal, not a page: it uses the same frame, one blank row and
    muted hint as the Settings dialogs. Full-page references (`Alt+H`) and
    external tools (`htop`, `passwd`) are not modals and keep their own
    presentation.
44. Do not draw scroll markers, counters or decoration on the frame. Overflow
    is shown by the list cursor and the footer, never by overwriting the
    border.

Implementation: `draw_modal_frame()` in `cpz-settings` and the
border/label/padding block in `fzf_args()` in `cpz-search`. Changing one
without the other is a finding.

### Sentence shape and translation

These rules apply to English and to every translation. English is the source of
meaning, not a word order to copy.

45. Name what appears on screen, not the place the system "starts in":
    `opens a terminal instead of a desktop`, not `starts in a terminal instead
    of on a desktop`.
46. Keep every noun phrase complete. `for the CardputerZero handheld`, not a
    bare adjective with an implied noun.
47. Keep contrasts parallel. Compare two interfaces or two places, not an
    interface with a place: `a terminal, not a desktop`, not `in a terminal,
    not on a desktop`.
48. Name a concrete actor and give every transitive verb an object. `This
    erases the card`, not `Writing erases the card`; `press again to undo`, not
    `press again to restore` when the object is unclear.
49. Use one grammatical form per list or table column. If the header is
    `Includes`, every row is a noun phrase; if it is `What you can do`, every
    row starts with a verb.
50. Prefer the everyday word when both words are accurate: `audio devices`,
    not `input and output devices`; `automatic time`, not `clock sync`.
51. Do not use a dash as a substitute for a verb in a full sentence.
    `Wi-Fi, sound and power are in Settings`, not `Wi-Fi, sound and power — in
    Settings`.
52. Translate meaning, not words. If a literal translation sounds like a
    calque, rewrite the sentence in the target language. Read it aloud before
    committing it.

| Bad | Good | Why |
| --- | --- | --- |
| starts in a terminal, not on a desktop | opens a terminal instead of a desktop | names what appears; keeps the contrast parallel |
| for the CardputerZero | for the CardputerZero handheld | completes the noun phrase |
| Writing erases the whole card | This erases everything on the card | a process is not an actor |
| press again to restore | press again to undo | a transitive verb needs an object |
| Wi-Fi, sound and power — in Settings | Wi-Fi, sound and power are in Settings | a dash is not a verb |
| input and output devices | audio devices | everyday word |

### Brevity and one fact, one place

53. Give each fact one job and one place on a surface. The same fact may appear
    again only when it changes job: a promise in the hero, an instruction in
    the first-start list, a reference in a table. Never repeat it twice with
    the same job.
54. Each section adds the next fact. The hero states the promise; the first
    section after it must not paraphrase the hero. If a card repeats the hero,
    replace it with a new capability or delete it.
55. A section introduction must add information that the heading and the
    controls do not already give. If it only announces the controls, delete it.
    A table or list is a reference, not a script: do not narrate its rows.
56. Keep one primary call to action per view. Do not repeat the primary
    download label in a section; a persistent header link is navigation, not a
    second CTA. Secondary links must have distinct destinations.
57. A title names the thing; its description adds a fact. Do not restate the
    title in the first sentence.
58. Prefer deletion to paraphrase. If two sentences say the same thing, keep
    the shorter one with the action. The footer does not repeat the product or
    device name. Metadata may restate the hero for search; visible copy may
    not.

| Was watery | Minimal | Why |
| --- | --- | --- |
| hero and first card both say "a terminal, not a desktop" | hero says it; first card says "Split the screen" | one job per fact |
| keys intro says "Alt+H shows the full list"; the Alt+H row repeats it | keep the row, delete the intro sentence | the table is the reference |
| help intro repeats Alt+H/O/S from Keys | delete the intro | adds no information |
| hero "Download image" and section "Latest release" open the same page | keep the hero CTA; the section offers "All releases" only | one primary CTA |
| second card repeats "your tabs stay open" | "Plug in a monitor at any time; your work stays open" | adds a new fact |
| footer repeats "built for CardputerZero" | "Based on Raspberry Pi OS." | branding already says it |

---

## 4. Pattern catalogue

Use these patterns first. A new control style needs an exception (section 9).

| Pattern | Use for | Keys | Value | Footer |
| --- | --- | --- | --- | --- |
| **Info row** | read-only state inside a page | none; not focusable if possible | state | no `Enter` promise |
| **Action row** | immediate command or opening another screen | `Enter` | optional state | `Enter open` |
| **Submenu** | another Settings page | `Enter` / `Right` | optional summary | `Enter open` |
| **Toggle** | exactly two states | `Enter`, `Left`/`Right` | `On`/`Off` or `Muted`/`Not muted` | `Enter toggle` |
| **Scale** | ordered numeric range, such as brightness or text size | `Left`/`Right` step, `Enter` opens the same list | current value + unit | `Z/C change  Enter list` |
| **Picker** | every named set, such as theme, language or text format | `Enter` opens, `Enter` applies, `q` cancels; `Left`/`Right` do nothing | current label | `Enter list` |
| **Searchable list** | more than ~20 unrelated items | type to filter, `Esc` clears, `Enter` applies | query line | `Type to filter  Enter keep  Esc clear` |
| **Text page** | About, key reference | scroll, `q` back | — | `F/X scroll  q back` |
| **Modal frame** | chrome for every confirm, result, picker, filter and Search | — | bold title in the top border, body one column in, muted hint on the last inner row | — |
| **Confirm modal** | destructive or irreversible action | `Enter`/`y`, `n`/`Esc` | question + detail | `Enter/y yes  n/Esc cancel` |
| **Result modal** | success that is not visible on screen | `Enter`/`Esc` | outcome | `Enter/Esc close` |
| **Toast** | routine success already implied by the screen | none | outcome | no hint |
| **Status token** | persistent state worth a permanent column | — | compact token | explained in `Alt+H` |
| **Context hint** | discovery of the next keys | — | — | only current keys |

Do not:

- use a toast for an unchanged state;
- use a modal for optional reading;
- cycle a named set with `Left`/`Right`; open a picker instead;
- use `picker` for a numeric range or `scale` for a named set;
- use a submenu for a single action;
- use an action row for a setting that could be a toggle;
- draw a second frame inside a modal, or add `-T` when the app already draws
  the frame;
- put scroll markers or counters on the frame.

Implementation: `cpz-settings --check-pages` rejects `cycle` rows and any
`special` row that hides `values`. A new named set MUST declare `picker`; only
an ordered numeric range may declare `scale`.

---

## 5. Text formulas

### Labels

```text
<Object>            Display, Battery, Brightness, Ethernet
<Object> <Qualifier>  Status Refresh, Text Size
```

No verbs, no sentences, no punctuation.

### Values

```text
<state>             On, Off, Muted, Never, Connected
<number><unit>      50%, 12px, 5s, 2,000 lines
<name>              Europe/Kyiv, Built-in screen
```

### Hints

```text
<keys>  <verb>  <keys>  <verb>
F/X move  Enter toggle  q back
```

### Messages

```text
<verb> <object>                  Removed htop
<object> <state>                 Time zone set to Europe/Kyiv
<what failed>. <next step>.      Install failed. Retry from System → About.
```

---

## 6. Navigation and keys

Top level:

| Key | Action |
| --- | --- |
| `Alt+S` | Settings |
| `Alt+H` | full key reference |
| `Alt+O` | Search |

These are the defaults. Every action is rebindable in Settings → Input →
Shortcuts; see [CPZ-KEYS.md](CPZ-KEYS.md) for the rules and the complete list.

Inside Settings:

| Key | Action |
| --- | --- |
| `F`/`X`/`Z`/`C` | move (Fn off; arrows also work) |
| `Enter` | open / apply |
| `Space` | toggle |
| `q`/`Esc` | back |
| `/` | start filtering in a long list |

Rules:

- A key that appears in a footer MUST work on the focused row.
- A key that is not in the footer MUST be in `cpz-help`.
- Do not add a shortcut for a destructive action without a confirmation.
- Do not rely on a tmux prefix for daily actions.

---

## 7. Site rules

- Navigation: `Install`, `Keys`, `Settings`, `Help`, `Download` (five).
- Hero: one primary `Download image`; at most one secondary link.
- Every section answers one question and links out instead of duplicating the
  documentation.
- Key combinations stay literal; only descriptions are translated.
- Describe a game or video by what it does. Do not name `cage`, `foot`,
  `Wayland`, `X11` or `tmux` on the site.
- Chapter numbers are decoration and are not used.
- Release version is not printed; link to Releases.
- Locale files have the same keys and pass `site/check.py`.

---

## 8. Review checklist

Before merging a UI change:

```text
[ ] Every new string passes the purpose test (A3).
[ ] No fact repeats another surface (A4).
[ ] Current value is visible; result is visible (A5).
[ ] Footer keys work on this row (A6, invariant 13).
[ ] Labels <= 16 chars; footer <= 51; main <= 9 rows.
[ ] Long list has filter and an empty state.
[ ] Every named set opens a picker; only numeric ranges use `Left`/`Right`.
[ ] New/changed binding is in cpz-help and the footer.
[ ] Destructive action confirms and defaults to no.
[ ] Modal uses the shared frame: bold title in the border, one blank row,
    body and hint at column 2.
[ ] A tmux popup behind a CPZ modal is borderless and has no `-T` title.
[ ] Errors say what failed and what to do.
[ ] Dark/light, Mono, one/many tabs, no/connected adapter checked.
[ ] Site: all 11 locales updated.
[ ] Every sentence has a concrete subject and object; no calque, hanging
    modifier, mixed list form or dash-for-verb (rules 45-52).
[ ] Lists and table columns use one grammatical form and the header names it.
[ ] Each fact has one job and one place; sections add facts, not paraphrases
    (rules 53-58).
[ ] One primary CTA; section intros add information; the footer does not
    repeat the product name.
[ ] python3 site/check.py
[ ] python3 -m unittest discover -s tests -p 'test_*.py'
[ ] tests/lint.sh
[ ] bash tools/verify-stage.sh
```

---

## 9. Exceptions

A new pattern is allowed when an existing pattern genuinely cannot express the
interaction. "It looks nicer" is not a reason.

Before implementing it, add a row to the exception register below and explain:

1. the surface and the user job;
2. which catalogue patterns were tried and why each fails;
3. the proposed pattern and its states (empty, loading, error, success);
4. the keyboard map and how it fits 51 columns;
5. how it is added to `cpz-help` and the site if needed;
6. the tests or verify checks that keep it correct;
7. why the extra pattern is worth its maintenance cost.

Rules for exceptions:

- one new pattern per change;
- the pattern is a pilot on one surface until it has been used twice;
- it must not introduce an unlabelled destructive key;
- it must not duplicate an existing destination;
- it is reviewed at the next UI audit and removed if unused;
- a text-only problem (filler, duplication, unclear wording) is never an
  exception; fix the text with the existing patterns.

### Exception register

| Date | Surface | Pattern | Why existing patterns fail | Revisit |
| --- | --- | --- | --- | --- |
| — | — | — | none yet | — |

---

## 10. Glossary

| Term | Use for | Not |
| --- | --- | --- |
| **Settings** | the TUI and its main page | Preferences, Control Panel |
| **Connections** | Wi-Fi, Bluetooth, Ethernet, VPN page | Network (for the page), Connectivity |
| **Display** | theme, brightness, screen output, font, text size, status bar | Display & Brightness |
| **Font** | foot typeface for the whole terminal interface | Font Family, Typeface |
| **Text Size** | foot font size, 12–32 px | Font Size |
| **Keys** | key reference | Key Bindings, Key reference |
| **pane** | a tmux split | split, window |
| **tab** | a tmux window | window (in user text) |
| **System Monitor** | `htop` | Resources |
| **About** | version, uptime, memory, battery, network, storage and diagnostics | Resources |
| **Clock Sync** | automatic NTP time | Set Automatically |
| **Status Refresh** | status bar refresh interval | Refresh Rate |
| **Not available** | a capability is missing | unavailable, n/a (in user text) |
| **Muted / Not muted** | audio mute state | Mute On/Off |
| **Built-in screen** | the internal panel | CPZ panel (in daily UI) |

---

## 11. How this audit was applied

The review that produced these rules used the same sequence:

1. Read every surface and extracted all string literals, then classified each
   as label, value, hint, message or explanation.
2. Removed strings that failed the purpose test: the "Three things…" intro,
   the repeated hero note, `Install.note` without an action, the status-bar
   hint that described a state the UI does not have.
3. Checked each fact once: login and Wi-Fi moved to the first-start list;
   `Download`, `Documentation` and `Latest release` kept one home each.
4. Walked the Settings tree with a 53x14 grid: labels over 16 characters,
   dead info rows, footers that promised Enter, and lists without filters.
5. Applied the glossary: `Network` → `Connections`, `Display & Brightness` →
   `Display`, `Resources` → `System Monitor`, `Set Automatically` → `Clock
   Sync`.
6. Replaced hidden/no-op feedback: removed the refresh action and its toast,
   removed "Cancelled", "Reloaded" and "Not connected", made info rows stop
   advertising `Enter`.
7. Removed duplicate key sources: deleted the unused tab counter, kept
   `cpz-help` as the device reference and mirrored its content in the
   `cpz-settings` fallback.
8. Re-ran `site/check.py`, the unit tests, `tests/lint.sh`,
   `tools/verify-stage.sh` and a browser pass (console, overflow, 11 locales).

Future audits follow sections 1 and 8; changes that cannot fit this document
need an entry in section 9.
