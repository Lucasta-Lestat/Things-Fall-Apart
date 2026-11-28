# Item specs for `gen_item`

One JSON file per worn item: `<item>.json`, where `<item>` is the id of the ORIGINAL pack in
`Rigs/items/`. `tools/rigkit/gen_item.py` holds no per-item data; everything a painter tunes is here.

```bash
python -m tools.rigkit.gen_item list
python -m tools.rigkit.gen_item guide   <item>                 # guide.png, guide_mask.png, swatch.png, guide.json
python -m tools.rigkit.gen_item prompt  <item>                 # print the prompt, no API call
python -m tools.rigkit.gen_item gen     <item> --n 4 --tag r1  # paint (GEMINI_API_KEY), then check
python -m tools.rigkit.gen_item check   <item> r1              # r1_check.json, r1_sheet.jpg, r1_<n>_iou.png
python -m tools.rigkit.gen_item install <item> tools/rigkit/out/items_td/<item>/r1_3.png --id <item>_td
python -m tools.rigkit.gen_item sheet   <item>                 # <item>/compare.jpg: original vs <item>_td
python -m tools.rigkit.gen_item promote <item>                 # <item>_td becomes Rigs/items/<item>
```

Outputs go to `tools/rigkit/out/items_td/<item>/`. `install` writes `Rigs/items/<item>_td/`
(`art.png`, `item.json`); a new `art.png` needs a Godot `--import` pass before the engine can load it.

`promote` moves the `_td` art, frames and mesh into `Rigs/items/<item>/`, which keeps its id, layer
and `item_ids`, deletes the `_td` pack, and files the old art as
`tools/rigkit/out/items_td/<item>/original.png`. From then on that file is "the ORIGINAL art" for the
swatch, `ground: auto`, the guide tint and `tone_match`. `ingest --legacy` skips promoted packs.

A repaint must be recognisably the SAME item as the original (same materials, colours, trim and
design), only seen from the race camera. Prompt text is phrased positively only: name what is
there, never what is absent.

## Fields

| Field | Meaning |
|---|---|
| `shell` | `torso`, `bucket`, `brim`, `open`, `hood` or `foot`. Sets the slot (torso / head / feet) |
| `swatch.box` | `[x0, y0, x1, y1]` crop of the ORIGINAL `Rigs/items/<item>/art.png`: the material reference shown to the model, the source of `ground: auto`, and the target of `tone_match`. Pick a patch of the main material with as little empty background as possible |
| `ground` | `auto` (default), `blue`, `green` or `magenta`: the key colour. `auto` = the key hue farthest from the swatch's hues; a colourless swatch (steel, black cloth) gets green |
| `tint_pct` | Luminance percentile of the original art the guide's flat tint is read above (default 65). Lower = a darker guide |
| `tone_match` | 0..1 (default 0). At install, pull the painting's mean colour and contrast (Lab) toward the swatch. Use it when a repaint drifts lighter, darker or tinted |
| `encloses` | `true` = while worn, the wearer's whole head is hidden (ears, jaw, tusks, nose). For helms and hoods that cover the face. Default false |
| `what`, `reads`, `look`, `paint`, `material` | The prompt's words: what the block-out is; how to read its forms; the finished item; how to paint it; the swatch's material. A string or a list of strings (joined). `{ground}` becomes the key colour's name |
| `hole_words` | Appended where the prompt names what the ground fills, e.g. `" and the round neck opening"` |
| `note` | Extra positive sentence(s) appended to the prompt (`gen --note` adds one more for a single run) |

### `torso` knobs

| Knob | Meaning |
|---|---|
| `build` | `neutral` (default): a smooth tailor's form of the proxy's proportions. `proxy`: the proxy race's own muscles (the accepted shirt pilot) |
| `sleeve` | `sleeveless`, `short` or `long`. Sets the item's frames: torso; + upper arms; + forearms |
| `layer` | 1..4, the torso draw layer (shirt 1 ... plate 4) |
| `inflate` | Clearance of the shell over the body, in half-span units (0.012 plate ... 0.020 padding) |
| `hole_clear`, `ring_r`, `hole_y` | Neck opening: radius beyond the neck, thickness of the collar ring, shift toward the front (+) |
| `sleeve_cover` | Share of the upper arm (short) or of the whole arm (long) the sleeve reaches |
| `sleeve_inflate`, `sleeve_taper` | Looser sleeve; sleeve that widens toward the cuff (0.25 = a quarter wider at the cuff) |
| `cap_x` | Sleeveless only: trunk forms further out than this share of the half shoulder width are dropped (1.01 = keep the shoulder caps, 0.62 = plate without them) |
| `clip_half` | Sleeveless only: cut the piece square at this share of the half shoulder width (straight arm holes) |
| `hip_wide` | Widen the trunk forms below the chest by this much (world units, 0.07 on the breastplate): a lower rim that flares over the hips. Raises cover on long-bodied legacy packs; above about 0.08 thin races WARN on spill |
| `flange` | Needs `clip_half`: draw a rolled band this wide (0.05) down each arm-hole edge, lighter than the plate and set off by a dark groove |
| `rim_steps`, `rim_step` | Draw the lower rim as this many stepped bands (2), each `rim_step` wide (0.024) |
| `skirt` | A robe: `{"hem": 0.02, "flare": 0.02, "wide": 0, "front": 0, "top": 1.0}`. A wall from the hips to `hem` above the floor, hugging the body footprint; `wide` / `front` push it out, `flare` widens it toward the hem |

### Head knobs

| Shell | Knobs |
|---|---|
| `bucket` | `pad` |
| `brim` | `pad`, `brim` (brim radius over the crown's), `brim_drop`, `brim_slope`, `brim_thick`, `crown`, `forward`, `ridge` (0 = none) |
| `open` | `pad`, `spikes` (count), `spike_len`, `spike_rise`, `spike_gap_deg` (front arc left free), `spike_base` (where a spike is rooted, as a share of the dome's radius: default 0.92 = inside the dome, 1.02 = on its surface, needed for steep upright spikes with `spike_rise` 4+), `cheek` (0 = none; size of the cheek guards), `cheek_in` (above 0: the guards become plates that curve in round the face toward the centre line, stopping `cheek_gap` x the head's half width short of it; `cheek` 1.8 = bands with eye gaps, 2.6 = a solid apron), `nasal` (0 = none; thickness of a nasal bar from the brow), `ridge` |
| `hood` | `pad`, `wide`, `drape` (cloth on the nape, 0 = none), `peak` (0 = round), `opening` (width of the dark face opening) |

### `foot` knobs

`inflate`, `cuff` (height, 0.10), `cuff_wide`, `cuff_open` (share of the cuff's top that is open),
`toe_point` (0 round ... 1 long point), `toe_reach`. One boot, painted on the image-left foot; the
rig mirrors it. The cuff's open top is ground and is keyed out, so the wearer's leg shows through it.

## What the guide fixes and what it does not

- Frames are NOT read from the painting. They are the proxy's own anatomy, written to
  `guide.json` and copied into `item.json` by `install`. Changing a shell knob never moves a frame;
  it only changes what the painter sees. A painting that leaves the guide's outline is therefore
  misplaced on the body: keep IoU high (0.95+ on the pilots).
- `check` measures the painting against the guide with the same key `install` uses.
