# Sound Effects Audit: what's silent that shouldn't be

2026-11-01. All paths are relative to `tfa-simultaneous-gemini-1/`. Every hook point below was checked against the code. Two of them were also checked against the engine. Line numbers are where a `SfxManager.play(...)` / `play_ui(...)` call would go. They refer to the code before the sound pass described next, so they have since shifted.

## Status: the sound pass (same day)

The audit below has since been acted on. It is kept as the record of what was found.

- **Bugs F1-F11 are fixed.**
  - F1: hit sounds go through `ProceduralCharacter.hit_sound_key()`, which picks flesh, armour or shield by how much of the hit was absorbed.
  - F2: the clash code is still unwired. It is documented as such, and its crash is fixed.
  - F9: three Kevin MacLeod CC BY 4.0 tracks were added (see `MUSIC_CREDITS.md`). `MusicManager` now loops every track.
- **§4 infrastructure is in place.**
  - `default_bus_layout.tres` defines Master / Music / SFX / UI / Ambience. `SfxManager.set_bus_volume()` persists to `user://audio_settings.cfg`, but no settings screen exists yet to call it.
  - Every path plays through `SfxManager`, including ability and condition sounds, so all of them honour Silence zones.
  - Looping emitters (`start_loop` / `stop_loop`) cull by distance and have per-key budgets.
  - Map ambience beds are chosen per map id in the new `data/map_ambience.json`. It isn't a Maps.json key because the Terrain Generation exporter rebuilds the `tg_*` rows.
  - Footsteps have their own voice pool. Voice stealing takes the voice with the least time left.
  - `<key>_<n>` files form variant groups.
  - Every button clicks. A button opts out with `set_meta("sfx_silent", true)`.
