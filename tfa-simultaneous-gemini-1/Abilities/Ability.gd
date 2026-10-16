# Ability.gd
# Defines an ability that can be loaded from JSON and executed
class_name Ability
extends Resource

## Unique identifier
@export var id: String = ""

## Display name
@export var display_name: String = ""

## Description for UI
@export var description: String = ""

## Icon for UI
@export var icon: Texture2D

## Cooldown in seconds. DEPRECATED — kept for JSON compat; the school-resource
## system replaces cooldowns. Ability availability is now gated only on the
## per-school resource costs derived from `traits`.
@export var cooldown: float = 0.0

@export var visual_duration: float = 1.5

## Resource costs (e.g., {"MP": 10, "stamina": 5}). DEPRECATED — costs are now
## derived from `traits` (Martial→adrenaline, Arcane→focus, Primal→harmony,
## Holy→devotion, Occult→souls). Legacy entries here are ignored by
## AbilityManager.
@export var costs: Dictionary = {}

## Casting time in seconds (0 = instant)
@export var cast_time: float = 0.0

## Whether the ability can be interrupted during casting
@export var interruptible: bool = true

## Traits this ability has (e.g., "spell", "fire", "attack", "magical")
@export var traits: Dictionary

## Targeting configuration
@export var targeting: Dictionary = {
	"type": "none",  # "point only support type 
	"range": 0.0,
	"shape": "none",  # "none", "circle", "rectangle", "cone"
	"radius": 0.0,
	"size": Vector2.ZERO,
	"angle": 0.0,  # For cones
}


## Effects this ability produces (array of effect definitions)
@export var effects: Array = []

## Visual effects configuration
@export var visuals: Dictionary = {
	"cast_effect": "",      # Scene path for casting effect
	"projectile": "",       # Scene path for projectile (if any)
	"impact_effect": "",    # Scene path for impact/explosion effect
	"sound_cast": "",       # Sound for casting
	"sound_impact": "",     # Sound for impact
}

## Conditions required to use this ability
@export var requirements: Dictionary = {
	"conditions": [],       # Required conditions on caster
	"no_conditions": [],    # Conditions that prevent use
	"traits": [],           # Required traits on caster
}

## Animation to play when using
@export var animation: String = ""

## Multi-step sequence. Each step is a Dictionary with:
##   "delay": float — seconds to wait before this step (relative to previous step completing)
##   "effects": Array — effect definitions (same format as top-level effects)
##   "targeting": Dictionary — optional per-step targeting override
##   "move_to_target": bool — if true, dash/move caster to target position
##   "move_speed": float — speed of dash movement (pixels/sec)
##   "animation": String — optional per-step animation
##   "visuals": Dictionary — optional per-step visual effects
## When empty, the ability uses top-level effects as a single step (backwards compatible).
@export var steps: Array = []


## Load an ability from a dictionary (parsed JSON)
static func from_dict(data: Dictionary) -> Ability:
	var ability = Ability.new()
	
	ability.id = data.get("id", "")
	ability.display_name = data.get("display_name", ability.id)
	ability.description = data.get("description", "")
	ability.cooldown = data.get("cooldown", 0.0)
	ability.costs = data.get("costs", {})
	ability.cast_time = data.get("cast_time", 0.0)
	ability.interruptible = data.get("interruptible", true)
	ability.traits = data.get("traits", {})
	ability.targeting = _parse_targeting(data.get("targeting", {}))
	var raw_effects = data.get("effects", [])
	ability.effects = [raw_effects] if raw_effects is Dictionary else raw_effects
	ability.visuals = data.get("visuals", {})
	ability.requirements = data.get("requirements", {})
	ability.animation = data.get("animation", "")
	ability.steps = data.get("steps", [])
	
	# Load icon if path provided
	var icon_path = data.get("icon", "")
	if icon_path != "" and ResourceLoader.exists(icon_path):
		ability.icon = load(icon_path)
	
	return ability


static func _parse_targeting(data: Dictionary) -> Dictionary:
	return {
		"type": data.get("type", "none"),
		"range": data.get("range", 0.0),
		"shape": data.get("shape", "none"),
		"radius": data.get("radius", 0.0),
		"size": _parse_vector2(data.get("size", {})),
		"angle": data.get("angle", 0.0),
		"target_count": data.get("target_count", 1),
		"target_filter": data.get("target_filter", "any"),
	}


static func _parse_vector2(data) -> Vector2:
	if data is Dictionary:
		return Vector2(data.get("x", 0), data.get("y", 0))
	elif data is Array and data.size() >= 2:
		return Vector2(data[0], data[1])
	return Vector2.ZERO


