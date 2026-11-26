# State of Implementation: Law, Crime, Stealth, and AI

> **OUT OF DATE (flagged 2026-11-13).** This is the *pre-implementation*
> snapshot from July 2026, written before Phases 1-7 of
> `docs/law_crime_stealth_plan.md` were built. Most of its "does not exist"
> findings are no longer true: there is a hostility oracle
> (`FactionDatabase.are_hostile`), laws/jurisdiction (`LawDatabase`), a
> witness/outcry pipeline (`CrimeManager`), ownership, standing, manhunts and
> surrender. The AI now uses abilities (ai.gd) and doors make sound
> (Door.gd). Read the plan's "As built" sections for the current design; treat
> everything below as history until this audit is redone.

## Known issues (re-audit 2026-11-13, updated 2026-11-26)

Fixed 2026-11-26 (branch `claude/map-bugs-ai-issues-75a82e`; regression
test `tests/guard_kill_check.tscn`):

- **Guards ignored a guard killed beside them.** Crime witnesses had no
  close-quarters exception to the view cone, and killing a golden_guard is
  legal in Perrow (liziti law doesn't protect its enemies), so nothing else
  reacted. Now the bystander REACTION path (`witnesses_of(..., close_quarters)`
  from `Game._on_character_damaged`) notices a blow within 2 tiles + body
  whichever way the witness faces (not a sneaking killer); a comrade seen
  fighting a grudge target takes the grudge up (`_share_alertness_with_allies`);
  and a guard who finds a comrade's body within 20 s with the killer within 3
  tiles of it attacks (`ai._check_slain_comrades`, the corpse's `slain_by`
  meta). By the user's decision a guard kill stays a LOCAL grudge: no crime,
  no record, liziti untouched. Crime identification keeps the strict cone.
- **Your own summons (and the culprit's enemies) reported you.**
  `CrimeManager.would_cry_out` now filters the fan-out, the victim fallback and
  the hue-and-cry relay: the law's enforcers always cry out; the culprit's own
  side (player faction, party summons, someone they've charmed) and anyone
  hostile to the culprit never do.
- **`wanted` was one global icon on the protagonist.** It is now a saved
  registry per region and per culprit (`FactionDatabase._wanted`, keyed
  `party:<party_index>`), written by an identified report or the downtime
  "caught" outcome (which now also records the theft). The icon shows only on
  that character, only in that region (`CrimeManager.refresh_wanted`), and the
  law's enforcers there attack that character on sight after warps and reloads
  (`CrimeManager.wanted_here`, read in `ai._is_enemy`). The description is now
  true; the inert `pardon` trait is gone.
- **Surrender settled with the wrong faction.** `_pick_counterparty` maps a
  hostile enforcer to the law faction the party owes (golden_guard answers for
  liziti in Perrow), preferring a debt, then a faction that accepts surrender,
  then the larger fine, then the nearest. Settling or a pardon clears the
  wanted entries and the watch's grudges against the party, and returns goods
  stolen from anyone the law protects (not only the law faction itself).

Still open:

- **Killing guards is legal in Perrow** (`LawDatabase._protected_by` derives
  protection from hostility; liziti and golden_guard are enemies). Kept by
  design: guards answer it with local grudges only.
- **The global outlaw mark remains.** An identified crime still marks the law
  faction hostile everywhere (D8's binary), alongside the per-region wanted
  registry; in Perrow that is liziti, who field nobody on the hillside maps.
- **Surrender ends a guard grudge for free.** With no debt on the books,
  surrendering to golden_guard settles an empty account but clears their
  grudges (a guard kill carries no record by design).
- **Confirmation prompts never reset.** `_confirmed_*_maps` in CrimeManager are
  never cleared ("for the rest of the map visit" is not what happens), and the
  attack confirmation can never warn about murder (the preview always sees a
  living victim).
- **Dead pieces:** `guard_alarm_alert` (laws.json) is never read; `silenced` is
  never applied by a shipped ability; `crime_committed` / `crime_reported` have
  only test subscribers; `AIState.RETREAT` / `PATROL` are never entered.
- **Plan inconsistency:** the plan's C3 callout says Perrow is policed by liziti
  only; the data and the Phase 3 section have `["liziti", "golden_guard"]`.

---


## Bottom line

There is **no law system, no crime concept, no ownership model, no reputation axis, no witness system, and no stealth mechanic** in this codebase. What exists is (a) a genuine, well-tuned *detection* pipeline â€” noise â†’ hearing â†’ a 0-100 alertness meter with LOS confirmation â€” that a crime system could be built on almost unchanged; (b) exactly one legality function, `RegionDatabase.is_service_legal()`, which checks whether an NPC's *profession title* is banned by the region's controlling faction, and which gates only shop-card visibility; and (c) a large amount of authored-but-dead crime vocabulary (`wanted`, `pardon`, `criminal`, `legal_title`, `thrill_of_sin`, `Stealth`, `Lockpicking`, `walking_noise`).

Two facts dominate everything else. **`Game.factions` (Game.gd:53) is declared and never assigned**, so the AI's sole hostility predicate `ai.gd:_is_enemy()` collapses to "different non-neutral factions are mutually hostile on sight" â€” factions.json's `allies`/`enemies` never touch combat. And **the hearing faction gate (HearingManager.gd:72) discards every sound a player-faction character makes**, because no faction lists `player` in its `enemies`. Both were confirmed by running a headless probe, not inferred.

There is also **no save/load system at all**, and only two classes of character survive a map transition (party members, and NPCs with a non-empty `titles` array). Guards and bystanders are freed with their state unrecorded.

---

## 1. AI

**One implementation, one file.** `Characters/ai.gd` (1051 lines), `extends Node`, attached as a child named `AI` on every `ProceduralCharacter.tscn`. Ticked from `ProceduralCharacter.gd:3042-3043` (`$AI.process_ai(delta)`), gated on `AI_enabled` and inside a `not PauseManager.is_paused` block at `:3015`. Real-time, per-frame, unthrottled. No turns, no scheduler, no behavior tree.

`process_ai()` (ai.gd:199) pipeline: timers â†’ `_update_alertness` (:208) â†’ `_check_stealth_wake` if AT_EASE (:211) â†’ early-outs for unconscious/stunned/panicked/frightened (:215-231) â†’ `_check_path_progress` (:236) â†’ `_update_target` (:239) â†’ apathetic suppression (:243) â†’ promote to SEARCHING if alertness â‰¥ 60 (:252) â†’ `match current_state` (:257) â†’ goal/wander only when IDLE and targetless (:274).

**Two orthogonal axes.** `enum AIState` (:8): DEAD, IDLE, PATROL, CHASE, APPROACH, ATTACK, RETREAT, STUNNED, SEARCHING. Only DEAD/IDLE/CHASE/APPROACH/ATTACK/SEARCHING are ever entered. `PATROL` is read once (:253) and never assigned â€” no patrol behavior, no patrol data anywhere. `_process_retreat` (:564) is fully written and never reached. The STUNNED branch (:220) reads the legacy `character.conditions` dict, not ConditionManager, and is doubly inert.

`enum Alertness` (:31): AT_EASE / UNAWARE / SUSPICIOUS / SEARCHING / HOSTILE, backed by a float 0-100 with thresholds 25/60/90 (:34-36), decay 4/sec after a 1.5 s grace (:897), sound gain `loudness * 55` capped at 85 (:38) so **audio can never confirm HOSTILE by design** â€” only `_acquire_target` (:440) does, and it slams the meter to 100 (:446). LOS-gated ally sharing every 0.75 s, half the gap, same-faction only (:983).

**Alertness does not gate combat.** `_update_target()` runs unconditionally at `:239`. An AT_EASE civilian of a non-neutral faction will acquire and attack the moment it has LOS. Alertness only drives SEARCHING behavior and the `?`/`!` head indicator (`ProceduralCharacter.gd:1186`).

**The hostility predicate is broken.** `ai.gd:429 _is_enemy()`:

```gdscript
if factions:                                   # :434 â€” always false
    ...enemies lookup...                       # :435 â€” dead
return character.faction_id != "neutral" and other.faction_id != "neutral"   # :438
```

`Game.gd:53 var factions: Dictionary` is never assigned (Game.gd:892 even comments "Game.factions is unused in current code paths"). Verified at runtime: `FactionDatabase.are_enemies("golden_guard","player") == false` while `ai._is_enemy()` returns true for the same pair. **Two contradictory hostility oracles coexist** â€” sight/targeting uses `ai.gd:429`, while `FactionDatabase.are_enemies` drives hearing (HearingManager.gd:72), ability targeting (AbilityTargeting.gd:507), the Trade menu (Game.gd:895), and the right-click attack-vs-menu split (ProceduralCharacter.gd:3519).

**Retaliation does not exist.** Stabbing a "neutral" NPC fires `damaged_by` (ProceduralCharacter.gd:5048) â†’ `ai._on_self_damaged` (:183) wakes it to 65 and points `last_heard_position` at the strike. It walks over, rotate-scans 2.5 s, and stands down â€” because `_is_enemy` still returns false. Nothing ever becomes hostile from being attacked. Death raises no alarm: `Game._on_character_died` (:1760) only sets `AIState.DEAD`, and does **not** remove the corpse from `characters_in_scene`.

**The AI never uses abilities.** `_process_attack` (:543) calls only `character.attack("Main", null, current_target)` (:553). Zero references to AbilityManager anywhere in ai.gd. No doors, no items, no fleeing, no calling for help.

**Non-combat stimuli â€” the complete list (four):** self-damage (`ai.gd:183`), witnessed attack (`Game.gd:1247`), stealth-mode sighting (`ai.gd:167`), sound (`ai.gd:954`). All four converge on `wake_from_at_ease(target_value, location)` (`ai.gd:937`) â€” the existing generic "something happened at X, raise me to at least N" entry point.

**Readiness:** the state machine, the meter, the stimulus entry point, and the alert-sharing are all reusable as-is. The hostility predicate must be fixed before anything crime-driven can land, and there is no non-lethal response state (`_acquire_target` makes acquisition synonymous with kill).

---

## 2. Vision and LOS

One primitive: `GridManager.sight_line_clear(space, from, to, viewer_elev, target_elev)` (Global/GridManager.gd:185). A Godot 2D physics raycast on `CollisionLayers.VISION_RAY_MASK` (== `VISION_BLOCKERS`, bit 4), continuous world-space â€” **not** grid raycast, not shadowcasting, not Area2D. Loops `for i in range(8)` (:199), reading each hit's `occlude_top` meta (absolute stories) and skipping it when `maxf(viewer_elev, target_elev) + 0.5 >= occlude_top` (:206). Missing meta â‡’ `top = 1e9` â‡’ always blocks. `occlude_top` is stamped at `MapLoader.gd:357` (value computed :277-282: deck = walk_elev, wall/door = base+1, tree/disc = base+2).

Cost per call: **1 raycast in the common case, up to 8**, plus one `PhysicsRayQueryParameters2D` allocation (:186) and a full `params.exclude` array rebuild per passed occluder (:208). The `range(8)` cap is a **silent correctness bug** â€” a 9th stacked pass-through occluder makes a genuinely clear line read as blocked.

Two near-duplicate wrappers that **disagree**:
- NPC side: `ai.gd:304 is_in_line_of_sight(target_position, target_elev)` â€” range `1440.0 * character.sight` (:295), FOV half-angle from `character.effective_fov()` (:313), then `_has_clear_sight_line` (:320). **No blinded/unconscious check.**
- Party side: `Game.gd:1277 _has_visual_los(from_char, target_pos)` â€” checks `blinded`/`unconscious` (:1281), uses **raw** `fov_angle_degrees`, and **passes no `target_elev`** (defaults 0), so a crime committed on a roof reads as unseen from the street.

Bulk queries already exist: `ai.gd:340 get_characters_in_line_of_sight()`, `ai.gd:330 get_items_in_line_of_sight()`, `Game.gd:1400 _is_position_visible_to_party()`.

**No per-tile visibility cache, no lighting model, no darkness, no distance falloff, no partial visibility.** Every check returns bool. Grep for `light_level|darkness|is_night|ambient_light|CanvasModulate` across `.gd` returns nothing.

**Fog of war is dead.** `fog_of_war.gd` (repo root) is referenced by zero `.tscn` and depends on autoload `VisibilityManager`, registered at `project.godot:49` as `res://Global/VisibilityManager.gd` â€” **a file that does not exist**. Git recovery: added in `a7f0d07a` ("Lighting", 2025-12-06 13:14), deleted 3 h later in `5b03177f`; the autoload line was never removed. Every headless run logs `Failed to instantiate an autoload`. The recovered file was an abandoned stub (`_process` body was `pass`; a per-tile GPU texture readback with `await get_tree().process_frame` per sample). **Delete the autoload line; do not resurrect.** `vfx/shaders/fog_of_war.gdshader` is the only graded-visibility machinery in the project and is loaded only by the dead script.

What actually ships is per-frame node hiding: `Game._update_npc_los_visibility()` (:1339) sets `npc.visible`, plus a hearing-driven alpha pulse / `radar_ping.tscn` for never-seen NPCs (`trigger_hearing_pulse` :1208). Player-rendering only; never feeds AI.

**`effective_sight()` (ProceduralCharacter.gd:426) has zero callers.** Every range check reads raw `character.sight`. `sight_modifier` is recomputed each frame from conditions (:1376) and consumed by nothing â€” so the `blinded` condition's `{stat: sight, operation: set, value: 0}` (ConditionDatabase.gd:528) is ignored by all range math, and `perceptive`'s +2 sight (:1136) does nothing. Blindness works only via the three explicit `has_condition` checks on the party side.

---

## 3. Hearing and noise

`Global/HearingManager.gd` (106 lines, autoload at `project.godot:60`) is the only push-based stimulus bus in the game and the best structural template for a crime broadcaster.

`emit(world_pos, loudness, source)` (:27) â†’ fires `sound_emitted` (:24, **zero subscribers**) â†’ iterates `game.characters_in_scene` â†’ per listener: `_loudness_at` raycast (:82, `VISION_RAY_MASK`, any hit â‡’ `Ã— 0.45`, binary, **no elevation term**) â†’ `max_dist = 240 * listener.effective_hearing() * eff_loudness` (:51) â†’ party listeners take a cosmetic-only branch (:58) â†’ faction gate (:72) â†’ `ai.on_sound_heard` (:74).

Note the raycast runs **before** the cheap distance test (:47 vs :52), so every footstep costs N raycasts. At N=14 (see Â§7) this is ~440 rays/sec â€” a cleanliness bug, not a perf problem.

**The faction gate is the critical defect.** `HearingManager.gd:72`:
```gdscript
if src_faction != "" and not FactionDatabase.are_enemies(listener.faction_id, src_faction): continue
```
All 13 emit sites pass a live `ProceduralCharacter`, so `src_faction` is never `""`. `golden_guard.enemies == ["bandits"]`; `player` appears in no faction's enemies list. **Runtime-verified:** a loudness-1.0 sound at zero distance from a player-faction source leaves a guard's alertness at 0.0; the same guard reacts normally to a bandit source. All three `default_alertness: "at_ease"` factions (`neutral` :10, `waldau` :582, `alamoneans` :659) have `"enemies": []`, so the carefully written AT_EASE loud-sound branch (`ai.gd:958-966`, threshold 1.2, gunshot = 1.5) is dead code in practice.

**Emitters:** footsteps every 32 px (`ProceduralCharacter._emit_footstep` :3907), melee swings 0.5 on both hands (:4558/:4578, fires on swing so misses count), impacts 0.7-0.9 (Game.gd:1540/1543/1962/1966/2061), arrow 0.4 / gunshot 1.5 (Game.gd:2275/2291), spell cast flat 0.6 (:5746). **Doors emit nothing** â€” `Structures/Door.gd` `open_door`/`close_door` (:45/:51) contain no HearingManager reference. Neither does lockpicking, pickup, or container opening.

Footstep loudness = `floor.base_sound_level Ã— footwear_mult + Î£ equipment.noise_per_step` (:3940). `data/floors.json` `base_sound_level` (0.25 grass â†’ 0.9 stone) is the **only working data-driven noise input**. Barefoot = 0.5Ã—. No item in Items.json authors `noise_per_step`, so all values come from the name/type heuristic (`Item.gd:312`, mirrored `equipment_shape.gd:46`).

`_source` reaches `on_sound_heard` (:954) and is **discarded** â€” sound carries no perpetrator identity, apparently by design (comment at :951).

---

## 4. Factions, reputation, legality

`Global/FactionDatabase.gd` loads `data/factions.json` (19 factions) into `_factions` keyed by `id`. Relations are **one-directional by accident**: `are_enemies(a,b)` (:76) reads only `a`'s list, and the JSON is inconsistently mirrored.

**There is no reputation.** `grep -rni 'reputation|standing|disposition|attitude|infamy|bounty|notoriety'` across all `.gd` returns 18 hits, every one the *physical* sense of "standing" (standing in fluid, standing on a roof). Zero hits for the social sense.

The only per-faction number is `tier` â€” a power/equipment-quality rank. `set_faction_tier` (:52) and `adjust_faction_tier` (:62) have **zero callers**, so `faction_tier_changed` never fires, `QuestManager._on_faction_tier_changed` (:233) never runs, and the `faction_tier::liziti/dragatini/tortellini` conditions in `data/Quests.json:116-128` can never become true. `tier` *is* live as an item-quality cap (`TopDownCharacterDatabase._roll_faction_loadout` :399).

**`Characters/Faction.gd`** is a complete parallel `class_name Faction` Resource relation API (`get_relationship_with` :17, `are_enemies` :52, `load_from_data` :69). Nothing instantiates it. `ProceduralCharacter.get_relationship_with` (:4893) indexes `game.factions[...]` and would crash; zero callers.

### The one legality function that exists

`Global/RegionDatabase.gd:116 is_service_legal(titles: Array, region_id: String) -> bool` â€” resolves region â†’ `controlling_faction` â†’ `faction["laws"]`, and returns false if any of the character's titles (normalized by the static `title_to_id` :113: lowercase, spaces//- â†’ `_`) appears in that array.

**`laws` is a list of banned professions, not banned actions.** Values: `whoremonger, venefica, veneficus, hierophant, pit_monitor, slavecatcher, hedge_witch`. Populated only on `golden_guard` (:124) and `patriciate` (:210); `liziti` is `[]` (:171); the other 16 factions omit the key.

Consumers (both cosmetic/economic, neither behavioral): `UI/TownServicesPanel.gd:194` (hide illegal service cards) and `Global/DowntimeDatabase.gd:78` (hide downtime activities whose `legal_title` is banned).

Introduced in commit `797fb1bc` (2026-05-09). It is **live and load-bearing for the shop UI**, but it never evaluates a player action.

**Jurisdiction already works at map granularity.** `RegionDatabase.get_region_for_map(map_id)` (:46) with an O(1) `_map_to_region` cache built at :27-28, falling back to the map's own `region` field. This is *not* greenfield.

Data problems worth knowing before extending: 20 of 30 `member_maps` entries in `regions.json` reference maps absent from Maps.json; `golden_guard` controls no region so its 7-entry laws array is unreachable; `pit_monitor` and `veneficus` match no character's `titles`; `downtime.json`'s `legal_title` values `"thief"` and `"prostitute"` appear in **no** faction's laws, so that gate has never fired; **Perrow â€” the starting region with 16 member maps â€” is controlled by `liziti`, whose laws array is empty**, so legality is a no-op across most shipped content.

---

## 5. Ownership, containers, and taking

**Nothing in this codebase carries an owner.** `Items/Item.gd` declares no `owner` property. `data/Items.json` has zero `"owner"` keys; so does `data/Maps.json`.

`ai.gd:798 is_item_owned_by_ally(item)` reads `item.owner` â€” that resolves to Godot's built-in `Node.owner`, which is `null` for runtime-instanced items. **Runtime-verified null.** The function returns `false` unconditionally at :800; its faction branch (:803) also reads the empty `game.factions`.

Taking is uniform and unconditional:
- `Game._world_item_options(item)` (:912) returns `["Pick Up"]` for anything not readable/container, **discarding** the JSON-authored `interact_options` (those become the *inventory* menu, `PartySidePanel.gd:745`).
- `Game.pick_up_item(item)` (:924) â€” returns bool, only failure branch is a full inventory.
- Left-click fast path is identical (`ProceduralCharacter.gd:3400-3404`).
- **AI bypasses all of this**: `ai.pickup_item(item)` (:815) never calls `Game.pick_up_item`.

Chests are Items with `num_slots > 0` and a `contents` Array. `Game.show_chest_inventory` (:963) has **no lock, key, faction, or hostility check** â€” both callers (`context_menu.gd:65`, `ProceduralCharacter.gd:3394`) go straight through. Taking mutates `chest_item.contents` in place (`ChestInventoryWindow.gd:200`, `:307`).

The only lock in the game is on doors: `Door.locked` / `key_id` / `consume_key` (:18-21), gated at `interact()` (:26) via the static `Door.try_party_unlock(party, key_item_id, consume)` (:119), which scans living party inventories and returns `{ok, key_name, holder_name}`. `Door.gd:115-118` explicitly documents the container gate as future work: *"Locked CONTAINERS later call this same static... Item.gd already parses the dormant per-item `key` field."* That `key` field is present on 47 Items.json entries and is **always null**.

Shops are barter-only. No currency deduction, no prices â€” `TradeWindow._recompute_balance` (:225) enables Accept when the NPC's net `cost` delta â‰¥ 0; `TownServicesPanel.can_accept_value_loss` (:722) enforces the same per-drop. The identical goods can be taken free off the ground.

**Item state does not persist.** There is no per-map world-item bucket; chest contents reset on map reload. `Item.controlling_faction` (:59) is set at spawn from Maps.json `extras` (Game.gd:1058), read once for chest-loot flavor (:236-239), then never consulted again â€” it is the closest thing to an ownership marker that exists, and it is also **lost the moment the item is taken**, because `Item.to_inventory_data()` (:303) re-reads the canonical Items.json entry and copies only `num_stacks`.

---

## 6. Every "actor does a thing to the world" entry point

This is the inventory a legality resolver has to cover. **There is no single funnel.** Only abilities have a real pre-execution veto.

| # | Action | Entry point | Actor available? | Returns / can refuse? |
|---|---|---|---|---|
| 1 | Cast ability | `Abilities/AbilityManager.gd:58 use_ability(ability, target_data)` | implicit (`character`, resolved `_ready` :40) | `bool`; vetoes at `_check_ability_usable` :349 (**ability only, no target**) and `_would_hit_infatuation_source` :393 called at :78 (**position-aware â€” the template to copy**) |
| 2 | Melee/ranged attack | `Characters/ProceduralCharacter.gd:4526 attack(Ability, aim_point, aim_node)` | `self` | **`void`** â€” bypasses AbilityManager entirely; own inline gates :4531 (apathetic/stunned), :4534 (infatuated) |
| 3 | Damage application | `Game.gd:2121 can_hit_target(attacker, target)` â† `weapon_shape.gd:292` | yes | `bool`, but fires per-overlap *after* the swing; elevation + double-hit only |
| 4 | Queued/planned action | `Characters/action_queue.gd:327 _execute_action(action)` | member `character` | **no validation, cannot fail**. Queue side `queue_action` :167 returns bool and already refuses on full |
| 5 | Player world pickup | `Game.gd:924 pick_up_item(item)` | resolved at :951 from primary selection | `bool` |
| 6 | **AI pickup** | `Characters/ai.gd:815 pickup_item(item)` | `character` | **separate path â€” a player-only gate misses this** |
| 7 | Open container | `Game.gd:963 show_chest_inventory(item)` | implicit | zero gates |
| 8 | Take from container | `UI/ChestInventoryWindow.gd:200 _transfer_slot_to_selected`, `:307 _drop_data` | resolved :232 | zero gates |
| 9 | Open/close door | `Structures/Door.gd:26 interact(option)` â†’ `:119 try_party_unlock` | **no actor param** | refuses on lock at :33-36 (**the model refusal**: floating text + GameLog + return) |
| 10 | World item verb | `Items/Item.gd:277 interact(option)` (Read/Take/Pick Up) | **no actor param** | `void` |
| 11 | Character verb | `UI/context_menu.gd:40 _on_option_selected(option)` | `target_character` only | **Attack/Talk/Trade/Open live; `_:` arm at :66-68 is guarded by `has_method("interact")` and ProceduralCharacter has none** â€” see below |
| 12 | Inventory verb | `UI/PartySidePanel.gd:811 _on_item_menu_selected(id, character, entry, options)` | **explicit** | Use/Consume/Throw/Drop/Equip/Unequip |
| 13 | Drop to world | `UI/PartySidePanel.gd:1010 _drop_item`, `:1029 _drop_item_amount` | explicit | â€” |
| 14 | Trade / purchase | `UI/TradeWindow.gd:445 _on_accept_pressed`; `UI/TownServicesPanel.gd:654 _drop_data` / `:722 can_accept_value_loss` | yes | value-balance only |
| 15 | Downtime activity | `scripts/DowntimeResolver.gd:24 begin_drop(character, activity_id, region_id)` â†’ `:81 _on_confirmed` â†’ `:183 _finish_resolution` | **explicit, and carries `region_id`** | already refuses (`_pending["refused"]`, :45-48) |
| 16 | Dialogue choice | `Global/Dialogue_Manager.gd:328 select_choice(index)` | party | applies favorability at :376 |
| 17 | Map warp | `Game.gd:2506 _create_warp_zones` / `context_menu.gd:43-52` | â€” | early-returns before any later gate |
| 18 | Emit noise | `Global/HearingManager.gd:27 emit(pos, loudness, source)` | `source` | â€” |
| 19 | Footstep | `ProceduralCharacter.gd:3907 _emit_footstep()` | `self` | the only continuous "actor is doing something" signal |
| 20 | Cast start (noise) | `ProceduralCharacter.gd:5737 _on_ability_cast_started` | `self` | fires *before* effects resolve |

**The only witness channel:** `Game.gd:1247 _on_character_damaged(attacker, location, total_damage, victim)`, wired per-spawn at `Game.gd:385`. It iterates `characters_in_scene`, skips victim/attacker/party (:1260), requires `_has_visual_los(c, victim.global_position)` (:1266), and calls `ai_node.wake_from_at_ease(65.0, location)` (:1271). It fires **only on damage** â€” theft, trespass, and lockpicking have no observation channel at all. It also passes no attribution payload.

### The character verb surface does not work

`UI/context_menu.gd:66-68` is:
```gdscript
_:
    if target_character.has_method("interact"):
        target_character.interact(option)
```
`func interact` is defined in exactly two files repo-wide: `Items/Item.gd:277` and `Structures/Door.gd:26`. `ProceduralCharacter` has none, and there is no `_get`/`_call` catch-all in `Characters/`. So every character verb outside {Attack, Talk, Trade, Open} is a **silent no-op** â€” not an error.

`data/TopDownCharacters.json`: 96 templates author `interact_options`. Verb totals: **`Inspect` Ã— 96** (no handler anywhere), `Talk` Ã— 62 (handled :57), `Trade` Ã— 2 (handled :60, and auto-injected anyway at `Game.gd:893`). `Attack` appears in **zero** templates, and hostile characters never get a menu at all (`ProceduralCharacter.gd:3513-3521` returns a menu target only for non-enemies), so that arm is dead too. The most-authored character verb in the game has never done anything.

The good news: `_on_option_selected` (:40) genuinely *is* the single chokepoint and does execute on every click â€” only its terminal arm is dead. Adding `func interact(option: String)` to ProceduralCharacter would simultaneously activate the existing guarded path and fix Inspect.

---

## 7. Perf reality (nobody had counted)

Across all 24 maps there are **50 authored NPCs**; 13 maps have zero. Maximum is `dock_tavern` at 12. `town_square` â€” the canonical Perrow town â€” has **7** (2 `town_guard`, 3 `merchant`, 1 `noble_lord`, 1 `smith_darcy`). The party is hardcoded at 2 (`Game.gd:89-92`). So `characters_in_scene` is **9 on town_square, 14 on dock_tavern**. Not 30.

Existing per-frame LOS load, worst case (dock_tavern): â‰¤24 `sight_line_clear` calls = 24â€“192 rays/frame â‰ˆ 1.4kâ€“11.5k rays/sec. `_update_item_los_visibility` is negligible on town maps (0â€“3 item spawns) but spikes on the map-generator demos (`tg_villa_demo` = 66 items â‡’ â‰¤132 calls/frame).

Three mitigating facts the perf worry overlooked:
- `_update_target` **early-returns at ai.gd:368** whenever a valid live target is held, and `_is_enemy` (:408) filters **before** the raycast (:418). On a peaceful town map the AI vision sweep costs â‰ˆ **zero raycasts**.
- Distance and FOV gates precede every raycast in all four sweeps.
- `_share_alertness_with_allies` is already throttled (`ALLY_SHARE_INTERVAL = 0.75`, :46) and gated on `alertness_value > 12.5` (:906).

The actual defect: **`Game.gd:1461-1464` sits outside the `if not PauseManager.is_paused:` block** that ends at :1450, so the full NPC + item LOS raycast sweep runs at full rate during tactical pause when nothing has moved. That, plus the fact that dead characters are never erased from `characters_in_scene`, is the largest free win available â€” larger than anything a cache would buy.

**Conclusion: per-frame legality checks are fine at N=14, provided the check itself does not raycast.** Crime broadcast is O(14) on a one-shot event â€” push, not poll. A separate hot spot worth knowing: `ai.gd:861-869`'s wander picker runs 121 `is_tile_walkable` (itself O(N)) + `GridManager.find_path` calls per re-roll, on a 3 s cooldown â€” a far bigger spike than any vision work.

---

## 8. Persistence: what survives, what doesn't

**There is no save/load system.** The only `FileAccess.WRITE` calls in the project are editor-time terrain export (`TerrainGeneration/grass_terrain_generator.gd:306`, `procedural_grass_map.gd:235`, `ui_controller.gd:193`). `QuestManager.get_save_data()` (:154), `ReadableManager.get_save_data()` (:84), and `Game.load_party_state_from_save()` (:172) all have **zero callers**. `Globals.world_state` is in no serializer at all. `project.godot` `run/main_scene` points straight at `game.tscn` â€” no menu, no save UI.

Within a session, exactly **two** buckets survive a map transition:
1. Party members â†’ `party_state[i].live_state`, via `Game.gd:169` `save_party_state` (:160).
2. NPCs where `_is_service_npc(c)` (`Game.gd:187`) â€” literally `character.titles.size() > 0` â€” via `Game.gd:209` into `npc_state_per_region[region][uid]`.

**Guards are in neither bucket.** No `town_guard`, `centurion_marcus`, or `deputy_gleg` template has a `titles` key (the 17 `titles` entries in TopDownCharacters.json are all clergy/merchant/craft roles). A guard fails the check at `Game.gd:201`, hits the `continue`, and is `queue_free()`d at `:644` with its state unrecorded. Additional silent drops: `_save_service_npc_states` returns early if the map has no region (`:193-195`, so wilderness saves nothing), and the uid is just `template_id` when `unique_name` is empty (`:181-185`), so multiple spawns of a generic template collide on one key.

`_serialize_character` (`Game.gd:2674`) captures conditions, faction_id, traits, stats, inventory, equipment, cooldowns. It does **not** capture `favorability`, and `faction_id` is overwritten to `"player"` at `Game.gd:820` after deserialization anyway.

Conditions round-trip as `{id, stacks, expires_at}` (`Game.gd:2797-2804`) â€” note `ConditionInstance.to_dict`/`from_dict` (:57/:80) and `ConditionManager.to_dict`/`from_dict` (:474/:482) exist and have **no callers**; Game.gd hand-rolls its own. Restore at `Game.gd:2977-2983` passes the absolute `expires_at` into `apply_condition`'s **relative** `duration_override` slot (`ConditionManager.gd:193-199`) â€” masked only because `ConditionInstance.apply()` (:86-91) then unconditionally re-stamps `expires_at` from the *template* duration. Net: **timed conditions reset to full duration on every map load; permanent ones (`duration: -1.0`) round-trip correctly.**

`MapTriggerState.fired` is in-memory only (`MapTriggerState.gd:9-10` flags save/load as a follow-up).

---

## 9. Authored but inert

Data with no code reading it, or code with no data feeding it. Each verified by grep.

**Crime vocabulary**
- **`wanted` condition** (`ConditionDatabase.gd:1296-1313`) â€” traits `{debuff, affliction, social, legal}`, `duration: -1.0`, `canceled_by_trait: ["pardon"]`, empty `stat_modifiers` / `triggered_effects` / `immunities`. Description: *"Guards in this region are hostile on sight."* **Correction to five prior audits: it IS applied by live code** â€” `data/downtime.json:349` (theft "caught" outcome) â†’ `DowntimeResolver.gd:191` â†’ `DowntimeEffectApplier.gd:59-60` â†’ `:166-179` `cm.apply_condition(cid, character, stacks, -1, null)`. It was missed because the id arrives as a JSON-sourced variable, never a literal. It has **zero consumers** (all 9 non-definition `has_condition` sites check `unconscious` or `blinded`), and once applied it is permanent and unremovable.
- **`pardon` trait** â€” appears exactly once repo-wide, at `ConditionDatabase.gd:1306`. Nothing grants it.
- **`canceled_by_trait` is globally unimplemented** â€” declared (`Condition.gd:59`), parsed (`:93`), authored on ~65 conditions, **read by nothing**.
- **`legal` condition trait** (`ConditionDatabase.gd:1300`) â€” the only crime-related taxonomy marker in the codebase. No reader.
- **`criminal` ability trait** â€” the hook is **live code**: `AbilityManager._check_action_trait_stacking` (:483-512) is fully implemented and called on every completed cast from `ProceduralCharacter.gd:5762`. `thrill_of_sin` (`ConditionDatabase.gd:567-586`, stackable to 20, *"Luck increases each time a criminal action is taken"*) declares `on_action_trait_stack: {"required_traits": ["criminal"]}` at :585. **No ability in `data/Abilities.json` carries a `criminal` trait** â€” zero hits. This is a ready-made "an action was criminal â†’ increment a flag" primitive needing only data.
- **`legal_title`** on downtime activities (`"thief"` :326, `"prostitute"` :427) â€” the gate at `DowntimeDatabase.gd:76-79` is correct; neither string appears in any faction's `laws`, so it has never fired.

**Stealth vocabulary**
- **`walking_noise`** (races.json, 34 entries, meaningful spread 0.3â€“1.5) â€” set onto the character (`RaceDatabase.gd:123`, `ProceduralCharacter.gd:470`) and **never read**. The footstep formula at `:3940` has no `walking_noise` term. The single most load-bearing dead stealth stat.
- **`Stealth` trait** on items (`stilleto` :1026, `dark_hood` :1548, `shadow_cloak` :1986), races (`halfling` :127), and factions.json (:389) â€” `grep "Stealth"` across all `.gd` returns **zero**.
- **`Stealthy`** â€” one consumer only: `downtime.json:323` preferred_traits for Theft. No tactical effect.
- **`Lockpicking`** trait (backgrounds.json:232 via the `criminal` background) â€” zero `.gd` references. **There is no lockpicking mechanic**; Door offers key-or-bash only. The `protagonist.ability_check('lockpicking', 12)` in `Dialogues.json:269` resolves to a flat 12% roll with the stat name discarded (`ability_check` :5595-5596) â€” and is unreachable anyway (no `protagonist` autoload).
- **`shadow_cloak.adds_condition_on_equip: "Invisible"`** (:1991) and **`dark_hood: "Shrouded"`** (:1553) â€” neither condition exists; and `adds_condition_on_equip` is only ever read on the item-*use* path (`action_queue.gd:381`, `PartySidePanel.gd:928`), never on equip.
- **`"invisibility"`** in `chameleon_paglia.extra_abilities` (TopDownCharacters.json:1428) â€” no such ability among the 41 in Abilities.json.
- **`"sensory": {sight, hearing, fov_angle_degrees}`** blocks in TopDownCharacters.json (:343, :385, :455, :494) â€” `grep '"sensory"'` across `.gd` returns nothing. Every spawned character uses `sight = 1.0`, `fov = 150.0`. Note the authored values (80/120/150/200) are on a different scale than the live multiplier semantics, so naive wiring would give ~115,200 px sight ranges.
- **`blocks_sight`** in `hex_tiles.json` / `hex_icons.json` â€” parsed into `hex_tile.gd:36`, `hex_icon.gd:27`, never read.
- **`cast_loudness`** â€” read speculatively at `ProceduralCharacter.gd:5743`; the Ability class has no such export and no JSON authors it. Every spell is exactly 0.6 loud.

**Permission / action machinery**
- **`restricted_actions_by_trait`** (`ProceduralCharacter.gd:336`) â€” an `@export` dict with a real action vocabulary (`manipulate, attack, magic, arcane, holy, occult, primal, concentration`), recomputed on `stats_recalculated` (:1396-1398) via `calculate_effective_stat(0.0, "restrict_<action>")`, loaded (:1783), and serialized (`Game.gd:2737` / `:2900`). **Ten hits repo-wide, all writes.** Worse: no condition in `ConditionDatabase.gd` defines any `restrict_*` stat (the complete authored vocabulary is 19 keys, none of them), so `calculate_effective_stat` returns `0.0` and `0.0 >= 1.0` is always `false`. It is a **fifth abandoned permission system, permanently dead**, and its restored values are overwritten on the next condition tick. The action names are free to reuse; recommend deleting it rather than leaving a same-named table that looks authoritative.
- `Ability.requirements.traits` (`Ability.gd:67`) â€” parsed, never read by `_check_ability_usable`.
- `Actions/PlannedAction.gd` â€” a complete AP/turn-based action Resource typed against a `CombatCharacter` class that does not exist. Zero references.

**Faction / state**
- `factions.json` `flag`, `icon`, and faction-level `traits` â€” no readers.
- Undefined faction ids in relation lists: `town_guard`, `merchants`, `nobles`, `demons`. Undefined factions assigned to live templates: `spider_party` (3), `druids` (3), `none` (2).
- `Globals.world_state`'s two seed keys `"Perrow Destroyed"` and `"Justinia Remaining Loops"` (`Globals.gd:3`) â€” zero references. (They contain spaces, so they are also unreachable from dialogue's identifier regex.)
- `hunger` (`ai.gd:90`) is only ever decreased, so `is_hungry()` (:726) is permanently false and the `seek_food` goal (:707) is unreachable. External writers (`action_queue.gd:380`, `PartySidePanel.gd:922`) target `character.hunger`, a property that does not exist â€” hunger lives on the AI child node.
- `Maps.json` `party_spawns` (present on all 24 maps) and map `description` â€” zero readers.
- Dialogue side-effect syntax is entirely inert: `[[start_combat(...)]]` (Dialogues.json:86), `[[spawn_character_from_name('golden_guard',4)]]` (:147), `[[protagonist.add_trait('subtle')]]` (:164) â€” `substitute_variables` (`Dialogue_Manager.gd:397`) never invokes functions, and none of those methods exist. All `protagonist.*` branch conditions push_error and fall to `"default"` (no `protagonist` autoload).
- 5 `Maps.json` condition blocks use an unimplemented schema (`{"quest":..., "state":...}` :102, `{"item":"catacombs_key"}` :193, :6837, :13511, :17545) â€” `_check_condition` warns and returns false, so that NPC and 4 warps never spawn.
- `data/ScheduledDialogues.json` is `{"triggers": []}`. Exactly one map time-trigger exists (`demo_midnight_bell` on cemetery).
- `HearingManager.sound_emitted` (:24) â€” zero subscribers.

---

## 10. Adjacent systems worth knowing

**Time.** `Global/TimeManager.gd` runs a real calendar (10 months Ã— 36 days + a 12-day Yearturn, leap rule :104), emitting `time_updated` (:42) and `date_changed` (:43). Four autoloads already hang daily logic off `date_changed` â€” `SaintCalendar` (:99), `VowManager` (:25), `WeatherManager` (:41), `QuestManager` (:237-244, which writes `quest_days::<id>` â€” the working "N days elapsed" idiom). **But `ConditionManager` does not subscribe** (`grep date_changed Conditions/ConditionManager.gd` â†’ empty).

Critically: `TimeManager.gd:76` wraps `game_time` every in-game day, confining it to `[0, 86400)`. **Any condition `expires_at` > 86400 is never reached and the condition becomes silently permanent.** A bounty authored as "expires in 3 days" cannot be expressed as a condition duration. The same wrap breaks `save_interval` periodic decay (`ConditionManager.gd:106`).

Also: local maps run at `time_scale = 1.0` (real time); only `scarlatti_world` overrides it (7200.0, Maps.json:1326). Days effectively pass only via world-map travel or downtime `duration_hours` (`DowntimeResolver.gd:195-197`).

**NPC schedules do not exist.** Grep for `schedule|patrol|routine|waypoint|home_position` across all `.gd` and `data/*.json` returns zero time-of-day NPC behavior. `EventScheduler` is a working `(hour, minute)` trigger engine with once/daily/`every_days` recurrence, map-or-global scope, and prerequisites â€” but it fires exactly one thing, `DialogueManager.start_dialogue` (:118), and its content pool is empty.

**Favorability** (`ProceduralCharacter.gd:37-56`) is a per-*companion* approval scalar toward the protagonist, clamped Â±100, with `apply_favorability_delta(delta, reason)` (:52) and a `favorability_changed` signal that has **zero subscribers**. Written by dialogue choices (`Dialogue_Manager.gd:376`), downtime effects (`DowntimeEffectApplier.gd:49`), and forced-action penalties (`DowntimeResolver.gd:91`). Read at exactly two places, both in DowntimeResolver: the refusal gate (:45-48) and a disadvantage penalty (:106-111). **Not serialized** â€” `_serialize_character` omits it, so companion approval resets to 0 on every map transition. Also asymmetric: only negative values do anything. It is the right precedent to copy, and a fine channel for "your party disapproves"; it is the wrong variable for legal standing (single unkeyed int, no observer dimension).

**Documentation.** There is no README and no CLAUDE.md/AGENTS.md anywhere. The tracked doc surface is four files; the only real design doc is `docs/melee_hitbox_plan.md` (Problem / Current implementation with file:line / Root causes / Proposed architecture / Step-by-step / Test plan / Out of scope / Files involved) â€” and it was fully implemented. Design intent otherwise lives in header comments inside `.gd`; `ai.gd:20-31` and `HearingManager.gd:9-23` are the exemplars.

**Testing works headless.** `tests/` holds three standalone `Node2D` harness scenes, hand-invoked, no framework, no CI. The pattern: game-stub properties on the root, `_check(name, cond, detail)` printing PASS/FAIL, `_ready()` calling ordered scenarios then `get_tree().quit(1 if failures > 0 else 0)`. The key enabler is that `ai.gd:132` does `game = get_tree().current_scene`, so **when the harness scene is the CLI main scene, the harness root IS `game`** â€” no `Game.tscn` boot needed. A 16-assertion probe spawning real `ProceduralCharacter.tscn` instances, asserting `_update_target()` â†’ HOSTILE, and verifying wall occlusion via the `_make_blocker` pattern (`elevation_harness.gd:457`) passed 16/16 headless. Required stubs: `characters_in_scene`, `party_chars`, `factions`, `items_in_scene`, `stealth_mode`. Two caveats: a script error before `quit()` hangs the process forever (always cap with an external timeout), and startup stderr is permanently noisy (the missing VisibilityManager, GameLog's absolute-path warning, ~25 missing-icon errors) â€” judge by PASS/FAIL lines only.

---

## Design implications

*Short section; the findings above are the deliverable.*

**Seams that already exist and are worth building on:**
- `wake_from_at_ease(target_value, location)` (`ai.gd:937`) â€” a generic stimulus injection point already shared by all four current stimuli. A witnessed crime should call it, not invent a parallel path.
- `Game._on_character_damaged` (:1247) + `_has_visual_los` (:1277) â€” the witness fan-out is already written (LOS filter, party skip, attacker skip). Generalize from damage-only to any observable act; the LOS helper needs a `target_elev` argument it currently omits.
- `HearingManager.emit` (:27) â€” the only central stimulus bus; its listener loop is the shape a `CrimeManager.report(...)` should copy.
- `RegionDatabase.get_region_for_map` (:46) / `get_controlling_faction` (:55) / `title_to_id` (:113) â€” position â†’ jurisdiction â†’ law-owning faction is O(1) and live today, at map granularity.
- `AbilityManager._would_hit_infatuation_source` (:393, called at :78) â€” the one existing position-aware, target-aware veto with a working refusal protocol (GameLog + `cast_failed` + return false). A `_would_be_illegal(ability, target_position, targets)` is a drop-in sibling.
- `AbilityManager._check_action_trait_stacking` (:483) â€” a live "this action had trait X â†’ increment a counter" primitive needing only a `criminal` trait on abilities.
- `Door.try_party_unlock` (:119) â€” a static, tested, party-wide gate; `Door.gd:115-118` already anticipates reusing it for containers.
- `DowntimeResolver.begin_drop` (:24) â€” already carries `region_id` and already knows how to refuse.

**Seams that do not exist and must be built:**
- Any ownership field on items, containers, or structures. `ai.gd:798` is not a partial implementation â€” it reads Godot's built-in `Node.owner` by accident and returns false always.
- Any sub-map spatial authority. Regions are map-granular; the only sub-map zones are one map's `dialogue_zones` circles and warp Area2Ds.
- Any actor parameter on `interact()`, and any `interact()` on characters at all.
- Any non-lethal AI response state. `_acquire_target` makes acquisition synonymous with attack.
- Any persistence for guards, bystanders, or `Globals.world_state`.
- Any per-character memory that outlives the 4/sec alertness decay.

**The three decisions that actually matter:**

1. **Pick one hostility oracle, first.** `ai.gd:_is_enemy` (:429) and `FactionDatabase.are_enemies` (:76) disagree for nearly every pair, and the same split runs through hearing (guards cannot hear the player because `player` is in no `enemies` array). Every crime-driven hostility rule lands on one of these. Fixing this changes global NPC behavior â€” most factions currently hostile-by-default would stop attacking â€” so it is a gameplay decision, not a cleanup. Note `are_enemies` is asymmetric by construction.

2. **Where crime state lives, given no persistence and no guard serialization.** A `wanted` condition on the *protagonist* works today (permanent conditions round-trip). Everything else does not: the Condition schema has no region field, its one free-form slot (`custom_data`) is dropped by `Game.gd:2800-2804`'s hand-rolled snapshot, its triggered-effect vocabulary is closed and reaches only the bearer, and the `game_time` daily wrap makes multi-day durations impossible. Per-NPC grudges are doubly blocked â€” guards aren't serialized, and generic-template NPCs share one uid. The alternative is a region-keyed ledger beside `Game.known_services_per_region` (:102), decaying off `date_changed` the way four autoloads already do. Nothing survives quitting either way.

3. **How many entry points to gate.** The 20-row table has no common ancestor. Either accept checks at ~6 sites (AbilityManager:58, ProceduralCharacter.attack:4526, ActionQueue._execute_action:327, pick_up_item:924 *and* ai.pickup_item:815, show_chest_inventory:963, Item/Door.interact) â€” noting `attack()` returns `void` and `ActionQueue`'s CUSTOM arm carries an opaque Callable that cannot be introspected â€” or first route them through a common `perform_action(actor, verb, target, position)`. The narrower question underneath: does legality apply to NPCs at all, or is it player-only? AI bypasses every player-facing path.

**Cheap wins available regardless of design:** delete `project.godot:49` (VisibilityManager) and the orphaned `fog_of_war.gd`; move `Game.gd:1461-1464` inside the pause guard; erase dead characters from `characters_in_scene` in `_on_character_died` (:1760); raise or instrument the `for i in range(8)` cap at `GridManager.gd:199`; fold `walking_noise` into `ProceduralCharacter.gd:3940` (one line, immediately gives grimalkin/bugaboo a stealth identity); delete `restricted_actions_by_trait` and its four write sites.
