# Rigging rewrite

Started 2026-11-26 on branch `claude/rigging-workflow-rewrite-bca442`. Nothing here is merged to main. A phone-readable version of this doc: https://claude.ai/artifact/E77oPLp4MwtCFhpDqehJvY

**Status in one paragraph.** The new system ("rig2") exists beside the old one and is proven end to end in bind pose: 52 race packs, 21 item packs of every kind, an offline previewer, an automated fit gate, and a Godot runtime that builds a dressed character from data with no per-race baking. The game still runs on the old rig; nothing in gameplay code was touched. Animation on the new rig is the next phase and is not built.

## 1. Goals

1. **Drop-in items.** A new piece of art is equippable by every race without per-race tuning.
2. **Race variants.** A second body for an existing race is a folder and a small data file.
3. **Accurate fit.** Collars at the neck, sleeves along the arms, boots on the feet, weapons in the hand.
4. **Redoing art is allowed** where a consistent camera and anatomy convention needs it.

## 2. Audit of today's system

### 2.1 What exists

Three generations of character visuals are wired into `Characters/ProceduralCharacter.gd` (10,630 lines), tried in this order by `_setup_body_part_sprites`:

| Generation | Files | Who uses it |
|---|---|---|
| Mesh rig | `RigCharacters/CharacterRig.gd`, `RigCharacters/<race>/CharacterMesh.tscn` | 26 of 35 races, both genders (52 scenes) |
| SkeletalBodyRig | `Characters/skeletal_body_rig.gd`, `scripts/extract_body_parts.py`, `body_manifest.json` | Nobody. Only Male Elf and Male Orc have manifests and both have a mesh rig, so this path runs only if a rig scene fails to load |
| BodyPartSprites / Line2D body | `Characters/body_part_sprites.gd` | carapacians, centaur, wolf, bear, horse (sprites); pixie, bugaboo, troll, rat (lines only) |

The mesh rig is produced in a second repository, `C:\dev\Procedural Character from Scratch`:

```
race painting + label map
  -> rig_pipeline.py   (segment, detect_parts, slice_parts, export_godot)   joints, legacy cutout scene
  -> fit_equipment.py  (x9 garments)                                         one warped PNG per garment per race
  -> fit_part_equipment.py (x19 helmets, boots, gloves, packs, capes, pants) one PNG per piece per race
  -> export_mesh_godot.py (mesh_deform, foreshorten, godot_common)           CharacterMesh.tscn + CharacterRig.gd
  -> install_tfa.py                                                          copies into TFA, writes races.json rig_scale
```

At runtime the game does nothing but toggle visibility: `set_garment` shows `G_<id>_mesh`, `set_equipment` shows `EQ_<slot>_<id>_*`.

### 2.2 What is wrong with it

**Every item is baked into every race.** A garment is warped offline against each race's pixels and stored as its own texture and its own full copy of the body polygon and bone weights inside that race's scene. The result is 2,177 PNGs and 374 MB under `RigCharacters/`, with scenes of 1.4 to 6.5 MB each. Adding one item means editing a Python registry, re-running the fit for 52 races, eyeballing 52 results, reinstalling, and re-importing. Adding one race variant means rebuilding it against every item. This is the root of goals 1 and 2 being hard.

**The fit reads two disagreeing descriptions of the body.** Arm joints come from the label map. The neck, the root, the torso width and the shoulder line still come from silhouette column profiles written for the first elf. Garments are scaled by shoulder span times hand-tuned looseness constants (`WIDTH_LOOSE 1.62`, `HEIGHT_LOOSE 1.75`, `OVERSIZE 1.15`), then corrected by coverage-grow passes, tuck bands and a collar fill. The warp is axis-aligned, so a sleeve cannot follow an arm that slopes. This is the root of goal 3.

**Item identity is fuzzy.** The rig spells an item `venonan_vestament`, Items.json spells it `venonan_vestments`, and `ProceduralCharacter.RIG_WEARABLE_ALIASES` bridges them by hand. An item with no baked art is equipped, keeps its stats, and is silently invisible. Legs items are invisible on 18 rigs. Gloves are baked into every rig but the game has no hands slot.

**Ownership is split.** `CharacterRig.gd` is a string literal inside `godot_common.py` in the other repo. Any fix made in TFA is reverted by the next export unless it is mirrored by hand.

**Duplicated or dead.**

- The cutout rig (`slice_parts`, `export_godot`, `Character.tscn`, per-garment `__body` and `__sleeve` PNGs) is still built for every race and used by nothing.
- Slot tables are repeated in at least eight GDScript files; an item's slot is decided once from `equip_slot` and again from `type`.
- The rig's baked `W_*` weapons, `equip()`, the bowstring, and the `hit_react`, `death`, `drink` and `shield_guard` clips are never used by the game.
- 49 character templates carry bespoke `body_sprites` heads that are ignored whenever the race has a rig.
- The generator's README describes a rig that no longer exists. The repo holds about 35 `gen_*`, 14 `probe_*` and 4 `dbg_*` one-off scripts with hard-coded absolute paths.
- `rig_scale` is hand-tuned per race and gender (0.048 to 0.183) because race paintings share no common scale.

**In-flight work to be aware of.** The generator repo has uncommitted changes from another session (five Skaarsgaardian gear pieces fitted to four races only). I did not touch that repo.

