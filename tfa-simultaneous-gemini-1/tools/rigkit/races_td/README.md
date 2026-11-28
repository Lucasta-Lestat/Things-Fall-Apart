# Race specs for `gen_plan`

One JSON file per race to repaint: `<race>.json`, where `<race>` is the folder name in `Rigs/races/`.
`tools/rigkit/gen_plan.py` holds no per-race data; everything a painter tunes is here.
`<family>_base.json` files (`"abstract": true`) hold what `x_male` and `x_female` share; a spec names
its base with `"base"` and only lists what differs.

**The standard** (docs/rigging_rewrite.md 4.1): orthographic camera tilted 15 degrees off vertical
toward the character's front, T-pose, palms down, facing south. The scalp (or hair) fills most of the
head and the face is a foreshortened strip on its bottom edge; shoulders widest; legs shortened so
only the feet show under the belly; matte painterly finish, thin crisp dark contour. Reference look:
`tools/rigkit/out/plan/orc/tilt15_final_3.png`, `tilt15_head_3.png` (installed as
`Rigs/races/orc/default`; the old orc is `orc/legacy`). The camera is the same for every race and is not a spec field.

**A repaint must stay recognisably the same race and character as its legacy painting** (skin colour,
hair colour and style, horns, ears, tail, markings, build, sex), keep its legacy in-game head size
and its legacy fingertip span. Only the camera changes.

## Commands

Run from the project folder. Outputs go to `tools/rigkit/out/plan/<race>/`.

```bash
python -m tools.rigkit.gen_plan list                              # specs and their features
python -m tools.rigkit.gen_plan guide --race R                    # guide_t15_{tint,clay,mask,labels,core}.png, .json, swatch.png
python -m tools.rigkit.gen_plan prompt --race R [--note "..."]    # print the prompt, no API call
python -m tools.rigkit.gen_plan gen --race R --n 4 --tag r1 [--note "..."]   # paint (GEMINI_API_KEY), then check
python -m tools.rigkit.gen_plan check --race R --tag r1           # r1_check.json, r1_heads.png, r1_<n>_iou.png
python -m tools.rigkit.gen_plan sheet --race R --tag r1           # r1_sheet.jpg, the candidates stacked
python -m tools.rigkit.gen_plan headsize --race R                 # head frame against the legacy pack
python -m tools.rigkit.install_plan tools/rigkit/out/plan/R/r1_2.png --race R --variant tilt15   # size matched to R/legacy if it exists, else R/default
python -m tools.rigkit.gen_plan compare --race R                  # compare.jpg: legacy painting vs the repaint
python -m tools.rigkit.promote_race R                             # once approved: tilt15 -> default, old default -> legacy
python -m tools.rigkit.gen_plan allguides [--fresh]               # out/plan/all_guides_sheet.jpg
```

- Use a NEW `--tag` for every `gen` run (`r1`, `r2`, ...). A tag snapshots the guide it was painted on
  (`<tag>.guide*`, `<tag>.in1_guide.png`), so `check` and `install_plan` always use the right guide even
  after the spec changes. Re-using a tag overwrites its candidates.
- `gen` logs its calls in that race's own `calls.json`. Nothing is shared between races, so painters
  can run in parallel. **Edit only your own race's file.** A `_base` file is shared with the other sex:
  to change a shared value, set it in your own file (your file wins).
- `install_plan` writes a standalone pack `Rigs/races/R/tilt15/` beside `default`, touches no other
  pack, uses no shared temp files and does not run Godot (new PNGs are imported once, at the end, by
  the integrator). `--debug DIR` writes label overlays for a look.
- `compare` writes `tools/rigkit/out/plan/R/compare.jpg`: legacy `default` against `tilt15` at the same
  world scale (chosen so the legacy span fills the tile), bare and wearing shirt, leather armour + kettle helm, great helm, robes + hood, boots
  (`leather_boot`), gloves + a gripped longsword, with a zoomed head pair on top.
