# res://Structures/HexTiles/hex_tile.gd
# Runtime world-map hex tile. Mirrors Structures/Floors/floor.gd but for the
# overworld layer. A HexTile reads its game properties (walkability, flammable,
# vision_modifier, movement_cost, resources, ...) from HexTileDatabase at _ready.
#
# Positioning: HexTile does NOT snap to the regular floor grid. The world-map
# uses its own axial-coordinate hex layout (see WorldMap when it exists). Until
# then, the caller is responsible for setting global_position.
extends Node2D
class_name HexTile

signal destroyed(hex_tile, axial_position)
signal health_changed(current_health, max_health, hex_tile)

# Identifies which row of hex_tiles.json this tile uses.
@export var tile_id: StringName

# Optional override of the texture chosen from alternate_textures. If left empty,
# a random one is picked at _ready().
@export var texture_override: String = ""

# Axial coordinate on the world-map grid (q, r). Set by the world map at spawn
# time, not snapped by the tile itself.
@export var axial_position: Vector2i = Vector2i.ZERO

# Display + gameplay properties (populated by apply_tile_data from the database).
var display_name: String = ""
var description: String = ""
var biome: String = ""
var season: String = ""
var current_health: int = 0
var max_health: int = 0
var walkability: float = 1.0
var flammable: bool = false
var conductive: bool = false
var blocks_sight: bool = false
var vision_modifier: float = 1.0
var movement_cost: float = 1.0
var passable_overworld: bool = true
var resources: Dictionary = {}
var damage_resistances: Dictionary = {
	"slashing": 0, "bludgeoning": 0, "piercing": 0,
	"fire": 0, "cold": 0, "electric": 0, "sonic": 0,
	"poison": 0, "acid": 0, "radiant": 0, "necrotic": 0,
}

@onready var sprite: Sprite2D = $Sprite

func _ready() -> void:
	apply_tile_data()

func apply_tile_data() -> void:
	var data: Variant = HexTileDatabase.hex_tile_definitions.get(String(tile_id))
	if data == null:
		printerr("HexTile: no definition for tile_id=", tile_id)
		return
	tile_id = StringName(data.get("id", String(tile_id)))
	display_name = data.get("name", String(tile_id))
	description = data.get("description", "")
	biome = data.get("biome", "")
	season = data.get("season", "")
	max_health = int(data.get("max_health", 0))
	current_health = max_health
	walkability = float(data.get("walkability", 1.0))
	flammable = bool(data.get("flammable", false))
	conductive = bool(data.get("conductive", false))
	blocks_sight = bool(data.get("blocks_sight", false))
	vision_modifier = float(data.get("vision_modifier", 1.0))
	movement_cost = float(data.get("movement_cost", 1.0))
	passable_overworld = bool(data.get("passable_overworld", true))

	resources = data.get("resources", {}).duplicate()
	# Merge in JSON-supplied damage_resistances on top of zeroed defaults.
	for k in data.get("damage_resistances", {}).keys():
		damage_resistances[k] = data["damage_resistances"][k]

	if texture_override != "":
		_set_sprite_texture(texture_override)
	else:
		var alts: Array = data.get("alternate_textures", [])
		var tex_path: String
		if alts.size() > 0:
			tex_path = alts.pick_random()
		else:
			tex_path = data.get("texture", "")
		if tex_path != "":
			_set_sprite_texture(tex_path)

func _set_sprite_texture(path: String) -> void:
	if sprite == null:
		return
	var tex = load(path)
	if tex == null:
		printerr("HexTile: failed to load texture ", path)
		return
	sprite.texture = tex

func take_damage(amount: Dictionary, success_level: int = 0) -> void:
	var damage_multiplier = pow(1.5, success_level)
	for damage_type in amount.keys():
		var resist = damage_resistances.get(damage_type, 0)
		current_health = max(0, current_health - int(amount[damage_type] * damage_multiplier - resist))
	emit_signal("health_changed", current_health, max_health, self)
	if current_health <= 0:
		emit_signal("destroyed", self, axial_position)
		queue_free()
