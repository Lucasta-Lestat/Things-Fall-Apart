# res://Structures/HexIcons/hex_icon.gd
# Runtime world-map building/feature icon. A HexIcon is a stamp placed on top of
# a HexTile — it carries gameplay properties (garrison capacity, production
# output, morale bonus, defense bonus, etc.) loaded from HexIconDatabase.
extends Node2D
class_name HexIcon

signal destroyed(hex_icon, axial_position)
signal health_changed(current_health, max_health, hex_icon)

# Identifies which row of hex_icons.json this icon uses.
@export var icon_id: StringName

# Axial position of the hex this icon is placed on. Set by the world map.
@export var axial_position: Vector2i = Vector2i.ZERO

# Owning faction (optional; for civilian buildings this may stay empty).
@export var faction_id: StringName = ""

# Display + gameplay properties (populated by apply_icon_data).
var display_name: String = ""
var description: String = ""
var category: String = ""
var current_health: int = 0
var max_health: int = 0
var flammable: bool = false
var blocks_sight: bool = false
var vision_modifier: float = 1.0
var damage_resistances: Dictionary = {}
var resources: Dictionary = {}

# Category-specific properties; only set on relevant icons.
var garrison_capacity: int = 0
var defense_bonus: float = 0.0
var produces: Dictionary = {}
var production_interval_days: int = 0
var research_rate: float = 0.0
var morale_bonus: float = 0.0

@onready var sprite: Sprite2D = $Sprite

func _ready() -> void:
	apply_icon_data()

func apply_icon_data() -> void:
	var data: Variant = HexIconDatabase.hex_icon_definitions.get(String(icon_id))
	if data == null:
		printerr("HexIcon: no definition for icon_id=", icon_id)
		return
	icon_id = StringName(data.get("id", String(icon_id)))
	display_name = data.get("name", String(icon_id))
	description = data.get("description", "")
	category = data.get("category", "")
	max_health = int(data.get("max_health", 0))
	current_health = int(data.get("current_health", max_health))
	flammable = bool(data.get("flammable", false))
	blocks_sight = bool(data.get("blocks_sight", false))
	vision_modifier = float(data.get("vision_modifier", 1.0))
	resources = data.get("resources", {}).duplicate()
	damage_resistances = data.get("damage_resistances", {}).duplicate()

	garrison_capacity = int(data.get("garrison_capacity", 0))
	defense_bonus = float(data.get("defense_bonus", 0.0))
	produces = data.get("produces", {}).duplicate()
	production_interval_days = int(data.get("production_interval_days", 0))
	research_rate = float(data.get("research_rate", 0.0))
	morale_bonus = float(data.get("morale_bonus", 0.0))

	var tex_path: String = data.get("texture", "")
	if tex_path != "":
		_set_sprite_texture(tex_path)

func _set_sprite_texture(path: String) -> void:
	if sprite == null:
		return
	var tex = load(path)
	if tex == null:
		printerr("HexIcon: failed to load texture ", path)
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
