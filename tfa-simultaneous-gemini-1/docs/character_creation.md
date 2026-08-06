# Character creation — the Scarlatti carta d'identità

Character creation and the character sheet are one document: the identity card
the Republic of Scarlatti issues at the immigration office. Creation is the
clerk filling it in; the sheet is the same card, already convalidated, reopened.

The visual reference is a mid-century Italian *carta d'identità* — engine-turned
guilloché print, engraved capitals, a photograph in a printer's frame — and the
whole document is in Italian.

The card carries only what varies. Decorative boilerplate (ministry line,
expatriation note, FOTOGRAFIA caption, office stamp, signature rule, the
CONNOTATI header, a CITTADINANZA line that read "Scarlattina" for everybody,
the examination's subheading and its provincial physician) was all cut, along
with the one-word verdict that used to sit beside each score. If you are adding
something to the document, the bar is that it differs between two characters.

## Where things live

| Concern | File |
| --- | --- |
| Stat dice (1d33 + 1d66 DARO) | `Global/DaroDice.gd` |
| Height / weight / age dice | `data/races.json` (`human`), rolled by `RaceDatabase.roll_body_metrics` |
| Italian strings, portrait pool, name pools, background filter | `data/character_creation.json` |
| Lookups over that data | `Global/CharacterCreationDatabase.gd` (autoload) |
| The document itself (both modes) | `UI/CartaIdentita.gd` |
| Security print / state arms | `UI/GuillocheRect.gd`, `UI/ScarlattiEmblem.gd` |
| Full-screen host | `UI/CharacterCreationScreen.gd` |
| Boot gate, sheet hotkey, applying the card | `Game.gd` |
| Portrait art generator | `tools/generate_creation_portraits.py` |
| Tests | `tests/character_creation_test.tscn` (39 checks) |

## Stat rolling — 1d33 + 1d66 DARO

DARO is "Doubles Add and Roll Over". A die that lands on a *repdigit* — a face
whose two digits match — adds that face to a running total and is rolled again;
the chain ends on the first non-repdigit, which is also added.

* d33 repdigits: 11, 22, 33
* d66 repdigits: 11, 22, 33, 44, 55, 66

Each die explodes independently and the two totals are summed. Both dice
explode at 1-in-11, so:

* E[1d33 DARO] = 18.7, E[1d66 DARO] = 36.85 → **mean stat ≈ 55.6**
* Minimum stat is 2; there is no maximum
* A DARO total can never itself be a repdigit of the die that produced it,
  since the chain only terminates on a non-repdigit — the test asserts this

Six stats are rolled (Forza, Costituzione, Destrezza, Volontà, Intelligenza,
Carisma). `luck` is left at its default of 0: it belongs to a separate opt-in
system and every existing template leaves it there.

**The peak rule.** If no stat reaches 80 the *entire block* is rerolled, not
the offending stat. Roughly 62% of blocks clear it on the first attempt.
`DaroDice.MAX_BLOCK_ATTEMPTS` caps the loop at 256 and returns the best block
seen — a backstop against bad data, not against bad luck.

**Rolls are binding.** The examination is sat once, when the screen opens, and
there is no button to re-sit it. The only thing on the card that changes a
rolled number is picking a sex, which re-measures the holder because the height
and weight dice are gendered.

## Height, weight and age

Rolled from the `human` entry of `data/races.json` **when the player picks a
sex** — changing sex re-measures the holder, because both the height and weight
dice are gendered.

```
height_cm = base + <dice>                                   male 160+2d10, female 148+2d10
weight_kg = base + height_roll * per_height_roll + <dice>   male 50+1.2r+2d6, female 42+1.1r+2d6
age       = starting.min + <dice>                           17+2d6
```

Weight keys off the *height roll*, so tall characters are heavy ones. Resulting
ranges: male 162–180 cm / 54–86 kg, female 150–168 cm / 46–76 kg, age 19–29.

Every other race still uses the old flat form (`"height": {"male": 148}`) and
resolves to exactly that number. `roll_body_metrics` accepts both shapes; the
test covers the legacy path so adding dice to a second race stays a data edit.

### Two things that used to be dead

`RaceDatabase` had always *tried* to write `race_height`, `race_weight`,
`base_age`, `middle_age` and `old_age` onto characters, but `ProceduralCharacter`
had no such properties and `_set_if_exists` silently dropped all five. They
exist now, along with `age`, `background_id` and `icon_path`.

Metrics are rolled once at creation and travel back through
`overrides.options.body_metrics`, which `apply_race_to_character` prefers over
rolling. Without that the protagonist would be re-measured on every map load.

### A third: spawning wounded

`max_health` is a derived property (`20 + CON/5 + Martial * 2`), but
`current_health` is stored, and `ProceduralCharacter._ready` seeds it at
`add_child` — which every spawner does *before* `build_character`. So the
template's stats, the race, the background and the school traits all moved
`max_health` afterwards and left `current_health` behind at whatever the
`@export` defaults implied.

This predates character creation: the protagonist spawned at 30/34 on its
`Martial: 2` alone, and djargo (constitution 40, below the default 50) spawned
at 30/28 — over its own maximum. A rolled constitution just made the gap wide
enough to notice. `build_character` now refills to full after the traits merge;
a `live_state` restore still wins, because Game applies it once
`_spawn_character` has returned and `_deserialize_character` clamps to the
final `max_health`. Two harness checks cover it, one per direction.

## The document

`UI/CartaIdentita.gd` builds both modes from one draft dictionary:

```gdscript
{name, gender, background_id, portrait_id,
 body_metrics: {height, weight, age, height_unit, weight_unit},
 stats: {strength: int, ...}}
```

* **Mode.CREATE** — name, sex, profession and photograph choosable; CONVALIDA
  emits `confirmed(draft)`.
* **Mode.VIEW** — everything set in type; CHIUDI or Escape emits `dismissed`.

Each score is printed as a bare number. The qualitative rating beside it
("Buono", "Eccellente") said nothing the number did not, and the `ratings`
table that backed it is gone from the data.

Typography carries the whole effect. Captions are engraved in Cinzel with
space-padded tracking (`_letterspace` — Godot's `Label` has no letter-spacing);
the holder's particulars are typed in a system monospace face. The project sets
Cinzel as `gui/theme/custom_font`, which also becomes `ThemeDB.fallback_font`,
so a value left on the default face comes out engraved like the caption above
it — `_typed()` overrides the font explicitly and must keep doing so.

The guilloché is procedural `_draw()`: a wave field, a sunburst, nested
spirograph rosettes and a woven rope border, seeded from the holder's name so
one character always gets one document. The arms of Scarlatti are a laurel
wreath around a set of scales that does not hang level.

## Flow

1. `Game._ready()` calls `_should_run_character_creation()`. If true it awaits
   `CharacterCreationScreen.completed` **before the first `load_map`** — the
   world never exists without a protagonist. `_ready` is a coroutine from that
   point on, so nothing may be added after the `load_map` call.
2. `apply_character_draft` folds the card into `party_state[0].overrides`:
   `unique_name`, `gender`, `race`, `background`, `stats`, `icon`,
   `options.body_metrics`, plus the verbatim `carta`. Because `build_save_dict`
   snapshots `party_state` wholesale, the card persists with no extra work.
3. `_spawn_player_and_party` stamps the `carta` onto the protagonist as node
   metadata — nothing in the simulation reads it, only the sheet does.
4. **F8** reopens the card for the primary-selected party member (protagonist
   if none). A character with a stored `carta` gets that document reprinted
   with live scores; anyone else gets one reconstructed from their properties.

`build_character` gained two override keys for this: `stats` (merged per key
over the template's) and `icon` (a per-character portrait, which the party
panel and downtime portraits now prefer over the template icon).

### Skipping the gate

* `--skip-creation` on the command line
* `Globals.skip_character_creation = true` (also set once a card is issued, so
  reloading with **R** does not reopen the office)
* Automatically when `DisplayServer.get_name() == "headless"`, which keeps all
  33 existing test scenes unblocked

## Portraits

`data/character_creation.json` holds the pick pool, filtered by sex. It is
seeded from the existing `Icons/` tokens, hand-tagged after reviewing them at
full size — several plausible-looking entries turned out to be elves,
lizard-folk or orcs, so **check new additions at full resolution**, not as
thumbnails. `portraits_for()` drops any entry whose art is missing rather than
showing an empty frame.

### Cropping

Those tokens are circular: artwork inside radius 113 of centre (128,128) on a
256px canvas, a tan ring outside it, transparent corners beyond that. Dropped
whole into a rectangular photo frame, the ring and the corners are the first
thing you see. So `CartaIdentita.TOKEN_CROP` crops to the largest frame-shaped
rectangle that fits wholly inside the artwork circle, nudged up so the sitter's
face lands centre, applied as an `AtlasTexture` region. It is expressed as
fractions of the source, so it holds at any token resolution.

A manifest entry may set `"crop": "full"` to be used as it stands — which is
what the generator writes, since its photographs are already frame-shaped.
Omitting the key means "token", because every seeded entry is one.

The seeded pool is lopsided (40 male / 12 female) because the existing token
set is. `tools/generate_creation_portraits.py` generates purpose-built card
photographs — front-facing sepia studio busts, cropped and toned to the frame —
and `--wire` appends them to the manifest:

```bash
python tools/generate_creation_portraits.py --gender female --wire
```

Its prompts are phrased entirely in the positive: image models attend to
concepts whether or not they are negated, so "no pointed ears" is a reliable
way to get pointed ears.

## Backgrounds

All 41 backgrounds are offered except those the manifest excludes. Only
`foppish_elf` is barred outright (every player character is human);
`yeatsian_breeding_slave` and `oriental_dancing_girl` are gender-locked. The
chosen background's traits print as TRATTI DISTINTIVI, and its description
prints below the profession.

The caption is deliberately not the authentic one. A real Italian card says
SEGNI PARTICOLARI, but "segni" only half-lands as "signs" for an English
reader. TRATTI DISTINTIVI is equally real Italian, both words are near-cognates
("traits", "distinctive"), and it describes what the field actually holds. The
empty value is the English "none" rather than "nessuno", because the values
beside it are English trait names and an Italian one read as a different kind
of thing. Captions are Italian; values follow the data.

The description paragraph is the longest run of text on the card, so it is set
larger and darker than a field entry and its box is fixed to the height of the
longest description in `backgrounds.json` (carnie, four lines). Fixing it to
the worst case stops every field below shifting as the player scrolls
professions.

Background names and descriptions stay in English — they are shared with the
rest of the game's data. Only the document's own chrome is Italian.

## Tests

```bash
godot --headless --path . res://tests/character_creation_test.tscn
```

39 checks: DARO invariants and distribution, the peak rule, body-metric ranges
for both sexes, the legacy flat-height path, manifest integrity, draft
consistency, and an end-to-end build of a protagonist from a convalidated card.

The harness asserts its own check count. A GDScript runtime error aborts only
the function it occurs in, so without that guard a case that crashed midway
would report zero failures — which is exactly what happened once during
development.