## Load abilities from a JSON file
static func load_from_json(path: String) -> Array[Ability]:
	var abilities: Array[Ability] = []
	
	var file = FileAccess.open(path, FileAccess.READ)
	if not file:
		push_error("Failed to open ability file: %s" % path)
		return abilities
	
	var json = JSON.new()
	var error = json.parse(file.get_as_text())
	file.close()
	
	if error != OK:
		push_error("Failed to parse ability JSON: %s" % json.get_error_message())
		return abilities
	
	var data = json.data
	if data is Array:
		for ability_data in data:
			abilities.append(from_dict(ability_data))
	elif data is Dictionary:
		# Single ability or wrapped in object
		if data.has("abilities"):
			for ability_data in data["abilities"]:
				abilities.append(from_dict(ability_data))
		else:
			abilities.append(from_dict(data))
	
	return abilities


## Convert to dictionary (for saving/serialization)
func to_dict() -> Dictionary:
	return {
		"id": id,
		"display_name": display_name,
		"description": description,
		"cooldown": cooldown,
		"costs": costs,
		"cast_time": cast_time,
		"interruptible": interruptible,
		"traits": traits,
		"targeting": targeting,
		"effects": effects,
		"visuals": visuals,
		"requirements": requirements,
		"animation": animation,
		"steps": steps,
	}



## Get the targeting shape for the UI
func get_target_shape() -> String:
	return targeting.get("shape", "none")


## Get the AoE radius (for circles)
func get_aoe_radius() -> float:
	return targeting.get("radius", 0.0)


## Get the AoE size (for rectangles)
func get_aoe_size() -> Vector2:
	return targeting.get("size", Vector2.ZERO)


## Whether this ability uses multi-step sequencing
func is_multi_step() -> bool:
	return steps.size() > 0


## Whether this is a Concentration spell (either casing of the trait): its
## focus cost is held while what it put into the world lasts.
func is_concentration() -> bool:
	return traits.has("Concentration") or traits.has("concentration")


# ===== INTENT =====
#
# Lives here rather than on AbilityTargeting for two reasons. `Ability` is the
# only global class the ability layer and the path-planning layer both already
# speak — AbilityTargeting.gd declares no class_name, so nothing outside its own
# node can reach its constants, and PathDrawer needs this same palette to keep its
# leader line in lockstep with the ghost it points at. And the classification is a
# property of the ability DATA, not of whichever widget happens to draw it.
#
# Static so a raw JSON dictionary can be classified without building a Resource:
# start_targeting() and create_queued_indicator() both hold the flattened
# dictionary AbilityShape.get_ability_data() produced, never an Ability.
enum Intent { NEUTRAL, HOSTILE, BENEFICIAL }

## `custom` effects are opaque method calls, so intent cannot be read off their
## payload — it has to be listed. Anything absent stays NEUTRAL rather than being
## guessed: a wrong red ring on a summon is a lie, a sepia one is merely
## uninformative.
const CUSTOM_INTENT := {
	"_self_heal": Intent.BENEFICIAL,
	"_copy_conditions": Intent.BENEFICIAL,
	"_confess": Intent.HOSTILE,
	"_hitch": Intent.HOSTILE,
	"_fatal_attraction": Intent.HOSTILE,
	"bind_soul_effect": Intent.HOSTILE,
}

## `_place_surface` is the one custom method whose intent lives in its PAYLOAD
## rather than its name — fire_spin lays down burning ground, bumper_crop lays
## down grass. Unlisted surfaces abstain.
const SURFACE_INTENT := {
	"fire_spin": Intent.HOSTILE,
	"grassy": Intent.BENEFICIAL,
}

## `fluid_well` is the same shape of problem: the intent is in the PAYLOAD, not
## the type. An oil well mires whatever wades through it and begs for a torch; a
## water well is scenery. Unlisted fluids abstain rather than being guessed.
const FLUID_INTENT := {
	"oil": Intent.HOSTILE,
	"acid": Intent.HOSTILE,
	"poison": Intent.HOSTILE,
}


