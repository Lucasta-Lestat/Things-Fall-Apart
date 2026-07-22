# Plan: Law, Crime, and Stealth

Crime is jurisdiction × ownership × witness. Jurisdiction already resolves O(1) today
(`RegionDatabase.get_region_for_map` :46 → `get_controlling_faction` :55); ownership is one
string on `Item`; and the witness fan-out already exists at `Game.gd:1247`. The new machinery is
therefore small: one JSON file of statutes read by a pure resolver, one delayed-scream timer that
lives **on the witness's own AI node** so that killing the witness cancels the alarm by
construction rather than by revocation code, one alarm channel on `HearingManager` so the scream
must physically travel through walls to reach a guard, and one per-faction standing scalar parked
beside the already-written-but-uncalled tier API at `FactionDatabase.gd:52`. Everything downstream
of "a guard heard it" — target acquisition, trade refusal, right-click-becomes-attack, ability
targeting — is existing code that follows for free once one hostility oracle says the player is
hostile. Two new autoloads, one new data file, roughly 700 lines of GDScript.

---

## Corrections to the brief

Six premises in the brief and the audit are **false against the shipped data**. Each was verified
by parsing the JSON or reading the function. They change the design materially, so they come first.

**C1 — `player` is already a real faction with real relations.** `data/factions.json` defines
`player` with `tier: 1`, `allies: ["town_guard", "merchants"]`, `enemies: ["bandits", "undead",
"demons", "rival_party"]`. It also appears in the `enemies` list of `bandits`, `undead`, `cultists`,
`rival_party`, and `skarsgaard`, and in the `allies` list of `golden_guard` and
`adventurers_guild`. **Do not author a new empty entry** — doing so silently pacifies every
scripted ambush in the game. (The audit's narrower runtime claim does hold: a `golden_guard`
listener discards player footsteps, because `golden_guard.enemies == ["bandits"]`.)

