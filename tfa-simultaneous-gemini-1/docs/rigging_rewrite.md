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

`Rigs/skeleton.json` lists the frame names every race shares: `torso`, `back`, `head`, `upperarm_l/r`, `forearm_l/r`, `hand_l/r`, `grip_l/r`, `foot_l/r`, and optional `leg_l/r`.

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
| feet, hands | rigid, authored once and mirrored | foot / hand | free |
| back | rigid, hangs from the trunk's rear edge | back | uniform, from shoulder span |
| main_hand, off_hand | rigid | grip | world: keeps the item's authored world size |

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

## 4. Art spec

### 4.1 The spec

**Camera.** Straight down, tilted at most about 15 degrees toward the front. The test: the crown of the head is the middle of the head, the face is hidden or reduced to brow and nose tip, the shoulders are the widest part, and the legs are hidden under the trunk with only the toes showing.

**Pose.** T-pose, arms straight out, palms down, facing south (toes toward the bottom of the image). Left-right symmetric.

**Canvas.** 1024 px on the long side, body centred, flat mid-grey background, soft contact shadow allowed.

**Label map.** Same size as the painting, flat colours on black: body, face, hair, upper arm, forearm and hand per side, foot per side, optional leg per side, white for anatomy that sits over clothing. The colours are in `tools/rigkit/derive.py`.

**Items.**

| Slot | How it is painted |
|---|---|
| torso | The garment as seen from straight above on a T-pose body: collar hole in the middle, sleeves out to the sides, back and front both visible around the collar |
| head | From straight above, centred on the skull |
| feet | One foot, toes toward the bottom |
| hands | One hand, fingers toward the right |
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
python -m tools.rigkit.export_parity            # refresh the Godot test fixture
godot --headless --path . res://tests/rig2_parity_test.tscn
```

Run them from `tfa-simultaneous-gemini-1/`. Sheets default to `tools/rigkit/out/`, which Godot ignores.