# ===== INTENT PALETTE =====
#
# Iron-oxide red for harm, muted olive for help, sepia ink for neither — all three
# desaturated and warmed onto the parchment UI. The blue they replace,
# Color(0.5, 0.8, 1.0), was the only cool colour on the battlefield.
#
# Red/green is the common colour-blindness axis AND these two are the semantically
# opposite states, so they are separated on THREE redundant channels, not one:
#   1. LUMINANCE (Rec.709): hostile border ~0.43, beneficial ~0.77 — a 1.8x gap
#      that survives a greyscale or deuteranope render. Neutral sits between at
#      ~0.57 and is near-achromatic, so the ladder reads dark / mid / light.
#   2. BORDER PATTERN: beneficial is DASHED, hostile and neutral are solid. This
#      is the channel that still works at full achromatopsia.
#   3. WEIGHT AND FILL DENSITY: hostile carries the thickest border (2.6 vs 2.0)
#      and the densest fill, so "this will hurt someone standing here" is the
#      heaviest mark on screen however the colour itself is perceived.
#
# Fill alphas sit in 0.20-0.30. Above ~0.35 the fill starts hiding the bodies
# standing inside the blast, which is the one thing the player has to be able to
# count; below ~0.15 it vanishes into grass. Inside that band the BORDER does the
# shape-reading over both pale stone and dark grass and the fill only has to tint,
# which is why the pale olive can afford to be lighter than the red.
const HOSTILE_FILL := Color(0.65, 0.26, 0.17, 0.30)
const HOSTILE_FILL_QUEUED := Color(0.58, 0.23, 0.15, 0.26)
const HOSTILE_BORDER := Color(0.80, 0.34, 0.22, 0.85)
const HOSTILE_BORDER_QUEUED := Color(0.71, 0.30, 0.19, 0.80)

const BENEFICIAL_FILL := Color(0.60, 0.70, 0.38, 0.24)
const BENEFICIAL_FILL_QUEUED := Color(0.54, 0.63, 0.34, 0.20)
const BENEFICIAL_BORDER := Color(0.72, 0.82, 0.48, 0.85)
const BENEFICIAL_BORDER_QUEUED := Color(0.64, 0.74, 0.43, 0.80)

const NEUTRAL_FILL := Color(0.58, 0.49, 0.36, 0.24)
const NEUTRAL_FILL_QUEUED := Color(0.51, 0.43, 0.31, 0.20)
const NEUTRAL_BORDER := Color(0.66, 0.56, 0.41, 0.85)
const NEUTRAL_BORDER_QUEUED := Color(0.58, 0.49, 0.36, 0.80)


## HOSTILE / BENEFICIAL / NEUTRAL for `data`, a raw ability dictionary.
##
## HOSTILE DOMINATES a mixed result on purpose. The preview answers a safety
## question — "will anything standing in this ring be hurt?" — so an ability that
## both helps and harms (force_march: force_marching + exhausted;
## alms_of_the_vein: damage + bleeding + a self-heal) must read red. Green that
## also damages costs a party member; red that also buffs costs nothing but
## caution.
##
## `targeting.type` is deliberately NOT consulted. Across data/Abilities.json it
## only ever takes point/direction/self/target/characters — never enemy/ally — and
## `self` is not a beneficial signal either: repulsion_wave and force_march are
## both type "self" and both hurt everyone inside the ring.
static func classify_intent(data: Dictionary) -> int:
	var intent: int = Intent.NEUTRAL
	intent = _fold_effect_intent(data.get("effects", []), intent)
	# Multi-step abilities (pounce, ram) carry their damage per STEP, not at the
	# top level, so a step-only ability would otherwise classify as neutral.
	for step in data.get("steps", []):
		if step is Dictionary:
			intent = _fold_effect_intent(step.get("effects", []), intent)
	return intent


## Fold one effect list into a running intent. Abstentions (NEUTRAL votes) never
## overwrite a decision already made, and HOSTILE short-circuits the rest.
##
## The parameter is `effect_list`, not `effects`: `effects` is a member of this
## class, and a parameter of that name raises SHADOWED_VARIABLE.
static func _fold_effect_intent(effect_list, intent: int) -> int:
	# Ability.from_dict tolerates a bare Dictionary in place of the array; so does
	# this, because it is handed the RAW data, not the normalised Resource.
	if effect_list is Dictionary:
		effect_list = [effect_list]
	if not (effect_list is Array):
		return intent
	for e in effect_list:
		if intent == Intent.HOSTILE:
			return intent  # nothing outranks hostile; stop looking
		if not (e is Dictionary):
			continue
		var vote: int = _effect_intent(e)
		if vote != Intent.NEUTRAL:
			intent = vote
	return intent


