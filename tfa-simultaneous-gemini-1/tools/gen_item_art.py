import os, sys, json, base64, urllib.request, urllib.error
from collections import deque
from PIL import Image
import io

KEY = os.environ["GEMINI_API_KEY"]
ITEMS = os.path.join(os.path.dirname(__file__), "..", "Items")
REFS = ["leather_armor.png", "legionnaires_armor.png"]
MODELS = ["gemini-3-pro-image", "gemini-3.1-flash-image", "gemini-2.5-flash-image"]

STYLE = (
    "A single top-down video-game inventory icon for a top-down RPG, drawn from a directly "
    "overhead bird's-eye camera looking straight down at the garment as it would be worn on a "
    "character lying flat, exactly matching the overhead perspective, proportions, framing, soft "
    "lighting and semi-realistic painterly style of the two reference armor icons provided. "
    "Seen from above: the two shoulders spread outward to the upper-left and upper-right, a rounded "
    "neck-and-head opening sits at the top-center, the sleeves extend out to the sides, and the "
    "foreshortened torso fills the lower portion of the frame. The entire garment fits fully inside "
    "the frame, centered, surrounded on all four sides by a generous empty margin of plain flat "
    "pure-white background, fully isolated as a clean cutout. "
)

# Held gear (weapons, shields) is drawn in a different register from the armor
# icons: a bold contour with flat cel shading, matching longsword.png and
# battleaxe.png.
#
# A shield drawn as a full circle reads as a disc lying flat on the ground. Held
# on a raised forearm and seen from above it foreshortens hard, and the parts
# that sell it are the ones a squashed face-on drawing loses: the rim's material
# THICKNESS all the way round, and a boss that domes up out of the face and
# catches the light. So ask for the perspective directly rather than flattening
# a front view afterwards.
#
# One of the reference images is deliberately a WIDE sprite: the model matches
# the references' aspect ratio, and tall weapon refs alone produce an upright
# portrait shield every time.
def shield_style(silhouette, placement, aspect):
    """Prompt for a shield seen from above.

    ROUND shields are easy: intrinsically 1:1, they foreshorten to a ~2.4:1
    ellipse and stay legible. ELONGATED shields (kite, heater) are not, and the
    reason is arithmetic rather than art: that same camera is a squash of ~0.42,
    so a 2:1 kite laid out horizontally comes to 2 / 0.42 = 4.8:1. At the ~36px
    these render at, that is a sliver — every attempt at it got called a canoe.

    Two things fix it, both encoded below: lay the shield DIAGONALLY in the
    ground plane rather than square-on (which buys back short-axis pixels), and
    cheat the foreshortening shallower than physically correct, capping the
    bounding box under 3:1. Generate at the final rotation and light it after —
    rotating a finished render drags the key light round with it.
    """
    return (
        "A single item sprite for a top-down RPG, drawn with bold dark contour lines and flat cel "
        "shading in the style of the reference sprites provided. The whole image is a WIDE LANDSCAPE "
        "picture. "
        "The camera sits high above the shield and looks down onto it at about sixty degrees, a high "
        "three-quarter overhead view: clearly looking ONTO the shield rather than at its face, while "
        f"keeping a generous amount of that face visible. SILHOUETTE: {silhouette} "
        "DEPTH: a thick slab of rim runs along the lower edge nearest the viewer and wraps around "
        "the far end, showing its full material thickness there, and thins away to almost nothing "
        "along the far upper edge. The face is dished, shaded in flat cel bands that step from "
        "lighter at the near lower edge to darker toward the far upper edge. The whole shield casts "
        "a soft dark shadow onto the ground beneath its near edge. "
        "The key light comes from the upper left of the finished picture. "
        "The shading is built from a few large flat areas so the sprite stays readable when it is "
        "shrunk to thirty pixels across, and the material is matte, shaded in flat steps. "
        f"PLACEMENT: {placement} The shield's bounding box is about {aspect} times as wide as it is "
        "tall. "
        "The shield sits centered and complete inside the frame, surrounded on all four sides by a "
        "generous empty margin of plain flat pure-white background, fully isolated as a clean cutout. "
    )

