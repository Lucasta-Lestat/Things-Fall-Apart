# Ability.gd
# Defines an ability that can be loaded from JSON and executed.
# Supports multi-step sequences for complex abilities (e.g. dash then AoE attack).
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

## Cooldown in seconds
@export var cooldown: float = 0.0

## Resource costs (e.g., {"MP": 10, "stamina": 5})
@export var costs: Dictionary = {}

## Casting time in seconds for the first (or only) step
@export var cast_time: float = 0.0

## Whether the ability can be interrupted during casting
@export var interruptible: bool = true

## Traits this ability has (e.g., "spell", "fire", "attack", "magical")
@export var traits: Dictionary = {}

## Targeting configuration (used for single-step abilities or as default)
@export var targeting: Dictionary = {
	"type": "none",
	"range": 0.0,
	"shape": "none",
	"radius": 0.0,
	"size": Vector2.ZERO,
	"angle": 0.0,
}

## Effects this ability produces (for single-step abilities; use steps for multi-step)
@export var effects: Array = []

## Multi-step sequence. Each step is a Dictionary with:
##   cast_time: float        — seconds to cast this step (0 = instant)
##   targeting: Dictionary   — optional per-step targeting override
##   effects: Array          — effect dicts executed at this step
##   visuals: Dictionary     — cast_effect, projectile, impact_effect paths for this step
##   move_to_target: bool    — if true, caster teleports to target_position before effects
##
## If empty, the ability executes as a single step using the top-level fields.
@export var steps: Array = []

## Visual effects configuration (used for single-step abilities)
@export var visuals: Dictionary = {
	"cast_effect": "",
	"projectile": "",
	"impact_effect": "",
	"sound_cast": "",
	"sound_impact": "",
}

## Conditions required to use this ability
@export var requirements: Dictionary = {
	"conditions": [],
	"no_conditions": [],
	"traits": [],
}

## Animation to play when using
@export var animation: String = ""


## Returns the list of steps to execute.
## If steps is empty, wraps top-level fields as a single implicit step.
func get_steps() -> Array:
	if not steps.is_empty():
		return steps
	return [{
		"cast_time": cast_time,
		"targeting": targeting,
		"effects": effects,
		"visuals": visuals,
		"move_to_target": false,
	}]


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
	ability.effects = data.get("effects", [])
	ability.steps = _parse_steps(data.get("steps", []))
	ability.visuals = data.get("visuals", {})
	ability.requirements = data.get("requirements", {})
	ability.animation = data.get("animation", "")

	var icon_path = data.get("icon", "")
	if icon_path != "" and ResourceLoader.exists(icon_path):
		ability.icon = load(icon_path)

	return ability


static func _parse_steps(raw: Array) -> Array:
	var result: Array = []
	for step_data in raw:
		result.append({
			"cast_time": step_data.get("cast_time", 0.0),
			"targeting": _parse_targeting(step_data.get("targeting", {})),
			"effects": step_data.get("effects", []),
			"visuals": step_data.get("visuals", {}),
			"move_to_target": step_data.get("move_to_target", false),
		})
	return result


static func _parse_targeting(data: Dictionary) -> Dictionary:
	return {
		"type": data.get("type", "none"),
		"range": data.get("range", 0.0),
		"shape": data.get("shape", "none"),
		"radius": data.get("radius", 0.0),
		"size": _parse_vector2(data.get("size", {})),
		"angle": data.get("angle", 0.0),
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
		"steps": steps,
		"visuals": visuals,
		"requirements": requirements,
		"animation": animation,
	}


## Get the targeting shape for the UI.
## Uses the first step's targeting if it has one, otherwise falls back to top-level targeting.
func get_target_shape() -> String:
	var t = targeting
	if not steps.is_empty():
		var first_step_targeting = steps[0].get("targeting", {})
		if first_step_targeting.get("shape", "none") != "none":
			t = first_step_targeting
	return t.get("shape", "none")


## Get the AoE radius (for circles)
func get_aoe_radius() -> float:
	var t = targeting
	if not steps.is_empty():
		var first_step_targeting = steps[0].get("targeting", {})
		if first_step_targeting.get("shape", "none") != "none":
			t = first_step_targeting
	return t.get("radius", 0.0)


## Get the AoE size (for rectangles)
func get_aoe_size() -> Vector2:
	var t = targeting
	if not steps.is_empty():
		var first_step_targeting = steps[0].get("targeting", {})
		if first_step_targeting.get("shape", "none") != "none":
			t = first_step_targeting
	return t.get("size", Vector2.ZERO)