- `--note` adds one positive sentence for a single run. A lasting sentence goes in the spec's `"note"`.
- `python -m tools.rigkit.draft_td R --force` re-drafts a spec from the legacy pack and THROWS AWAY
  hand edits. It was the one-time bootstrap; do not run it on a spec you have tuned.

## Notes for painters

- `goblin.json` and `halfling.json` are the pilot specs and serve as bases (`"abstract": true`); paint
  `goblin_male`, `goblin_female`, `halfling_male`, `halfling_female`. `orc` is done (promoted: `orc/default`).
- Pale grey races (goluna, silver or white hair, ashen skin) are as grey as the ground. `check` and
  `install_plan` use the guide silhouette to keep grey paint that the contour line encloses, so the
  contour must be closed all the way round: look at `<tag>_<n>_iou.png` for blue holes.
- After `install_plan`, read its output: `head: label snapped ... (area x0.9 to x1.1)` is normal, `head snap
  rejected` means the face/chest boundary was not found (try another candidate or `--no-head-snap`);
  `derived 18 frames` is the full set (14 = a hand could not be measured, look at the pack's `notes`).
  `compare` prints each pack's head frame radius in world px: the two should agree within about 7 %.
- `naga_male`: the legacy pack's world scale is 0.0594 (59 world px span; `naga_female` is 156), so its
  hands are drawn wider than the draft to keep the grip pose. If a painting loses it
  (`palm not measurable` in the pack's notes), raise `palm_rx` / `palm_ry`.
- `half_elf_female`'s legacy painting wears a cloth chest band; the spec's `note` keeps it.

## What the gates measure

| Gate | Rule |
|---|---|
| IoU | Painted silhouette against the guide's, whole figure, 0.90 or better |
| depth / span | Measured on the **core figure** only: trunk, skull and face (with snout and beard), arms, hands, legs and feet. Tails, wings, back fins, crests, horns, upright ears, hats, hair caps and hanging hair are left out (`guide_t15_core.png` is that mask; in a painting, pixels within 14 px of a guide appendage and off the core are left out the same way). Band 0.22 to 0.30, or the spec's `depth_band` |
| symmetry | Also on the core figure, so a tail to one side does not fail it |
| ground | Flat mid-grey, RGB 128 |

`depth_band` exists because of the head-size rule: a race whose legacy head is very large (cerebrals,
small folk) has a core figure deeper than 0.30 at the standard camera. The draft widened the band for
those and says so in `notes`. It is never a licence to change the camera.

The gates cannot see style. LOOK at `<tag>_heads.png` and the candidates themselves. Usual misses:
gloss, heavy outline, off-colour noses, an enlarged face, over-muscling. Expect 1 or 2 good in 4.

## Head-size rule

`derive.py` fits helmets to the head frame: the largest circle inside the face + hair labels. On a
haired race that circle is on the **hair mass**, in the legacy pack and in the guide alike.
`head_scale` is solved so the guide's circle is the same share of the fingertip span as the legacy
pack's, so after `install_plan` (which matches fingertip span) a helmet has exactly the world size it
has today. The skull under the hair is smaller: `cap.thick` is the hair cap's radius over the skull's.
To make the hair bigger without growing the face, raise `cap.thick` and lower `head_scale` until
`gen_plan headsize --race R` prints `in_game_head_now_vs_legacy` 1.00 again. Known cost: on thick hair
(high elf, mephistkin woman, dwarf, gnome caps) helmets are as oversized as they are today.

## Fields

Proportions are in half-span units (fingertip to body centre = 1.0). `anat` holds values that apply
to the tilted guide only and win over the top-level ones.

| Field | Meaning |
|---|---|
| `base` | Another spec this one is laid over (`anat`, `features`, `colours`, `swatch` merge key by key) |
| `pack` | The legacy pack this spec repaints, `race/variant` (default `<name>/default`): source of the head size and the swatch |
| `shoulder_half`, `delt_r` | Half shoulder width; deltoid radius |
| `trunk_depth_n`, `chest_depth_s`, `belly_depth_s`, `belly_half`, `pec_half` | Upper back depth; chest and belly depth to the front; belly and pectoral half-widths |
| `upper_arm_r`, `forearm_r` | `[radius at the near end, at the far end]` |
| `elbow_x`, `wrist_x` | Joint positions along the arm |
| `palm_rx`, `palm_ry`, `finger_r` | Hand |
| `foot_x_tilt`, `foot_w`, `toe_y_tilt`, `leg_r`, `foot_len` | Feet: sideways position, half width, how far the toes reach south, leg radii |
| `foot` | Non-human foot: `{"kind": "claw" / "hoof" / "paw", "toes": 3, "toe_len": 1.25, "spread": 0.34, "claw": 0.5}` (`claw` 0 = blunt toe tips, 1 = points) |
| `feet` | `false` = no legs or feet at all (a serpent body is then a thick `tail` feature) |
| `skull_r`, `head_z`, `head_fwd`, `jaw`, `brow`, `nose_tilt`, `face_scale`, `face_fwd` | Head: skull radius, height, forward carry, jaw and brow size, nose `[extra reach, radius factor]`, face-form size and forward offset |
| `head_scale`, `head_pivot_z`, `head_back` | The head-size rule (above); the height the head scales about; slide the head north (+) or south (-) |
| `cap` | A cap over the skull: `{"thick": 1.4, "label": "hair" / "face", "colour": <colours key>, "wide": 1, "deep": 1, "tall": 0.8, "fwd": .., "up": ..}`. Hair, a hat, a toadstool cap (`label: hair`) or an oversized cranium (`label: face`). It grows up and back from the skull so the face strip stays visible |
| `ear_len`, `ear_tilt` | Sideways ears: length; `[root radius, tip sweep back, tip rise]` (negative rise = drooping) |
| `tusk`, `tusk_x_tilt` | Tusk length and sideways position |
| `skin`, `hair`, `ivory`, `colours` | Guide tints, RGB. `colours` is `{name: [r, g, b]}` for feature colours (`horn`, `hat`, `beak`, `wing`, `beard` ...) |
| `swatch` | `{"src": legacy body.png, "box": [x0, y0, x1, y1]}`: a patch of UPPER ARM only, shown to the model for colour, texture and line. Never the face or the whole body (a body reference drags its own camera along). Furred and scaled races: the box must show the fur or scales. Check `swatch.png` after `guide` |
| `depth_band` | `[lo, hi]` for this race's core depth / span gate (default 0.22 to 0.30) |
| `features` | The proxy forms beyond the plain humanoid, see below |
| `notes` | Free text for people; the tool ignores it |

### Prompt words

Positive phrasing only: name what is there, never what is absent. Naming a feature grows it, so name
each thing once, at the size the guide has it.

| Field | Where it goes |
|---|---|
| `look` | "Paint over this exact sculpt to make a finished game character: ..." The one-sentence identity: sex, race, skin, hair, build |
| `dome`, `dome_cover_tilt` | What most of the head is from above ("cap of short black hair"), and its one-word name for the highlight sentence |
| `face_tilt`, `face_paint` | What the face strip of the sculpt is; how to paint the head |
| `torso_tilt`, `torso_paint` | What the torso of the sculpt shows; how to paint it |
| `arms_paint`, `hands_paint` | Shoulder band and arms; hands. Defaults name full muscles and five fingers with nails: slim, furred and scaled races override them |
| `feet_tilt`, `feet_paint` | The feet sentence of the sculpt; how to paint them (hooves, claws, paws) |
| `finish`, `swatch_of` | Surface ("chalky matte skin", "matte short fur"); what the swatch shows ("skin", "fur", "scaled skin", "feathers") |
| `skin_words`, `line_words` | Hue of the skin and of the contour line, for the swatch sentence |
| `symmetry_words` | Default "left-right symmetric"; races with a tail to one side say "the body left-right symmetric" |
| `note` | Extra positive sentence(s) appended to every prompt of this race |

Each feature adds its own `guide` sentence (what that form of the sculpt is) and `paint` phrase;
both can be overridden inside the feature.

## Features

`"features": {"<name>": {<knobs>}, ...}`. The preset is `"kind"` (default: the name). Every knob
has a default (`tools/rigkit/plan_features.py`, `PRESETS`), so `"beard": {}` works. In a spec with a
`base`, `"<name>": null` removes the base's feature. Common knobs: `label` (which label the pixels
get), `colour` (a `colours` key), `core` (counts for the depth gate), `guide`, `paint`.

Head features are in **head units**: x = image right, y = toward the character's front (image
bottom), z = up, origin at the centre of the skull, 1.0 = `skull_r`. They scale with `head_scale`.
Body features are in half-span units; the shoulders are at z = 1.56, the floor at 0.70.

