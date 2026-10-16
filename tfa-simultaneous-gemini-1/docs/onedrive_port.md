# Port of the OneDrive work into the dev repo

2026-10-16. Branch `claude/port-feedback`, fast-forwarded into `main` on top of `212ce1fe`.

## What happened

Two rounds of work were done in the old OneDrive copy (`C:\Users\Nolan\OneDrive\Documents\Things-Fall-Apart`). That copy had stalled at `fcb5c77a` (July 20), while this repo had 55 newer commits: the law/crime system, calendar time, cond_* icons, combat AI, fire/oil, call-outs, the roof view, exploration and more.

1. A player-feedback audit, with fixes.
2. A feature round you directed.

Rather than merging, the work was **ported selectively**:

1. **Classify.** Each change unit was checked against this repo's code: still needed, partly done, already covered, conflicting with one of your systems, or obsolete.
2. **Foundation.** The feedback layer and the shared APIs were rebuilt on your systems: `FactionDatabase.are_hostile`, `TimeManager.absolute_time()`, your hover cursor and visibility cache.
3. **Twelve lanes.** Subsystem lanes ported their units in the original order: round-1 fixes first, then round-2 features.
4. **Integration.** An integration review found 58 cross-lane or dev-interaction issues and fixed 43 of them; the rest are judgement calls, listed below.

The full old work remains on branch `claude/onedrive-feedback-work`, for reference. It holds the two original reports, `docs/player_feedback_audit.md` and `docs/feature_round_2.md`.

There were 303 distinct change units:

| Outcome | Units |
|---|---|
| Foundation (feedback layer and shared APIs), ported or adapted | 9 |
| Ported as-is | 137 |
| Adapted to your code | 95 |
| Partly ported | 5 |
| Dropped before porting (covered, conflicting or obsolete) | 36 |
| Skipped during porting (found covered, conflicting or dependent on something dropped) | 23 |

**Verification.**
- Every one of your `tests/*.tscn` harnesses gives the same result as on `212ce1fe` or better. No regressions.
- 20 new harnesses, about 1,600 checks, all pass.
- Fairy chess passes 271 checks (235 before).
- The compile is clean apart from the 3 old dead scripts (ForceFieldExamples, PlannedAction, CharacterUI).
- Three main-scene smoke runs had 0 script errors.
- Pre-existing and unchanged: `template_data_check` (33 failures), `quest_proof_test`'s one script error at Item.gd:232, and a flaky claw bleed check.

## Dropped, because your code does it its own way

- **Hostility:** your `are_hostile` oracle. The old rewrite is not ported.
- **Reputation, provocation, kill credit:** your law/crime system (CrimeManager, standing, outlaw marks, surrender) replaces the old model. Where old features displayed hostility or standing, they now show yours.
- **Condition clock:** your `absolute_time()`. The old `world_time` is not ported.
- **Condition icons:** your cond_* set. The old icon mapping and generated icons are not ported.
- **Invisible:** your binary Invisible stays. The Shadow Cloak grants it.
- **Weapon on-hit:** your `on_hit_ability`. The old proc engine (Ignite, Cleave and the rest) is not ported.
- **Already fixed in your code:** Dialogues.json parsing, the Melee STR typo, the VisibilityManager autoload, ice melting, deselected-path execution, dash previews, AoE ghost cleanup, the music fallback, and several others.

## What's in

- **Feedback layer**
  - The on-screen game log, with repeats folded into "(xN)".
  - `notify()` refusal notices over characters.
  - Cast-failure reasons; your "Illegal here" refusal floats without a second log line.
  - Inventory-full notices, and honest partial stack merges.
  - The PAUSED banner.
  - Names in every log line.
- **Shared APIs**
  - A world hover tooltip with providers.
  - A HUD status strip.
  - One item-tooltip builder for every window.
  - Sight, visibility and hostility wrappers on your systems.
- **Round-1 fixes still needed here** (about 190): refusals and hidden rolls reported across combat, planning, inventory, trade, chests, services, downtime, dialogue, quests and the world. Highlights:
  - Inventory drag-and-drop works in every window. It was broken: slots are MOUSE_FILTER_STOP with no forwarding.
  - Dead menu options are removed.
  - Debug hotkeys work only in debug builds.
  - Party runtime state survives warps.
  - Same-map ladders move the party without a reload.
  - Fairy chess explains collisions, deaths and game-over reasons.
