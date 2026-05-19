"""Gemini prompts for generating hex terrain tiles in the Jacana portrait style.

These are stylistic siblings of the JACANA_STYLE block in
``generate_character_icons.py`` — vintage 1980s AD&D module aesthetic, heavy
halftone newsprint grain, dirty muted palette of dusky purples, deep teals,
mossy greens, ochres and ink-blacks — but reframed for top-down terrain
tiles that have to mosaic together on a hex grid.

How to use:
    from hex_tile_prompts import build_hex_prompt, TERRAIN_PROMPTS
    prompt = build_hex_prompt("forest")
    # feed `prompt` to gemini-2.5-flash-image (with the Jacana icon as
    # style reference) or to imagen-4.0-ultra-generate-001 (text-only).

Generation recipe (pairs cleanly with the existing
``generate_character_icons.py`` plumbing):

  * Render at 1:1 aspect, ~1024px square, then downsample to the in-game
    tile size (e.g. 256px).
  * Apply a hex alpha mask in code (pointy-top or flat-top to match the
    Godot tilemap), with a 1-2px feathered edge. The prompt asks the model
    to keep the visual content within the central ~80% so the mask never
    crops a salient feature.
  * If you want hard-edge variants for terrain transitions (e.g. forest-
    edge tiles), generate the base tile and the transition tile from the
    same seed/prompt with the transition variant appended — see
    ``EDGE_VARIANTS`` below.

WHY THIS APPROACH TILES CLEANLY:

  1. The style block forbids directional lighting, painted vignettes,
     borders, frames, page-edge effects, sky horizons and labels — all
     things that would betray a tile boundary when six identical hexes
     sit next to each other.
  2. It pins the camera as a strict top-down orthographic survey so
     neighboring hexes share the same projection.
  3. It asks for the dominant terrain colour to bleed all the way to the
     canvas edge with no rim-darkening, so abutting tiles meet on matching
     hues. Salient features (trees, boulders, gravestones) are clustered
     in the central 60% — the hex's "interior" — leaving the outer band
     as quiet base terrain that flows into neighbours.
  4. Halftone grain is asked for at a *consistent density* across the
     whole canvas, so the grain texture itself doesn't betray seams.
"""

# Shared style block. Mirrors JACANA_STYLE in generate_character_icons.py
# almost line for line — same palette, same painterly description, same
# halftone-grain insistence — but recast for an overhead survey rather
# than a bust portrait.
HEX_TILE_STYLE = (
    "Painted in the exact style of a vintage 1980s AD&D fantasy book "
    "illustration: dim moody atmosphere with heavy halftone newsprint "
    "grain texture applied at a consistent density across the entire "
    "image. Painted in loose gouache and ink wash with soft brush edges "
    "— NOT clean comic-book line art, NOT bright modern digital "
    "painting, NOT a polished video-game splash, NOT a satellite photo. "
    "Limited dirty palette of dusky purples, deep teals, muted ochres, "
    "mossy greens and ink-blacks. The whole image looks like a faded "
    "printed page from an old AD&D module hex-map insert. "
    "The painting fills the entire square canvas edge to edge as a single "
    "bleed-off scene with NO border, NO frame, NO vignette, NO page "
    "shadow, NO compass rose, NO grid lines, NO label, NO text, NO "
    "watermark, NO drop shadow around features."
)

# Geometry / tiling constraints. Kept separate from style so they can be
# tuned without touching the aesthetic.
HEX_TILE_GEOMETRY = (
    "Camera: strict overhead orthographic survey, looking straight down "
    "at the ground from directly above (90-degree top-down, NOT isometric, "
    "NOT three-quarter, NOT a landscape view, NO horizon line, NO sky). "
    "Lighting: flat, even, ambient overcast daylight with no cast "
    "shadows and no directional sun — features must NOT have long "
    "shadows pointing in any direction. "
    "Composition: a single seamless patch of terrain that would sit "
    "inside one hexagon on a map. Salient features (trees, boulders, "
    "ruins, gravestones, etc.) are clustered in the central ~60% of "
    "the canvas. The outer ~20% on every side shows only the dominant "
    "base terrain (e.g. grass, dirt, water) painted in a calm, even "
    "wash so the tile blends into identical neighbours on all six hex "
    "edges. The dominant base colour bleeds all the way to the canvas "
    "edge with no rim-darkening, no fade to black, no fade to white, "
    "no painted halo around the tile. Halftone grain density is "
    "identical at the centre and at the edges."
)