static func _effect_intent(e: Dictionary) -> int:
	match String(e.get("type", "")):
		"damage", "knockback", "disarm":
			return Intent.HOSTILE
		"heal":
			return Intent.BENEFICIAL
		"apply_condition", "cloud":
			# `cloud` carries a condition_id too (cloud_kill -> poisoned), so one
			# buff/debuff lookup answers both.
			return _condition_intent(String(e.get("condition_id", "")))
		"remove_condition":
			# Keyed by TRAIT (heal strips "poison") or by condition id (chasten
			# ends "infatuated"). A cleanse is a favour unless what is stripped
			# is a buff.
			return Intent.HOSTILE if String(e.get("trait", "")) == "buff" else Intent.BENEFICIAL
		"custom":
			var method := String(e.get("method", ""))
			if method == "_place_surface":
				return int(SURFACE_INTENT.get(String(e.get("surface_id", "")), Intent.NEUTRAL))
			return int(CUSTOM_INTENT.get(method, Intent.NEUTRAL))
		"fluid_well":
			return int(FLUID_INTENT.get(String(e.get("fluid_type", "")), Intent.NEUTRAL))
		"compulsion_field":
			# Every compulsion is something done TO the people in the ring, and
			# these ones all end in violence or a lost turn. No payload lookup:
			# unlike a fluid, there is no benign variant.
			return Intent.HOSTILE
	# summon / force_field / spawn_fluid / sound_zone read either way — a magnetic
	# pull or a silence zone is a tool, not an attack. They ABSTAIN rather than
	# force a colour; a sibling effect (vortex's damage, gravity_well's `slowed`)
	# still gets to colour the ring.
	return Intent.NEUTRAL


## buff/debuff off the registered condition template. An unregistered id abstains
## rather than defaulting. (`rage` was exactly that case: it applied an
## unregistered "berserker_rage" and so scored NEUTRAL. It now applies the
## registered "rage" and reads BENEFICIAL off that condition's `buff` trait.)
## A missing definition is a ConditionDatabase data bug
## to fix there — not something to guess a colour from here.
static func _condition_intent(condition_id: String) -> int:
	if condition_id == "":
		return Intent.NEUTRAL
	var cond = ConditionManager.condition_registry.get(condition_id)
	if cond == null or not ("traits" in cond):
		return Intent.NEUTRAL
	var traits_dict: Dictionary = cond.traits
	if traits_dict.has("debuff"):
		return Intent.HOSTILE
	if traits_dict.has("buff"):
		return Intent.BENEFICIAL
	return Intent.NEUTRAL


## Fill colour for `intent`. `queued` picks the dimmer committed-ghost variant so
## a planned blast recedes under the one currently being aimed.
# --- The LIVE, still-being-aimed preview -------------------------------------
# Plain white, exactly as before intent colouring existed. Intent is a property
# of a COMMITTED plan: while the ring is still following the cursor the player is
# asking "where will this land", not "is this ring safe to stand in", and a
# neutral white ring reads cleanly over every surface without pre-judging a shot
# that may never be taken. Colour therefore arrives at the moment of commitment,
# which also makes committing visible in itself.
const LIVE_FILL := Color(1.0, 1.0, 1.0, 0.4)
const LIVE_BORDER := Color(1.0, 1.0, 1.0, 0.8)
const LIVE_BORDER_WIDTH := 2.0


static func intent_fill_color(intent: int, queued: bool) -> Color:
	if not queued:
		return LIVE_FILL
	match intent:
		Intent.HOSTILE:
			return HOSTILE_FILL_QUEUED
		Intent.BENEFICIAL:
			return BENEFICIAL_FILL_QUEUED
	return NEUTRAL_FILL_QUEUED


static func intent_border_color(intent: int, queued: bool) -> Color:
	if not queued:
		return LIVE_BORDER
	match intent:
		Intent.HOSTILE:
			return HOSTILE_BORDER_QUEUED
		Intent.BENEFICIAL:
			return BENEFICIAL_BORDER_QUEUED
	return NEUTRAL_BORDER_QUEUED


## Redundancy channel 3: danger is the heaviest stroke on screen. Only once
## committed -- the live ring keeps a single uniform weight so it reads as one
## consistent "you are aiming" state.
static func intent_border_width(intent: int, queued: bool) -> float:
	if not queued:
		return LIVE_BORDER_WIDTH
	return 2.6 if intent == Intent.HOSTILE else 2.0


## Redundancy channel 2: the one that still works in full greyscale. Committed
## rings only, for the same reason as the width.
static func intent_border_dashed(intent: int, queued: bool) -> bool:
	return queued and intent == Intent.BENEFICIAL