### 2.3 Every caller of the rig, and what happens to it

`ProceduralCharacter.gd` is the only game file that talks to the rig. This is the full contract the new rig must honour or replace.

| Contract | Where | New rig |
|---|---|---|
| Root is a Node2D; game sets `scale`, `rotation = PI`, `position`; reads meta `center` | PC:4284-4331 | Keep. `RigCharacter` is a Node2D with the torso origin at (0,0), so `center` disappears |
| `set_moving(bool)` | PC:4339 | Keep (phase 2) |
| `actions()`, `play_action(name, duration)` with `swing_right`, `swing_left`, `thrust`, `bow_draw` | PC:4412-4442 | Keep (phase 2) |
| `set_arm_ik(side, world_pos)`, `clear_arm_ik()` | PC:4444, 9298, 9366 | Keep (phase 2) |
| `garments()`, `set_garment`, `equipment(slot)`, `set_equipment` | PC:7099-7139 | Replace with `wear(item_id)` / `remove(item_id)`; the alias table goes away |
| Hard-coded node path `Rig/Skeleton2D/root/upperarm_r/forearm_r/hand_r/grip_r`; holders copied from the grip's global transform each frame | PC:295-325 | Replace with `grip(side)`, which already returns position, rotation and scale |
| `rig.visible = false` on death | PC:8074 | Keep |
| Rig gates its clips on `get_tree().paused` | PC:4569 | Keep (phase 2) |
| `_ensure_clothed`, `clothe_if_bare` key off `body.rig_scene` | TopDownCharacterDatabase:221, 519 | Key off "race has a rig pack" instead |
| `MeleeReach.HAND_REACH_PX = 48` is deliberately not read from the rig | Global/MeleeReach.gd:76 | Unchanged; the rig stays cosmetic for reach |
| `CrimeManager` reads worn-slot shapes for disguises | Global/CrimeManager.gd:1085 | Unchanged; it reads the inventory side, not the rig |
| Tests: `spawn_clothing_check`, `wearable_strip_check`, `orc_rig_check`, `RigProbe`, `RigSmoke` | tests/, EditorScripts/ | Ported in phase 3; they assert `G_`/`EQ_` node names today |

Unused by the game and dropped: signal `action_finished`, `face()`, `weapons()`, `equip()`, `set_foreshorten()`, meta `zoom`, `nock`, `BowString`.

## 3. The new architecture

### 3.1 One idea: named frames

A **frame** is the only geometric primitive:

```json
{"o": [x, y], "ax": [ux, uy], "lx": 120.5, "ly": 34.0, "ly_neg": 51.0}
```

An origin, a unit axis, a scale along the axis, a scale across it (and optionally a different scale on the negative side, for a torso whose back and front depths differ).

`Rigs/skeleton.json` lists the frame names every race shares: `torso`, `back`, `head`, `upperarm_l/r`, `forearm_l/r`, `hand_l/r`, `palm_l/r`, `wrist_l/r`, `grip_l/r`, `foot_l/r`, and optional `leg_l/r`.

- A **race pack** gives each frame's position on its own painting.
- An **item pack** gives the same-named frames on its own art: where the shoulders, the sleeve or the skull sit in the item's picture.
- **Fitting** maps each item pixel from the item's frame to the race's frame of the same name. Normalise in one, de-normalise in the other.

That is the whole fit. There are no looseness constants per race, no coverage passes and no per-race output. Because the frames have an axis, a sleeve rotates to follow a sloping arm, which the old axis-aligned warp could not do.

Slots choose how frames combine:

| Slot | Fit | Frames | Scale |
|---|---|---|---|
| torso | skinned: torso blends into upper arm and forearm across each joint | torso + arm chain | free (width and depth independently), 6 % ease across |
| legs | skinned along the legs | torso + legs | free |
| head | rigid | head | uniform, from skull radius, 12 % ease |
| feet | rigid, authored once and mirrored | foot | free |
| hands | the showing hand recoloured, plus rigid cuff and back pieces (section 3.6) | wrist, palm | cuff uniform; back knuckle-to-knuckle |
| back | rigid, hangs from the trunk's rear edge | back | uniform, from shoulder span |
| main_hand, off_hand | rigid, under a closed fist (section 3.6) | grip | world: keeps the item's authored world size |

### 3.2 Races and variants are data

```
Rigs/races/<race>/<variant>/
  body.png      the painting, keyed, at most 1024 px on the long side
  labels.png    the colour label map (same palette as before)
  race.json     frames + world_scale; DERIVED from labels.png, never hand-written
  head.png      derived: head pixels redrawn above collars and capes
  over.png      derived: crests, fins, tail coils redrawn above garments
```

All anatomy is measured from the label map and nothing else (`tools/rigkit/derive.py`). Joints are the seams between labels. The skull is the largest circle that fits inside the head label, so ears, horns and beards cannot inflate a helmet.

A **variant** is a sibling folder:

- Re-skin (scars, skin tone, tattoos): `body.png` painted on the parent's canvas plus `{"inherits": "default"}`. Nothing else. `Rigs/races/orc/ashen/` is a working example.
- New build (heavier, taller): its own `body.png` and `labels.png` plus `{"inherits": "default", "labels": "labels.png"}`.

Then `python -m tools.rigkit.build_race <race>/<variant>`.