# Per-terrain flavour. Each entry is the SUBJECT description that gets
# combined with the style + geometry blocks. Keep these tight — the
# style blocks already carry the heavy aesthetic load.
TERRAIN_PROMPTS = {
    # --- Open ground -----------------------------------------------------
    "grassland": (
        "An overhead patch of windswept open meadow. Mossy green and "
        "ochre grasses with a few clumps of darker thistle and a "
        "scatter of pale wildflowers near the centre. Faint hint of a "
        "trodden footpath winding through the middle and disappearing "
        "on both sides."
    ),
    "moor": (
        "An overhead patch of bleak upland moorland. Patchy heather in "
        "dusky purples and bruised ochres over peat-dark soil, with a "
        "scatter of grey lichen-spotted stones near the centre. Wisps "
        "of low fog drifting over the heath."
    ),
    "tilled_farmland": (
        "An overhead patch of ploughed peasant farmland. Furrowed rows "
        "of dark earth and pale stubble running diagonally across the "
        "tile so they meet the edges without lining up to a single "
        "compass direction. A scarecrow lashed to a crooked post stands "
        "near the centre."
    ),
    "wasteland": (
        "An overhead patch of barren wasteland. Cracked grey-ochre clay "
        "veined with darker fissures, a scatter of bleached bones and "
        "broken pottery shards near the centre, wind-scoured pebbles "
        "drifted at the edges."
    ),

    # --- Forested --------------------------------------------------------
    "forest": (
        "An overhead patch of dense oak woodland. Several mossy-green "
        "and ink-black canopy crowns clustered toward the centre seen "
        "from directly above, with glimpses of dark leaf-litter floor "
        "between them. The outer band is calm mossy undergrowth so the "
        "tile abuts cleanly to neighbouring forest."
    ),
    "pine_forest": (
        "An overhead patch of dim pine forest. Several dark teal-green "
        "conical pine crowns seen from directly above, clustered toward "
        "the centre. Needled rust-brown floor visible between them. "
        "Calm needled floor at the outer edges."
    ),
    "dead_forest": (
        "An overhead patch of dead winter forest. Bare ink-black "
        "branching skeletons of trees seen from above splayed across "
        "the centre like cracks, over a floor of frost-grey dirt and "
        "dry brown leaf-litter. A few crows perched on the branches."
    ),

    # --- Elevation -------------------------------------------------------
    "hills": (
        "An overhead patch of low rolling hills. Soft mossy-green and "
        "ochre rises painted with subtle tonal banding so the "
        "elevation reads from directly above without cast shadows. A "
        "single small standing stone near the centre. No horizon."
    ),
    "mountains": (
        "An overhead patch of jagged mountain peaks seen from directly "
        "above. Ink-black ridgelines and grey scree fanning out from a "
        "central cluster of summits, mossy-green and ochre lower slopes "
        "fading to the edges. No cast shadows, no horizon, no sky."
    ),
    "badlands": (
        "An overhead patch of dry eroded badlands. A central knot of "
        "twisting ochre ravines and ink-black gully shadows, surrounded "
        "by cracked clay flats that bleed evenly to the tile edges."
    ),

    # --- Wetland / water -------------------------------------------------
    "swamp": (
        "An overhead patch of fetid swamp. Pools of brackish teal-black "
        "water threaded between hummocks of mossy-green tussock, a "
        "broken half-sunken log near the centre, wisps of pale fog "
        "drifting across the whole tile."
    ),
    "river": (
        "An overhead patch of slow river. A wide band of deep teal "
        "water flowing diagonally across the tile from one edge to the "
        "opposite edge so it meets neighbour tiles on two sides; ochre "
        "mossy banks on the remaining two sides. No bridge, no boat — "
        "just the water and its banks."
    ),
    "lake": (
        "An overhead patch of still dark lake water. Deep teal-black "
        "with a faint painterly ripple texture and a single tiny "
        "reed-cluster silhouette near one corner of the central area. "
        "The water bleeds evenly to all four canvas edges."
    ),
    "coast": (
        "An overhead patch of foggy coastline. Roughly half the tile is "
        "dark teal sea with a painterly surf line; the other half is "
        "ochre wet sand. The shoreline runs diagonally so the tile can "
        "abut sea-tiles on one side and land-tiles on the other."
    ),
    "marsh_reeds": (
        "An overhead patch of reed marsh. Brackish dark teal shallow "
        "water threaded between dense clumps of pale ochre reeds seen "
        "from directly above, with a few darker open channels winding "
        "through. Wisps of fog over the whole tile."
    ),

    # --- Cold / arid -----------------------------------------------------
    "tundra": (
        "An overhead patch of frozen tundra. Pale grey-ochre frost-"
        "burnt ground patched with mossy-green lichen and ink-black "
        "exposed stones, a thin crust of dirty snow drifted at the "
        "edges, no shadows, no sun."
    ),
    "snow": (
        "An overhead patch of trampled snowfield. Dirty greyed-out "
        "white with faint ochre bare-earth showing through in patches, "
        "a few sets of footprints crossing the centre and continuing "
        "off the edges. Halftone grain visible across the snow."
    ),
    "desert": (
        "An overhead patch of dunes. Soft ochre and dusky-purple sand "
        "with painted ripple patterns running diagonally so neighbour "
        "tiles continue the dunes naturally. A bleached skull and a "
        "scatter of dark stones near the centre. No horizon, no sun."
    ),

    # --- Built / inhabited ----------------------------------------------
    "cemetery": (
        "An overhead patch of overgrown graveyard. Mossy-green and "
        "ochre tussocks of long grass between a small cluster of "
        "weathered grey headstones and a single broken crypt near the "
        "centre. Wisps of pale fog drift across the tile. No fence, no "
        "lich-gate."
    ),
    "ruins": (
        "An overhead patch of crumbled stone ruins. A central cluster "
        "of broken grey walls and tumbled blocks half-swallowed by "
        "mossy-green undergrowth, the surrounding outer band is calm "
        "grassland so the tile blends to neighbouring grass hexes."
    ),
    "village_hamlet": (
        "An overhead patch of a small peasant hamlet. Two or three "
        "thatched-roof cottages and a sagging wooden barn seen from "
        "directly above, clustered tightly in the centre, with a dirt "
        "path running between them. Mossy grass around them filling the "
        "outer band."
    ),
    "town_district": (
        "An overhead patch of a dense town district. A cluster of "
        "slate-grey rooftops, narrow alleys and one small cobbled "
        "square seen from directly above, packed into the centre. A "
        "rim of dirt road and grass around the buildings filling the "
        "outer band so the tile abuts open-terrain hexes cleanly."
    ),
    "docks": (
        "An overhead patch of weathered fishing docks. A few short "
        "wooden piers projecting from a strip of ochre wet sand into "
        "deep teal water that fills roughly half the tile diagonally, "
        "a single moored rowboat in the middle, coiled rope and crates "
        "on the planks. Fog hangs over the water."
    ),
    "road_cobble": (
        "An overhead patch of cobbled road. A broad band of grey-ochre "
        "cobblestones running diagonally across the tile from one edge "
        "to the opposite edge so it joins neighbour road tiles, with "
        "mossy grass verges on either side filling the remaining canvas."
    ),
    "road_dirt": (
        "An overhead patch of rutted dirt road. A wide muddy-brown "
        "track running diagonally across the tile from one edge to the "
        "opposite edge so it joins neighbour road tiles, with patchy "
        "mossy grass verges on either side."
    ),

    # --- Setting-specific (Perrow / Things Fall Apart) -------------------
    "cult_ground": (
        "An overhead patch of cursed ground. A faint ink-black ritual "
        "sigil painted into the centre of muddy ochre earth, guttered "
        "candle stubs at the points of the sigil, mossy-green "
        "undergrowth crowding the edges. Wisps of dusky purple smoke."
    ),
    "battlefield_recent": (
        "An overhead patch of a freshly-fought battlefield. Trampled "
        "mossy grass churned to ochre mud at the centre, a few broken "
        "spears, a discarded iron kettle helm, dark stains in the dirt. "
        "Calm grass at the outer band so it blends to neighbouring "
        "grass hexes."
    ),
    "burned_village": (
        "An overhead patch of a torched village. Two or three blackened "
        "skeletal cottage frames at the centre with ochre scorched "
        "ground around them and one thin curl of grey smoke. The outer "
        "band is calm sooted grass."
    ),
}