| Kind | Space | Label | Core | Knobs (defaults) |
|---|---|---|---|---|
| `horns` | head | face | no | `style` swept / up / ram / wide, `len` 1.8, `r` [0.22, 0.03], `root` [0.55, -0.25, 0.95], `count` 1 (pairs), `gap`; or set `dir`, `toward`, `curl` (degrees) yourself |
| `ears_up` | head | face | no | Upright cat ears: `root`, `dir`, `len` 1.3, `r` [0.5, 0.05], `flat` |
| `snout` | head | face | yes | `len` 1.0, `r` [root, tip], `droop` 0.35, `root` |
| `beak` | head | face | yes | As snout, pointed; colour `beak` |
| `crest` | head | face | no | Row of spines or a fin along the scalp: `count` 5, `h` 0.45, `w` 0.07, `start` / `end` as [y, z] |
| `ring` | head | face | yes | A ring of lumps round the head (ruff, frill): `count`, `radius`, `size`, `z`, `arc` [from, to] in degrees, 0 = front |
| `hair_bushy` | head | hair | yes | A `ring` in hair: an uneven mane round the cap |
| `hair_long` | head | hair | no | Hair spread over the shoulder tops and upper back: `width` 1.7, `depth` 1.0, `back` 0.9, `drop`, `thick` |
| `locks` | head | hair | no | A lock or braid over each collarbone: `x`, `len` 1.1, `fwd` [start, end], `r` |
| `ponytail`, `bun` | head | hair | no | `root` / `end` / `r`; `at`, `size` |
| `beard` | head | hair | yes | `len` 1.0, `width` 0.85, `depth`, `at` |
| `hat_cone` | head | hair | no | A tall pointed cap: `len` 3.0, `lean` 0.8, `r`; colour `hat` |
| `tail` | body | over_garment | no | On the floor, out past the back, curling to one side: `len` 0.9 (of the curl), `r` [0.07, 0.012], `curl` 120 (degrees), `side` +1 image right / -1 left, `root_y`; `tip` 0 = a further run after the curl (with `curl` 180 it comes forward past the arm to the feet), `tip_curl` degrees that run bends (+ away from the body, - toward it), `taper` 1 (above 1 the tail stays thick longer) |
| `wings` | body | over_garment | no | Folded on the upper back: `x`, `y`, `z`, `r` [3], `fan` (tail feathers) |
| `dorsal_fin` | body | over_garment | no | Fin or spine ridge down the upper back: `y` [from, to], `h` 0.14, `w` 0.014, `count` |
| `arm_fins` | body | forearm | yes | `at` 0.5 (along the forearm), `size` 0.07 |
| `bust` | body | body | yes | `size` 1.0: a soft swell on the chest of a female build |
| `blob`, `rod` | either | any | yes | Raw shapes: `{"kind": "blob", "space": "head", "at": [x,y,z], "r": [rx,ry,rz], "mirror": true}`, `{"kind": "rod", "a": [..], "b": [..], "r": [r0, r1], "kz": 1}` |

`over_garment` (white in the label map) is anatomy the rig draws again ABOVE worn items: tails,
folded wings, back fins. It matches what the legacy label maps do (naga_male and newt_female tails,
goluna_male wings, sahuagin and saurian_male back fins). Head features (`face`, `hair`) are drawn
above collars and capes and are hidden by enclosing helms.

The model copies the guide literally. If a painting lacks a feature or has it at the wrong size, fix
the guide (the knob), not the wording.
