# Plan: Area2D-based melee weapon hitbox

## Problem

Melee hits are unreliable. Two characters can stand still, swing weapons that
visually connect with each other's bodies, and take/deal no damage. Symptom is
intermittent — same setup sometimes hits, sometimes misses.

## Current implementation

`Game._check_combat_collisions()` (Game.gd:793) runs every `_process` frame.
For every attacker currently in `is_attacking()` state, it calls
`Game.check_weapon_body_collision()` (Game.gd:1471) against every other
character, item, and structure.

`check_weapon_body_collision` takes the blade tip and base in world space,
samples 5 evenly-spaced points along the blade line, and tests each against the
target's body polygon (`get_body_hitbox_corners` + `point_in_polygon`).

`attack_animator.attack_hit_frame` (attack_animator.gd:319, 327, 354) does
*not* drive damage — its handler `ProceduralCharacter._on_attack_hit` (line
2993) just re-emits a generic `attack_hit` signal. All damage goes through the
per-frame path above.

## Root causes (highest-suspected first)

1. **Visual / hitbox mismatch.** The hitbox polygon is built from
   `body_width` × `body_height`. If the visual sprite is wider than that quad
   (or has limbs sticking out), the blade visibly connects but no sample lands
   inside the polygon. *Suspected primary cause* given the report (consistent
   geometry, intermittent failure, weapon visibly contacting body).
2. **Rotational tunneling between `_process` frames.** The blade rotates
   during the swing; `_process` runs at variable framerate. Between frame N
   and N+1 the blade can sweep through enough arc that frame N's snapshot has
   the blade approaching the body and frame N+1's has it past, with no
   intermediate sample inside the polygon.
3. **Linear sampling density.** Only 5 evenly-spaced samples along the blade.
   A target polygon narrower than ~25% of blade length can fall between
   adjacent samples. Plausible but unconfirmed; less likely on its own.

## Proposed solution: Area2D weapon hitbox

Replace the per-frame point-in-polygon check with a real Area2D attached to
the weapon. Godot's broadphase handles continuous geometric coverage; no
manual sampling required.

### Architecture

- Each `WeaponShape` instance gets a child `Area2D` named `Hitbox` with a
  `CollisionShape2D` matching the **visible** blade volume (rectangle or
  capsule, sized from blade length × blade width — adjust to match the
  sprite, not `body_width`/`body_height`). Authoring: shape parameters live
  on the WeaponShape resource and are applied on _ready.
- The Hitbox's `monitoring` is `false` by default. The attack_animator
  toggles it `true` between `start_attack` (attack_animator.gd:191) and
  `_finish_attack` (line 262). Toggling matches the existing per-attack
  hit-tracking lifecycle (`register_attack_start` / `register_attack_end`).
- A new `WEAPON_HITBOXES` layer in `Global/CollisionLayers.gd` (suggest
  L6 = 32). Hitbox `collision_layer` = `WEAPON_HITBOXES`. `collision_mask` =
  `CHARACTERS | ITEMS | STRUCTURES`.
- Listen to `body_entered` on the Hitbox. Handler dispatches to existing
  `process_weapon_hit` / `process_object_hit` based on collider type.

### Hit deduplication

The existing `active_hits` dictionary (Game.gd:1155) and
`register_attack_start` / `register_attack_end` already prevent the same
attacker from hitting the same target twice in one swing. Reuse this
verbatim — the new Area2D handler calls `register_hit(attacker, target)`
exactly like the old code does at line 791.

### Removing the old path

Once the Area2D path is verified, gut `_check_combat_collisions` and
`check_weapon_body_collision`. `check_weapon_object_collision` and
`get_body_hitbox_corners` / `point_in_polygon` may still be used elsewhere —
audit before deleting (the AbilityShape AoE iteration in
`ProceduralCharacter._find_targets_in_area` reads the hitbox quad for
geometric containment tests; that's a separate concern and should stay).

## Step-by-step

1. **Add layer constant.** `Global/CollisionLayers.gd`: add
   `WEAPON_HITBOXES = 32` plus a `WEAPON_HITBOX_MASK` composite of
   `CHARACTERS | ITEMS | STRUCTURES`.
2. **Add Hitbox to WeaponShape.** In `Weapons/ProceduralWeapon.gd` (or
   wherever WeaponShape's setup runs), create a child Area2D + CollisionShape2D
   on the new layer/mask. Size from blade dimensions, not body dimensions.
   Default `monitoring = false`.
3. **Toggle monitoring with the swing.** In `attack_animator.gd`'s
   `start_attack` (line 191), set `weapon.hitbox.monitoring = true`. In
   `_finish_attack` (line 262) and `interrupt_attack` (line 658), set it back
   to `false`. The existing `register_attack_start` / `_end` lifecycle is
   already there — wire alongside it.
4. **Wire body_entered.** In WeaponShape (or attack_animator), connect
   `hitbox.body_entered` to a handler that:
   - Looks up the attacker (the WeaponShape's holder).
   - Calls `Game.can_hit_target` and `Game.register_hit` to gate dedup.
   - Routes to `Game.process_weapon_hit` (for ProceduralCharacter colliders),
     `Game.process_object_hit` (for items / structures), or whichever
     lives in Game.gd by then.
   - Passes the contact world position from `Hitbox.global_position`'s
     transform applied to the contact (or use `body.global_position` for a
     coarser estimate; melee impact position only matters for limb selection
     and impact SFX, not damage).
5. **Decommission per-frame check.** Once tests pass, delete the
   `_check_combat_collisions` melee path and `check_weapon_body_collision`.
   Leave `process_weapon_hit` / `process_object_hit` in place — they're the
   shared damage application logic.

## Test plan

- Two characters facing each other at melee range, swing — every swing in
  the visual contact arc should register exactly one hit per target per
  swing. Repeat at multiple framerates (toggle vsync, force 30 fps via
  Project Settings) to confirm the framerate-dependent miss is gone.
- Wide swing through three stacked enemies — should hit each once (dedup
  works, but doesn't suppress legitimate multi-target hits).
- Swing into a wall and an item simultaneously — both should register.
- Equip / swap weapons during combat — Hitbox follows the new weapon, old
  one becomes inert.
- Cast an ability while in melee range of a structure (the bug we just
  fixed — make sure the AbilityShape doesn't bring up its own Hitbox; only
  WeaponShape should).

## Out of scope

- Replacing the AoE / cone targeting in
  `ProceduralCharacter._find_targets_in_area` — separate system, also CPU
  iteration, but lower priority and works correctly for its intent.
- KE-based contact damage (Phase B). The Area2D handler should still call
  the existing `process_weapon_hit` for now; once Phase B is underway it can
  be extended to read contact velocity and apply KE damage in addition to
  the weapon's flat damage dict.
- `attack_hit_frame` signal repurposing — leave as-is; it now becomes
  decorative (or drives audio cues), since damage flows through the Area2D.

## Files involved

- `Global/CollisionLayers.gd` (new layer)
- `Weapons/ProceduralWeapon.gd` and `Weapons/WeaponShape` definition (Hitbox
  child)
- `Weapons/attack_animator.gd:191, 262, 658` (monitoring toggle)
- `Game.gd:793, 1471` (delete dead code at end)
- `Characters/ProceduralCharacter.gd:699` (no change expected; verify)