**C2 — `golden_guard` lists `player` as an ALLY.** So does `adventurers_guild`. Any design where
stance is `static_base + crime_scalar` starts the town guard at a *friendly* offset, and the first
several crimes are cancelled out before they can register. This is why enforcement cannot be
threshold-derived alone (§Phase 6).
> **RESOLVED in Phase 1 by user direction:** the player starts *neutral* with the guard.
> `golden_guard.allies` no longer contains `player`, and `player.allies` no longer contains the
> undefined `town_guard`. (`adventurers_guild`'s ally link stands.) The `hostile_override`
> mechanism in Phase 6 is still required for D8's binary, but the friendly-offset hazard is gone.

**C3 — the guards who police Perrow are declared ENEMIES of Perrow's lawgiver.** `regions.json`
gives `perrow.controlling_faction == "liziti"` (16 member maps, the starting region). The
`town_guard` template's faction is `golden_guard`. And `liziti.enemies == ["golden_guard"]`. Every
design that gates "who cares about this crime" on *the hearer being the offended faction or its
ally* is dead on arrival in the only town that matters. Enforcement authority must be authored
explicitly, not derived from relations (§Phase 3, `policed_by`).
> **CONFIRMED INTENTIONAL by the user:** Perrow is a city under mob rule. The Liziti mafia does
> the actual policing; the golden_guard are de facto powerless there. So Perrow's `policed_by` is
> **`liziti`**, not `golden_guard` — the authored-`policed_by` conclusion stands, and the lore
> reading is now canon. Note the enmity also means guards and mafia fight on sight wherever they
> co-spawn (`dock_tavern`: 5 liziti + 2 golden_guard) — true before Phase 1 and after. If cold
> hostility rather than open combat is wanted there, that is a data edit to `liziti.enemies`
> paired with a Phase 6 standing rule, and it needs a deliberate decision.

**C4 — a working currency deduction exists.** `scripts/DowntimeEffectApplier.gd:107
_apply_money(character, value, success_tier)` is static, drains gold-first across
`_ordered_currency_ids()` (:148), handles negative amounts and the `"all"` sentinel (:114-120), and
has two live callers (:48, :298). Fines are payable in coin. The elaborate barter-confiscation
machinery the brief implies is unnecessary as the *primary* path.

**C5 — the brief names the wrong container sites.** D5(d) cites
`ChestInventoryWindow.gd:200` and `:307`. `:200 _transfer_slot_to_selected` is a genuine take
(tap-to-take; erases at `:225` after the `if not transferred` guard at `:222`). **`:307 _drop_data`
is the receive side** — its `source_character` arm at `:312` *deposits into* the chest, and its
`source_chest` arm at `:340` pulls from *another* chest. The actual take-by-drag lives in
`UI/PartySidePanel.gd:586 _drop_data`, `source_chest` arm at `:595`, erasing at `:610`. Gating
`:307` makes giving items away a crime and still misses every drag-take.

**C6 — item ownership has almost no shipped coverage.** `data/Maps.json` carries **178 item spawns
across 24 maps, of which exactly 3 set `controlling_faction`** (cemetery, town_square, colosseum).
`town_square` has **one** item spawn. Defaulting `owner_faction` from `controlling_faction` yields
three owned objects in the entire game. Ownership needs a resolution chain with a
jurisdiction-level fallback (§Phase 4).

One further data hazard, not a brief error: `Abilities.json` authors traits with **value 0** on
some entries (`test_confused` has `"Occult": 0`). A predicate written as `trait in ability.traits`
matches those. All trait predicates must test **tier ≥ 1**, not key presence. The same file mixes
`Fire`/`fire`, `Martial`/`martial`, `Holy`/`holy` — hence the boot lint in Phase 3.

---

## Problem

There is no law system. There is a genuinely good detection pipeline — noise →
`HearingManager` → a 0-100 alertness meter with LOS confirmation → SEARCHING behaviour — and a
large amount of authored crime vocabulary with no reader (`wanted`, `pardon`, `criminal`,
`thrill_of_sin`, `walking_noise`, `Stealth`, `legal_title`).

The specific thing being built: the player should be able to steal, kill, and cast proscribed magic;
those acts should be crimes only where a faction has authored them as crimes; and the consequence
should have to *physically travel* from the eyes that saw it to the ears that enforce it, through a
window in which the player can intervene. That window is the game.

## Current implementation

| Concern | Where it lives now | State |
|---|---|---|
| Jurisdiction | `RegionDatabase.gd:46`, `:55` | Live, O(1), map-granular |
| Legality | `RegionDatabase.gd:116 is_service_legal` | Live but only for banned *professions*; gates shop UI only |
| Hostility (targeting) | `ai.gd:429 _is_enemy` | Reads never-assigned `Game.gd:53 factions`; collapses to `:438` "non-neutral vs non-neutral" |
| Hostility (everything else) | `FactionDatabase.gd:76 are_enemies` | Asymmetric by construction (reads only `a`'s list) |
| Stimulus bus | `HearingManager.gd:27 emit` | Only push-based bus; faction gate at `:72` discards nearly everything |
| Witness fan-out | `Game.gd:1247 _on_character_damaged` | Complete: iterates `characters_in_scene`, skips victim/attacker/party, LOS-filters, calls `wake_from_at_ease(65.0, location)` |
| Generic AI stimulus | `ai.gd:937 wake_from_at_ease` | All four existing stimuli converge here |
| Pre-execution veto | `AbilityManager.gd:393 _would_hit_infatuation_source`, called `:78` | The one position-aware veto with a refusal protocol |
| Trait-stacking primitive | `AbilityManager.gd:483 _check_action_trait_stacking` | Live; `thrill_of_sin` (`ConditionDatabase.gd:567-586`) needs only a trigger |
| Ownership | — | Does not exist. `ai.gd:798` reads Godot's built-in `Node.owner` |
| Persistence | `Game.gd:160`, `:190` | Party + NPCs with non-empty `titles` only |
| Save | — | Does not exist. Three orphaned `to_dict`/`from_dict` pairs |

## Root causes

**R1 — two contradictory hostility oracles.** Fixing this changes global NPC behaviour and is the
single highest-risk item in the plan, so it lands alone and first (Phase 1).

**R2 — `TimeManager.gd:74-76` wraps `game_time` to `[0, 86400)` daily.** No condition can outlive
one in-game day. Already breaks `ConditionManager.gd:106` periodic decay silently.

**R3 — `HearingManager.gd:72` discards a sound unless `are_enemies(listener, source)`.** Since
`player` is in almost no faction's enemies list, *no lawful NPC can hear the player at all*. The
entire noise half of stealth (`floors.json base_sound_level`, `noise_per_step`, the unread
`walking_noise` race stat) is inert against guards.

**R4 — ownership is lost at every boundary.** `Item.to_inventory_data()` (`:303`) re-reads
canonical Items.json and copies only `num_stacks`. `PartySidePanel._drop_item` (`:1010`) calls
`create_item(id, pos)` with no extras. `inventory.add_stack` (`inventory.gd:60`) merges a stackable
into an existing entry and **returns without ever appending the incoming dict** (`:82-83`).
`stow_weapon_from_data` routes weapons into an entirely different schema.

**R5 — nothing that dies stays dead.** `_is_service_npc` (`Game.gd:187`) is
`character.titles.size() > 0`; no guard template has `titles`. And `_on_character_died`
(`Game.gd:1760`) sets `AIState.DEAD` but **never sets `AI_enabled = false`** (verified: no such
assignment exists anywhere), so `process_ai` keeps ticking on a corpse and the `AIState.DEAD` arm at
`ai.gd:258` is reached only *after* the timer block at `:200-208`. A naively-placed scream timer
fires from a dead body.

---

## Proposed architecture

```
  act (4 gated sites)
    └─> CrimeManager.report(actor, verb, payload)          [Global/CrimeManager.gd]
          ├─ LawDatabase.jurisdiction_for_map(map_id)      [pure]  → law faction | ""
          ├─ LawDatabase.evaluate(code, verb, payload)     [pure]  → Verdict {} | {...}
          ├─ witnesses: LOS-to-crime  ∪ LOS-to-actor ∪ {victim} ∪ {self-enforcers}
          ├─ identified = LOS-to-actor AND not disguised
          └─ per witness: ai.begin_outcry(payload)         [timer lives on the WITNESS]
                 │
                 │  ← 0.9–3.0 s. Kill / KO / silence the witness here and nothing ever happens.
                 ▼
             HearingManager.emit(pos, 1.35, witness, "alarm", payload)
                 │  ← walls (×0.45 per wall, up to 3) and distance, existing physics
                 ▼
             ai.on_alarm_heard  →  CrimeState.record(payload)   [dedup by crime_id]
                 ├─ standing[faction] -= severity
                 ├─ hostile_override[faction] = true            ← D8's binary
                 ├─ ledger[faction].append(record)              ← pricing + dialogue ONLY
                 └─ manhunt_target = perp                       ← survives alertness decay
```

**Where state lives.** Two new autoloads, registered after `RegionDatabase` in `project.godot`:

- `Global/LawDatabase.gd` — loads `data/laws.json`, flattens code inheritance once at boot, runs
  the validation lint. Pure queries; no runtime state.
- `Global/CrimeManager.gd` — the mechanism (report, witness fan-out, alarm handling, surrender).
- `Global/CrimeState.gd` — **no.** Standing, ledger, and sentences live on `FactionDatabase`,
  mirroring the `set_faction_tier` (:52) / `adjust_faction_tier` (:62) API that is already written
  with zero callers. It is an autoload, so session durability across map transitions costs nothing.
- Item and NPC world state lives on `Game.gd` beside `npc_state_per_region` (:102).

**The D2 mitigation, stated as an invariant.** `_player_standing` and `hostile_override` resolve
*behaviour*. `_crime_ledger` prices fines and feeds dialogue and is read by **nothing** on an AI,
targeting, hearing, or hostility path. This goes in the `FactionDatabase.gd` header comment and is
asserted by a test.

---

# Phase 1 — One hostility oracle

Small, self-contained, and by far the riskiest change in the plan. It ships alone, gets its own
playtest pass, and nothing else starts until it is verified.

`ai.gd:438`'s "two distinct non-neutral factions are hostile on sight" fallthrough is what makes
this game hostile today. Deleting it and delegating to `FactionDatabase` would pacify most of the
bestiary: `wildlife` has **both** `allies: []` and `enemies: []`, and `liziti`, `patriciate`,
`pirates`, `tortellini`, `dragatini`, `vermincelli`, `waldau`, `alamoneans` never name `player`.

### Steps

1. **`data/factions.json` — add `hostile_by_default: true`** to `wildlife`, `bandits`, `undead`,
   `cultists`, `pirates`, `vermincelli`, `rebels`, `rival_party`, `skarsgaard`. Data only; no code
   branches on a faction id. Do **not** touch `player` (C1) and do **not** touch `laws` (it is the
   banned-professions list read by `TownServicesPanel.gd:194` and `DowntimeDatabase.gd:78`).

2. **`Global/FactionDatabase.gd` — add the oracle beneath `are_enemies` (:76).** Note the ordering:
   the `hostile_by_default` test sits **above** the player short-circuit. Putting it below (as every
   candidate design did) makes it unreachable for exactly the pairs that matter.

   ```gdscript
   func are_hostile(a: String, b: String) -> bool:
       if a == b:
           return false
       # Beasts and outlaws attack anyone not explicitly allied — INCLUDING the
       # player. This must precede the player branch or wildlife stops fighting.
       if _hostile_by_default(a) and not _friendly_to(a, b):
           return true
       if _hostile_by_default(b) and not _friendly_to(b, a):
           return true
       if a == "player" or b == "player":
           var other: String = b if a == "player" else a
           return player_stance_toward(other) == "hostile"
       # Symmetric: factions.json is inconsistently mirrored and are_enemies (:76)
       # reads only a's list. Fix the predicate, not 19 hand-mirrored JSON entries.
       return are_enemies(a, b) or are_enemies(b, a)

   func _hostile_by_default(fid: String) -> bool:
       if not _factions.has(fid):
           return false
       return bool(_factions[fid].get("hostile_by_default", false))

   func _friendly_to(a: String, b: String) -> bool:
       return a == b or are_allies(a, b) or are_allies(b, a)
   ```

   `player_stance_toward` is a Phase 6 addition; in Phase 1 it is a stub returning `"neutral"`.
   Keep `are_enemies` itself unchanged — `get_relationship` (:80) and future one-directional queries
   depend on its current semantics.

3. **`get_faction_data` (:36) stops `push_error`-ing.** `are_hostile` doubles the query count and
   the relation lists contain four undefined ids (`town_guard`, `merchants`, `nobles`, `demons`).
   Add `func has_faction(fid: String) -> bool` and make the relation helpers use it; keep
   `get_faction_data`'s error for genuine lookups.

4. **`ai.gd:429 _is_enemy` becomes a delegate.** Deletes the dead `:433-436` branch and the `:438`
   fallthrough:
   ```gdscript
   func _is_enemy(other: ProceduralCharacter) -> bool:
       return FactionDatabase.are_hostile(character.faction_id, other.faction_id)
   ```

5. **Delete `Game.gd:53 var factions: Dictionary`** and its readers: the `ai.gd:433-436` branch
   (gone in step 4), `ai.gd:803-806` inside `is_item_owned_by_ally` (rewritten in Phase 4), and
   `ProceduralCharacter.gd:4893 get_relationship_with` (delete the function — zero callers, would
   crash).

6. **Cheap wins that this phase makes free.** Erase dead characters from `characters_in_scene` in
   `_on_character_died` (`Game.gd:1760`) — the witness loop iterates it in Phase 5. Move
   `Game.gd:1461-1464` inside the pause guard that ends at `:1450` (the full LOS sweep currently
   runs at full rate during tactical pause). Delete `project.godot:49`'s `VisibilityManager`
   autoload, which points at a file that does not exist. Fold the unread `walking_noise` race stat
   into `ProceduralCharacter.gd:3940`: `loudness = (base_sound * footwear_mult + item_noise) *
   character.walking_noise` — one term, authored on 34 races with a real 0.3–1.5 spread, and it is
   the only thing that makes race matter to stealth.

**Testable at end of phase (headless).** `tests/hostility_harness.gd`: for all 19² faction pairs,
`are_hostile(a,b) == are_hostile(b,a)`; an AI's `_is_enemy` agrees with `are_hostile` for every
pair; and — the regression that matters — every pair that the old `:438` fallthrough made hostile is
either still hostile or is on an explicit allow-list committed with the test. **Manual pass
required on `town_square` (7 NPCs) and `dock_tavern` (12) before Phase 2 starts.**

### As built (2026-07-22)

Implemented as above with five deviations, all deliberate:

1. **`are_hostile` keeps the old predicate's "neutral" carve-out.** The sketch above had
   `hostile_by_default` factions attacking *everyone* unallied — but per-map spawn analysis showed
   that changes shipped scenes (`dock_tavern`'s bandit vs 4 neutral patrons, `don_manor`,
   `cemetery`'s conditional cultists vs the gravedigger). As built, `hostile_by_default` spares
   `faction_id == "neutral"`, exactly preserving old behaviour: bandits menace factions, not
   extras. Attacking civilians becomes a *crime* (Phase 6), not an impossibility.
2. **`player_stance_toward` reads static base relations, not a bare `"neutral"`,** so
   data-authored player enmity keeps working before Phase 6 replaces the internals.
3. **Per user direction, the guard starts neutral:** `golden_guard.allies` dropped `player`;
   `player.allies` dropped the undefined `town_guard`.
4. **The `characters_in_scene` death-erase was dropped.** Corpses in that array are load-bearing:
   ability target gathering (`ProceduralCharacter.gd:5863`) feeds necromancy/corpse-targeting from
   it, and `_update_npc_los_visibility` (`Game.gd:1344`) needs corpses in the sweep or their
   visibility freezes at death state. The Phase 5 witness loop must filter `is_alive()` instead
   (the existing loops already do).
5. **All player-facing hostility consumers switched to the oracle in this phase, not later:**
   right-click attack-vs-menu (`ProceduralCharacter.gd:3519`), Trade injection (`Game.gd:895`),
   ability target filter (`AbilityTargeting.gd:507`), town-services gate
   (`TownServicesPanel.gd:177`). `HearingManager.gd:72` deliberately stays on `are_enemies` until
   Phase 5's channel redesign. `connect_ally_witness` (`ProceduralCharacter.gd:6545`) also stays
   on one-directional `are_allies` — switching it to `are_friendly` would newly wire
   adrenaline-sharing between same-faction characters, a behaviour change that should not ride
   along silently; flagged as a candidate follow-up.

The old fallthrough → oracle behaviour diff was computed from live data before implementation:
**zero newly-hostile pairs, exactly 37 pacified pairs**, committed verbatim as
`EXPECTED_PACIFIED` in the harness. Harness: 26/26 PASS headless. Full-game headless boot shows
no new errors and the `VisibilityManager` autoload failure is gone. Undefined-faction templates
(`spider_party` ×3, `druids` ×3, `none` ×2) verified unspawned on all 24 maps; the tolerant
`_faction_or_empty` lookup keeps them peaceful and silent if they are ever wired in — give them
real faction entries at that point.

Post-implementation adversarial review (10 findings, 7 refuted, 3 confirmed) forced two fixes:

- **Doors could open during tactical pause** (the planning-mode context menu dispatches
  `Door.interact` while paused, and `open_door` swaps the collision layer out of
  `VISION_RAY_MASK` immediately), which made the pause-frozen LOS sweep show a stale room
  during planning. **User ruling: pause-time door use is itself the bug**, not something to
  design around — so `Door.interact` now refuses while paused (floating text "Not while
  paused"), the LOS sweeps stay fully pause-gated, and the invariant is documented at both
  sites: *nothing may change LOS during tactical pause; a future feature that does must
  trigger the sweeps itself*.
- **`fog_of_war.gd` + its `.uid` are deleted** (not just the autoload line): with the
  `VisibilityManager` autoload gone, the orphan script showed a parse error when opened in the
  editor. Zero references existed; the audit had already sentenced it.

Beware: an open Godot editor can transiently re-serialize `project.godot` and resurrect the
deleted `VisibilityManager` autoload line (observed once during review). If it reappears in a
diff, delete it again after closing the editor.

---

# Phase 2 — Calendar time

`TimeManager.gd:74-76` subtracts a whole day from `game_time` on every rollover. Three candidate
approaches were considered and all three had arithmetic faults; the correct form is **derived, not
accumulated**.

- A per-frame sibling accumulator double-counts, because `_process` *itself* calls `advance_days`
  at `:75` — the accumulator gains 86400 from the frame term and 86400 again from the rollover.
- Removing the wrap and *also* adding a day offset double-counts for the same reason in mirror.
- Removing the wrap alone breaks `set_time` (`:111-116`), which assigns the intraday value only and
  would rewind the clock by `days_elapsed` days, un-expiring every condition.

### Steps

1. **`Global/TimeManager.gd`** — keep the wrap at `:76` exactly as it is. Add a counter incremented
   *inside* `advance_days`' loop (`:79-98`), which is the single funnel every day change passes
   through — `_process:75`, downtime, and jail all route here:
   ```gdscript
   var days_elapsed: int = 0     # absolute days since epoch; never wraps

   # inside advance_days' `for i in range(days)` loop, alongside current_day += 1:
   days_elapsed += 1

   func absolute_time() -> float:
       return float(days_elapsed) * 86400.0 + game_time

   func today() -> int:
       return days_elapsed
   ```
   `set_time` (`:111`) and `set_date` (`:119`) need no change: `game_time` keeps its intraday
   meaning and `days_elapsed` is independent of both. `UI/TimePickerWindow.gd`'s hand-rolled
   `game_time` reset likewise keeps working.

   This is also correct for `DowntimeResolver.gd:197`, which advances time by mutating `game_time`
   directly — the wrap at `:74-76` then fires and routes through `advance_days`, so a sub-day or
   multi-day downtime block lands on the same counter.

2. **Switch `ConditionManager` to `absolute_time()` atomically.** The complete read set, from grep:
   `ConditionManager.gd:58` (`_process`) and `:219` (`apply_condition`). `ConditionInstance.apply`
   (:86), `is_expired` (:98), and `get_remaining_duration` (:104) are already parameterised on the
   passed time and need no edit. A partial migration compares a wrapped value against an unwrapped
   one and makes every condition either instantly expire or become permanent, silently.

3. **`UI/PartySidePanel.gd:1488` must move with them.** It reads `time_manager.game_time` and
   computes `instance.expires_at - game_time` at `:1501`. Left behind, every condition tooltip in
   the game reads a garbage countdown from the first day boundary onward. This is a regression the
   time fix itself introduces.

4. **Fix the absolute-into-relative mixup.** `Game.gd:2977-2983` passes an absolute `expires_at`
   into `apply_condition`'s **relative** `duration_override` slot, masked only because
   `ConditionInstance.apply()` (:86-91) re-stamps from the template. Replace `Game.gd:2795-2804`'s
   hand-rolled `{id, stacks, expires_at}` snapshot with the already-correct, already-written,
   zero-caller `ConditionManager.to_dict()` (:474) / `from_dict()` (:482). `ConditionInstance.from_dict`
   (:64-84) sets `expires_at` directly and never calls `apply()`.

5. **`ConditionManager.from_dict` skips apply-time side effects.** Re-run the `grants_ability` block
   (mirroring `:264-267`) for each rebuilt instance, or a restored condition silently loses its
   granted ability.

**Testable at end of phase.** `tests/time_harness.gd`: after `advance_days(3)`, `absolute_time()`
≈ `3*86400 + game_time` (not double); a condition with `duration: 259200.0` survives
`advance_days(2)` and is expired after two more; the 8-hour downtime path expires a 4-hour buff;
`ConditionManager._try_periodic_save` still fires across a day boundary (a bug that has been live
since the wrap was written); `get_remaining_duration` is sane after a rollover.

### As built (2026-07-22)

Implemented as specified (steps 1-5), plus three discoveries:

1. **`apply_condition` was clobbering every `duration_override` on fresh instances** —
   `instance.apply(current_time)` re-stamped the template expiry *after* the override branch set
   it. Reordered (apply first, then override). This unmasks two live callers toward their
   authored intent: `fog_overlay.gd:62`'s `condition_duration_override` and the condition-copy
   effect's `duration` (`ProceduralCharacter.gd:1344`, default 12 s) now actually take effect on
   first application. Callers passing explicit `-1.0` (races, backgrounds, thrill-of-sin) now get
   genuinely permanent conditions even on timed templates — previously the template duration won.
2. **`Condition.create_from_data` had type-wrong defaults** — `traits` and `immunities` are
   `Dictionary` properties but defaulted to `[]`, so any input omitting either key aborted with a
   runtime type error (masked at boot because `ConditionDatabase` always authors both). Fixed the
   two defaults; the Dictionary arm of `register_condition` works now.
3. **The plan's step 5 re-grant needed a dedup guard**: `Inventory.add_ability_by_id` does not
   dedup, and granted abilities *also* round-trip through the weapon serializer (restore order:
   inventory first, then conditions). `_regrant_condition_abilities` scans
   `stowed_items`/`equipped_weapons` for a matching `ability_id` before granting, so a restored
   character neither loses nor duplicates a condition-bestowed ability.

`tests/time_harness.gd`: 20/20 PASS headless (drives `TimeManager._process` by hand around
`pause_time()` so day rollovers are deterministic; synthetic conditions registered through the
now-working `create_from_data`). Hostility harness re-run green; full-game headless boot has zero
script errors.

---

# Phase 3 — Statutes, jurisdiction, and the pure resolver

Nothing behavioural. A data file, a loader, and one pure function that can be tested with no scene
tree at all.

## `data/laws.json`

Statutes are reusable **nouns**, defined once. Codes are per-faction **bundles** with inheritance,
flattened at boot into a `{statute_id: severity}` dict so runtime evaluation is one dictionary
lookup and not a graph walk.

```json
{
  "version": 1,
  "default_code": "common_law",
  "applies_to": ["player"],
  "confirm_above_severity": 50,

  "statutes": {
    "theft":       { "display_name": "Theft",   "verb": "take",  "match": { "owner": "law_faction" }, "severity": 25 },
    "burglary":    { "display_name": "Burglary","verb": "loot",  "match": { "owner": "law_faction" }, "severity": 30 },
    "assault":     { "display_name": "Assault", "verb": "attack","match": { "victim_protected": true, "lethal": false }, "severity": 40 },
    "murder":      { "display_name": "Murder",  "verb": "attack","match": { "victim_protected": true, "lethal": true  }, "severity": 90 },
    "necromancy":  { "display_name": "Necromancy",           "verb": "cast", "match": { "traits_any": ["necrotic", "drain"] }, "severity": 90 },
    "conjuration": { "display_name": "Unlawful Conjuration", "verb": "cast", "match": { "traits_all": ["summon", "Occult"] }, "severity": 55 },
    "mind_magic":  { "display_name": "Coercion of the Will", "verb": "cast", "match": { "traits_any": ["charm", "mental"] },  "severity": 40 },
    "occultism":   { "display_name": "Occultism",            "verb": "cast", "match": { "traits_any": ["Occult"] },          "severity": 30 }
  },

  "codes": {
    "none":        { "display_name": "No Law", "statutes": [] },
    "common_law":  { "display_name": "The Common Law", "statutes": ["theft", "burglary", "assault", "murder"] },
    "liziti_custom": {
      "display_name": "Liziti Custom", "extends": "common_law", "repeals": ["assault"],
      "notes": "Duelling is a private matter. Killing is not."
    },
    "waldau_rationalist_code": {
      "display_name": "The Rationalist Code of Waldau", "extends": "common_law",
      "statutes": ["necromancy", "conjuration", "mind_magic"], "overrides": { "theft": 40 }
    },
    "patrician_code": {
      "display_name": "Patrician Law", "extends": "common_law",
      "statutes": ["necromancy", "mind_magic"], "overrides": { "burglary": 55 }
    },
    "golden_guard_martial_law": {
      "display_name": "Martial Law", "extends": "patrician_code",
      "statutes": ["occultism"], "overrides": { "assault": 55 }
    }
  },

  "witness": {
    "outcry_delay_base": 2.2,
    "outcry_delay_guard": -1.1,
    "outcry_delay_victim": -1.3,
    "outcry_delay_afraid": 0.8,
    "outcry_delay_far": 0.6,
    "outcry_far_distance": 512.0,
    "outcry_delay_min": 0.8,
    "outcry_delay_max": 4.0,
    "outcry_jitter": 0.15,
    "scream_loudness": 1.35,
    "witness_alert": 70.0,
    "unidentified_alert": 45.0,
    "guard_alarm_alert": 74.0,
    "cancel_on_conditions": ["unconscious", "silenced", "panicked"]
  },

  "standing": {
    "hostile_at": -50, "friendly_at": 50, "floor": -250, "cap": 100,
    "decay_per_day": 1.0,
    "fine_gold_per_severity": 12.0,
    "jail_days_per_severity": 0.06
  },

  "surrender": {
    "default_profile": "implacable",
    "profiles": {
      "lawful":     { "accepts": true,  "options": ["pay_fine", "return_goods", "serve_time"],
                      "line": "On your knees. The magistrate will hear of it." },
      "predatory":  { "accepts": true,  "options": ["rob"], "rob_fraction": 0.5,
                      "line": "Purse or throat. Choose." },
      "implacable": { "accepts": false, "line": "It does not understand the word." }
    },
    "faction_profiles": {
      "golden_guard": "lawful", "patriciate": "lawful", "liziti": "lawful", "waldau": "lawful",
      "alamoneans": "lawful", "adventurers_guild": "lawful", "dragatini": "lawful",
      "tortellini": "lawful", "skarsgaard": "lawful",
      "bandits": "predatory", "pirates": "predatory", "rival_party": "predatory",
      "vermincelli": "predatory", "rebels": "predatory",
      "undead": "implacable", "wildlife": "implacable", "cultists": "implacable"
    }
  }
}
```

Verified against shipped `Abilities.json` (41 abilities): `necromancy` matches `creepy_beam`
(`necrotic: 3`) and `alms_of_the_vein` (`necrotic: 2, drain: 1`); `conjuration` matches `rat_pack`
(`summon: 1, Occult: 2`) and nothing else; `mind_magic` matches `beguile`, `confess`, `hitch`,
`fatal_attraction`, `wave_of_dysthymia`, and the three `test_*` abilities.

## `data/factions.json` — two new sibling keys

`laws` (banned professions) is **untouched**, so `TownServicesPanel.gd:194` and
`DowntimeDatabase.gd:78` are byte-for-byte unaffected. Profession-legality and act-legality are
different questions with different consumers — one filters UI visibility, the other sits on the hot
path of every cast — and there is no scheduled unification.

```json
{ "id": "liziti",       "law_code": "liziti_custom",           "policed_by": ["liziti", "golden_guard"] }
{ "id": "patriciate",   "law_code": "patrician_code",          "policed_by": ["patriciate", "golden_guard", "dragatini"] }
{ "id": "golden_guard", "law_code": "golden_guard_martial_law","policed_by": ["golden_guard"] }
{ "id": "waldau",       "law_code": "waldau_rationalist_code", "policed_by": ["waldau", "golden_guard"] }
{ "id": "bandits",      "law_code": "none" }   // + pirates, undead, wildlife, cultists,
                                               //   rebels, rival_party, vermincelli
```

**`policed_by` is the fix for C3** and is the most important single key in the schema. Enforcement
authority is authored, never derived. Without it, a `golden_guard` town guard hearing a theft in
liziti-controlled Perrow discards it — the two factions are declared enemies — and the system is
inert across 16 of 24 maps. `policed_by` defaults to `[law_faction]` when absent.

## `Global/LawDatabase.gd`

```gdscript
func jurisdiction_for_map(map_id: String) -> String
func code_for_faction(faction_id: String) -> String
func evaluate(code_id: String, verb: String, payload: Dictionary) -> Dictionary   # {} or Verdict
func enforces(hearer_faction: String, law_faction: String) -> bool                # policed_by
func witness_cfg() -> Dictionary
func standing_cfg() -> Dictionary
func surrender_profile(faction_id: String) -> Dictionary
```

`evaluate` returns `{}` for legal and a Verdict dict otherwise:
`{statute, display_name, severity, law_faction}`. **Highest severity wins** across matching
statutes, so ordering in the hand-edited JSON carries no meaning.

`jurisdiction_for_map` checks a per-map `controlling_faction` override in `Maps.json` **before**
falling back to `RegionDatabase.get_region_for_map` → `get_controlling_faction`. This is not
optional: **Waldau — the motivating example's own jurisdiction — controls no region.**
`regions.json` ships four regions (perrow/liziti, and argentiara/bortellini/alamone all
patriciate), and `waldau` is a faction governing nothing. Without the override the headline feature
is unreachable in shipped content. It also lets a designer flip one tavern or villa to a different
lawgiver, and it is the coarse-grained stepping stone to the sub-map zones trespass will eventually
need.

The `match` vocabulary is a **closed set of six named predicates**, each one line in
`_matches(statute, payload)`. Adding a statute is JSON; adding a *kind* of statute is one match arm
plus one payload key. A general expression language is explicitly refused — that is where these
systems die.

| key | meaning |
|---|---|
| `owner` | `"law_faction"` (owner is the law faction or someone it polices) / `"any"` / a faction id |
| `victim_protected` | victim's faction is policed by the law faction, and the victim was **not** already hostile to the actor |
| `lethal` | bool |
| `traits_any` | any listed trait present **at tier ≥ 1** |
| `traits_all` | all listed traits at tier ≥ 1 |
| `min_value` | item `cost` ≥ N |

The tier-≥-1 rule is load-bearing: `test_confused` authors `"Occult": 0`, and a key-presence test
would criminalise it.

## Boot-time validation lint

`LawDatabase._validate()` + `FactionDatabase._validate_relations()`, ~60 lines, `push_warning` only.
For a solo dev hand-editing JSON with no code review this is the highest value-per-line in the plan,
and it is what lets the schema afford to be expressive.

- a `law_code` naming a code that does not exist; an `extends` **cycle** (which would hang at boot)
- a code naming a statute that does not exist
- a `traits_any`/`traits_all` name matching zero abilities at tier ≥ 1 — catches `Necrotic` vs
  `necrotic` in a file that already ships `Fire`/`fire`, `Martial`/`martial`, `Holy`/`holy`
- a `policed_by` / `faction_profiles` / `owner` key naming an undefined faction
- unmirrored `enemies` relations, and undefined faction ids in relation lists (`town_guard`,
  `merchants`, `nobles`, `demons`)
- **a region whose controlling faction has no `policed_by` faction present on any of its member
  maps' `npc_spawns`** — i.e. a jurisdiction with no possible enforcer. This is the check that
  would have caught C3 before it shipped.

**Testable at end of phase (pure, no scene tree, no `game` stub).** `tests/law_data_test.gd`:
`laws.json` parses; every `law_code` resolves; no cycles; `_flatten_code("waldau_rationalist_code")`
contains `necromancy` at 90 and `theft` at 40 (override applied); `_flatten_code("liziti_custom")`
lacks `assault` (repeal) but has `murder` (inherited);
`evaluate("liziti_custom", "cast", creepy_beam_payload) == {}` while
`evaluate("waldau_rationalist_code", ...)` returns `necromancy` — **this pair is the acceptance test
for the whole design**; `evaluate` is pure (same payload twice, identical verdict);
`enforces("golden_guard", "liziti") == true`; and a regression guard that
`RegionDatabase.is_service_legal(["hedge witch"], "argentiara")` still returns false.

---

# Phase 4 — Ownership and the four gates

Crimes get reported and written to `GameLog`. Nothing consumes them yet. This phase is safe to ship
half-tuned.

## Ownership on `Item`

`Items/Item.gd` extends `AnimatableBody2D` → `Node`, which **already declares `owner`**.
Redeclaring it is a parse error, and that collision is exactly why `ai.gd:798` reads null today.
Three fields beside `controlling_faction` (`:59`), with the reason in a comment so nobody
re-introduces the bug:

```gdscript
# NOT named `owner` — Node.owner already exists, and ai.gd:798's is_item_owned_by_ally
# is a live bug caused by exactly that shadowing.
var owner_faction: String = ""   # "" == unowned, free to take
var owner_uid: String = ""       # optional specific NPC; the seam for per-NPC grudges
var stolen_from: String = ""     # stamped on take; drives confiscation and fencing
```

`owner_uid` costs one string and is the seam for "that's *my* chalice" dialogue and eventual
NPC-vs-NPC crime. `ai.gd:798`'s original intent was per-NPC ownership (it reads
`item.owner.faction_id`), so this preserves it.

**Resolution chain at spawn**, first hit wins, evaluated in `Game._spawn_items` (`:832-851`) and
passed through `create_item`'s `extras` (`:1042-1061`, which already carries `controlling_faction`
and `value`):

1. per-spawn `owner_faction` in `Maps.json` `item_spawns[]`
2. map-level `default_item_owner`
3. `LawDatabase.jurisdiction_for_map(map_id)` **if** the map declares `"settlement": true`
4. `""` — unowned

Step 3 is what gives shipped content coverage. Per C6, only 3 of 178 item spawns set
`controlling_faction`; a `controlling_faction`-derived default would produce three owned objects in
the entire game. One `"settlement": true` key per town map covers Perrow. There is deliberately
**no** "everything on a lawful map is owned" global — that criminalises picking up a stray apple
with no authoring signal.

## Closing the four ownership leaks (R4)

1. **`Item.to_inventory_data()` (`:303`)** — after the `num_stacks` copy:
   ```gdscript
   if owner_faction != "":
       dict["stolen_from"] = owner_faction
       dict["stolen_value"] = cost
   ```
   Free persistence: `Game._serialize_character` duplicates inventory dicts wholesale, so extra keys
   round-trip through the existing party save with zero new code.

2. **`inventory.add_stack` (`inventory.gd:60`)** — the merge path at `:71-83` increments an existing
   entry and returns **without appending `item_data`**, silently discarding `stolen_from`. Every
   stackable good (gold, arrows, draughts, food) would be unprovable the moment the player already
   holds one. Fix: propagate onto the merged entry.
   ```gdscript
   if item_data.has("stolen_from"):
       items[i]["stolen_from"] = item_data["stolen_from"]
   ```

3. **`inventory.stow_weapon_from_data`** — weapons route into `WeaponShape` and serialize via
   `to_data()`, an entirely different schema with no ownership field. Add `stolen_from` to
   `WeaponShape.to_data()`/`from_data()` and set it in `stow_weapon_from_data`. Weapons are the
   highest-value, most-stealable class; without this they are the one class that launders itself.

4. **`UI/PartySidePanel.gd:1010 _drop_item` and `:1029 _drop_item_amount`** call
   `create_item(item.get("id",""), pos)` — id only. Drop a stolen candlestick and pick it back up
   and it is clean. Pass `extras` carrying `owner_faction` / `stolen_from`, and accept them in
   `create_item` alongside the existing keys.

## The derived ownership query (D6)

```gdscript
# Game.gd
func items_owned_by(faction_id: String) -> Array
```

Linear scan of `items_in_scene` plus party inventories. **Derived, not indexed — and the argument is
correctness, not cost.** The three sites that mutate `items_in_scene` already disagree:
`Game.gd:1064` appends, `Game.gd:1073 _on_item_destroyed` erases via the `destroyed` signal wired at
`:1067`, and `ai.gd:828-831` removes the node and erases the array **without** calling
`_destroy_item()`, so the signal never fires. An index built on those leaks stale entries on the AI
pickup path on day one. Cost is irrelevant anyway: 178 spawns across 24 maps, 173 of them on three
map-generator demos, and `town_square` has one.

## The four gated sites

**Crimes are reported, never blocked** — with exactly one exception. Three of the four sites
structurally cannot refuse (`attack()` returns void, `ai.pickup_item` returns nothing, the chest
transfer is already committed at `:222`), and an RPG that refuses to let you steal is worse than one
that lets you and makes you regret it.

`CrimeManager` exposes a two-function contract so no call site contains policy:

```gdscript
func preview(actor, verb: String, payload: Dictionary) -> Dictionary   # side-effect free
func report(actor, verb: String, payload: Dictionary) -> void
```

`preview` is pure enough to call twice and is what lets the UI annotate an illegal action.

**(a) Cast — `Abilities/AbilityManager.gd`, inserted after the infatuation veto at `:84`, before
`_pay_ability_costs` at `:86`.** `target_position` is already resolved (`:67`) and self-corrected
(`:74-75`). This is the one site with a refusal, and it is a **one-shot confirmation**, not a veto:
legality is jurisdiction-dependent and invisible, and committing a capital crime by misclick is
worse than a prompt. Reuses `_would_hit_infatuation_source`'s protocol verbatim (`GameLog` +
`cast_failed.emit` + `return false`). A Yes sets a per-map flag so it never asks twice, and it only
fires above `confirm_above_severity` (50).

Report fires on *completion*, from `ProceduralCharacter.gd:5762` — the same site that already calls
`_check_action_trait_stacking` — so an interrupted cast is not a crime.

**(b) Attack — `Game.gd:1247 _on_character_damaged`.** Gated on damage application, not on swing:
`attack()` (`:4526`) returns void and a missed swing should not be assault. **Lethality is derived
here, not from `character_died`.** `character_died` is declared zero-arg (`ProceduralCharacter.gd:691`),
emitted with no payload (`:5183`), and connected as `_on_character_died.bind(character)`
(`Game.gd:382`) — there is no attacker in scope, so a murder report from that handler is
unreachable. But `take_damage` sets `current_health = clamp(...)` *before* emitting `damaged_by`
(`:5041` vs `:5048`), so `victim.is_alive()` is already false at fan-out time:
```gdscript
var kind: String = "murder" if not victim.is_alive() else "assault"
```

Two guards, both required:
- **Self-defence.** `victim_protected` is false when the victim's faction was already hostile to the
  actor. Without it, three hits in a bandit ambush are three assault charges against bandits, or
  −120 standing against the town for winning a fight it did not see.
- **Debounce per `(actor, victim)` pair on a 2.0 s window.** `damaged_by` fires once per damage
  application; a melee exchange is one crime, not one per hit. (The container gate needs the same
  treatment for the same reason.)

**(c) Pickup — `Game.gd:924 pick_up_item` (after the `if ok:` at `:941`, so a full inventory is not
a crime) and `ai.gd:815 pickup_item`.**

`pick_up_item` resolves the taker via `_resolve_pickup_character()` (`:950`), which returns
`primary_selected` **with no distance check anywhere in the call chain**. Today the player can
select a character outside the town gate and take an item from inside the guardhouse. Both possible
witness anchors are wrong when actor and item are unrelated, so this must be fixed rather than
worked around: gate both `pick_up_item` and `Item.interact("Pick Up")` on
`character.global_position.distance_to(item.global_position) <= PICKUP_REACH` (96.0 px, 1.5 tiles).
Walk-to-then-take is already expressible through the action queue. The same hole exists on
`show_chest_inventory` (`:963`, zero gates of any kind) and gets the same guard.

**(d) Container — `UI/ChestInventoryWindow.gd:200 _transfer_slot_to_selected` (tap-take, after the
`if not transferred` guard at `:222`, before `contents.erase` at `:225`) and
`UI/PartySidePanel.gd:595` (drag-take, after `if not transferred: return` at `:608`, before
`chest_item.contents.erase` at `:610`).**

Per C5, **leave `ChestInventoryWindow._drop_data` (`:307`) and `_can_drop_data` (`:296`) entirely
alone** — they are the receive side. Its `source_character` arm (`:312`) deposits into the chest and
gating it makes giving items away a crime; its `source_chest` arm (`:340`) is a chest-to-chest move
whose take is already covered by reading the *source* chest's owner.

## Who can commit a crime

**Player-facing only in v1**, expressed as `"applies_to": ["player"]` in `laws.json`. But the gate
is `actor.faction_id in applies_to`, **not** `actor in party_chars`. Those are different sets:
`AbilityEffect.gd:137-143 _resolve_summon` sets `spawned.faction_id = caster.faction_id` and
`spawned.AI_enabled = true`, while `party_chars.append` happens only at `Game.gd:801` (the party
spawn loop). A party-membership gate lets the player summon a rat pack, have it kill every NPC in
town, and stay friendly with the Golden Guard.

`_resolve_summon` additionally stamps `spawned.set_meta("summoned_by", caster)`, and `report`
attributes a summon's crime to its summoner — otherwise the fix merely makes the rats wanted, and
they despawn.

Justification for player-only: the AI never touches `AbilityManager` (zero references in `ai.gd`),
never opens containers, and its only crime-capable verb is `pickup_item`. Enabling NPC crime later
is adding a faction id to a JSON array; the AI pickup site is instrumented now so that flip needs no
archaeology.

**One AI-side change ships anyway, as a bug fix.** `ai.gd:798 is_item_owned_by_ally` becomes correct
for the first time and is used as a **refusal**, so guards stop looting their own barracks:
```gdscript
func is_item_owned_by_ally(item: Node) -> bool:
    if not ("owner_faction" in item) or item.owner_faction == "":
        return false
    if item.owner_faction == character.faction_id:
        return true
    return FactionDatabase.are_allies(character.faction_id, item.owner_faction)
```

**Testable at end of phase.** `tests/crime_gate_test.gd`: an owned pickup produces a verdict and an
unowned one does not; steal → drop → retake still reads stolen; steal into a **pre-seeded matching
stack** still reads stolen (the `add_stack` merge case — a fresh-inventory test passes while the bug
ships); an owned weapon survives `_serialize_character` → `_deserialize_character`; four takes from
one chest inside 2 s produce one crime; depositing into a chest produces none; a summon's kill is
attributed to the summoner; remote pickup beyond `PICKUP_REACH` is refused; self-defence against an
already-hostile attacker produces no verdict.

---

# Phase 5 — The witness pipeline

The centerpiece. Roughly 60 lines of genuinely new code.

## Fan-out

`CrimeManager._witnesses_of(crime_pos, actor, elev)` generalises `Game._on_character_damaged`'s loop
(`:1252-1271`) rather than duplicating it; `_on_character_damaged` becomes a thin caller. Four
corrections to that loop, all of them closing a way to commit crime for free:

1. **`Game.gd:1277 _has_visual_los` gains `target_elev: float = 0.0`** and passes it to
   `_sight_line_clear` at `:1291`. Today a crime on a roof reads as unseen from the street.
   `ai.gd:304 is_in_line_of_sight` already takes it. While there, add the blinded/unconscious guard
   from `Game.gd:1281` to `ai.gd:304` so the two wrappers stop disagreeing.

2. **Two LOS tests, not one.** Every candidate design tested LOS from witness to *actor*, which
   makes every ranged and AoE crime free: stand behind a wall at the plaza edge, `creepy_beam` a
   merchant, and no witness exists in the design's sense. Split them:
   - LOS to the **crime position** → the witness saw *something happen*. Starts an outcry with
     `identified: false`.
   - LOS to the **actor** → upgrades to `identified: true` (absent a disguise; D7).

   One extra `_has_visual_los` call per witness on a push event.

3. **The victim is a witness.** `Game.gd:1252-1254` skips `victim` and `attacker` — so the one
   person guaranteed to know about an assault is the one person who can never report it. Beat a
   merchant unconscious in a side street and nothing is ever recorded. Add the victim explicitly,
   with `identified: true` forced (they were touched) and the `-1.3 s` delay modifier.

4. **The sole witness may be the enforcer.** `HearingManager.emit` skips the emitter
   (`HearingManager.gd:44`), so a lone town guard who witnesses a theft screams to nobody and the
   causal chain terminates. Pick the pocket of a solitary guard forever. Before scheduling the
   outcry, test whether the witness itself satisfies `LawDatabase.enforces(witness.faction_id,
   law_faction)`; if so, apply the consequence directly **at outcry-fire time** — same delay, same
   kill-window, no `HearingManager` round trip.

## The outcry — on the witness's AI node

New state on `ai.gd`, ticked by one line in `process_ai` beside the existing timers at `:200-206`.

```gdscript
var pending_outcry: Dictionary = {}   # {crime_id, perp, crime_pos, identified, law_faction, ...}
var _outcry_timer: float = -1.0
var _outcry_total: float = 0.0
var manhunt_target: ProceduralCharacter = null
signal outcry_state_changed(active: bool, frac: float)

func begin_outcry(payload: Dictionary) -> void
func _tick_outcry(delta: float) -> void
```

**The timer lives on the witness**, which is the whole design. There is no cancellation code,
because there is nothing centralised to cancel — kill the witness and the fire-time guard rejects,
`queue_free` them and the timer never ticks, knock them out and the condition check catches it. A
manager-side queue would need explicit revocation and could get it wrong.

**Guard the fire, not the tick site.** Per R5, nothing sets `AI_enabled = false` on death and the
`AIState.DEAD` arm at `ai.gd:258` is reached only *after* the timer block, so a corpse will scream
unless the check sits immediately before the emit:

```gdscript
func _tick_outcry(delta: float) -> void:
    if _outcry_timer <= 0.0:
        return
    _outcry_timer -= delta
    var frac: float = 1.0 - (_outcry_timer / max(_outcry_total, 0.001))
    outcry_state_changed.emit(true, clampf(frac, 0.0, 1.0))
    if _outcry_timer > 0.0:
        return
    _outcry_timer = -1.0
    if not _can_still_cry_out():          # dead / unconscious / silenced / panicked
        pending_outcry = {}
        outcry_state_changed.emit(false, 0.0)
        return
    CrimeManager.fire_outcry(character, pending_outcry)
    pending_outcry = {}
    outcry_state_changed.emit(false, 0.0)
```

**Delay: 2.2 s base**, modifiers additive, clamped `[0.8, 4.0]`, plus ±0.15 s per-witness jitter so
a crowd screams raggedly rather than in chorus. Guards and `courageous` witnesses: −1.1 (→1.1 s) —
they react fast, which is why you kill them last. The victim: −1.3 (→0.9 s). `frightened`/`panicked`:
+0.8. Beyond 512 px: +0.6 — *"did I just see that?"* Distance does not grant anonymity (D7); it
grants **doubt, measured in seconds**, which is what stops a far-off witness being an unblockable
auto-fail.

Justification for 2.2: `ALERTNESS_DECAY_GRACE` is 1.5 s (`ai.gd:44`), so the game already asserts
1.5 s is one beat of reaction — the outcry sits just past it. `SEARCH_LOOK_AROUND_DURATION` is 2.5 s
(`ai.gd:50`), so the outcry is deliberately shorter than the game's existing "giving this my full
attention" duration. And **`PauseManager.pause()` halts the whole tree** (`ProceduralCharacter.gd:3015`
gates the AI tick), so the fuse freezes: unlimited thinking time, 2.2 s of execution time. That
contract is why the number can be aggressive. Do not "fix" the fuse to keep ticking under pause.