# Optional edge / transition variants. Append one of these to the base
# prompt when you need a tile that hands off cleanly to a *different*
# terrain on one side (e.g. forest-meets-grassland, coast-meets-river).
# The model still gets the same style + geometry blocks, just with a
# tweaked composition instruction.
EDGE_VARIANTS = {
    "blend_n":  "Compositionally, the upper edge of the tile transitions softly into open mossy grassland.",
    "blend_s":  "Compositionally, the lower edge of the tile transitions softly into open mossy grassland.",
    "blend_e":  "Compositionally, the right edge of the tile transitions softly into open mossy grassland.",
    "blend_w":  "Compositionally, the left edge of the tile transitions softly into open mossy grassland.",
    "shore_diag_ne_sw": "Compositionally, water occupies the upper-right half of the tile and land the lower-left, with the shoreline running diagonally from upper-left edge to lower-right edge.",
    "shore_diag_nw_se": "Compositionally, water occupies the upper-left half of the tile and land the lower-right, with the shoreline running diagonally from upper-right edge to lower-left edge.",
}


def build_hex_prompt(terrain_id, edge_variant=None):
    """Compose the full prompt for one hex tile.

    Order matches generate_character_icons.build_prompt: subject first
    (so the model locks onto the terrain identity before being primed by
    the style descriptors), geometry next (camera + tiling constraints),
    style block last.
    """
    if terrain_id not in TERRAIN_PROMPTS:
        raise KeyError(f"Unknown terrain id: {terrain_id}")
    subject = f"Subject of the painting: a single hex-map terrain tile. {TERRAIN_PROMPTS[terrain_id]}"
    parts = [subject, HEX_TILE_GEOMETRY]
    if edge_variant:
        if edge_variant not in EDGE_VARIANTS:
            raise KeyError(f"Unknown edge variant: {edge_variant}")
        parts.append(EDGE_VARIANTS[edge_variant])
    parts.append(HEX_TILE_STYLE)
    return " ".join(parts)


if __name__ == "__main__":
    # Print every terrain prompt so you can eyeball them.
    for tid in TERRAIN_PROMPTS:
        print(f"\n--- {tid} ---\n{build_hex_prompt(tid)}\n")