PROMPTS = {
    # The generic quest-proof trophy: whatever the bounty was, this is what you
    # carry back. Deliberately anonymous where the king's head is characterful —
    # it gets renamed per victim at runtime ("Severed Head of Ser Brannoc"), so
    # the art has to read as "somebody's head" rather than as one person's.
    # Kept stylised and cel-shaded to match its shelf-mate rather than pushed
    # toward realism, and it has to survive being shrunk to about twenty pixels.
    "severed_head": (
        "A single item sprite for a top-down RPG inventory, drawn with bold dark contour lines and "
        "flat cel shading, exactly matching the framing, proportions, line weight, muted palette and "
        "painted cel-shaded style of the reference severed-head sprite provided. "
        "SUBJECT: the severed head of an ordinary grown man, a slain roadside brigand, carried as "
        "proof of a bounty. He faces the viewer straight on and fills the frame the same way the "
        "reference head does. "
        "FACE: gaunt and slack, the eyes closed and sunken into shadowed sockets, the mouth hanging "
        "slightly open, the skin drained to a pallid grey with faint cold blue-green tones in the "
        "hollows of the cheeks and under the jaw. A short unkempt stubbled beard and a crooked nose "
        "that has been broken before. "
        "HAIR: dark brown, matted, hanging in lank clumps, bare-headed and plainly kept. "
        "NECK: the head ends at a ragged cut across the neck near the bottom of the frame, the "
        "cut edge dark and clotted in deep desaturated maroon. "
        "The key light comes from the upper left. The shading is built from a few large flat areas "
        "so the sprite stays readable when it is shrunk to twenty pixels across. "
        "The head's bounding box is very slightly taller than it is wide. "
        "The head sits centered and complete inside the frame, surrounded on all four sides by a "
        "generous empty margin of plain flat pure-white background, fully isolated as a clean cutout. "
    ),
    "dark_robes": STYLE + (
        "The garment is a cultist's heavy dark ritual robe in charcoal black with deep-purple "
        "undertones, thick draping cloth folds radiating outward from the shoulders, a thin twisted "
        "rope cord across the waist lower in the frame, and frayed cloth edges."
    ),
    "dark_hood": (
        "A single top-down video-game inventory icon for a top-down RPG, drawn from a directly "
        "overhead bird's-eye camera looking straight down at a hood, exactly matching the overhead "
        "perspective, framing, soft lighting and semi-realistic painterly style of the reference "
        "armor icons provided. Seen from directly above: a charcoal-black cloth hood with rounded "
        "draped fabric forming the outer cowl and a dark open hole at the center where the face "
        "looks up, soft radiating folds around the rim. Fully isolated as a clean cutout on a plain "
        "flat pure-white background."
    ),
    "padded_vest": STYLE + (
        "The garment is a quilted padded gambeson vest in warm brown and tan, with vertical stitched "
        "channels, short leather lacing at the top-center neck opening, rugged practical street-tough "
        "styling, lightly worn."
    ),
    "peasants_stained_shirt": STYLE + (
        "The garment is a humble loose homespun peasant shirt in faded off-white and beige rough "
        "linen, a simple laced collar at the top-center neck opening, dirt smudges and brown stains, "
        "creased well-worn fabric spreading from the shoulders."
    ),
    "breastplate_2": STYLE + (
        "The garment is a polished steel plate breastplate (metal torso armor), rounded pauldrons "
        "at the shoulders, a fitted curved chest plate with subtle engraved gold trim along the "
        "edges, a small neck opening at the top-center, sturdy and noble, with realistic brushed-"
        "metal highlights and soft reflections."
    ),
    "nobles_blouse": STYLE + (
        "The garment is an elegant noble's blouse in rich deep-burgundy silk accented with gold "
        "embroidery, a ruffled high collar around the top-center neck opening, and ruffled cuffs at "
        "the ends of the sleeves that spread out to the sides."
    ),

    # ── Shields ──
    # Held items live in the hand next to swords and axes, so they follow the
    # WEAPON style (bold black contour, flat cel shading) rather than STYLE's
    # painterly armor register — hence the REFS_OVERRIDE entries below.
    #
    # Perspective: a shield drawn as a full circle reads as a disc lying flat on
    # the ground — a tray, not something strapped to a raised forearm. Overhead,
    # an upright shield foreshortens to a wide shallow oval, so that is what these
    # ask for, with a strip of rim thickness along the bottom to sell the depth.
    "buckler": shield_style(
        silhouette=(
            "the shield is round, so it foreshortens into a smooth even ellipse with no corners "
            "and no taper."
        ),
        placement="The ellipse lies flat across the middle of the frame.",
        aspect="two and a half",
    ) + (
        "The shield is a small round wooden buckler. Pale warm timber planks run across the face in "
        "parallel bands with visible grain and a few nicks, an iron-banded rim wraps the outer edge, "
        "and a pale domed steel boss crowns the centre, standing proud of the planks."
    ),
    # The asymmetry has to be stated twice over. Described as a teardrop or a
    # smooth lens, the model produces something pointed at BOTH ends and every
    # reader calls it a canoe; describing one blunt end and one sharp end, and
    # then saying outright that the two ends look different, is what fixes it.
    "iron_shield": shield_style(
        silhouette=(
            "the shield is a kite. It has ONE broad rounded shoulder at one end which holds almost "
            "its full width for the first third of its length, and from there both sides run in a "
            "long straight taper to ONE single sharp point at the other end. The broad end is wide "
            "and blunt and the far end is a single point, so the two ends look completely different "
            "from each other."
        ),
        placement=(
            "The shield lies at a shallow diagonal across the ground, its broad rounded shoulder "
            "toward the upper right of the frame and its single point aimed down toward the lower "
            "left corner, the long axis about thirty degrees off horizontal."
        ),
        aspect="two and a third",
    ) + (
        "The shield is a knight's iron kite shield. The camera looks onto its OUTER face, which is "
        "dished and crossed by a raised iron band. A domed steel boss stands proud of the face near "
        "the broad shoulder, catching the light on its upper left and casting a soft shadow down "
        "onto the face beside it. The boss is the one detail that must survive the sprite being "
        "shrunk, so it is bold and high in contrast."
    ),
}