Independent per-witness timers, **no pooling** — pooled timers mean the player can always find the
one throat to cut and the tension evaporates. Two witnesses on opposite sides of a plaza is a
genuinely losable position, and that is correct.

### Outcry SFX (this phase)

Two clips, wired through the existing `SfxManager.play(key, position, pitch_range, vol_db)`
pattern used by footsteps (`ProceduralCharacter.gd:3946`):

- **`witness_huh`** — a short startled "huh?" played at `begin_outcry`, the audible tell that a
  fuse just lit (pairs with the accelerating `!` indicator).
- **`witness_scream`** — played at the fire moment, alongside the `alarm` channel `emit`.

An ElevenLabs API key is available for generating both (sound-effects endpoint; a few takes per
clip, pick by ear — pitch variance at play time covers the rest). Free-license SFX are an
acceptable fallback. Generate once, commit the `.ogg` + `.import` under `sfx/`, and register the
keys wherever the existing footstep keys live. Do this *during* Phase 5, not after — the outcry
window is tuned by feel, and it cannot be felt silently.

## Silencing

Three verbs, spanning lethal to non-lethal so the system does not force a murder spree on a player
who wanted to be a thief: **kill**, **knock out** (`unconscious` already exists and is already
checked at `ai.gd:216` and `Game.gd:1281`), and a new **`silenced`** condition (`duration: 12.0`,
traits `["debuff", "social"]`, no stat modifiers — twelve lines of data). `cancel_on_conditions` is
a JSON array, so authoring a silencing spell later needs no code.