### 3.3 Items are data

```
Rigs/items/<id>/
  art.png
  item.json    slot, frames, mesh cells, layer, the Items.json ids it dresses
```

`python -m tools.rigkit.ingest <id> <art.png> --slot torso` measures the frames from the art's alpha: armpits from the column-thickness profile, sleeve axis and radius, hem and collar extent, or the bounding box for rigid pieces. It also stores the mesh as a cell list so the engine never scans pixels. Anything measured can be overridden in `item.json` and pinned so a re-ingest keeps it.

`item_ids` replaces the alias table: the pack says which Items.json ids it dresses.

### 3.4 Runtime

`Characters/rig2/`:

- `rig_fit.gd` (`RigFit`): the fit maths, a line-for-line mirror of `tools/rigkit/core.py`.
- `rig_library.gd` (`RigLibrary`): loads and caches skeleton, race packs with variant inheritance, item packs, and the game-id lookup.
- `rig_character.gd` (`RigCharacter`): `setup(race, variant)`, `wear(id)`, `remove(id)`, `cannot_wear(id)`, `grip(side)`. `wear` builds one textured `Polygon2D` per item side on the spot.

An item that cannot be worn says why (`race naga_male has no leg_l`) instead of vanishing.

### 3.5 Decisions and why

**Rig ownership moves into TFA.** The cross-repo generator made every fix a two-place edit and tied the game's runtime script to a project with no TFA autoloads. The new runtime is ordinary hand-written GDScript in TFA, and the offline tools live in `tools/rigkit/`. The old repo becomes the art workshop and archive. It stays read-only from here.

**Fit at runtime, not at build time.** Baking was the cause of the item x race matrix. The fit is a few hundred vertices of arithmetic at equip time. Cost measured in the headless test: all 52 races dressed in six items in well under a second.

**Frames instead of mesh-to-mesh warping.** I weighed three options:

- Keep per-race baking but automate it better. Rejected: it cannot make variants or new items cheap, whatever the automation.
- Free-form silhouette matching (warp the item until it covers the body). Rejected: it is what the coverage-grow passes already approximate, it distorts art unpredictably, and it cannot be checked by a simple rule.
- Named frames (chosen). Every placement is explainable from two small dictionaries, the same arithmetic runs in Python and GDScript, and a bad fit shows up as a number.

**Held gear stays on the existing weapon system.** `WeaponShape` already sizes art from `total_length` and puts the grip on the holder. Weapons were never the baked problem. The new rig only has to expose `grip(side)`.

**`_l` and `_r` stay image-left and image-right.** All 52 label maps are painted that way. Every pack faces south, so `_r` is the main hand.

### 3.6 Hands

Added 2026-11-27 after the user asked for weapons that are "actually held in the hands rather than just sitting on top of them" and a better glove fit. Sheet: `tools/rigkit/out/hands/hands_sheet.jpg` (before and after, three races). Numbers: `python tools/rigkit/out/hands/compare_gate.py`.

**What was wrong.** The hand was only pixels of `body.png`. A held item was drawn above it, so it lay on the back of an open hand. A glove was one picture stretched onto the hand's bounding box, and one picture cannot match the finger layout of another painting (gauntlets squashed to x0.43, gloves left fingertips bare).

**The design in four rules.**

1. **A hand has a pose.** `open` is the hand the race painting already has. `grip` is a fist. Holding anything closes that hand; so does being the second hand of a two-handed item. More poses later are more entries, not more code.
2. **The fist is one shared greyscale painting** (`Rigs/hands/humanoid/grip.png`, made by the guide method, `tools/rigkit/gen_hands.py`). It is fitted to each race's palm frame and coloured through that race's skin ramp, so every race, variant and re-skin has a fist with no art of its own.
3. **The fist is drawn over the item, and the item's tail goes under the body.** Palm down, a handle is under the hand and a haft runs under the forearm. So the blade comes out past the knuckles and the pommel or spear butt disappears under the wrist. No per-weapon mask is needed.
4. **A glove is the hand that is showing, drawn again in the glove's material,** plus rigid pieces cut from the glove's art (cuff on the wrist, back-of-hand plate on the palm). The fingers are the race's own fingers, or the shared fist, recoloured. That is why a glove covers any hand in either pose with nothing tuned per race.

**New frames** (measured by `derive.py` from the label map, like every other frame):

| Frame | What it is |
|---|---|
| `palm_l/r` | Origin at the wrist seam, forearm axis. `ly` = the hand's half-width (radius of the largest circle inside the hand label, the same trick as the skull); `lx` = distance to the knuckle line. Finger spread, finger count and claws do not move it |
| `wrist_l/r` | Wrist seam, forearm axis, `lx = ly` = half the wrist's width. Glove cuffs sit here |
| `grip_l/r` | Re-defined: the **front of the closed fist**. A held item's hold point lands here |

**New race data** (all written by `build_race`, nothing by hand): `skin` (four tone stops and four colours read off the hands: outline, shadow, mid, light) and `parts.hand_l/r` (the open hand as a list of 2 px cell runs of `body.png`). No new image files per race.