# ── Furniture / map props ──
# Battlemap set dressing drawn in the flat painterly top-down register of
# long_table.png and desk.png (rounded dark border, soft flat lighting). These
# render at map scale (~30-110px wide), so each prompt leans on a few large
# readable shapes rather than fine detail. Phrasing stays positive throughout —
# describe what IS there ("lying perfectly flat, all four edges visible"), the
# image models latch onto any concept a sentence tries to rule out.
PROP_STYLE = (
    "A single top-down video-game item sprite for a top-down RPG battlemap, drawn from a directly "
    "overhead bird's-eye camera looking straight down, exactly matching the overhead perspective, "
    "soft lighting, muted palette and flat painterly style of the reference furniture sprites "
    "provided. The object sits centered and complete inside the frame, surrounded on all four "
    "sides by a generous empty margin of plain flat pure-white background, fully isolated as a "
    "clean cutout. "
)
PROMPTS.update({
    "headstone": PROP_STYLE + (
        "SUBJECT: a weathered granite headstone seen from directly above on a grave plot: "
        "a rounded-top upright grave marker slab tipped back so its full face shows from "
        "the bird's-eye view, pale grey stone with darker mottling, a few rows of shallow "
        "weathered chisel grooves worn smooth across the upper face, moss creeping along "
        "one edge, a narrow bed of dark packed grave soil framing the stone, and a thin "
        "cast shadow along its base. The whole image is a small compact picture, the "
        "marker's bounding box slightly taller than it is wide."
    ),
    "golden_idol": PROP_STYLE + (
        "SUBJECT: a small gilded devotional idol standing on a low round stone plinth, seen "
        "from directly above: a squat seated figure of polished gold with a smooth featureless "
        "face and folded arms, a ring of short blunt rays fanning out around its head like a "
        "halo, warm reflected highlights along the shoulders and knees, the pale grey plinth "
        "forming a circular base around it, and a soft warm glow pooling on the ground at its "
        "foot. The whole image is a SQUARE picture, the idol and its round plinth filling a "
        "bounding box as wide as it is tall."
    ),
    "golden_apple": PROP_STYLE + (
        "SUBJECT: a single golden apple lying on the ground, seen from directly above: a round "
        "fruit of burnished solid gold with a soft specular highlight curving across its upper "
        "surface, a short dark stem at its centre, one small pointed gold leaf lying flat "
        "beside the stem, faint hammered facets catching the light around its shoulder, and a "
        "soft warm glow on the ground beneath it. The whole image is a SQUARE picture, the "
        "apple filling a bounding box as wide as it is tall."
    ),
    "sarcophagus": PROP_STYLE + (
        "SUBJECT: an ancient stone sarcophagus seen from directly above: a heavy rectangular "
        "coffin-chest of pale weathered limestone with a thick carved lid, a raised border "
        "rim running around the lid's edge, a worn effigy relief of a recumbent knight down "
        "the lid's centre, hairline cracks across one corner, and moss gathering in the "
        "carved recesses. The whole image is a WIDE LANDSCAPE picture, the chest about two "
        "and a half times as wide as it is tall."
    ),
    "stone_stairs": PROP_STYLE + (
        "SUBJECT: a straight outdoor staircase of pale cream limestone seen from directly "
        "above: eleven wide rectangular stone treads stacked in a single column, each tread "
        "one worn slab spanning the full width, a crisp dark shadow line tucked under every "
        "step edge and a sun-bleached highlight along every tread nose. A low curb of the "
        "same cream masonry runs down each long side of the flight. The staircase descends "
        "from a slightly brighter landing slab at the TOP of the image to the darkest, most "
        "worn bottom step, the whole flight shading gradually darker toward the bottom edge. "
        "The whole image is a TALL PORTRAIT picture, the flight's bounding box about two and "
        "a half times as tall as it is wide."
    ),
    "bench": PROP_STYLE + (
        "SUBJECT: a plain sturdy wooden sitting bench seen from directly above, lying "
        "perfectly flat in plan view: one long rectangular seat plank of warm honey-brown "
        "wood filling the silhouette, its full top surface visible with straight parallel "
        "long edges, gentle lengthwise grain, a couple of worn knots, and two slightly "
        "darker cross-batten shadow lines showing through where the legs sit under the "
        "seat near each end, with a soft thin contact shadow along both long edges "
        "grounding it. The whole image is a TALL PORTRAIT picture, the seat's bounding "
        "box about three times as tall as it is wide."
    ),
    "compass_mosaic": PROP_STYLE + (
        "SUBJECT: a grand inlaid marble compass-rose floor mosaic seen from directly above, "
        "lying perfectly flat like a painted pattern: a large square panel of pale cream and "
        "warm sand marble tiles framed by a slim double border inlay of antique gold and "
        "charcoal stone, and at its centre a great eight-pointed compass star of polished "
        "charcoal-black and antique-gold marble, with four slender minor points in dusty rose "
        "and cream between the cardinal points. Fine pale mortar seams divide the tiles, the "
        "polish is worn matte by footsteps, and the lighting is soft and even across the whole "
        "face. The whole image is a SQUARE picture, the panel exactly as wide as it is tall."
    ),
    "stone_bath": PROP_STYLE + (
        "SUBJECT: a sunken octagonal stone bathing pool seen from directly above: a wide "
        "eight-sided rim of pale weathered limestone blocks framing still, clear pale-turquoise "
        "water, the water shading gently deeper toward the middle, a submerged sitting ledge of "
        "paler stone visible just under the surface along two sides, a faint darker waterline "
        "where water meets the rim's inner edge, and a folded beige linen towel with a small "
        "brass ewer resting on one rim corner. The whole image is a SQUARE picture, the pool's "
        "bounding box exactly as wide as it is tall."
    ),
    "stove": PROP_STYLE + (
        "SUBJECT: a medieval kitchen's masonry cooking stove seen from directly above: a sturdy "
        "rectangular block of mortared grey fieldstone with a rim of stone visible around the top "
        "edge, the flat top holding a thick dark cast-iron cooking plate with two round iron "
        "burner rings, a faint warm ember glow escaping the fire slot along the lower edge, and a "
        "small stack of split firewood tucked against one end of the stone base. The whole image "
        "is a WIDE LANDSCAPE picture, the stove's bounding box about one and a half times as wide "
        "as it is tall."
    ),
    "prep_table": PROP_STYLE + (
        "SUBJECT: a well-used kitchen preparation table seen from directly above: a broad "
        "rectangular butcher-block worktop of pale scrubbed hardwood with visible plank joints "
        "and knife scars, a round wooden chopping board resting on one half with a small kitchen "
        "knife lying across it, a scatter of chopped green herbs beside the board, and a folded "
        "beige linen cloth draped over one corner of the worktop. The whole image is a WIDE "
        "LANDSCAPE picture, the bounding box about twice as wide as it is tall."
    ),
    "shelf": PROP_STYLE + (
        "SUBJECT: a long kitchen storage shelf standing against a wall, seen from directly above "
        "so its flat top plank and the goods standing on it fill the sprite: a long narrow band "
        "of dark oak boards carrying a neat row of round clay jars with cork lids, two stacked "
        "wooden bowls, a small tied linen sack, and a squat green glass bottle. The whole image "
        "is a WIDE LANDSCAPE picture, the bounding box about two and a half times as wide as it "
        "is tall."
    ),
    "round_table": PROP_STYLE + (
        "SUBJECT: a round wooden tavern table seen from directly above: a perfectly circular "
        "tabletop built from straight parallel oak planks all running in the same single "
        "direction across the whole circle, the plank wood warmly varnished with soft grain and "
        "a few pale ring stains left by mugs, and a thin darker band of table edge running all "
        "the way around the circle. The picture is exactly SQUARE and the tabletop is a perfect "
        "centered circle."
    ),
    "rug": PROP_STYLE + (
        "SUBJECT: a single ornate rectangular woven carpet lying perfectly flat on the floor, "
        "seen from directly above: one complete flat rectangle with all four edges straight and "
        "fully visible, a deep crimson central field with an intricate golden medallion at the "
        "center, a broad decorative border of geometric knotwork in navy and gold running around "
        "all four sides, and short pale fringe along the two short ends. The whole carpet lies "
        "smooth and flat like a painted pattern. The image is a LANDSCAPE picture, the bounding "
        "box about one and a third times as wide as it is tall."
    ),
    "grain_sack": PROP_STYLE + (
        "SUBJECT: a plump burlap grain sack lying slumped on the ground, seen from directly "
        "above: the rounded body of the sack bulging with grain fills most of the frame, coarse "
        "woven burlap texture with soft creases radiating across the top of the bulge, and the "
        "gathered neck tied off with a short cord pointing out to one side, lying flat against "
        "the ground. The image is a LANDSCAPE picture, the bounding box slightly wider than it "
        "is tall."
    ),
    "firewood": PROP_STYLE + (
        "SUBJECT: a small pile of split firewood lying on the ground, seen from directly above: "
        "several split logs lying side by side in one direction, their rounded bark backs and "
        "pale split faces alternating along the pile, with the sawn end grain of the logs "
        "visible as small pale ovals at the two ends of the pile, and one shorter log resting "
        "diagonally across the top of the others. The image is a LANDSCAPE picture, the bounding "
        "box about one and a half times as wide as it is tall."
    ),
    "rope_coil": PROP_STYLE + (
        "SUBJECT: a length of thick hemp rope coiled up lying flat on the ground, seen from "
        "directly above: the rope is wound into a tight flat spiral that starts at a small "
        "curled center and winds outward to the rim, every winding lying snug against its "
        "neighbour so the whole round shape is solid rope from center to edge, with the twisted "
        "strand texture following the spiral and the loose tail end of the rope trailing out "
        "from under the outer edge. The picture is exactly SQUARE and the coil is centered."
    ),
    "red_carpet": PROP_STYLE + (
        "SUBJECT: a very long narrow ceremonial red runner carpet lying perfectly flat on the "
        "floor, seen from directly above: one complete flat rectangle with all four edges "
        "straight and fully visible, a rich scarlet central field with a subtle repeating "
        "diamond damask pattern woven in slightly darker red, a double border line of golden "
        "thread running along all four long sides, and neat squared ends. The whole runner lies "
        "smooth and flat like a painted pattern. The image is a TALL PORTRAIT picture, the "
        "bounding box about four times as tall as it is wide."
    ),
    # ---- Renaissance piazza set (town square rebuild) ----------------------
    "piazza_rosette": PROP_STYLE + (
        "SUBJECT: a grand circular paved plaza rosette seen from directly above, lying "
        "perfectly flat like a painted pattern: one great CIRCLE of pale cream sandstone "
        "paving filling the frame edge to edge, inlaid tone-on-tone with warm tan and ochre "
        "stone. At the centre a large eight-pointed compass star of warm tan stone with "
        "slender darker outlines, around it a ring of eight broad petal-shaped loops of "
        "tan cobble inlay forming a rosette, and a wide double border ring of warm sand "
        "stone closing the circle's rim. Fine pale mortar seams divide the big irregular "
        "paving flags everywhere, the surface is sun-worn and matte with soft ochre "
        "staining, and the whole pattern reads as flat inlaid pavement. The whole image is "
        "a SQUARE picture, the circle touching all four edges, the four corners outside "
        "the circle plain flat pure white."
    ),
    "piazza_fountain": PROP_STYLE + (
        "SUBJECT: a public plaza fountain seen from directly above: a wide octagonal basin "
        "rim of warm cream travertine blocks framing clear pale-turquoise water, and at the "
        "centre a smaller raised round upper bowl on a stone pedestal, its own disc of "
        "brighter rippling water catching the light, thin white rills of falling water "
        "fanning from the upper bowl's lip onto the lower pool, gentle concentric ripples "
        "spreading to the basin edge, and a faint darker waterline along the rim's inner "
        "edge. The whole image is a SQUARE picture, the basin's bounding box exactly as "
        "wide as it is tall."
    ),
    "market_umbrella": PROP_STYLE + (
        "SUBJECT: a large market parasol umbrella seen from directly above, fully open: a "
        "round canvas canopy of eight neat wedge panels alternating deep terracotta red and "
        "warm cream, slim darker seam lines between the panels meeting at a small round "
        "wooden hub button in the exact centre, a gently scalloped outer edge, soft fabric "
        "shading along each wedge, and a thin soft contact shadow ringing the canopy's rim. "
        "The whole image is a SQUARE picture, the canopy filling a bounding box as wide as "
        "it is tall."
    ),
    "stall_table": PROP_STYLE + (
        "SUBJECT: an open-air market display table seen from directly above, its whole top "
        "surface visible and uncovered: a sturdy rectangular trestle counter of warm "
        "honey-brown planks, a plain strip of cream burlap cloth laid flat down the middle "
        "third of the top as a display runner, the bare wood grain showing along both long "
        "edges, slightly darker end boards at the two short ends, and a thin soft contact "
        "shadow grounding all four sides. The table top stays open and empty, ready for "
        "wares to be laid out on it. The whole image is a WIDE LANDSCAPE picture, the "
        "counter about twice as wide as it is tall."
    ),
    "stall_canopy": PROP_STYLE + (
        "SUBJECT: a market stall seen from directly above, its rectangular canvas awning "
        "covering nearly the whole silhouette: bold stripes of deep red and warm cream "
        "canvas running across the short axis, the fabric draping in gentle scalloped waves "
        "along both long edges, a slim timber frame corner peeking at each of the four "
        "corners, and along one long side a narrow strip of the wooden counter plank "
        "showing from under the awning with a couple of small round produce baskets on it. "
        "The whole image is a WIDE LANDSCAPE picture, the stall about one and three "
        "quarter times as wide as it is tall."
    ),
})