> **Update 2026-07-22:** a **Silence ability now exists in-tree** (`vfx/SilenceZone.gd` +
> `HearingManager.sound_gain_between`, applied inside `_loudness_at`). It is a *zone*, not a
> condition: it does not stop the witness screaming, it stops the scream *propagating*. Because
> the Phase 5 alarm channel routes through `_loudness_at`, the outcry integration is free —
> **provided the alarm emit is not given a bypass around `_loudness_at`**. Keep that invariant.
> The `silenced` condition above remains worth authoring as a second, single-target verb
> (`cancel_on_conditions` reads it), but the zone retires the known limitation that kill/KO were
> the only practical silencing verbs.

Killing a witness is itself an `attack` crime re-entering the pipeline, so silencing in view of a
second witness starts a fresh fuse on them. The cascade is the drama.

Not silencing: `blinded` (they already saw it), `frightened` (they scream *more* — hence +0.8, not a
cancel), fleeing, or distance.

## Propagation

`HearingManager.emit` gains two optional parameters. All 13 existing call sites default to
`"ambient"` and are behaviourally unchanged.

```gdscript
func emit(world_pos: Vector2, loudness: float, source = null,
          channel: String = "ambient", payload: Dictionary = {}) -> void
```

**Numbers, derived from shipped constants rather than invented:**