- **96 new sounds were added to `sfx/`.**
  - Sources: 20 Kenney (CC0), 28 OpenGameArt (CC0 / CC BY 3.0), 42 ElevenLabs, and 6 edited from existing sounds. Licences and the attribution block are in `SFX_CREDITS.md`.
  - The ElevenLabs recipes are in `tools/generate_missing_sfx.py`.
  - No human has listened to them. Gemini listening QA was unavailable (the API key's credits were spent). Choices were made from spectrogram analysis plus a local CLAP zero-shot check, and the takes that check ranked poorly were regenerated.
- **Wired:** nearly every Tier 1-3 row, the 8 silent abilities, and 14 of the silent conditions.
- **Deliberately not done:**
  - No AI hearing emit for non-humanoid death cries.
  - No bark on every AI target switch, only on alert transitions.
  - No enemy-yields surrender sound, because that path doesn't exist.
  - No volume-settings UI.
- **Tests:** the new `tests/sfx_manager_test.tscn` has 37 checks. `tests/music_manager_test` was updated now that the "broken" tracks exist.

## Bottom line

**What already makes sound:**
- Footsteps on all 12 floor types, with boots and barefoot variants.
- Slashing melee swings.
- Gunshots and bow releases.
- Hit impacts.
- Humanoid death screams.
- Drawing a weapon.
- 44 of 52 abilities.
- 12 of 76 conditions.
- The chest, trade and shop windows.
- Weather loops.
- Witness reactions.
- Music: map ambient plus a combat layer.

**The biggest silences**, in order of how often the player runs into them:
1. **The interface outside shops and chests.** No button has a click or hover sound. Pausing, planning paths and action nodes, the right-click menu, and advancing dialogue are all silent. In a tactical-pause game that is most of a fight.
2. **Hit feedback.**
   - Bludgeoning and piercing swings are silent: 41 bludgeoning and 6 piercing weapons, plus fists and bites.
   - Hits on armour almost always play the flesh sound (a bug, see F1).
   - Nobody grunts when hurt, only when they die.
3. **The world.** Doors, fire, eating and drinking, map transitions, and structures breaking make no sound.
4. **Conditions.** 64 of 76 are silent on apply, including Bleeding (every slash and pierce applies it), Unconscious, and all 18 stress afflictions and virtues.
5. **Meta events.** Quests, gold and items changing hands outside shops, skill checks, companion approval, crime, party joins, and training all happen without a sound.

**The plumbing has four structural gaps** (section 4):
- No audio bus layout, so there is no way to set music and SFX volumes separately.
- Two separate playback paths. The one used by spells and conditions ignores Silence zones.
- No looping emitter, which fire crackle and ambience need.
- A 32-voice pool that footsteps can exhaust.

---

## 1. Fix first: existing hookups that are broken or wrong

| # | Problem | Where | Fix |
|---|---|---|---|
| F1 | **Hits on armour play the flesh sound.** Melee picks `clash`/`armor-impact` only when the hit is BOUNCED, which requires `take_damage` to return 0. The chip floor guarantees at least 1 damage whenever raw damage is above 0. Projectiles (`dealt <= 0`) and thrown items work the same way. So plate struck by a dagger plays `sword-on-flesh`. | `Game.gd:4642` (melee), `:5100` (projectile), `:5223` (thrown); chip floor at `Characters/ProceduralCharacter.gd:7824` | Choose the sound by how much armour absorbed. That amount is already computed for the "-N blocked" float text around `ProceduralCharacter.gd:7812-7854`. Use `shield_brace` when an off-hand shield did the absorbing. |
| F2 | **Weapon-vs-weapon clash is dead code.** `process_weapon_clash` and `check_weapon_weapon_collision` are never called, so the `clash` at `:4746` can't play. If someone revived it, `:4768` calls `knock_weapon_away()`, which doesn't exist (the real function is `_knock_weapon_away`, `ProceduralCharacter.gd:8599`). | `Game.gd:4707`, `:4955` | Either wire it up and fix the name, or delete it. |
| F3 | **Some humanoids die without a scream.** The check is `creature_type == "Humanoid"`, but dhampir (`"Humanoid, Undead"`), high_elf (`"Humanoid, Fey"`) and aedelf (`"Humanoid, Dream Spirit"`) use compound strings. | `Characters/ProceduralCharacter.gd:8082` | `begins_with("Humanoid")`, as `CompulsionField.gd:256` already does. |
| F4 | **Item on-hit procs skip their authored sound and VFX.** Effects go straight through `AbilityEffect.resolve_effect`, so the Heartbreaker's `heartbreak` proc never plays its `charm_chime`. | `Game.gd:4028-4030` | Call the ability's visuals and sound after resolving. |
| F5 | **Drinking a healing potion is silent.** The potion's `heal` ability is resolved without being cast, so its `holy_cast` / `heal_chime` never play. `heal()` itself has no sound. | `Characters/action_queue.gd:518-524`, `:589` | Same fix as F4. |
| F6 | **Spell and condition sounds ignore Silence zones.** Only `SfxManager.play` checks `HearingManager.sound_gain_at`. `_play_sfx_at` (every ability cast and impact) and `_start_condition_sfx` build their own players, so a Fireball inside a Silence zone still booms. A cast sound also keeps playing after the cast is interrupted. | `Characters/ProceduralCharacter.gd:9211`, `:9367`; check only at `Global/SFXManager.gd:41` | Route both paths through SfxManager, or apply the same zone gain in both. |
| F7 | **Searching a body plays a wooden chest creak.** "Search Body" opens `ChestInventoryWindow`, which always plays `chest_open` / `chest_close`. | `Game.gd:2255` → `UI/ChestInventoryWindow.gd:86`, `:447` | Branch when `chest_item is ProceduralCharacter`. New asset: cloth/body rummage. |
| F8 | **"Loop" condition sounds play once.** `_start_condition_sfx` relies on the stream's loop flag, but every `sfx/*.mp3.import` has `loop=false`. So `regen_loop`, `shield_hum`, `heavy_breathing` and `poison_tick` sound once, on apply. | `Characters/ProceduralCharacter.gd:9367-9390` | Set `loop=true` on the intended loops, or treat them as apply-stings and rename them. |
| F9 | **10 maps point at music tracks that don't exist.** `town_theme` (7 maps), `tavern_theme` (2) and `cemetery_ambient` (1) are missing from `Music/`, so all of them fall back to `ambient-permafrost`. | `data/Maps.json` (e.g. `:64`, `:206`, `:577`); fallback at `Global/MusicManager.gd:138-150` | Add the tracks or repoint the maps. |
| F10 | **Roof walkers get ground footsteps.** `footstep_noise()` reads the floor or fluid of the tile underneath and ignores `on_roof`, so someone on a roof splashes or crunches grass. | `Characters/ProceduralCharacter.gd:5852-5861` | When `on_roof`, use `footstep_wood` or a new tile/roof key. |
| F11 | Minor UI mismatches. | see right | `QuestLogPanel.gd:136` is the J open/close sound; the Quests/Notes tabs (`:331`) are silent. `trade_close` only plays on a forced close in `_exit_tree` (`TradeWindow.gd:549`), never on a normal one. `PartySidePanel.gd:1204` plays `ui-click` and then the `:1214` refusal plays `trade_decline` on top of it. |

**Six files are never played:** `weapon-break`, `reload`, `footsteps-dirt-gravel`, `footsteps-grass`, `footsteps-stone` and `footsteps-wood`. The four `footsteps-*` files look superseded by the `footstep_*_boots/bare` set. Suggested uses for `weapon-break` and `reload` are in the tables below.

**Correction (same day):** this audit first said sounds started during the tactical pause play normally. That held for the non-positional `AudioStreamPlayer` it was tested on, but not for the pooled `AudioStreamPlayer2D` voices behind `SfxManager.play`: a pausable 2D player started while paused stays at playback position 0 until unpause, then fires late. The sound pass fixed this. `play()` now gives the voice `PROCESS_MODE_ALWAYS` while the tree is paused, `play_ui()` players are always `PROCESS_MODE_ALWAYS`, and `tests/sfx_manager_test` checks it.

---

## 2. Gaps, ranked by player impact

"Reuse" means an existing `sfx/` key would do, possibly pitched or quieter. "New" means it needs an asset.

### Tier 1: every session, every fight

| Moment | Hook | Sound |
|---|---|---|
| **Any button click or hover.** There is no theme sound and no global hook. The only `mouse_entered` hook is on world items. Silent buttons include CartaIdentita, the QuestRewardScreen buttons, SurrenderPanel, Next Day, the split popup, and every OK/Cancel dialog. | `Global/SFXManager.gd` `_ready`: `get_tree().node_added` → for each `BaseButton`, `pressed` → `ui-click` and `mouse_entered` → `ui-navigation` at about -14 dB. Add a meta opt-out for buttons that already play their own sound. | Reuse |
| **Pause / unpause** (dozens of times per fight) | `Global/PauseManager.gd:68` `pause()`, `:82` `unpause()` | New: time-freeze / resume pair. Interim: `ui-navigation` pitched down or up. |
| **Planning while paused:** placing an action node, FACE node, assigning an ability, item, attack or dash, cancelling | `Characters/PathInputHandler.gd:123`, `:416`, `:429`, `:446`, `:498`, `:381-396`; Esc cancel `:306` | Reuse: soft `ui-click`; `trade_decline` for cancel. |
| **Right-click menu:** open, select, refusal | open `Game.gd:2032`; select `UI/context_menu.gd:91` (skip Trade/Open, which have their own sounds); "select someone first" `:164`, law refusal `:179` | Reuse: `ui-navigation`, `ui-click`, `trade_decline` |
| **Bludgeoning and piercing swings:** maces, hammers, staves, daggers, spears, fists, bites and claws. The AI hears them (emit 0.5); the player doesn't. | `Characters/ProceduralCharacter.gd:6675`, `:6706` only play `slash` when `damage_type == "slashing"` | Interim: `slash` at pitch 0.7-0.85. New: heavy whoosh and thrust swish. |
| **Pain on non-lethal damage.** Only death has a voice. | `Characters/ProceduralCharacter.gd:7881` (`total_damage > 0`). Skip when `_condition_tick_damage` is set and throttle per character. | New: male, female and beast grunts |
| **Doors:** open, close, "Locked", unlock. NPCs push through town doors constantly. | `Structures/Door.gd:67` `open_door` (covers `push_open`), `:85` `close_door`, `:56` locked, `:59` unlock | New: creak, shut, rattle, key click. The AI can't hear doors either; add an emit. |
| **Dialogue:** open, advance a line, close | open `Global/Dialogue_Manager.gd:131` `start_dialogue`; advance `dialogue_panel.gd:44`; close `Dialogue_Manager.gd:822` `end_dialogue`. Currently only picking a choice clicks (`dialogue_panel.gd:131`). | Reuse: `ui-navigation` at about -8 dB for advance. New: a soft paper sound for open. |
| **AI alert icons:** red "!" when a target is acquired, "?" when searching. Matters most while sneaking. | `Characters/ProceduralCharacter.gd:2196-2220` (driven from `Characters/ai.gd:1105`, `:2148`) | New: alert bark. Don't reuse `witness_huh` for "?"; it's already the crime-outcry cue (`ai.gd:2262`). |

### Tier 2: common

| Moment | Hook | Sound |
|---|---|---|
| **Fire:** ignite, burning crackle, douse. `CellFire`/`CellFireFX` have no audio at all, and placed braziers and campfires don't crackle either. | ignite `CellFire.gd:182` `_light` (throttle it: spread lights many cells at once); douse `:123`; crackle loop per cluster light in `CellFireFX._refresh_lights` (~`:242`); braziers `Items/Item.gd:259-261` | Ignite: reuse `fire_cast`. New: crackle loop, steam hiss. Needs the loop API (§4). |
| **Eating and drinking** (player and NPCs) | `Characters/action_queue.gd:511` `apply_consumable`; NPCs `Characters/ai.gd:2032` `eat_food` | New: gulp, crunch. Plus the F5 fix for potions. |
| **Map transitions and stairs** | `Game.gd:1045` `load_map`; same-map stairs `Game.gd:1846` `_relocate_party` | Reuse a door or footstep sound, or new: travel whoosh. |
| **Damage-over-time ticks** (bleeding from every slash and pierce, poison, burning, chill) and stacks gained | tick `Characters/ProceduralCharacter.gd:2652`; stacks `:2397` | Reuse `poison_tick`, `burning_flesh`, `ice_crack` by damage type, quiet. New: bleed drip. |
| **Healing received** (potions, drain, Regenerating, downtime) | `Characters/ProceduralCharacter.gd:7669` `heal()` | Reuse `heal_chime`, throttled for Regenerating ticks. |
| **Condition resisted or immune; cured or cancelled** | `Conditions/ConditionManager.gd:888-899`, `:205`; cure `:807` | Reuse: quiet `shield_brace`; `holy_cleanse` for cures |
| **Cast fizzles:** interrupted, refused, concentration broken | `Characters/ProceduralCharacter.gd:8909`, `:8957`, `:9857` | New: fizzle. Interim: `debuff_generic`. |
| **Ranged edge cases:** throw release; arrow or bullet reaching max range; out of ammo; after a pistol or crossbow shot | throw `Game.gd:5128`; range end `:5053`; out of ammo `Characters/ProceduralCharacter.gd:6770`; after the shot ~`:6751` | New: throw whoosh, dry click. Reuse: quiet `arrow-wall-impact`, and the unused `reload`. |
| **Non-humanoid deaths:** wolves, bears, rats (including the summoned rat swarm), undead, trolls, horses | `Characters/ProceduralCharacter.gd:8082` (the `else` of the Humanoid check) | New: beast yelp. Interim: `animal_call` pitched down. |
| **Quests:** started, stage advanced, completed, failed | `Global/QuestManager.gd:76` `start_quest`, `:476` `_advance`, `:113` `complete_quest`, `:123` `fail_quest`. Auto-start quests fire at boot (`:58`, `:70`), and `_advance` can chain several stages in one call, so allow one sting per frame. | New: stingers. Interim: `radar_ping` / `heal_chime`. |
| **Quest reward screen:** open, take a reward, forfeit | open `Game.gd:465`; take `UI/QuestRewardScreen.gd:387`; Esc `:398` | Reuse `coin_pickup`, `chest_item_in`, `charm_chime` by reward type; `trade_decline` for forfeit |
| **Gold and items changing hands outside shops** | received: `Global/DialogueActions.gd:720`, quest money `Game.gd:474`, downtime `scripts/DowntimeEffectApplier.gd:182`. Paid: `DialogueActions.gd:756`, fine `Global/CrimeManager.gd:702`. Item given/taken: `DialogueActions.gd:647` / `:693`. Robbed: `UI/SurrenderPanel.gd:178`. | Reuse `coin_pickup` (pitch about 0.75 when paying), `chest_item_in` / `chest_item_out` |
| **Skill checks pass/fail** (one funnel for dialogue, plus downtime) | `Global/Dialogue_Manager.gd:441` `_log_ability_check`; `scripts/DowntimeResolver.gd:222` | New: dice roll plus success and fail stings |
| **Companion approves or disapproves** | `Characters/ProceduralCharacter.gd:71` `apply_favorability_delta` | Reuse `charm_chime`. New: disapprove sound. |
| **Equipping:** weapon from the menu, stowing it, putting armour on or off. Menu equips skip the `draw-steel` that weapon cycling plays. | `Characters/inventory.gd:291` `equip_item`, `:331` stow; armour `Characters/ProceduralCharacter.gd:6975`, `:7166` | Reuse `draw-steel`. New: sheathe, armour rustle. |
| **Dropping or throwing non-weapons.** Drops are silent; thrown potions and food clang like swords (`sword-fall`). | drops `UI/PartySidePanel.gd:1469`, `:1493` (weapons only); thrown `Game.gd:5233`, `:5240` | Reuse `chest_item_out`. New: soft thud, glass break. |
| **Splashes.** Shots and throws into water only make a ripple, then the `sword-fall` clang. | `Game.gd:5061` `_splash_if_fluid` | Reuse `footstep_shallow_water_bare` |
| **Movement:** dash, jump or fall landing, fall damage, slipping on ice, knocked into a wall | dash `Characters/ProceduralCharacter.gd:8058`; land `:6186`, `:6221`; fall damage `:6292`; ice `:5931`; wall `:6056` | Reuse `haste_wind`, `stun_impact`, `ice_crack`, `armor-impact`. Landings need an AI emit too. |
| **Structures and crates breaking.** The "Cracking" / "Crumbling" notice is silent too. | `Structures/structure.gd:157` → `_destroy_structure`; notice `:155`; crates and barrels `Items/Item.gd:532` (not `_destroy_item`, which also runs when a book is read) | Reuse the unused `weapon-break`. Add an AI emit. |

### Tier 3: rare but dramatic, or atmosphere

| Moment | Hook | Sound |
|---|---|---|
| **Stress:** breakdown into an affliction, rising to a virtue, "Courage holds" | `Characters/ProceduralCharacter.gd:9713` (affliction), `:9711` (virtue), `:9690` (courage) | New: one dread sting and one resolve sting (this covers all 18 stress conditions). Interim: `fear_shriek` / `holy_cast`. |
| **Crime:** committed, alarm raised / outlaw, pardon or squared with the law | `Global/CrimeManager.gd:120`, `:639`; `:711`; pardon `Global/DialogueActions.gd:1361` | New: low sting, alarm bell or whistle. Reuse `heal_chime` for pardon. |
| **Surrender panel** open or refused | `UI/SurrenderPanel.gd:48`, `:46` | New, plus `trade_decline` |
| **Party member joins or leaves** | `Global/DialogueActions.gd:1078`, `:1126`; rejoin `Game.gd:628` | New. Interim: `charm_chime`. |
| **Ability learned** through training | `Global/TrainingManager.gd:153`; `scripts/DowntimeEffectApplier.gd:342` | New. Interim: `charm_chime`. |
| **Character creation:** roll name, pick gender (re-rolls the body), portrait arrows, confirm (stamping the carta) | `UI/CartaIdentita.gd:543`, `:549`, `:570`/`:573`, `:585`; the stat roll on open `UI/CharacterCreationScreen.gd:66` | New: dice, rubber stamp. Reuse `ui-navigation` for the arrows. |
| **Downtime:** moon button, Next Day, result popup | `UI/MoonToggleButton.gd:75`; `UI/CampDowntimePanel.gd:102` → `Game.gd:206`; `scripts/DowntimeResolver.gd:295` | New: dawn bell. Reuse `ui-navigation`. |
| **Disarm, severed limb, vomiting, contagion spreading** | `Characters/ProceduralCharacter.gd:8649`, `:8368`, `:2783`, `:2719` | Reuse `sword-fall` or `weapon-break`, `nausea_retch`, `disease_cough`. New: gore. |
| **A summon appearing** (Rat Pack); rat swarm skitter | `Abilities/AbilityEffect.gd:164-174`; swarm visual `:199` | New: squeaks, skitter loop |
| **Oil Well** gushing for 6 seconds after the cast sound | `vfx/FluidWell.gd:121-124` `_build` | New: oil gush. Interim: `acid_splash` pitched down. |
| **Locked or unlocked containers; taking a readable** | `Items/Item.gd:386`, `:389`; `:371` `_take_from_world` | Share the door assets; new: paper rustle |
| **Stealth toggle; "in view" eye; new off-screen threat** | `Game.gd:2982`; `vfx/StealthOverlay.gd:108-121`; `UI/OffscreenThreatIndicators.gd:52-63` | New: hush. Reuse a quiet, throttled `radar_ping` for threats. |
| **Party selection; wait toggle** | portrait `UI/PartySidePanel.gd:477`; number keys `Game.gd:4154`; wait `Game.gd:4361` | Reuse: soft `ui-click` |
| **Vows:** Poverty breaking (no sound and no log line either), Chastity's +1 | `Global/VowManager.gd:106-112`, `:71` | New sting |
| **Time and ambience:** church bells; feast days; a per-map ambient bed (town crowd, cave drips, cemetery wind); the villa spring; birds and insects | `Global/TimeManager.gd:80` `time_updated`; `Global/SaintCalendar.gd:118`; per-map `Game.gd:1431` `setup_map_music` (needs a new Maps.json key); spring `Game.gd:2023` | New: bell, ambience loops. Needs the loop API. |
| **Weather:** changes hard-cut the loop with no crossfade; loops stay at full volume indoors under a roof; no thunder (weather.json has no storm type) | `vfx/WeatherVFXController.gd:96-100`; `Game.gd:1505` `_announce_weather_change` | Crossfade, plus a roof duck |
| **Lockpicking** exists only as dialogue text ("*Click!*", `data/Dialogues.json:330`) | `Global/DialogueActions.gd` has no play-sound action | Add a `play_sfx` dialogue action |

### Silent abilities (8 of 52)

| Ability | Note |
|---|---|
| `rat_pack` | Needs a summon squeak. It has no `impact_effect`, so a `sound_impact` alone won't play (see §3). |
| `bind_soul` | Needs an occult cast; `necrotic_cast` fits. |
| `silence` | A soft "hush" on cast reads better than nothing. |
| `force_march` | Overworld buff; a march drum or bugle. |
| `match_strike`, `prod_jolt`, `pensword_blot`, `chrome_smoke` | Item procs. They need F4 fixed before any authored sound can play. Suggested: match strike; `lightning_strike` pitched up; ink splat; hiss. |

### Silent conditions (64 of 76): the ones worth a sound on apply

A sound on apply plays whatever applied the condition. The `test_*` abilities play `fear_shriek`, `nausea_retch` and so on as impact sounds, but the same conditions applied by other sources (a failed fear save, contagion) are silent.

| Condition | Suggested sound |
|---|---|
| `bleeding` | New: drip or tear |
| `unconscious` | New: body thud |
| `grappled` | Reuse `stun_impact` |
| `frightened`, `panicked` | Reuse `fear_shriek` |
| `confused` | Reuse `mental_confuse` |
| `sickened` | Reuse `disease_cough` |
| `nauseated` | Reuse `nausea_retch` |
| `shocked` | Reuse `lightning_strike`, quiet |
| `corroding` | Reuse `acid_splash` |
| `infatuated` | Reuse `charm_chime` |
| `slowed` | Reuse `debuff_generic` |
| `blinded` | Reuse `debuff_generic` |
| `suffocating` | New: gasp |
| `invisible` | Reuse `haste_wind`, reversed or quiet |
| The 12 stress afflictions and 6 virtues | Covered by the stress stings in Tier 3 |

---

## 3. Gates to know before adding sounds to data

None of these breaks current data. Each one silently drops a sound someone adds later.

- **`sound_cast` only plays when `cast_time > 0`.** Instant abilities (25 of 52) go straight to `_execute_ability`, skipping `_start_casting`, where the cast sound plays. See `Abilities/AbilityManager.gd:224` vs `:255`.
- **`sound_impact` only plays when `impact_effect` is set.** `_spawn_ability_visuals` returns early otherwise (`Characters/ProceduralCharacter.gd:9129-9131`).
- **Multi-step abilities ignore top-level `visuals`.** Only per-step `visuals` play (`Abilities/AbilityManager.gd:406-415`).
- **Item procs and consumables bypass all ability visuals and sounds** (F4, F5).

---

## 4. Infrastructure

1. **There is no audio bus layout.** `SfxManager` and `WeatherVFXController` play on bus `"SFX"` and `MusicManager` on `"Music"`, but no `default_bus_layout.tres` defines either. Everything falls through to Master, and no volume setting exists anywhere. Add the layout (Master / Music / SFX, and possibly UI and Ambience) and a settings slider per bus.
2. **There are two playback paths.**
   - `SfxManager.play(key)`: pooled, keyed by filename, honours Silence zones.
   - `ProceduralCharacter._play_sfx_at(path)` / `_start_condition_sfx`: one new node per sound, keyed by path, no zone gain, default bus.
   - Unify them through SfxManager. This fixes F6 and puts ability sounds on the SFX bus.
3. **There is no looping emitter.** SfxManager only plays one-shots. Fire crackle, ambience beds, the Oil Well gush, condition loops and the rat-swarm skitter all need `start_loop(key, pos) -> handle` / `stop_loop(handle)`. `WeatherVFXController._get_looped_stream` already shows how to loop a stream.
4. **Voice stealing (worked out on paper, not observed in play).** The 32-voice pool is round-robin and stops whatever is in the next slot. Footsteps fire every 32 px per walker (`FOOTSTEP_DISTANCE`), off-screen NPCs included. A town with a dozen-plus walkers recycles each voice in about a second, which cuts multi-second sounds like death screams. Options:
   - A separate small pool for footsteps.
   - A distance cull before taking a voice.
   - A priority so stealing skips long sounds.
5. **Some sounds are heard by the player but not the AI.** No code in `Abilities/` calls `HearingManager.emit`, so a Fireball explosion is inaudible to the AI, although `HearingManager.gd:20` says civilians react to explosions. The same is true of doors, landings and breaking structures. Worth fixing alongside the sounds they get.

## 5. Not applicable (no mechanic to make noise)

- No save/load UI; the only save is the F11 debug round-trip.
- No main menu or title screen.
- No XP or level-up system.
- No parry, dodge, miss roll or crit mechanic; a whiff only writes a log line (`Game.gd:4811`).
- No weapon durability.
- No reload step: ammo is drawn from the inventory per shot.
- No storm weather type.
- The fairy-chess minigame (`fairy-chess-2/`) is a separate project with its own `audio_manager.gd`, so it's out of scope.

## Suggested first batch

These have the most effect for the least work. Most reuse existing assets.

1. Global button click/hover hook (one function in `SfxManager._ready`).
2. Swing sound for every damage type (`slash` pitched down for bludgeoning).
3. F1: armour sound chosen by the amount absorbed.
4. Pause / unpause, and path-planning clicks.
5. F3: `begins_with("Humanoid")`.
6. F6: Silence-zone gain on ability and condition sounds.
7. F4 / F5: play ability visuals for procs and potions.
8. Then the asset-dependent work: doors and fire (fire also needs the loop API), pain grunts, eating and drinking.