# Items whose style comes from a different set of reference sprites than REFS.
# shield_topdown_aspect.png is a WIDE landscape sprite and is what stops the
# model copying the tall weapon refs' portrait framing; longsword.png supplies
# the contour-and-cel-shading register. (tools/refs carries a .gdignore so Godot
# leaves these out of the project's asset import.)
_REFS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "refs")
SHIELD_REFS = [
    os.path.join(_REFS_DIR, "shield_topdown_aspect.png"),
    os.path.join(ITEMS, "longsword.png"),
]
# The generic bounty trophy has to sit beside skarsgaard_king_head.png in the
# same bag, so that sprite IS the reference: same face-on framing, same bold
# contour and flat cel shading, same roughly-square aspect. Adding longsword.png
# reinforces the contour register without dragging the aspect portrait-tall.
HEAD_REFS = [
    os.path.join(ITEMS, "skarsgaard_king_head.png"),
    os.path.join(ITEMS, "longsword.png"),
]
# Furniture refs: two shipped flat-painterly top-down pieces carry the
# register; the FIRST ref anchors the output's aspect, so square targets lead
# with a square ref and the runner leads with the portrait carpet.
PROP_REFS = [os.path.join(ITEMS, "long_table.png"), os.path.join(ITEMS, "desk.png")]
REFS_OVERRIDE = {
    # plank_bridge FIRST: the shipped portrait walkway anchors the tall aspect;
    # desk carries the flat-painterly furniture register
    "stone_stairs": [os.path.join(ITEMS, "plank_bridge.png"), os.path.join(ITEMS, "desk.png")],
    "headstone": [os.path.join(ITEMS, "tombstone.png"), os.path.join(ITEMS, "desk.png")]
        if os.path.exists(os.path.join(ITEMS, "tombstone.png")) else PROP_REFS,
    "sarcophagus": PROP_REFS,
    # round_table FIRST anchors the square aspect (the first ref dictates the
    # output ratio); desk carries the flat-painterly register
    "golden_idol": [os.path.join(ITEMS, "round_table.png"), os.path.join(ITEMS, "desk.png")],
    "golden_apple": [os.path.join(ITEMS, "round_table.png"), os.path.join(ITEMS, "desk.png")],
    "buckler": SHIELD_REFS,
    "iron_shield": SHIELD_REFS,
    "severed_head": HEAD_REFS,
    "stove": PROP_REFS,
    # plank_bridge FIRST anchors the tall wooden-plank aspect; desk carries the
    # furniture register (the old bench art read as a tipped-over side view)
    "bench": [os.path.join(ITEMS, "plank_bridge.png"), os.path.join(ITEMS, "desk.png")],
    # square first refs anchor the square aspect; rug carries the flat inlaid-
    # pattern register for the mosaic, round_table the circular-basin forms
    "compass_mosaic": [os.path.join(ITEMS, "rug.png"), os.path.join(ITEMS, "desk.png")],
    "stone_bath": [os.path.join(ITEMS, "round_table.png"), os.path.join(ITEMS, "desk.png")],
    "prep_table": PROP_REFS,
    "shelf": PROP_REFS,
    "round_table": [os.path.join(ITEMS, "round_table.png"), os.path.join(ITEMS, "desk.png")],
    "grain_sack": PROP_REFS,
    "firewood": PROP_REFS,
    # square first ref anchors the square aspect; basket carries the round
    # woven top-down register without the old ring's hollow centre
    "rope_coil": [os.path.join(ITEMS, "basket.png"), os.path.join(ITEMS, "desk.png")],
    "rug": [os.path.join(ITEMS, "rug.png"), os.path.join(ITEMS, "red_carpet.png")],
    "red_carpet": [os.path.join(ITEMS, "red_carpet.png"), os.path.join(ITEMS, "bed_wooden.png")],
    # piazza set: square-first refs anchor the square aspect; compass_mosaic
    # carries the flat inlaid-paving register for the rosette, stone_bath the
    # water-in-stone-basin register for the fountain
    "piazza_rosette": [os.path.join(ITEMS, "compass_mosaic.png"), os.path.join(ITEMS, "rug.png")],
    "piazza_fountain": [os.path.join(ITEMS, "stone_bath.png"), os.path.join(ITEMS, "round_table.png")],
    "market_umbrella": [os.path.join(ITEMS, "round_table.png"), os.path.join(ITEMS, "desk.png")],
    "stall_canopy": [os.path.join(ITEMS, "long_table.png"), os.path.join(ITEMS, "desk.png")],
    "stall_table": [os.path.join(ITEMS, "long_table.png"), os.path.join(ITEMS, "desk.png")],
}