| | value | why |
|---|---|---|
| scream loudness | **1.35** | `1.35 × ALERTNESS_SOUND_GAIN(55) = 74.25` — above SEARCHING (60), below HOSTILE (90). A guard **comes and looks**; `_process_searching` (`ai.gd:1011`) then does exactly the right thing with zero new AI code. It also clears `LOUD_SOUND_THRESHOLD` (1.2), so screams and the 1.5 gunshot become the only two sounds that wake an at-ease town — which finally makes the carefully-written dead branch at `ai.gd:958-966` reachable. 1.6 would put a guard at 88, one point under HOSTILE: an accidental cliff. |
| `ALARM_RANGE_MULT` | **2.5**, on `max_dist` only, never on the gain | Sight is `1440 × sight` = 22.5 tiles (`ai.gd:296`); hearing is `240 × hearing × loudness` = 3.75 tiles at loudness 1. **Vision outranges hearing 6:1**, so an unmultiplied scream carries 5.06 tiles and essentially never reaches a guard on `town_square` — every design that omits this ships a system that is silently inert. Separating range from arousal is also the right factoring: they are the two knobs that need independent tuning. This is the number most likely to be wrong; it lives in `laws.json` beside the delays it must be tuned against. Do **not** raise `BASE_HEARING_RADIUS` instead — that silently retunes every footstep interaction in the game. |

Resulting reach at hearing 1.0 (`TILE_SIZE` 64):

| | clear | 1 wall | 2 walls |
|---|---|---|---|
| range | 810 px / **12.7 tiles** | 365 px / 5.7 tiles | 164 px / 2.6 tiles |
| alertness gain | 74.25 → **SEARCHING** | 33.4 → SUSPICIOUS | 15.0 → nothing |

So: outdoor crime in a plaza reaches everything within 12.7 tiles; **indoor crime is quiet crime**;
a guard two rooms away hears nothing. That contrast is the map-reading skill the system teaches.

