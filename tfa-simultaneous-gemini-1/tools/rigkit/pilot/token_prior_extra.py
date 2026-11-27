"""Later-round wordings for the token_prior pilot (imported by token_prior.py)."""
STYLE = (" The attached small images are paint-style swatches only: image 1 is a patch of this orc's "
         "olive-green skin (colour, soft shading, dark outline weight); image 2 is a patch of forearm and hand "
         "showing the line and brush style. Use them for colour and rendering style.")
IDENT = ("a huge muscular orc with olive-green skin, a bald head, pointed ears, and two ivory tusks, bare "
         "unclothed base body")
AXIS = (
    "One single straight horizontal line runs across the middle of the picture and passes through the left "
    "fingertips, left wrist, left elbow, left shoulder joint, the centre of the skull dome, right shoulder "
    "joint, right elbow, right wrist and right fingertips. The skull dome is a circle centred on that line: "
    "half of the circle lies north of the line over the nape and upper back, half lies south of it. "
    "North of the line the picture shows the rounded upper back and shoulder blades; south of the line it "
    "shows an equally shallow bulge of chest. ")
V = {}

# (3b) drone nadir framing + the axis sentence
V["drone2"] = (
    "A hand-painted game sprite based on a drone nadir photograph: the drone hovers 10 metres directly "
    "above the subject with its telephoto lens pointing straight down at the ground, an orthographic "
    "satellite-style view. The subject is " + IDENT + ", standing bolt upright on the ground in a T-pose, "
    "chin level, eyes on the horizon. " + AXIS +
    "From the drone the head is a smooth bald scalp with the crown at the centre of the circle, a pointed ear "
    "tip at its left and right side, and a thin sliver at its south rim made of the brow ridge, the nose tip "
    "and two ivory tusk tips. Both arms are straight horizontal bars, backs of the flat hands up, fingers "
    "pointing outward. Ten toe tips peek out just south of the chest bulge. The whole silhouette is a wide "
    "shallow bar, its north-south depth one fifth of the arm span. Left-right symmetric. Semi-realistic "
    "painted style with a soft dark outline, flat mid-grey (128,128,128) background, 16:9, fingertips near "
    "the left and right edges." + STYLE)

# (1b) VTT token vocabulary + the axis sentence
V["vtt2"] = (
    "A top-down virtual tabletop token of " + IDENT + ", in the style of Roll20 / Foundry VTT / Forgotten "
    "Adventures top-down character tokens: pure plan view, 90-degree overhead, the character seen from "
    "straight above standing bolt upright in a T-pose, chin level. " + AXIS +
    "The bald scalp has its crown at the centre of the circle, a pointed ear tip at its left and right side, "
    "and a thin sliver at its south rim made of the brow ridge, the nose tip and two ivory tusk tips. Both "
    "arms are straight horizontal bars, backs of the flat hands up, fingers pointing outward. Ten toe tips "
    "peek out just south of the chest bulge. The token faces south. Wide shallow silhouette, five times "
    "wider than it is deep, left-right symmetric. Hand-painted semi-realistic style with a soft dark outline, "
    "flat mid-grey (128,128,128) background, 16:9, fingertips near the left and right edges." + STYLE)

# ---- round 3: the head is described as scalp only (facial words pull a face into view) ----
SCALP = (
    "The head is a plain smooth bald green dome, like an egg seen from directly above: unbroken scalp skin "
    "from its centre to its entire rim, with one soft highlight on the crown at the centre. A small pointed "
    "ear tip sticks out sideways at the left and at the right of the dome, and two tiny ivory tusk points "
    "poke out from under the dome's southern rim. ")
TAIL = ("Left-right mirror symmetric. Hand-painted semi-realistic game art with a soft dark outline, flat "
        "mid-grey (128,128,128) background, 16:9, fingertips near the left and right edges.")

# (4) classic top-down shooter sprite vocabulary + scalp-only head
V["shooter"] = (
    "A character sprite for a classic top-down game, drawn the way Hotline Miami, the first Grand Theft Auto "
    "and top-down twin-stick shooters draw people: the character is seen from exactly overhead, so the "
    "sprite is a round head sitting in the middle of a wide pair of shoulders. The character is " + IDENT +
    ", standing bolt upright in a T-pose and facing the bottom of the picture. " + SCALP +
    "The dome sits dead centre on the shoulders, covering the neck, with the same amount of shoulder and "
    "upper back showing above it as chest showing below it. The shoulders, trapezius and both arms make one "
    "long straight horizontal bar across the whole picture, level from fingertip to fingertip, with the "
    "backs of the flat hands facing the viewer. The torso is a shallow oval under the bar, barely deeper "
    "than the head itself, and ten toe tips peek out along its southern edge. The whole sprite is five times "
    "wider than it is deep. " + TAIL + STYLE)

# (5) paper cut-out shape construction + scalp-only head
V["shapes"] = (
    "Plan-view painting of " + IDENT + ", standing bolt upright in a T-pose, seen from exactly overhead and "
    "facing the bottom of the picture. The figure is built from three stacked shapes sharing one centre "
    "point in the middle of the picture. Bottom shape: a very long, thin, perfectly horizontal capsule that "
    "spans the picture, painted as the two outstretched arms seen from above, each ending in the back of a "
    "flat hand. Middle shape: a wide shallow ellipse, twice as wide as it is deep, painted as the tops of the "
    "massive shoulders, the trapezius, a little upper back at its northern edge and a little chest at its "
    "southern edge. Top shape: a circle one third the width of the ellipse, painted as the head. " + SCALP +
    "Ten toe tips peek out along the southern edge of the ellipse. The whole figure is five times wider than "
    "it is deep. " + TAIL + STYLE)

# ---- round 4: over-correct the head placement and the arm level ----
PLACE = (
    "The dome is the northernmost part of the body in the picture: its northern rim is level with the "
    "northern edge of the shoulders, so the back of the skull, the trapezius and the shoulder tops share one "
    "straight top edge. The centre of the dome, both shoulder caps, both elbows and both hands all sit at the "
    "same height in the picture, exactly half way up the image; each hand is level with the ears. The arms "
    "are two straight horizontal bars of even thickness. ")

V["shooter3"] = (
    "A character sprite for a classic top-down game, drawn the way Hotline Miami, the first Grand Theft Auto "
    "and top-down twin-stick shooters draw people: the character is seen from exactly overhead, so the "
    "sprite is a round head sitting in the middle of a wide pair of shoulders. The character is " + IDENT +
    ", standing bolt upright in a T-pose and facing the bottom of the picture. " + SCALP + PLACE +
    "South of the arms the torso shows only as a shallow rounded bulge of chest, reaching a little further "
    "south than the dome, with ten toe tips peeking out along its southern edge. The whole sprite is five "
    "times wider than it is deep. " + TAIL + STYLE)

V["drone3"] = (
    "A hand-painted game sprite based on a drone nadir photograph: the drone hovers 10 metres directly "
    "above the subject with its telephoto lens pointing straight down at the ground, an orthographic "
    "satellite-style view. The subject is " + IDENT + ", standing bolt upright on the ground in a T-pose, "
    "chin level, eyes on the horizon, front toward the bottom of the image. " + SCALP + PLACE +
    "South of the arms the torso shows only as a shallow rounded bulge of chest, reaching a little further "
    "south than the dome, with ten toe tips peeking out along its southern edge. The whole silhouette is "
    "five times wider than it is deep. " + TAIL + STYLE)
