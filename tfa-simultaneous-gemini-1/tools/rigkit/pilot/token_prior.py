"""Pilot "token_prior": true top-down orc from wording alone (no full-body reference).

    python -m tools.rigkit.pilot.token_prior <variant> [<variant> ...]

Only image inputs are two tight STYLE swatches (old orc shoulder skin, human
forearm+hand). Each variant = one Gemini call. Outputs to out/overhead2/token_prior/.
"""
import os
import sys

from PIL import Image

from tools.rigkit.gen_overhead import generate, _part

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
OUT = os.path.join(ROOT, "tools", "rigkit", "out", "overhead2", "token_prior")
ORC = os.path.join(ROOT, "Rigs", "races", "orc", "default", "body.png")
HUMAN = os.path.join(ROOT, "Rigs", "races", "human", "default", "body.png")


def swatch(src, box, name):
    im = Image.open(src).convert("RGBA")
    w, h = im.size
    c = im.crop((int(box[0] * w), int(box[1] * h), int(box[2] * w), int(box[3] * h)))
    bg = Image.new("RGBA", c.size, (128, 128, 128, 255))
    bg.alpha_composite(c)
    p = os.path.join(OUT, name)
    bg.convert("RGB").save(p)
    return p


STYLE = (" The attached small images are paint-style swatches only: image 1 is a patch of this orc's "
         "olive-green skin (colour, soft shading, dark outline weight); image 2 is a patch of forearm and hand "
         "showing the line and brush style. Use them for colour and rendering style.")

IDENT = ("a huge muscular orc with olive-green skin, a bald head, pointed ears, and two ivory tusks, bare "
         "unclothed base body")

V = {}

# (1) VTT token vocabulary
V["vtt"] = (
    "A top-down virtual tabletop token of " + IDENT + ", in the style of Roll20 / Foundry VTT / Forgotten "
    "Adventures top-down character tokens: pure plan view, 90-degree overhead, bird's-eye, the character "
    "seen from straight above standing in a T-pose. The bald crown of the head is a round dome in the exact "
    "centre of the figure, resting on the middle of the shoulder line. Both arms stretch straight out left and "
    "right as horizontal bars level with the shoulders, hands flat, palms down. The shoulders and upper back "
    "form one wide horizontal band. The token faces south: the tusk tips, nose tip and toe tips point toward "
    "the bottom edge. Left-right symmetric. Wide shallow silhouette, about five times wider than it is deep. "
    "Hand-painted semi-realistic style with a soft dark outline, flat mid-grey (128,128,128) background, 16:9, "
    "fingertips near the left and right edges." + STYLE)

# (2) physical part-by-part description of what a nadir camera sees
V["physical"] = (
    "Orthographic plan-view painting, like an architect's roof plan of a standing figure: " + IDENT + ", "
    "standing upright in a T-pose, drawn exactly as projected onto the floor from directly above. "
    "What the picture contains, from the centre outward: "
    "The skull seen from above is a smooth bald oval dome, its crown (the topmost point) at the centre of the "
    "oval; the oval sits centred on the shoulder line, overlapping the neck completely. A pointed ear tip "
    "pokes out on the left and right side of the oval. Along the south rim of the oval a thin sliver shows the "
    "jutting brow ridge, the tip of the nose and two small ivory tusk tips. "
    "Behind and beside the skull, the trapezius, the tops of both deltoids and the upper back form one "
    "straight horizontal band across the picture. "
    "From each deltoid an arm continues straight outward, perfectly horizontal, at the same height in the "
    "picture as the shoulders: the top surface of the upper arm, elbow, forearm, then the back of a flat hand "
    "with fingers together pointing outward. "
    "On the south side of the shoulder band a shallow rounded bulge shows the top edge of the pectoral "
    "muscles and belly, and just beyond it ten small toe tips. "
    "The whole silhouette is a wide shallow bar: its north-south depth is one fifth of the fingertip-to-"
    "fingertip width. Left-right mirror symmetric. Even soft light from above. Hand-painted semi-realistic "
    "game art with a soft dark outline, flat mid-grey (128,128,128) background, 16:9, fingertips near the left "
    "and right edges." + STYLE)

# (3) drone nadir photograph translated to painting
V["drone"] = (
    "A hand-painted game sprite based on a drone nadir photograph: the drone hovers 10 metres directly "
    "above the subject with its telephoto lens pointing straight down at the ground, an orthographic "
    "satellite-style view. The subject is " + IDENT + ", standing upright on the ground in a T-pose, looking "
    "straight ahead at the horizon. From the drone, the figure is a wide shallow shape: a bald round scalp "
    "in the middle with the crown at its centre, sitting on the line of the shoulders; the broad shoulder "
    "tops and upper back as a horizontal band; both arms as straight horizontal bars level with the "
    "shoulders, backs of the flat hands up; pointed ear tips at the sides of the scalp; the brow ridge, nose "
    "tip and tusk tips as a thin sliver at the bottom rim of the scalp; the top of the chest as a shallow "
    "bulge below the shoulder band and the toe tips just beyond it. The figure's front faces the bottom of the "
    "image. Depth of the silhouette is one fifth of the arm span. Left-right symmetric. Semi-realistic painted "
    "style with a soft dark outline, flat mid-grey (128,128,128) background, 16:9, fingertips near the left "
    "and right edges." + STYLE)


def run(name):
    os.makedirs(OUT, exist_ok=True)
    s1 = swatch(ORC, (0.30, 0.12, 0.42, 0.42), "_swatch_orc_skin.png")
    s2 = swatch(HUMAN, (0.02, 0.28, 0.17, 0.68), "_swatch_hand.png")
    key = name.split("#")[0]
    raw, model = generate([{"text": V[key]}, _part(s1), _part(s2)])
    p = os.path.join(OUT, "orc_%s.png" % name.replace("#", "_"))
    with open(p, "wb") as f:
        f.write(raw)
    print("[ok ] %s via %s" % (p, model))


if __name__ == "__main__":
    try:
        from tools.rigkit.pilot import token_prior_extra  # noqa: F401  (later-round variants)
        V.update(token_prior_extra.V)
    except ImportError:
        pass
    for n in sys.argv[1:]:
        run(n)