**Multi-wall occlusion.** `_loudness_at` (`:82-98`) is binary — one `intersect_ray`, one ×0.45
regardless of wall count — so two rooms currently reads identically to one and the table above has
no third column. Rewrite as an exclude-list loop capped at `MAX_OCCLUDERS = 3`, mirroring
`GridManager.gd:199-208`. While in the file, **swap the raycast at `:47` with the distance test at
`:52`** so the cheap check runs first; that refund more than pays for the extra occluder rays (the
audit counts ~440 footstep rays/sec today).

**The faction gate at `:72` — two changes, not one.** Alarms are exempt, and ambient sound switches
to the standing-aware oracle. The second half fixes R3: without it, the player's footsteps remain
inaudible to every lawful NPC forever and the entire noise half of stealth is fiction.

```gdscript
var is_alarm: bool = channel == "alarm"
if not is_alarm and src_faction != "" and src_faction != "player" \
        and not FactionDatabase.are_hostile(listener.faction_id, src_faction):
    continue
```

The `src_faction != "player"` clause admits player-made sound unconditionally, so sneaking is
detectable *before* the player is hostile — which is the only ordering under which pre-crime stealth
exists. The gate's stated purpose (`:63-64`, "so enemies don't constantly alert each other from
their own footsteps") is preserved for NPC-to-NPC sound, which is all it was ever written for.

Route by channel at `:74`, and give `sound_emitted` (`:24`, zero subscribers) its first subscriber.

**`ai.on_sound_heard` (`:954`)** gains the two parameters. The alarm branch must sit **before** the
AT_EASE branch at `:958`, or a civilian hearing a murder scream is handled by `:962-966` and woken
only to `WAKE_FROM_AT_EASE_VALUE`.

`_share_alertness_with_allies` (`:983`) then does the rest for free: the LOS-gated half-the-gap
transfer at `:997-1006` pulls neighbours up on the existing 0.75 s cadence and tags their
`last_heard_position`. No "call for backup" code is needed.

## Identification and disguise

Binary, per D7. LOS to the actor means identified unless the actor is disguised. **No proximity
unmasking** — that reintroduces a distance gradient through the back door and makes the one cleanly
testable predicate in the pipeline geometric.

**Disguise is a data block on equipment, deliberately *not* `adds_condition_on_equip`.** Three items
author that field — `golden_crown_helm` → `"Inspired"` (`Items.json:1490`), `dark_hood` →
`"Shrouded"` (`:1553`), `shadow_cloak` → `"Invisible"` (`:1991`) — and **none of those three
conditions exists**. Condition ids in `ConditionDatabase` are lowercase, so the capitalised strings
would not match even if they did. Wiring that field into the equip path makes every helm equip
`push_warning` through `ConditionManager.gd:200`. Coupling a new system to a broken one to reuse a
dead key is a bad trade.

Instead:
```json
"dark_hood":    { "disguise": { "strength": 2, "conceals": ["face"] } },
"shadow_cloak": { "disguise": { "strength": 3, "conceals": ["face", "build"] } }
```
`CrimeManager._is_disguised(actor)` sums `disguise.strength` over equipped items read from
`equipment.get_meta("item_data")` — already stamped for every slot at `ProceduralCharacter.gd:4838`
inside `equip_equipment` (`:4795`), so the read needs no new plumbing — and requires
`strength >= 3` with the head slot filled. Pure read of equipment state: no lifecycle, nothing to
desync, nothing to serialize. Hood + cloak = 5: disguised.

**An unidentified crime still screams.** Guards hear, come, and search; `identified: false` means no
`manhunt_target`, no standing change, no ledger entry. The town roils and you walk out through it —
dramatically far better than "the disguise makes nothing happen", and it makes the disguise a tool
rather than an off-switch.

**Testable at end of phase.** `tests/crime_witness_test.gd`, real `ProceduralCharacter.tscn`
instances, `_make_blocker` from `elevation_harness.gd:457`: unwitnessed crime → no pending outcry
anywhere; witnessed → `pending_outcry` non-empty within one tick; killing the witness at
`delay/2` **and** at `delay - 0.001` → zero alarm emits on both; `silenced` at `delay - 0.2` → zero
emits; guard at 700 px clear line → alertness in `[70, 78]`, state SEARCHING; same guard behind one
blocker → `[30, 37]`, SUSPICIOUS; two blockers → below 25, no state change; **neutral witness +
neutral guard, both with `enemies: []` → the alarm is delivered** (the `:72` regression);
player footstep at loudness 0.9 heard by a `golden_guard` → alertness rises (R3); disguised actor →
alarm fires, `identified == false`; crime on a deck witnessed from ground level → seen (the
`target_elev` fix); ranged crime from behind cover → outcry starts with `identified: false`; lone
guard victim of a pickpocket → consequence applied with no `HearingManager` round trip; assault
victim with no third party → outcry pending on the victim.

---

# Phase 6 — Consequence, hostility, and legibility

## Standing, ledger, and the binary

On `FactionDatabase`, mirroring the tier API at `:49-66`:

```gdscript
signal player_standing_changed(faction_id: String, old_value: int, new_value: int)

var _player_standing: Dictionary = {}    # faction_id -> int
var _crime_ledger: Dictionary = {}       # faction_id -> {records: Array, days_served: float}
var _hostile_override: Dictionary = {}   # faction_id -> true

func get_player_standing(fid: String) -> int
func adjust_player_standing(fid: String, delta: int) -> void
func player_stance_toward(fid: String) -> String
func mark_outlaw(fid: String) -> void
func record_crime(fid: String, verdict: Dictionary, ctx: Dictionary) -> void
func fine_owed(fid: String) -> int
func jail_days_owed(fid: String) -> int
func settle(fid: String, mode: String) -> void
func to_dict() -> Dictionary
func from_dict(d: Dictionary) -> void
```

Note the signature: **`player_stance_toward(fid)`, one argument.** A two-argument
`standing_stance(a, b)` invites `_is_enemy` to pass NPC pairs on every frame and read the player's
own standing as an answer for `bandits`-vs-`wildlife`.

```gdscript
func player_stance_toward(fid: String) -> String:
    # D8: an identified crime makes the offended faction hostile, full stop.
    # The scalar tunes DEGREE; the override carries the binary.
    if _hostile_override.get(fid, false):
        return "hostile"
    var base: int = 0
    var rel: String = get_relationship(fid, "player")
    if rel == "ally":
        base = 40
    elif rel == "enemy":
        base = -60
    var v: int = base + get_player_standing(fid)
    var cfg: Dictionary = LawDatabase.standing_cfg()
    if v <= int(cfg.get("hostile_at", -50)):
        return "hostile"
    if v >= int(cfg.get("friendly_at", 50)):
        return "friendly"
    return "neutral"
```

**Why the override exists.** Per C2, `golden_guard.allies` contains `"player"`, so a pure threshold
scheme starts the town guard at +40 and a 90-severity murder lands at −50 — still not hostile under
its own threshold, and the *first* crime is free against every faction. `liziti` at base 0 minus a
25-severity theft is −25: also free. D8 mandates binary enforcement; the override delivers it while
leaving the scalar as the single tuning axis for how *much* worse things get. `mark_outlaw` is
cleared only by `settle` or a pardon.

**The ledger is behaviourally inert.** It answers exactly two questions — what a fine costs, and
what dialogue says — and appears on no AI, targeting, hearing, or hostility path. That invariant is
the D2 mitigation and it is asserted by a test.

**Applying exactly once.** `CrimeManager` holds `_crimes_applied: Dictionary` keyed by `crime_id`.
Ten guards hearing one scream apply one penalty. The hearer must also satisfy
`LawDatabase.enforces(hearer.faction_id, law_faction)` (C3), so a bandit overhearing you rob a
merchant does not report you to the Liziti.

## Enforcement is one line, and everything follows

`mark_outlaw(offended)` flips `player_stance_toward` to `"hostile"`, `are_hostile` follows, and every
existing system reacts with no further code: target acquisition (`ai.gd:408` → `:426` →
`_acquire_target` :440), hearing (`HearingManager.gd:72`), the Trade menu (`Game.gd:895`),
right-click-becomes-attack (`ProceduralCharacter.gd:3519`), and enemy-only ability targeting
(`AbilityTargeting.gd:507`). No arrest ladder, no new AI state.

## Knowledge outlives arousal

`manhunt_target` on `ai.gd`, set from an identified alarm, plus one clause in `_is_enemy`:
`if other == manhunt_target: return true`. Alertness decays at 4/sec from 74.25 and the guard stops
actively searching after ~11 s, but he does not *forget*. Without this the optimal play is to hide
behind a crate for twenty seconds and the entire law system is a mild inconvenience.
`manhunt_target` is cleared by `settle` and by a pardon, never by time.

## Fines, jail, and "done the time"

Per C4, fines are payable in **coin**, via `DowntimeEffectApplier._apply_money(character, -amount, 1)`
— static, working, gold-first, and already handling insufficient funds by draining what exists.

`fine_owed = Σ severity × fine_gold_per_severity(12.0)`. Theft (25) = 300 gold; assault (40) = 480;
murder (90) = 1080, which is more than the most expensive item in the game (`golden_crown_helm`,
1000) and therefore pushes murder toward jail by construction. Median item cost is 15 gold, so a
theft fine is roughly twenty ordinary items — meaningful, payable. Flag `fine_gold_per_severity` for
the first playtest.

Three settlement paths, all reusing existing functions:
1. **Return goods** — walk party inventories for `stolen_from == faction` and hand them back. Always
   offered first, always non-optional as a component: giving back what you stole is the fiction.
2. **Pay the fine** — `_apply_money`. Shortfall rolls into jail days.
3. **Serve time** — `TimeManager.advance_days(n)`, `n = ceili(severity_total × 0.06)`, which already
   emits `date_changed` to four subscribers, so jail is world time for free. Phase 2's fix is what
   makes a multi-day sentence expressible at all, and makes conditions correctly expire across it.

`settle` clears `_hostile_override`, floors standing at 0 (**square, not beloved**), stamps
`days_served`, and marks ledger records `settled: true` **without deleting them**. You are square
with the law and nobody has forgotten what you did — which is exactly the distinction a single
scalar risked losing, recovered by the inert ledger. Dialogue can then read three states: never
caught, wanted, and did their time.

## `wanted` becomes a derived marker

`wanted` already exists (`ConditionDatabase.gd:1296-1313`, `duration: -1.0`,
`canceled_by_trait: ["pardon"]`) and is already applied by live code
(`downtime.json:349` → `DowntimeResolver.gd:191` → `DowntimeEffectApplier.gd:59`), with zero
consumers and no removal path. Subscribe to `player_standing_changed` in `Game.gd` and
apply/remove it on the protagonist as a **pure display derivative** of `_hostile_override`. Its
description — *"Guards in this region are hostile on sight"* — becomes true for the first time. The
existing downtime application keeps working and gains one line
(`FactionDatabase.mark_outlaw(region_faction)`), so the shipped "caught stealing" outcome starts
doing something.

`canceled_by_trait` stays globally unimplemented — it is declared (`Condition.gd:59`), parsed
(`:93`), authored on ~65 conditions, and read by nothing. Implementing it for one pair is a much
larger job than deriving that pair.

## `thrill_of_sin`, correctly triggered

