# Unique-Items Pipeline

How to add an item with unique mechanical effects. Everything below the
framework layer is **pure data + art** — no engine code per item.

## The trigger vocabulary (what an item can DO)

| Trigger | Item field (Items.json) | Fires when |
|---|---|---|
| On hit | `"on_hit_ability": "<ability_id>"` | A landed, non-bounced hit — melee swing, projectile, or thrown. Resolved by `Game._apply_item_on_hit_effects` with the attacker as caster and the victim as target. |
| Bane multiplier | `"damage_vs_trait": {"spectral": 2.0}` | Damage build, before DR. Multiplies every damage type against targets carrying the trait (case-insensitive; multiple matching traits multiply together). |
| While drawn (weapons) | `"adds_condition_on_equip": "<condition_id>"` | Weapon enters a hand → condition applied permanent; stripped on stow/swap/disarm — including anything it chained into (triggered `apply_condition` ids and `transforms_into`). |
| While worn (armor) | `"adds_condition_on_equip": "<condition_id>"` | Armor equipped to a slot; stripped on unequip. |
| On use/consume | `"use_ability": "<ability_id>"` | Pre-existing path (PartySidePanel / action queue). |

`on_hit_ability` points at a normal Abilities.json entry whose `effects` array
uses the standard vocabulary — `apply_condition` (with `chance`, `stacks`,
`duration`, and effect-level `save_stat`), `damage` (with
`target_traits`/`immune_traits`), `disarm` (new; `chance` + `save_stat`),
`cloud`, `spawn_fluid`, `knockback`, `summon`, `custom`. Two extras:

- **`min_damage`** (top level of the ability entry): the proc only fires when
  the hit dealt at least this much post-DR damage (Match Striker's ">3").
- **Effect-level `save_stat`** on `apply_condition`: rolls the target's
  saving throw for THIS application only, without touching the condition
  template (Heartbreaker's will save doesn't change Beguile).
- Do NOT give on-hit abilities capitalized school traits
  (Martial/Arcane/...) — those are for cast abilities and cost resources.

## Conditions (Global/ConditionDatabase.gd)

New mechanics usually mean one new condition dict. Useful levers:
`stackable`/`max_tier` (per-stack scaling of `stat_modifiers` is automatic),
`duration` (-1 = permanent — right for while-drawn conditions),
`save_stat`/`save_interval` (built-in apply + periodic saves),
`triggered_effects` (periodic `damage`, `apply_condition` — note the FIRST
firing happens after one full `interval`, which is how Winter's Grip gets its
18-second grace period — or `custom` types handled in
`ProceduralCharacter._on_triggered_effect_fired`: `bleed_puddle`,
`ink_puddle`, `frost_fog`, ...), `transforms_into`, `immunities` (keys are
condition IDS this condition blocks — how `illuminated` prevents
`invisible`), `custom_vfx` (a .tscn instanced as a child of the character for
the condition's lifetime — see `vfx/glow_mark.gd` for a code-built
PointLight2D pattern).

To slow "movement AND action speed" use a `dexterity` modifier (feeds
move_speed, attack cooldown, and rotation) plus `speed_modifier` for extra
movement bite — the metallacized pattern.

## Fluids / clouds

- New fluid = one entry in `data/fluids.json` (ink is the template —
  characters standing in a fluid automatically receive its `condition_id`).
- Continuous emission from a character = a while-drawn condition with a
  `custom` triggered effect that deposits at the wielder's tile
  (`_handle_ink_puddle`) or puffs a cloud (`_handle_frost_fog`).

## Art

Weapons are flat profiles: generate with
`tools/gen_unique_items.py` in the rig project (img2img off the nearest
existing sprite in `Items/`, green keyout) → copy `item art/<id>.png` to
`<TFA>/Items/<id>.png` → run a headless `--import`. `sprite_path` serves as
both world sprite and inventory icon. WORN art (helmets, hoods, capes) uses
the worn-on-character pipeline instead — see `tools/gen_worn2.py`. HEAD-slot
art obeys the DOME-ONLY contract: the fitter covers a square box anchored at
the skull top that ends ABOVE the face, so the art must be one opaque dome
ending at its front rim — no pointed crown, no neck flange/chin wrap, and no
face-opening interior (opaque or hollow); a thin visor sliver at the rim is
the most that works. See tools/gen_hoods.py / gen_full_face.py.

## Checklist for a new unique item

1. Items.json entry (copy a same-type weapon; add the trigger fields).
2. Abilities.json entry for the on-hit proc, if any.
3. ConditionDatabase entry + optional `custom_vfx` scene, if a new condition.
4. fluids.json / custom triggered handler, if world effects.
5. Sprite via gen_unique_items.py → Items/ → `--import`.
6. Add a case to `tests/unique_items_check.gd` (data chain + behavior) and run
   it headless. It must stay 0 FAIL.

## The 7 exemplars (2026-08-01)

match_striker (min_damage-gated illuminated brand; illuminated blocks
invisible via immunities), pensword (while-drawn inking + blind chance),
heartbreaker (infatuated with effect-level will save — reuses Beguile's
condition and its existing AI enforcement), ghost_buster_sword
(damage_vs_trait spectral/ghost/incorporeal ×2 — the traits are established
here; give them to future ghosts), winters_grip (while-drawn fog +
18s-delayed self cold DoT via triggered apply_condition), chrome_smoker
(stacking metallacized on a pistol — procs work on projectiles), 
prod_of_justice (electric damage + stun con-save + real disarm str-save; the
disarmed weapon lands at the victim's feet as a world item).