def b64_image(path):
    with open(path, "rb") as f:
        return base64.b64encode(f.read()).decode()


def gen(prompt, ref_paths):
    parts = [{"text": prompt}]
    for rp in ref_paths:
        parts.append({"inline_data": {"mime_type": "image/png", "data": b64_image(rp)}})
    body = {
        "contents": [{"parts": parts}],
        "generationConfig": {"responseModalities": ["TEXT", "IMAGE"]},
    }
    data = json.dumps(body).encode()
    last_err = None
    for model in MODELS:
        url = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent?key={KEY}"
        req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=180) as resp:
                out = json.loads(resp.read())
            for cand in out.get("candidates", []):
                for p in cand.get("content", {}).get("parts", []):
                    idata = p.get("inlineData") or p.get("inline_data")
                    if idata and idata.get("data"):
                        return base64.b64decode(idata["data"]), model
            last_err = "no image part in response: " + json.dumps(out)[:400]
        except urllib.error.HTTPError as e:
            last_err = f"{model} HTTP {e.code}: {e.read().decode()[:300]}"
        except Exception as e:
            last_err = f"{model} {e}"
    raise RuntimeError(last_err)


def remove_bg(img, tol=28):
    """Edge flood-fill: clear contiguous background matching the corner color."""
    img = img.convert("RGBA")
    w, h = img.size
    px = img.load()
    # already has meaningful transparency? keep it
    alpha_min = min(px[x, y][3] for x in range(0, w, max(1, w // 50)) for y in range(0, h, max(1, h // 50)))
    if alpha_min < 250:
        return img
    corners = [px[0, 0], px[w - 1, 0], px[0, h - 1], px[w - 1, h - 1]]
    key = tuple(sum(c[i] for c in corners) // 4 for i in range(3))

    def close(a):
        return abs(a[0] - key[0]) <= tol and abs(a[1] - key[1]) <= tol and abs(a[2] - key[2]) <= tol

    seen = bytearray(w * h)
    q = deque()
    for x in range(w):
        for y in (0, h - 1):
            q.append((x, y))
    for y in range(h):
        for x in (0, w - 1):
            q.append((x, y))
    while q:
        x, y = q.popleft()
        i = y * w + x
        if seen[i]:
            continue
        seen[i] = 1
        r, g, b, a = px[x, y]
        if not close((r, g, b)):
            continue
        px[x, y] = (r, g, b, 0)
        for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
            if 0 <= nx < w and 0 <= ny < h and not seen[ny * w + nx]:
                q.append((nx, ny))
    return img


def trim(img, margin=6, max_side=640):
    """Crop to the artwork and drop it to a sane resolution.

    The prompts all ask for a generous empty margin, so a raw render is a 1024
    square that is mostly nothing. Every sprite already in Items/ is cropped
    close to its alpha bounding box (buckler 512x215, skarsgaard_king_head
    266x320), and the in-world footprint comes from base_width in Items.json
    rather than from the pixel dimensions — so the untrimmed square is pure
    waste, and it also throws off any code that reasons about the art's aspect.

    Cropping to the bounding box preserves the content's aspect ratio, which is
    what the shield work cared about; it is the empty margin that gets removed,
    not any of the shape.
    """
    bbox = img.convert("RGBA").getchannel("A").getbbox()
    if bbox is None:
        return img
    w, h = img.size
    box = (max(0, bbox[0] - margin), max(0, bbox[1] - margin),
           min(w, bbox[2] + margin), min(h, bbox[3] + margin))
    img = img.crop(box)
    longest = max(img.size)
    if longest > max_side:
        scale = max_side / float(longest)
        img = img.resize((max(1, round(img.size[0] * scale)),
                          max(1, round(img.size[1] * scale))), Image.LANCZOS)
    return img


def main():
    targets = sys.argv[1:] or list(PROMPTS.keys())
    for name in targets:
        prompt = PROMPTS[name]
        # REFS entries are bare Items/ filenames; REFS_OVERRIDE entries are full paths.
        ref_paths = REFS_OVERRIDE.get(name) or [os.path.join(ITEMS, r) for r in REFS]
        print(f"[gen] {name} ...", flush=True)
        raw, model = gen(prompt, ref_paths)
        img = Image.open(io.BytesIO(raw))
        img = remove_bg(img)
        img = trim(img)
        out_path = os.path.join(ITEMS, name + ".png")
        img.save(out_path)
        print(f"[ok ] {name}.png  {img.size}  via {model}", flush=True)


if __name__ == "__main__":
    main()