`_check_action_trait_stacking` (`:483-512`) is live code requiring a literal `criminal` trait in
`ability.traits`, and no ability has one. **Do not add it** — criminality is jurisdictional, and a
static trait would lie (`creepy_beam` is capital in Waldau and lawful in Perrow). Instead
`CrimeManager` walks the actor's conditions for any whose
`on_action_trait_stack.required_traits == ["criminal"]` and stacks via the same
`apply_condition(cond_id, null, 1, -1.0)` call `:512` makes. This fires for **all four action
classes** rather than casts only, and needs zero edits to `Abilities.json`.

**Grant the stack only when at least one live witness entered the outcry pipeline and no alarm
escaped.** The reward is for beating the fuse, not for the absence of a fuse — otherwise the player
stands alone in a room picking up and dropping the same object twenty times for a permanent max-stack
Luck buff. Additionally dedupe by `(item_uid, verb)`.

## Legibility

Absence-as-feedback is unteachable, so success is made explicit.

- **The accelerating amber `!`.** `ProceduralCharacter._setup_alertness_indicator` (`:1159`) and
  `_on_alertness_changed` (`:1186`) already own the `?`/`!` Label and a flash tween (`:1208-1217`).
  Add a branch driven by `outcry_state_changed`, taking priority over alertness glyphs, and
  parameterise the hardcoded `0.12` flash period into `_restart_flash(period)` lerping **0.30 → 0.08
  s** across the delay. It communicates time-remaining with no new art, no progress bar, and no new
  UI file, and it reads as a fuse because it is one. Amber distinguishes it from red-HOSTILE and
  yellow-SEARCHING. Re-issued at ~5 Hz, not per frame.
- **"Unseen."** — grey `Globals.show_floating_text` (`Globals.gd:33`) at the actor on an
  unwitnessed crime, plus a `GameLog` line. This is how the player learns the system exists at all.
- **"No one raised the alarm."** — `GameLog` when the last pending outcry for a `crime_id` resolves
  without an emit.
- **Owned items read differently.** `Game._world_item_options` (`:912`) returns
  `["Pick Up (owned)"]` when `owner_faction != ""`. One string; no new art.
- **Alertness-tinted sight cones.** `Game.gd:1016-1034` already renders per-NPC cones with real
  shadow occlusion under the existing **C** toggle. Drive colour/energy off `alertness_changed`
  (`ai.gd:68`): AT_EASE/UNAWARE dim blue-grey, SUSPICIOUS amber, SEARCHING/HOSTILE the current red.
  Cones then show *state*, not just geometry. Do **not** auto-show cones for outcry-phase witnesses
  — the amber `!` is the channel the player must be able to trust, and a second louder tell muddies
  it.

**Testable at end of phase.** Standing crosses `hostile_at` → `are_hostile("player", f)` true and
`ai._is_enemy` agrees; a single identified murder against `golden_guard` (base +40) makes it hostile
via the override; three guards in earshot of one scream → standing drops by exactly `severity`;
ten ledger records at standing 0 → still `"neutral"` (the inertness invariant); `manhunt_target`
survives full alertness decay to 0 and re-LOS fires `_acquire_target`; `settle("pay_fine")` clears
the override, floors standing at 0, and leaves records present with `settled: true`;
`thrill_of_sin` does not stack on an unwitnessed crime.

---

# Phase 7 — Persistence and surrender

## What must and must not persist

**Witness memory is deliberately NOT persisted.** `record_crime` is called by the enforcer's alert
handler, downstream of the entire hearing pipeline — never by the witness. So leaving the map
mid-window means the crime is unreported, permanently ("you got away with it"), and the whole D7
pipeline requires **zero serialization**. This is the largest scope saving in the plan and it is
also the correct fiction.

**Death must persist**, or the centerpiece is theatre. `_is_service_npc` (`Game.gd:187`) gates on
`titles.size() > 0` and no guard template has `titles`, so a murdered guard is `queue_free`d at
`:644` with state unrecorded and respawns pristine. Killing the witness is currently undone by
walking through a door.

```gdscript
func _should_persist_npc(c) -> bool:
    return _is_service_npc(c) or (is_instance_valid(c) and "current_health" in c and c.current_health <= 0)
```
`_serialize_character` already captures `current_health` (`:2754`) and `_deserialize_character`
already calls `restore_dead_state()` at ≤ 0 (`:2996-2997`), so fixing the **predicate alone** makes
murdered guards stay murdered.

Two adjacent defects in `_save_service_npc_states` (`:190-209`) fixed at the same time:
- the `region_id.is_empty()` early return at `:193-195` means wilderness maps persist nothing —
  fall back to a `"map:" + current_map_id` bucket key;
- `_build_npc_uid` (`:181-185`) returns bare `template_id` when `unique_name` is empty, so two
  `town_guard` spawns collide on one key and overwrite each other — append a spawn ordinal, stamped
  as meta in `_spawn_npcs` (`:261-289`). **Preserve the bare-`template_id` form for named service
  NPCs**, or `known_services_per_region` (`Game.gd:102`) and `RegionDatabase._build_npc_uid`
  (`:104-107`) stop matching and the town services panel loses every discovered service.

**Note what still resets: guard *alertness*.** That is deliberate. Fleeing across a warp calms the
immediate pursuit but does not clear your standing, your override, or the corpse. Fleeing has a
real, limited payoff.

## Corpse discovery (scheduled here per user direction, 2026-07-22)

With corpse persistence in hand, close the isolated-kill loophole: on `_on_character_died` for a
victim whose killing was a crime with **zero surviving witnesses**, stamp the corpse with
`corpse_of::<law_faction>` meta. Any enforcer (`policed_by` member) gaining LOS on a stamped corpse
calls `begin_outcry` on itself with `identified: false` — guards alarm, standing does not move,
no bounty attaches. Killing the witness stays a real tactic (it buys time and anonymity, and an
undiscovered corpse buys everything), but it is no longer *free* against a whole town. ~30 lines:
the stamp in `_on_character_died`, one check in the enforcer's LOS sweep, and a
`discovered` flag on the corpse record so a body alarms once, not per-frame. The kill-cascade
interaction (discovering corpse A while fleeing crime B) needs a playtest pass before tuning.

## Item state

`item_state_per_map: Dictionary` on `Game.gd` beside `npc_state_per_region` (`:102`) — same shape,
so a reader who understands one understands the other. Captured in `_unload_current_map` (`:631`,
beside `_save_service_npc_states()` at `:633`, before the character sweep at `:642`), restored after
`_spawn_items` in `load_map` (`:557`). Keyed `"%s@%d,%d#%d" % [item_id, pos.x, pos.y, index]`, with
an authored `spawn_id` winning when present.

**The ordering trap, which needs its own test.** `create_item` calls `add_child` at `:1063`, which
runs `_ready` → `_apply_item_data`, which auto-fills a faction chest's contents when
`num_slots > 0 and controlling_faction != ""` and contents are empty (`Item.gd:236-239`, verified).
Restore must therefore run **after** `create_item` returns and must **overwrite** `contents`, never
merge — otherwise every emptied chest silently refills from the loot table on revisit and theft
becomes pointless.

## The named caller

The three orphaned `to_dict`/`from_dict` pairs happened because nobody ever called them. The
structural fix is one function whose entire job is to be that caller:

```gdscript
# Game.gd
func build_save_dict() -> Dictionary:
    return {
        "version": 1,
        "party_state": party_state,
        "npc_state_per_region": npc_state_per_region,
        "item_state_per_map": item_state_per_map,
        "factions": FactionDatabase.to_dict(),        # standing, ledger, overrides, sentences
        "quests": QuestManager.get_save_data(),       # was orphaned :154
        "readables": ReadableManager.get_save_data(), # was orphaned :84
        "triggers": MapTriggerState.fired.duplicate(true),  # standing TODO at :9-10
        "world_state": Globals.world_state.duplicate(true), # in no serializer at all
        "unlocked_locks": unlocked_locks,
        "known_services": known_services_per_region,
        "days_elapsed": TimeManager.days_elapsed,
        "date": [TimeManager.current_day, TimeManager.current_month, TimeManager.current_year],
        "current_map_id": current_map_id,
    }

func apply_save_dict(d: Dictionary) -> void   # symmetric, every read via .get(key, default)
```

**No disk I/O in v1**, per D4. But `build_save_dict`/`apply_save_dict` get **two callers that ship
with them** — a headless round-trip test, and a debug hotkey (F11, beside the existing F9/F10
windows wired at `Game.gd:141-153`) that round-trips through an in-memory dict and logs a diff.
An interface with no caller is precisely how the three orphans happened. Disk save is then
`FileAccess` + `JSON.stringify` around a tested function.

Every store's `to_dict` emits `"version"`. v1→v2 rule: **additive only**, every read via
`.get(key, default)`, which is already the house idiom (`ConditionInstance.from_dict:76-82`).

## Surrender

New `UI/SurrenderPanel.gd` + `.tscn` — the only new runtime UI. A **Surrender** button appears
whenever a hostile is within 800 px, and is *always* visible in that condition (a greyed-out button
with a reason is information; a missing button is confusion). The counterparty is the faction with
the largest ledger among currently-hostile characters.

- **`lawful`** — panel shows the ledger ("Theft ×2, Assault ×1"), the return-goods manifest, the
  fine, and the jail alternative. Settle via §Phase 6.
- **`predatory`** — a confirm, then ~50% of inventory value by `cost`, combat ends, standing
  untouched. Fast, humiliating, survivable — and often the right play.
- **`implacable`** — refuse with the authored line, following `Door.gd:33-36`'s refusal protocol
  (floating text + GameLog + return). **This is the default**, so an unauthored faction fails
  conservatively rather than silently pacifying a boss.

On acceptance, clear combat with functions that already exist: `_lose_target()` (`ai.gd:453`) and
`_set_alertness_value(0.0)` (`:910`) per hostile, plus `manhunt_target = null`. No new AI state.

Player-initiated surrender is what makes binary enforcement survivable without an arrest ladder —
`_acquire_target` (`ai.gd:440`) makes acquisition synonymous with attack, so a non-lethal guard state
would be real surgery. It also puts the decision on the player's side of the fence.

**Testable at end of phase.** `tests/law_persist_test.gd`: emptied chest does not refill on
capture→clear→restore (the ordering trap); a taken authored item does not respawn; two `town_guard`
spawns, one killed → exactly one dead after restore (uid collision); a named service NPC's uid is
still the bare `template_id` form; a wilderness map persists NPC state; `build_save_dict` →
mutate standing/ledger/overrides/item owners → `apply_save_dict` → deep equality;
surrender to `lawful` clears the override and zeroes hostiles' targets; surrender to `implacable`
changes nothing.

---

# Future phase — AI fight-picking and morale (user direction, 2026-07-22; unscheduled)

Not part of v1; recorded here so Phases 5-6 keep the seams open.

- **AI weighs crimes by witnesses.** The more *non-allied* witnesses present, the less likely an
  AI is to commit a crime. Phase 5's fan-out already computes exactly this set — expose it as a
  pure query (e.g. `CrimeManager.count_potential_witnesses(actor, pos)`) so AI decision-making
  and the reporting pipeline share one witness definition. This is also why `report`'s witness
  enumeration should stay separable from its consequence half.