**Held items** (`ingest`, main_hand / off_hand). The item's `grip` frame now sits on its hold point, not on Items.json `grip_position`. On a sword `grip_position` is on the crossguard, so ingest finds the guard in the art's width profile and puts the hold point at its back edge: the guard rests against the knuckles on any size of hand. An item with no guard (spear) is held around its grip point. `item.json` gets a `hold` block: `at`, `handle`, `width`, `offset` (world px between hold point and gameplay grip point), `tail` (`under` | `over`), `layer` (`through` | `over` for shields), `hands` (1 | 2, from Items.json `grip_style`) and, for two-handed items, a `grip2` frame.

**Gloves** (`ingest --slot hands`). `item.json` gets a `hand` block: `ramp` (four colours), `cuts` (wrist and knuckle lines of the art) and `pieces` (`cuff`, `back`; each has its own frame and mesh; either may be absent). The old single-image `hand` frame is kept as the fallback.

**Draw order at a hand:** item tail -1 < body 0 < sleeves 6-9 < held item 15 < fist 16 < gloved hand 17 < glove back 18 < glove cuff 19 < head 20 < items held `over` 21.

**Runtime.** `RigCharacter` draws the body as three polygons on one texture (`Body`, `Hand_l`, `Hand_r`). `wear()` of a held item closes the hand: the open-hand polygon is hidden and `Fist_<side>` shown. Gloves are rebuilt in the new pose. New calls: `hand_pose(side)`, `set_hand_pose(side, pose)` (an empty fist; `""` returns to the rule), `cannot_grip(side)`, `grip_target(item, side)`; `grip(side)` also returns `pose`. Colour goes through one small shader, `Characters/rig2/rig_ramp.gdshader`.

**Why this one.** Three designs were weighed.

| Option | Verdict |
|---|---|
| Squash each race's own painted hand into a fist (no art at all) | Rejected as the base. A prototype read as a fist but was lumpy on the orc, and plate fingers lose all detail. Its ideas kept: palm circle, item under the hand, handle measured from the art |
| A painted fist per race | Rejected as the default: about 50 races times 4 generations, and every new race or new-build variant needs one more. Kept as an override: a race can ship its own hand set (`"hand_set"` in `race.json`) |
| One shared fist coloured per race (chosen) | A new race needs nothing. A new glove needs one picture. The cost is that claws, fur and scales do not show on the closed hand |
| Stretching a glove picture to the hand's silhouette | Rejected: unpredictable, and it cannot be gated by a simple rule |
| Splitting fingers over and under the handle | Not needed: seen from above with the palm down, nothing of the hand is under the handle |

**Results** (gate over all 55 packs; glove cover is 1.00 by construction, because the glove is the hand recoloured, so spill and stretch are the informative columns):

| | Before | After, open | After, gripping |
|---|---|---|---|
| leather_glove cover (worst / median) | 0.74 / 0.87 | 1.00 / 1.00 | 1.00 / 1.00 |
| leather_glove spill (worst) | 0.23 | 0.00 | 0.00 |
| plate_gauntlet cover (worst / median) | 0.81 / 0.91 | 1.00 / 1.00 | 1.00 / 1.00 |
| plate_gauntlet stretch | 0.43 to 1.08 | 0.83 to 1.59 | 0.75 |
| plate_gauntlet WARN rows | 32 of 110 | 0 | 0 |
| Handle inside the hand (longsword / dagger / spear, median) | 0 | | 1.00 / 1.00 / 0.97 |

**Known limits.**

- **Bind pose only.** A two-handed grip cannot be shown in a T-pose. The data (`hold.hands`, `grip2`) and `grip_target()` exist and are untested beyond the measurement; no two-handed item pack exists yet. Phase 2 arm IK has to bring the second hand to `grip2`.
- **The shader is not pixel-checked.** Headless Godot does not render. The parity test checks geometry, layering, the pose rule and that the material is set; the colour maths is mirrored in `core.ramp_colour` and has only been looked at offline.
- **Race character is lost on the closed hand**: the shared fist is smooth skin in the race's colours. Scaled, furred and clawed races get a plain fist.
- **The fist is softer than the paintings** at 4x zoom (a 135 px greyscale picture, re-inked at the rim). At game size it reads cleanly.
- **Gauntlet fingers are recoloured fingers**, not articulated plates. The gauntlet's identity is its cuff and knuckle plate.
- **The glove's wrist and knuckle lines are pinned by eye** for the two existing gloves (`cuts` in `ingest.LEGACY`); the automatic measurement was off on both. That is per item, never per race.
- **The spear's shaft art is as wide as a small fist** (7.1 world px; 18 packs WARN). An item-art problem the gate now lists.
- **Hold point and hitbox.** The hold point is 3 to 4 world px from Items.json `grip_position` (`hold.offset`). Phase 3 must add it back when it places the `WeaponShape` holder, or correct `grip_position`, which would change melee reach and is the user's call.
- **A tail drawn under the body** is also under the torso once arms cross it. Fine in bind pose; phase 2 should move the tail to just under its own arm.
- The automatic gate cannot say whether a hand looks good. Look at the sheet.

## 4. Art spec

### 4.1 The spec

**Camera (approved by the user 2026-11-27).** Orthographic, tilted 15 degrees off vertical toward the character's front. The test: the scalp fills most of the head and the face is a foreshortened strip along its bottom edge (brow, nose tip, front of the jaw), the shoulders are the widest part, the top of the chest and a glimpse of upper belly show, and the legs are shortened so only the feet show under the trunk. Depth is 22-30% of the arm span.

