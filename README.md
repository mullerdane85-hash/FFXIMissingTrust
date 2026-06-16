# FFXIMissingSpells

## 🔑 Hotkey

**Default toggle: `Alt+M`**

Press `Alt+M` in-game to show or hide the window. Goes through Windower's `bind` system, so the keybind is automatically suppressed while the chat bar, search box, or macro editor is open — won't fight with typing.

`M` for "Missing".

Slash-command equivalents: `//ms`, `//missingspells`, `//mspells`, `//mt`, `//mtrust`.

---

Tells you which spells *and trusts* your character still needs to learn.
Started life as FFXIMissingTrust (the trust-only addon) and got expanded
to cover the full spell book — thirteen tabs across the top: a `TRUST`
tab that does exactly what the old addon did, plus twelve job tabs
listing every spell that job can learn at lv 1-99. Each row is `-` red
if missing or `+` green if already learned.

## Install

Drop the `FFXIMissingSpells` folder into `addons\`. Then in-game:

```
//lua load FFXIMissingSpells
```

To autoload it every session, add `lua load FFXIMissingSpells` to
`scripts\init.txt`.

## Window

Press **Alt+M** to toggle the window in-game. The keybind is suppressed while
chat is open so typing the letter 'm' still works normally.

```
//ms              — toggle the window (same as Alt+M)
//ms show         — show the window
//ms hide         — hide the window
```

The window has two strips of tabs:

- **Title bar (top right)** — `Missing` / `Owned` / `All` filter
- **Beneath the title bar** — thirteen tabs:
  `TRUST | WHM | BLM | RDM | PLD | DRK | BRD | NIN | SMN | BLU | GEO | SCH | RUN`

The `TRUST` tab is the original FFXIMissingTrust functionality: every
trust in the game (minus Unity Concord variants) with its combat job
tag and role descriptor.

The twelve job tabs show every spell that job can learn natively, sorted
by level. Row format is `[Lv NN]  Spell Name   (Skill)`. In the All
mode entries are color-coded individually (red = missing, green = owned);
in Missing / Owned the entire list is the matching color.

**Mouse:** drag the title bar to move. Mouse-wheel scrolls the list. Up/down
arrow buttons appear on the right when there are more entries than fit on
screen. Window position, current job tab, and current mode all persist to
`data/settings.xml`.

## Chat commands

| Command | What |
|---|---|
| `//ms count [TAB]` | One-line "owned / total (missing)" summary for the given tab (defaults to current) |
| `//ms list  [TAB]` | Print every missing entry for the tab in chat |
| `//ms have  [TAB]` | Print every owned entry for the tab in chat |
| `//ms find <name>` | Search every tab — shows owned/missing status and which job(s) or trust role |
| `//ms <TAB>` | Quick-switch the active tab (e.g. `//ms trust`, `//ms blm`) |
| `//ms mode <missing\|owned\|all>` | Change the filter mode |
| `//ms refresh` | Re-read the spell book and redraw |
| `//ms help` | Show the help blurb |

Aliases: `//missingspells`, `//mspells`, and `//ms` all work. The original
trust-only command prefixes `//mt` and `//mtrust` are also kept as
back-compat aliases so anyone with the old commands in their scripts
keeps working.

## How it works

- Iterates `resources/spells.xml` for every spell that has
  `spell.levels[job_id]` set for the selected job tab
- Filters out trust spells (`spell.type == 'Trust'`) — those live in their
  own addon (FFXITrusts / FFXIMissingTrust if you still have it)
- Compares each spell ID against `windower.ffxi.get_spells()` — your
  actual spell book
- Sorts by level ascending, then alphabetically
- Skill column comes from `res.skills[spell.skill].en` if it's a recognized
  magic skill, otherwise falls back to `spell.type` (e.g. "Geomancy",
  "BlueMagic", "BardSong", "Ninjutsu", "SummonerPact")

## Notes per job

- **BRD** — every song the job can learn natively, regardless of whether
  it's currently slotted in your active set.
- **BLU** — every Blue Magic spell. The addon does NOT check what's in
  your set spells; missing means you haven't learned it yet at all.
- **SMN** — covers SummonerPact spells (the avatar magics like Ramuh's
  Wind Blade, Aerial Armor, etc.), not the BPs themselves.
- **NIN** — Ninjutsu spell list (Utsusemi, elemental ni / san, status
  enfeebles, Tonko, etc.).
- **GEO** — Indi-, Geo-, Bolster, Entrust, the works. Geomancy type.
- **SCH** — strategos / addendum magic. Doesn't distinguish Light Arts
  vs Dark Arts; the level number is what matters.
- **RUN** — runes themselves aren't spells, so this tab is light. Lunge,
  Swipe, Gambit, Vallation etc. show here when they're stored as spells.

## Renamed from FFXIMissingTrust

This repo started life as FFXIMissingTrust — only listed trusts. It got
expanded to handle every magic school so it could replace the
type-it-out-in-chat workflow for spell scrolls too. If you remember the
old `//mt` commands, they still work.

## Credits

- **Isolraine @ Asura** — provided the entire spell-acquisition
  database (`formatted_spells.csv` → `libs/acquisition.lua` and
  `libs/acquisition_full.lua`). Every vendor name, NPC location,
  gil price, monster drop list, BCNM source, and Blue Magic mob
  list that the addon shows comes from Isolraine's tables. Without
  that work this would just be a list of spell names with no
  context for where to get them. Massive thanks.
- The data layer also cribs from `resources/spells.xml` (Windower's
  bundled spell table) and `windower.ffxi.get_spells()` (your live
  spell book), same approach the **Spellbook** addon pioneered.
- Trust → job and trust → role tables curated from BG-Wiki.

## Author

TWinn22 (GitHub: TWinn22 / FFXI: Jason, 2026). Built for the
FFXIWindower personal repo.