- **Morale: run from losing fights.** Flee when outnumbered or outmatched — including from the
  player. `_process_retreat` (`ai.gd:564`) is fully written and currently unreachable; it is the
  landing pad. Needs a cheap strength estimate (side headcount + HP fraction, tier as a proxy
  for equipment) — resist anything fancier until play demands it.
- **NPC surrender**, mirroring D8's player surrender.
- **`fanatical` trait** gates all of it: a fanatical AI attacks on sight, never flees, never
  surrenders — the current universal behaviour becomes the *exception*, authored per template or
  granted by conditions (a `frenzied` condition could confer it). Wildlife and undead are
  natural implicit fanatics via their templates.

## Test plan (harness conventions)

Harness scenes in `tests/`, following `elevation_harness.gd` and `door_lock_test.gd`: game-stub
properties on the root, `_check(name, cond, detail)` printing PASS/FAIL, `_ready()` running ordered
scenarios, then `get_tree().quit(1 if failures > 0 else 0)`. `ai.gd:132` does
`game = get_tree().current_scene`, so **the harness scene run as the CLI main scene IS `game`** —
no `Game.tscn` boot needed. Required stubs: `characters_in_scene`, `party_chars`, `items_in_scene`,
`stealth_mode`, `current_map_id`.

```
timeout 90 ~/Downloads/Godot_v4.6-stable_win64.exe/Godot_v4.6-stable_win64_console.exe \
  --headless --path <proj> tests/law_data_test.tscn 2>&1 | grep -E 'PASS|FAIL'
```

**Always cap the run with an external timeout** — a script error before `quit()` hangs forever.
Judge by PASS/FAIL lines only; startup stderr is permanently noisy.

Seven harnesses, one per phase: `hostility_harness`, `time_harness`, `law_data_test` (pure — no
scene tree, no stubs, the only one that needs neither), `crime_gate_test`, `crime_witness_test`,
`crime_consequence_test`, `law_persist_test`. Assertions are listed at the end of each phase above.

---

## Open calls, resolved

| Call | Decision | Why |
|---|---|---|
| Statute defaults | **Illegal by default.** `default_code: "common_law"` (theft, burglary, assault, murder) applies wherever a controlling faction exists; trait proscriptions are opt-in; nine factions get `"law_code": "none"`. | Opt-in ships a no-op: Perrow (16 maps, the start) is liziti with `laws: []`, and golden_guard's 7 laws control no region. The audit proves this failure is already live — `DowntimeDatabase.gd:78`'s gate has never fired once. Escape hatch for shipping inert while tuning: `default_code: "none"`. Wilderness is lawless for free. |
| Disguise shape | **A `disguise` data block on equipment items**, read from `get_meta("item_data")`. Binary, `strength >= 3` + head slot. No proximity unmasking. | `adds_condition_on_equip` names three conditions that do not exist, in the wrong case, and wiring it warns on every helm equip. The disguise block has no lifecycle to desync or serialize. Proximity unmasking contradicts D7 and makes the one clean predicate geometric. |
| Fine pricing | **Gold, via `DowntimeEffectApplier._apply_money`.** `severity × 12`. Return-goods first, jail for the shortfall. | The "no currency" premise is false (C4). Theft = 300 gold ≈ 20 median items; murder = 1080 > the most expensive item in the game, so murder pushes toward jail by construction. |
| NPC-vs-NPC | **Player-facing only**, gated on `actor.faction_id in applies_to` — **not** party membership. | The AI never casts, never opens containers, and has one crime-capable verb. Party-membership gating leaks summons (they are player-faction, non-party). Flipping it later is a JSON array edit. |
| Scream vs the `:72` gate | **A `channel` parameter. Alarms bypass the faction gate; ambient switches to `are_hostile` and admits `src_faction == "player"` unconditionally.** | The gate's own comment says its job is stopping allies alerting each other with footsteps — a scream is the inverse. The player clause fixes R3, without which no lawful NPC can hear the player at all and the noise half of stealth is fiction. |
| `are_enemies` asymmetry | **Fixed in the predicate** (`are_hostile` ORs both directions); `are_enemies` untouched; boot lint warns on every unmirrored pair. | Hand-mirroring 19 factions' JSON is error-prone and a future author will silently un-mirror it. The lint fixes the data over time without a behavioural cliff. |
| Enforcement authority | **Authored `policed_by`, never derived.** | C3: Perrow's lawgiver (liziti) declares its own town guards (golden_guard) as enemies. Relation-derived enforcement is inert across 16 of 24 maps. |
| Common `perform_action` funnel | **No.** A two-function `preview`/`report` contract each site hosts natively. | The four sites have irreconcilable signatures (`bool`, `void`, `bool`, drag-drop override), and the audit documents four abandoned permission systems that died of exactly that ambition. |
| Veto vs report | **Report, never block** — except a one-shot confirm above severity 50 on the cast path. | Three sites structurally cannot fail. But a silent unknowing capital crime is worse than a prompt, and the confirm nags once per map. |
| `criminal` ability trait | **Never added.** `CrimeManager` walks the actor's conditions directly. | Criminality is jurisdictional; a static trait would lie. Walking conditions covers all four action classes, not just casts, and needs zero `Abilities.json` edits. |
| `faction["laws"]` | **Untouched, and no unification scheduled.** | Banned professions and banned acts have different shapes and different consumers (UI visibility vs the cast hot path). The profession gate has never fired; merging a dead system into a live one imports its bugs for no gain. |

---

## Known limitations / deliberately not doing

**Accepted, with reasons:**

- **Trespass** (D5, explicit). Needs sub-map zones. Ownership is a property of the *object* and
  `report`'s `law_faction` slot takes a plain String, so trespass later is a `zone_owner_at(pos)`
  lookup feeding the same slot plus one verb. The per-map `controlling_faction` override is the same
  idea at coarser granularity and is the stepping stone.
- ~~Corpse discovery is a v1.1 stub.~~ **Now scheduled in Phase 7** (user direction, 2026-07-22) —
  see §Phase 7, "Corpse discovery". It rides after corpse persistence lands, in the same phase.
- **`OUTCRY_DELAY_BASE = 2.2` and `ALARM_RANGE_MULT = 2.5` are unvalidated.** They are the entire
  feel of the system and cannot be tuned headlessly — the harness can only assert the boolean
  (killed inside the window → no alarm), never the feel. Both live in `laws.json` and should move
  before anything else.
- **The `hostile_by_default` pass is a content decision, not a cleanup.** Phase 1 changes global NPC
  behaviour and requires a manual pass on `town_square` and `dock_tavern`. It cannot be deferred —
  every crime-driven hostility rule terminates in `_is_enemy`.
- **Illegal-by-default will make the starting town punitive on the commit that lands it.** Severity
  tuning (25/40/90 against a hostility override that fires on the first identified crime) is a guess.
  Expect an initial playtest where Perrow turns hostile within minutes.
- **Guard alertness resets on map transition** while standing, overrides, and corpses do not. A
  player can commit a crime, cross a warp, and return to a calm-but-hostile town. Argued as a
  feature (fleeing has a limited payoff); if it reads badly in play, persisting per-map alertness is
  a real addition, not a tweak.
- **The disguise is unbreakable while worn.** A player who finds `dark_hood` early trivialises
  identification until something else costs them. There is intentionally no counterplay in v1; D7
  makes identification binary and an integrity meter is its own system.
- **Item spawn keys encode position.** Nudging an item's coordinates in `Maps.json` orphans its
  saved record and it respawns pristine. Acceptable at 7 authored items outside the generator demos;
  an explicit optional `spawn_id` is the escape hatch and is documented in the schema.
- **`items_owned_by` is O(items) with a nested contents scan.** Fine at debug/test frequency and for
  confiscation; it must never be called per-frame. A live "stolen goods" HUD indicator would need a
  different shape.
- ~~No non-lethal silencing ability ships.~~ **Retired** — the user is building a Silence ability
  concurrently (2026-07-22). Wire its condition id into `cancel_on_conditions` when it lands
  (§Phase 5, "Silencing") and the outcry integration is free.

**Explicitly out of scope:** disk save UI; arrest ladder and non-lethal guard AI states; lockpicking;
NPC schedules and patrols; faction-vs-faction standing; per-NPC grudges (the `owner_uid` seam
exists); general `canceled_by_trait` implementation; the `livery` misattribution mechanic (wear a
faction's tabard, witnesses blame them) — genuinely good, and a whole second identity system;
fog of war and lighting; the `sensory` blocks in `TopDownCharacters.json`; unifying
`faction["laws"]`; `restricted_actions_by_trait` deletion and the `GridManager.gd:199` occluder cap
(worth doing, unrelated, should not ride in a commit whose blast radius already includes the
hostility oracle, the condition clock, and item persistence).

---

## Files involved

**New (5 runtime + 7 test pairs):** `Global/LawDatabase.gd`, `Global/CrimeManager.gd`,
`data/laws.json`, `UI/SurrenderPanel.gd`, `UI/SurrenderPanel.tscn`; `tests/hostility_harness`,
`tests/time_harness`, `tests/law_data_test`, `tests/crime_gate_test`, `tests/crime_witness_test`,
`tests/crime_consequence_test`, `tests/law_persist_test` (`.gd` + `.tscn` each).

**Modified:** `Game.gd` (`:53` delete, `:102`, `:181-190`, `:557`, `:631`, `:832-851`, `:912`,
`:924`, `:1016-1034`, `:1042-1063`, `:1247-1271`, `:1277-1291`, `:1461`, `:1760`, `:2795-2804`,
`:2977-2983`, + new reporters/save) · `Characters/ai.gd` (`:199-208`, `:258`, `:304`, `:429`,
`:798`, `:815`, `:954-966`, + outcry) · `Characters/ProceduralCharacter.gd` (`:1159`, `:1186`,
`:1208-1210`, `:3940`, `:4893` delete, `:5762`) · `Characters/inventory.gd` (`:60-83`,
`stow_weapon_from_data`) · `Global/HearingManager.gd` (`:27`, `:47/:52` swap, `:51`, `:72`, `:74`,
`:82-98`) · `Global/FactionDatabase.gd` (`:36`, `:76`, + standing/ledger/override API) ·
`Global/RegionDatabase.gd` (unchanged — `is_service_legal` explicitly untouched) ·
`Global/TimeManager.gd` (`:79-98`, + `absolute_time`/`today`) · `Conditions/ConditionManager.gd`
(`:58`, `:219`, `:482-489`) · `Conditions/ConditionDatabase.gd` (+ `silenced`) ·
`Abilities/AbilityManager.gd` (`:84`) · `Abilities/AbilityEffect.gd` (`:137-143`, `summoned_by`) ·
`Items/Item.gd` (`:59`, `:303`) · `Weapons/WeaponShape` (`to_data`/`from_data`) ·
`UI/ChestInventoryWindow.gd` (`:200` only) · `UI/PartySidePanel.gd` (`:595`, `:1010`, `:1029`,
`:1488`) · `scripts/DowntimeEffectApplier.gd` (`:166-179`) · `data/factions.json`
(`hostile_by_default`, `law_code`, `policed_by` — `laws` untouched) · `data/Items.json`
(`disguise` blocks on `dark_hood`, `shadow_cloak`) · `data/Maps.json` (`owner_faction`,
`default_item_owner`, `settlement`, `controlling_faction` override) · `project.godot` (2 autoloads
added, `:49` VisibilityManager deleted).
