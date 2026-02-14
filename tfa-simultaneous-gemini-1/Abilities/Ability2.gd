# Ability.gd
# Defines an ability that can be loaded from JSON and executed
class_name Ability2
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

@export var visual_duration: float = 1.0

## Resource costs (e.g., {"MP": 10, "stamina": 5})
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


## Load an ability from a dictionary (parsed JSON)
static func from_dict(data: Dictionary) -> Ability2:
	var ability = Ability2.new()
	
	ability.id = data.get("id", "")
	ability.display_name = data.get("display_name", ability.id)
	ability.description = data.get("description", "")
	ability.cooldown = data.get("cooldown", 0.0)
	ability.costs = data.get("costs", {})
	ability.cast_time = data.get("cast_time", 0.0)
	ability.interruptible = data.get("interruptible", true)
	ability.traits = {}
	ability.targeting = _parse_targeting(data.get("targeting", {}))
	ability.effects = [] #Array of Dictionaries
	ability.visuals = data.get("visuals", {})
	ability.requirements = data.get("requirements", {})
	ability.animation = data.get("animation", "")
	
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