- **Round-2 features**
  - Unarmed strikes, using your designation pattern.
  - Fire, poison and cold hits apply their condition, with the attacker as source, so your crime system credits DoT kills.
  - Armour DR in tooltips, and "-N blocked" floats.
  - Interruptible casts, ability range clamping, and Concentration (reserve model, lavender pips).
  - Dark Hood → Shrouded (half sight range to you), Golden Crown → Inspired, weapon and gear light, backpack slots.
  - Sight API, Perceptive +20%, creature senses, weather and fog vision, and Acid/Freezing Rain outdoors (attributed to the caster for crime purposes).
  - NPCs lose track after about 2 s without line of sight, and a Suspicious stage before Searching. Both are reconciled with your occluded-chase demotion and call-outs.
  - Stealth mode benefit (sneaking ×0.5 noise, ×0.7 walk), STEALTH badge, elevated cones, noise rings and readouts.
  - Hover info for characters (stance from your hostility and standing), structures (damage state) and hazards (while paused).
  - Distinct poison and acid colours, wind indicator, electrify preview, overhead condition tooltips, target-intent lines.
  - Fairy chess piece rules and Doppelganger royalty.

## Open questions

1. **`canceled_by_trait`.** Still yours to decide. Should anything carrying trait X clear conditions that list X (abilities, damage types, fluids), or only explicit cleanse effects?
2. **World-map condition timers.** Force March lasts 120 in-world seconds while the world map runs at 7200×, so it ends within a frame. The recommendation is to author travel and downtime durations in in-world hours (`duration_hours` is supported now). The alternative is a separate travel clock.
3. **Elemental riders stack per hit regardless of size.** Match Striker's 1 fire applies a full Burning stack, about 60 damage over 15 s. Options:
   - require the dealt damage to reach the tick value;
   - roll dealt ÷ tick value;
   - exempt weapons whose main damage type isn't the element.
4. **Winter's Grip.** Its frost fog puffs cut the wielder's own sight to about ×0.66, under the new fog-vision rule. Make item fog cosmetic, or don't count a fog against its own source?
5. **Concentration.** Currently it holds focus without spending it, so recasting your own held spell is free. Spend and hold instead?
6. **Plans and stuns.** A drawn plan is dropped entirely when its character becomes unable to act, even for a 0.5 s stun. Pause it instead?
7. **Djargo** starts in a Dark Hood, so he's Shrouded from the first frame. Keep?
8. **Shrouded and Inspired** borrow icons. They need cond_* style art (one line each in ConditionDatabase).
9. **Indoor maps.** Only 7 maps are flagged indoors. `venonan_chapel`, `don_manor`, `minschaleft_university`, `curia`, `alamonean_tower`, `southrons_mill` and `vermincelli_hideout` may need it too. Casting Acid Rain over a town reports an assault for every NPC it hits. Intended?
10. **Training** is exempt from the 7-day downtime cooldown. With only 4 outcomes, a long stay would otherwise run dry. Revert in `DowntimeDatabase.pick_result` if unwanted.
11. **No `ration` item** exists, so Feasting gives nothing and Burn a Ration costs nothing.
12. **Federica's inline dialogue actions** (spawn guards, start combat, give an item) have no API to call and are stripped. Should a small dialogue action API be added?
13. **NPCs can pick up items owned by other factions.** Your CrimeManager reports that as theft. Should owned items be off-limits to NPCs?
14. **Exploration reveal** now uses live sight, so less is revealed in fog and rain. Wanted?
15. **The Shadow Cloak's Invisible** survives attacks and casts (your binary rule). Should attacking break it, as it reveals Shrouded?
16. **Stealth and talking.** With stealth mode on, left-clicking a peaceful NPC still swings, as in your code. The C-key log line says so.
17. **Starter weapons** still leave a hidden inventory entry each. They no longer count toward the cap, but a cleanup is pending.

## Check in the editor

The headless runs can't show any of this:
- **Drag and drop** in every window: party, trade, chest and corpse loot, and service cards.
- **Layout:** the log panel, the PAUSED banner and the HUD strip, next to your MoonToggleButton and surrender button.
- **Feel:**
  - Unarmed fights, elemental DoTs, interrupts and concentration pips.
  - Stealth: the badge, the noise rings, the eye marker and the pink elevated cones.
  - Weather sight: heavy rain, cemetery fog, and Acid Rain outdoors only.
- **Hover:** NPCs, walls, and (while paused) hazards.
- **Fairy chess:** piece tooltips.
- **Icons:** open the editor once so it generates `.uid` files for the new scripts, then commit them.

The full per-lane test lists are on the integration branch history; each lane's commits name the units they ported.