**Method.** Race bodies are not painted from a text description of the camera. `tools/rigkit/gen_plan.py` renders a 3D proxy of the race at this camera and the painting is made over that guide, so every race shares one camera by construction. The guide also supplies the label map. A candidate must match the guide's outline (IoU 0.90 or better) and pass a look at the head.

**Pose.** T-pose, arms straight out, palms down, facing south (toes toward the bottom of the image). Left-right symmetric.

**Canvas.** 1024 px on the long side, body centred. Generated on flat mid-grey, which is keyed out on install.

**Label map.** Same size as the painting, flat colours on black: body, face, hair, upper arm, forearm and hand per side, foot per side, optional leg per side, white for anatomy that sits over clothing. The colours are in `tools/rigkit/derive.py`.

**Items.**

| Slot | How it is painted |
|---|---|
| torso | The garment as seen from straight above on a T-pose body: collar hole in the middle, sleeves out to the sides, back and front both visible around the collar |
| head | From straight above, centred on the skull |
| feet | One foot, toes toward the bottom |
| hands | One open hand from above, fingers toward the right. Only the cuff and the back of the hand are used as art; the fingers give the colour (section 3.6) |
| back | Hanging from the top edge; only the part that shows past the shoulders matters |
| held | Upright, business end at the top (unchanged) |

Two registers stay as they are: painterly for worn gear, outlined cel shading for held gear.

### 4.2 What fails the spec today

**Races.** The label maps give an objective signal: a race whose thighs are visible has a leg label, and thighs are only visible when the camera is well off vertical.

- **34 of 52 packs show legs**, so are painted from a high three-quarter view with the face fully visible: orc, orc_female, half_orc (both), goblin (both), cerebrals (both), draconian (both), goatmen (both), goluna (both), grimalkin (both), kobold (both), naga (both), newt (both), saurian (both), human_undead (both), vampire (both), dhampir (both), human_female, half_elf_female, mephistkin_female, quadrelf_female.
- **18 packs are overhead**: human, elf, halfling (both), gnome (both), dwarf (both), aedelf (both), sobruaro (both), sahuagin (both), half_elf_male, high_elf_female, mephistkin_male, quadrelf_male.

By eye the split is the same, with two caveats. dwarf_male and both aedelf hide their legs but still show the whole face. half_elf_female is a different problem: older clothed art, standing, legs fully drawn.

The practical damage from the three-quarter view is that the head sits in front of the chest rather than on top of the shoulders. Collars cannot close around a neck, helmets drawn from above sit on a face, and the two camera angles look wrong side by side in a crowd.

**Items.** The fit gate measures how much each item's art is distorted to fit a top-down body.

- All nine torso garments are painted as front views. They are squashed to between 45 % and 60 % of their height on most races (the gate reports "art stretched x1.7 to x2.2"). The old pipeline compensated with `ref_aspect`.
- `great_helm`, `plate_sabaton`, `steel_greaves`, `leather_pants` and `armored_leggings` are front or side views.
- `dark_robes` has a flared hem that floats off narrow bodies.

### 4.3 Art redo proposal (needs your approval; nothing has been regenerated)

The Gemini key works again as of this run (it was out of credits on 2026-11-01).

**Batch A: races to the overhead camera.** Regenerate the 34 three-quarter races, image-to-image from their current painting, with the human male as the camera reference. Each needs a new label map (auto-draft plus a pass by eye) and then `build_race`. Order: orc and orc_female first, since they are the named problem and the most common enemy, then half_orc, goblin, human_female and the launch-map races, then the rest.

**Batch B: torso garments from above.** Regenerate the nine garments as true overhead views with a visible back panel: peasants_stained_shirt, nobles_blouse, dark_robes, padded_vest, leather_armor, chain_shirt, legionnaires_armor, breastplate, venonan_vestament.

**Batch C: rigid pieces.** great_helm, plate_sabaton, steel_greaves, and the two pants if legs stay visible on any race after batch A.

**Pilot 1 (2026-11-26, four generations, `tools/rigkit/gen_overhead.py`): rejected.** Both modes copied a reference painting's camera. The user's verdict: "almost the same perspective but with the legs cropped off". The root cause is that the human painting used as the camera reference is itself a high three-quarter view whose face is hidden by hair, so no amount of copying it gives a plan view.

**Pilot 2 (2026-11-27, method bake-off, 29 generations, `tools/rigkit/pilot/`, outputs and `orc_bakeoff_sheet.jpg` in `tools/rigkit/out/overhead2/`).** Four methods were tried on the orc and ranked by three judges (camera, style, rig use).

| Method | Camera result | Verdict |
|---|---|---|
| Wording only ("top-down token", drone, plan view; style swatches only) | Shallow and legless, but 0 of 8 true plan views | Dropped |
| Clay guide (numpy height-map render of a parametrised proxy, painted over) | Silhouette IoU 0.95-0.99 with the guide, depth/span 21-22% (old orc 38%) | Chosen base |
| Blender guide (headless orthographic render, painted over) | Same lock, 6 of 6 plan views | Fallback for odd bodies (tails, wings, four legs) |
| Flat block-out paint-over (PIL shapes) | Same lock; cleanest heads | Its head recipe is adopted |

What was learned:

- **Give the camera, do not ask for it.** A rendered guide that already is the plan view fixes silhouette, arm level, depth and hidden legs every time. A full-body reference painting always drags its own camera along.
- **The model paints a face wherever the guide leaves room for one.** The face goes away only when the guide's skull is a plain dome with at most nose-tip and tusk-tip bumps on its south rim, and the prompt never names brow, eyes or mouth.
- **Naming a feature grows it.** Asking for "five clear toes" grew whole feet and shins.
- **A small skin swatch** (a patch of upper arm from the old painting, never the face or whole body) carries colour and line style without carrying the camera.
- **The guide also yields the label map and silhouette mask for free**, so a repainted race needs no hand-made or segmented labels, and silhouette IoU against the guide is an automatic gate. IoU cannot see a painted-on face, so a zoomed head crop still needs a look.

Still open after pilot 2: finish is softer than the house style in the best-camera images; the head sits a little south of the shoulder line in the clay guide; feet vary between toe tips and stumps; each recipe has only one to four samples. Next step is one merged recipe (clay guide + block-out head + swatch), run several times, before any batch.

**Pilot 3 (2026-11-27, merged recipe, 22 generations, `tools/rigkit/gen_plan.py`, outputs in `tools/rigkit/out/plan/`).** One tool now renders the guide (clay, tint, mask, label map in `derive.py` colours, JSON), generates candidates, and checks them (IoU against the guide, depth/span, symmetry, ground colour, head-crop sheet). Races are entries in its `RACES` dict; orc, human and halfling guides render, only the orc has been painted.

| Set (4 images, one frozen recipe each) | Clean heads | Judges' pass counts (camera / style / rig) |
|---|---|---|
| `final_*`: guide with nose bump and tusks | 0 of 4 raw | 1 / 2 / 2 |
| `v2_*`: nose bump removed, tusks only | 4 of 4 | 2 / 2 / 3 |

- **Removing the nose bump is what removed the face**: a nose between two tusks is read as a face and completed. 8 of 8 noseless images have a plain dome.
- **Cost:** the head is now a ball identified as an orc only by ears and tusks, and the judges disagree on whether that is acceptable.
- **Still open:** toes copy the guide's pegs literally and read as stalks; the chest shelf can read as thighs; outline weight and gloss vary run to run; the crown highlight drifts 11-30 px north; the shoulder label cut sits inside the painted deltoid.
- **Decision needed from the user:** strict 90 degree plan view (ball head, no face) or a small forward tilt rendered into the guide (a sliver of brow and nose, slightly deeper chest). The guide is 3D, so tilt is a parameter.

**Pilot 4 (2026-11-27, 15 degree tilt, 20 generations).** The user rejected the strict plan-view set ("all 4 look kind of insane") and asked for the camera tilted 15 degrees. Two guide renderers were run, a set of four each.

| Renderer | Where | Result |
|---|---|---|
| `gen_plan.py` (numpy, analytic ray cast, `--tilt`, default 15) | `tools/rigkit/out/plan/orc/tilt15_final_*` | Reads as a living orc in 4 of 4; IoU 0.96-0.97, depth/span 27%; 2 of 4 clean, 2 have a pink nose or glossier highlights |
| Blender proxy (`tools/rigkit/pilot/blender_tilt_*.py`) | `tools/rigkit/out/plan_blender/orc/final_*` | Also natural, IoU 0.95-0.96, depth/span 28-29%, but a paunchy build and squat legs; one emerald-ear and one four-toe artefact |

- **An anatomical proxy fixes the odd look at the source.** With a brow, nose and jaw form, one chest mass and real feet in the guide, no image had a ball head, peg toes or a split chest.
- **A true 15 degree view of a full-height figure shows the whole legs** (33-36% depth, about what the old orc has). Both renderers shorten the legs so only the feet show under the belly. This is a stylisation, the same one the existing human painting uses.
- **The model enlarges the face** past the guide's strip (30-40% of the head against a 25-33% target), and nose colour, gloss and outline weight still vary between runs, so expect to pick the best of about four.
- `gen_plan.py` is the chosen renderer; tilt 0 still reproduces the strict plan guide.

**Pilot 5 (2026-11-27, standard approved; 4 generations).** The user approved the 15 degree `gen_plan` look as the standard for every race. Two follow-ups were run and independently reviewed.

*Orc installed in the new rig.* `tools/rigkit/install_plan.py` turns a painted candidate plus its guide into a race pack: it keys the grey ground, snaps the guide's labels to the painted outline, moves the shoulder seam to the armpit, and runs `build_race`. `tilt15_final_3` is installed as `orc/tilt15` (standalone pack, no leg frames; `orc/default` untouched). Sheet: `tools/rigkit/out/plan/orc/tilt15_rig_sheet.jpg`.

| | orc/default | orc/tilt15 |
|---|---|---|
| Fit gate, 25 rows | 22 ok, 3 WARN, 0 FAIL | 18 ok, 7 WARN, 0 FAIL |
| Godot parity test | | 1,210 checks, 0 failures |

Open after the install:

- **Size match needs a decision.** The pack is scaled so fingertip span equals the old orc's. The head then comes out about 27% smaller in game than the old one, because the old painting's head was oversized by its camera. Matching shoulders, arm length or head instead gives a different scale each.
- **Boots and sabatons draw over the lower edge of the belly**: feet items sit above the body layer. Needs the trunk redrawn over feet items or the feet slot clipped to the foot label.
- **Gauntlets squash (x0.43) and gloves leave fingertips bare** on the spread-finger hands. Fixed by the hand rig, section 3.6.
- **The upper-arm frame tilts about 5.6 degrees** because the armpit seam's centre sits below the arm's centre line.
- **Front-view item art is now the main visual problem** (batches B and C): `great_helm` leaves jaw, tusks and ears out; shirt, vest and robes stretch x1.7 to x1.9; the breastplate collar reads as a wide ring.
- **Variant inheritance leaks frames**: a new-build variant that uses `inherits` keeps the parent's leg frames (section 3.2 recipe). Not fixed; the pack avoids it by being standalone.
- The parity fixture has no vertex samples for `orc/tilt15` yet.

*Second race.* Human and halfling tilted guides now pass the depth band (0.257 and 0.276), and a goblin entry was added and painted (`tools/rigkit/out/plan/goblin/tilt15_pilot_*`, 4 of 4 pass the gate, IoU 0.94-0.99, depth/span 0.277 against the orc's 0.270). Camera matches the orc. Style holds in 2 of 4 (best `tilt15_pilot_1`). Open: the goblin came out muscular, not wiry; its big head and ears cover most of the chest and shoulder tops, so torso items will have little visible area; eye sockets are large dark hollows. The halfling's face strip is very thin under the fringe, so its first painting is a risk. Guides side by side: `tools/rigkit/out/plan/tilt15_guides_sheet.jpg`.

**Pilot 6 (2026-11-27, 28 generations; three tracks, each independently reviewed).** After seeing the installed orc the user said the head was too small, agreed that front-view item art is the main visual problem, and asked for the hands to be rigged properly (section 3.6).

*Head size.* `gen_plan.py` has a `head_scale` knob that scales the whole tilted head together, and a `headsize` command that reads the legacy pack's head frame. **Convention: a repainted race keeps its legacy in-game head size.** The orc was repainted with `head_scale=1.362` and installed as `orc/tilt15_head` (best of four: `tilt15_head_3`; one of four matched the house style). Head radius in world px: default 14.11, tilt15 10.34, tilt15_head 14.12. Fit gate same as `orc/tilt15`. Sheet: `tools/rigkit/out/plan/orc/tilt15_head_rig_sheet.jpg`. Cost: visible trunk area drops 19%, to about the old orc's; guide depth/span is 0.290 against a 0.30 ceiling. The tracked orc `guide_t15*` files are now the big-head guide; `orc/tilt15` is reproducible from its `tilt15_final.guide*` snapshot.

*Top-down item art.* `tools/rigkit/gen_item.py` renders an item shell on the same proxy and camera as the races (torso garment: trunk plus upper arms with a keyed neck hole; helm: shell round the head), paints over it on a blue ground, and takes the item's frames from the proxy's own anatomy, not from the art. Three items were piloted as new packs beside the originals: `peasants_stained_shirt_td`, `breastplate_td`, `great_helm_td`. Sheet: `tools/rigkit/out/items_td/pilot_sheet.jpg`.

| Across all 55 packs | Old (ok / WARN / FAIL) | `_td` |
|---|---|---|
| Shirt | 18 / 34 / 3, median stretch 1.87 | 52 / 2 / 1, median stretch 1.07 |
| Breastplate | 42 / 12 / 1 | 50 / 4 / 1 |
| Great helm | 55 / 0 / 0 | 55 / 0 / 0 |

Open: ears stick out of the great helm on big-eared races (needs a rig rule: a full helm hides head pixels outside it); the `_td` breastplate came out bluer and brighter than the original and reads as a muscle cuirass with shoulder caps, so it is a different-looking item; plate needed a corrective round (1 of 4 clean); the shell copies the orc proxy's build; robes, long sleeves and layering are untested; `human/default` has an abnormal torso frame that loses cover. The items table in 4.1 changes for worn gear: painted over the item guide at the race camera, not "from straight above".

*Hands.* See section 3.6. Sheets: `tools/rigkit/out/hands/hands_sheet*.jpg`. Glove and gauntlet spill fell from 0.23 / 0.17 worst case to 0.00 / 0.01, gauntlet WARN rows from 32 of 110 to 0, and held handles sit inside the fist (median share 1.00 sword and dagger, 0.97 spear). The reviewer found and fixed a shader bug that would have drawn fists and gloves 35-50% too dark in engine. Not yet seen in engine: a full character render with the new hand path.

I recommend finishing the pilot before any batch: one orc and one shirt you are happy with, reviewed on a contact sheet against the current art. If batch A is approved, most `leg` frames disappear and the legs slot can be retired for bipeds.

## 5. Migration plan

The game keeps running at every step. The old rig stays the default until phase 4.

| Phase | What | State |
|---|---|---|
| 0 | Survey, design, format | Done |
| 1 | Skeleton, race packs, item packs, fit, previewer, gate, bind-pose runtime, parity test | Done (this branch) |
| 2 | Posing and animation on `RigCharacter`: a real `Skeleton2D` built from the frames, body mesh skinned by label, the 12 clips retargeted from bone names, arm IK, foreshortening | Not started |
| 3 | Switch: a `rig2` project setting; `ProceduralCharacter` routes `_setup_character_rig` and `_rig_show_wearable` to `RigCharacter` when it is on; port `spawn_clothing_check`, `wearable_strip_check`, `orc_rig_check`, `RigProbe` | Not started |
| 4 | Port the remaining items (19 part pieces, Skaarsgaardian gear), flip the default, soak | Not started |
| 5 | Delete `RigCharacters/` (374 MB), `skeletal_body_rig.gd`, `body_part_sprites.gd` for rigged races, `scripts/extract_body_parts.py`, the alias tables, and collapse the slot tables into `skeleton.json` | Not started |

Phase 2 is the largest remaining piece. Its main risk is the Godot mixer bug with nested `Bone2D` tracks that the old rig works around in `_fix_bone_tracks`. The plan is to drive bones from code (sampling clip data directly) rather than through `AnimationPlayer` tracks, which removes that bug class instead of repairing it each frame.

Art batches A to C are independent of phases 2 to 5 and can run in parallel once approved, because a regenerated race is only a new `body.png` and `labels.png`.

## 6. Verification plan

**Fit gate** (`python -m tools.rigkit.check`). For every race and item it renders the fitted item alone and compares it with the label map.

| Measure | Meaning | Catches |
|---|---|---|
| cover | share of the anatomy the item should hide that it does hide | skin showing, cut-off or undersized items |
| spill | share of the item lying well outside its silhouette | floating, oversized |
| stretch | along-to-across distortion applied to the art | art that fails the spec |
| clipped | the item ran off the canvas | cut-off art |
| frames | the race has every frame the item needs | anchor coverage |
| gripped | share of a held item's handle hidden inside the closed hand | a weapon lying on the hand |
| visible | share of a held item that still shows | a dagger swallowed by a big fist |

Gloves get one row per side per hand pose (open, grip).

It exits 1 on any FAIL. Thresholds are one table in `check.py`.

**Contact sheets** (`python -m tools.rigkit.sheet`). Every race by six outfits that between them use every slot, rendered with the same mesh and the same arithmetic as the engine. `--frames` draws each race's derived anatomy over its painting, which is the fastest way to spot a bad label map.

**Engine parity** (`tests/rig2_parity_test.tscn`, headless). `RigFit` must place every vertex where `core.py` placed it, every race pack must carry the required frames and art, and `RigCharacter` must build a dressed character for every race with the right node count and z order.

**Still to add in phase 2.** Posed contact sheets (idle, walk, swing), and a windowed off-screen capture compared against the offline render.

## 7. What was verified on this branch (2026-11-26 run)

| Check | Result |
|---|---|
| Legacy import | 52 of 52 race packs built from their label maps, no failures |
| Fit gate, 53 packs x 21 items | 1,325 pairings: 1,002 ok, 261 WARN, 62 FAIL. Report: `tools/rigkit/out/fit_gate.txt`, `fit_report.json` |
| Godot parity test (headless) | 1,196 checks, 0 failures; worst vertex error 0.0007 px over 150 pairings |
| Mutation check | Changing `BLEND_FRAC` in `rig_fit.gd` gives 36 failures, so the test does detect drift |
| Variant | `orc/ashen` builds and dresses from a `body.png` and a four-line `race.json` |
| Game | No existing file changed. A headless `--import` reported only the two known addon errors |

Where the 62 failures are: 40 are `plate_sabaton` (side-view art squashed onto a foot), 9 `dark_robes` (flared hem), 8 `human_undead_male`, 5 other.

Contact sheets for every pack are in `tools/rigkit/out/outfits_01..05.jpg` and `frames_01..04.jpg`.

**Known problems in the fit itself, not the art.**

- The torso's front depth is measured from the body label only. On hunched races the head label covers the chest, so the depth comes out shallow (`human_undead_male`: every garment is flagged as distorted). Measuring the trunk under the head as well should fix it.
- Thick hair inflates the skull circle (high_elf_female, mephistkin_female: helmets too large), and long beards pull hoods down (dwarf_male).
- Rigid sleeveless armour does not reach the upper back on overhead races (human in `legionnaires_armor` covers 71 %).
- No arm-over-garment depth split yet: in bind pose the arms never cross the trunk, so this only matters once posing lands.
- Held gear whose art is wider than tall is not handled by ingest (the game auto-rotates it).
- Rendering a full set of sheets takes about 20 minutes; the renderer is not optimised.

## 8. Commands

```bash
python -m tools.rigkit.import_legacy            # one-time: old generator -> race packs
python -m tools.rigkit.build_race [race/variant] # re-derive frames after editing labels
python -m tools.rigkit.ingest <id> <art.png> --slot <slot>
python -m tools.rigkit.ingest --legacy          # the starter catalogue
python -m tools.rigkit.check [--races a,b] [--items x,y] [--list]
python -m tools.rigkit.sheet --out <dir> [--frames]
python -m tools.rigkit.gen_hands guide|gen|check|install   # the shared fist (section 3.6)
python -m tools.rigkit.hands_sheet              # hand cases, arm view and zoom, before/after
python -m tools.rigkit.export_parity            # refresh the Godot test fixture
godot --headless --path . res://tests/rig2_parity_test.tscn
```

Run them from `tfa-simultaneous-gemini-1/`. Sheets default to `tools/rigkit/out/`, which Godot ignores.
