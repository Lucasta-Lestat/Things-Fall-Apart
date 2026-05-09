# res://Items/Item.gd
extends AnimatableBody2D
class_name Item

# TODO(phase-b): switch to RigidBody2D with gravity_scale = 0 so items can be
# moved by force fields and projectile impacts as part of the KE-based gameplay
# pass. AnimatableBody2D is kinematic — forces don't affect it without a custom
# velocity loop. The collision layer below stays the same; only the base class
# changes.

signal destroyed(item)
signal health_changed(current_health, max_health, item)
signal stack_changed(count, item)

@export var id: StringName
var display_name: String = ""
var description: String = ""
var weight: float = 0.5
var cost: float = 1.0
var equip_slot: String = ""
var use_ability = null
var healing: float = 0.0
var weapon_range: float = 50.0
var adds_condition_on_equip = null
var triggers_ability_on_equip = null
var adds_condition_in_inventory = null
var is_stackable: bool = false
var max_stack_size: int = 1
var stack_count: int = 1
var num_slots: int = 0
var key = null
var contents = null
var sprite_path: String = ""
var walkability: float = 1.1
var item_type: String = ""

var current_health: int = 1
var max_health: int = 1
var size: Vector2 = Vector2(16, 16)
var resources: Dictionary = {}
var damage_resistances: Dictionary = {
	"slashing": 0, "bludgeoning": 0, "piercing": 0,
	"fire": 0, "cold": 0, "electric": 0, "sonic": 0,
	"poison": 0, "acid": 0, "radiant": 0, "necrotic": 0
}
var damage: Dictionary = {"bludgeoning": 1}
var primary_damage_type: String = "bludgeoning"
var traits: Dictionary = {}
var options: Array = []

# Container/chest spawn-time loot generation. Set by Game.create_item from per-spawn data
# in Maps.json before _ready runs. If controlling_faction is set and contents are empty,
# _apply_item_data fills the chest with random faction-appropriate items + gold totalling
# loot_value (which falls back to cost when not overridden).
var controlling_faction: String = ""
var loot_value: float = -1.0  # sentinel: <0 means "use cost"

@onready var floating_text_label: RichTextLabel = $FloatingTextLabel
@onready var sprite: Sprite2D = $Sprite
@onready var collision_shape: CollisionShape2D = $CollisionShape2D
@onready var stack_label: RichTextLabel = $StackLabel

var _grid_pos: Vector2i = Vector2i.ZERO
var _cursor_active: bool = false

const PICKUP_CURSOR_TEXTURE := preload("res://UI/pickup-cursor.png")
# First-interact options that should swap the cursor to the pickup cursor while hovered.
const _PICKUP_CURSOR_OPTIONS := ["Open", "Pickup"]

func _ready():
	# Items are walkable and don't block vision, but should be detectable by
	# projectiles, force fields, and other items via the ITEMS layer.
	collision_layer = CollisionLayers.ITEMS
	collision_mask = CollisionLayers.ITEM_PHYSICS_MASK
	# Render above structures (z=-3), floors (z=-4), and the cemetery's tile
	# layer; below characters (z=5) so they can stand on top. Without this,
	# items inherit z=0 from the .tscn, which is in the same render bucket as
	# anything else with no explicit z and can flicker behind unrelated nodes.
	z_index = 1
	_apply_item_data()
	floating_text_label.visible = false
	floating_text_label.z_index = 200
	floating_text_label.z_as_relative = false
	_update_stack_label()
	_grid_pos = GridManager.world_to_map(global_position)
	global_position = GridManager.map_to_world(_grid_pos)
	GridManager.register_object(_grid_pos, self)
	# Enable mouse hover signals so we can swap the cursor for pickup-style items.
	input_pickable = true
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)

func _on_mouse_entered() -> void:
	if options.size() > 0 and options[0] in _PICKUP_CURSOR_OPTIONS:
		Input.set_custom_mouse_cursor(PICKUP_CURSOR_TEXTURE)
		_cursor_active = true

func _on_mouse_exited() -> void:
	if _cursor_active:
		Input.set_custom_mouse_cursor(null)
		_cursor_active = false

func _exit_tree() -> void:
	# Reset the cursor if this item was the active hover target when freed —
	# otherwise the pickup cursor would persist after the item disappears.
	if _cursor_active:
		Input.set_custom_mouse_cursor(null)
		_cursor_active = false

func _apply_item_data():
	var data = _lookup_item_data()
	if not data:
		printerr("Failed to get data for item_id: ", id)
		return

	# Name — items use display_name, weapons/equipment use name
	display_name = data.get("display_name", data.get("name", str(id)))

	# Health — items use max_hp/hp, weapons/equipment use max_health/current_health
	max_health = int(data.get("max_health", data.get("max_hp", 1)))
	current_health = int(data.get("current_health", data.get("hp", max_health)))

	# Resources (only some items have these)
	var res_data = data.get("resources", {})
	resources = res_data.duplicate() if res_data else {}

	# Sprite
	sprite_path = data.get("sprite_path", "res://Structures/Item.png")
	if not FileAccess.file_exists(sprite_path):
		sprite_path = "res://Structures/Item.png"

	# Core properties with safe defaults
	description = data.get("description", "")
	weight = float(data.get("weight", 0.5))
	cost = float(data.get("cost", 1.0))
	equip_slot = data.get("equip_slot", "")
	use_ability = data.get("use_ability", null)
	healing = float(data.get("healing", 0.0))
	weapon_range = float(data.get("range", 50.0))
	walkability = float(data.get("walkability", 1.1))
	item_type = data.get("type", "item")

	# Conditional properties
	adds_condition_on_equip = data.get("adds_condition_on_equip", null)
	triggers_ability_on_equip = data.get("triggers_ability_on_equip", null)
	adds_condition_in_inventory = data.get("adds_condition_in_inventory", null)

	# Stacking
	is_stackable = bool(data.get("is_stackable", false))
	max_stack_size = int(data.get("max_stack_size", 1)) if is_stackable else 1
	stack_count = int(data.get("num_stacks", 1)) if data.get("num_stacks", null) != null else 1

	# Container properties
	num_slots = int(data.get("num_slots", 0)) if data.get("num_slots", null) != null else 0
	key = data.get("key", null)
	contents = data.get("contents", null)

	# Combat
	var damage_data = data.get("damage", {"bludgeoning": 1})
	damage = damage_data if damage_data else {"bludgeoning": 1}
	primary_damage_type = data.get("primary_damage_type", "bludgeoning")

	# Resistances
	var res_dict = data.get("damage_resitances", data.get("damage_resistances", {}))
	if res_dict:
		for key_name in res_dict:
			damage_resistances[key_name] = res_dict[key_name]

	# Traits and options. JSON uses "interact_options" as the canonical key;
	# "options" is accepted as a legacy fallback.
	traits = data.get("traits", {})
	options = data.get("interact_options", data.get("options", []))

	# Size (equipment has base_width/base_height, others may not)
	var w = float(data.get("base_width", 16.0))
	var h = float(data.get("base_height", 16.0))
	size = Vector2(w, h)

	# Apply sprite and scale to base_width/base_height
	sprite.texture = load(sprite_path)
	if sprite.texture:
		scale_sprite(size)

	# Default loot_value to this item's cost if no per-spawn override was provided.
	if loot_value < 0.0:
		loot_value = cost

	# Faction-controlled chests: if no explicit contents were defined, fill the
	# chest with random faction-appropriate items + gold totalling loot_value.
	if num_slots > 0 and controlling_faction != "":
		var has_explicit_contents := contents is Array and not (contents as Array).is_empty()
		if not has_explicit_contents:
			contents = _generate_chest_contents(controlling_faction, loot_value)

func _generate_chest_contents(faction_id: String, target_value: float) -> Array:
	var generated: Array = []
	var total: float = 0.0
	var candidates := _gather_faction_filtered_items(faction_id)
	candidates.shuffle()
	for pick in candidates:
		var pick_cost := float(pick.get("cost", 1.0))
		generated.append(pick.duplicate(true))
		total += pick_cost
		if total > target_value:
			generated.pop_back()
			total -= pick_cost
			break
	var gold_needed := target_value - total
	if gold_needed > 0.0:
		var gold_data := _lookup_item_data_by_id("gold")
		if not gold_data.is_empty():
			var gold_entry := gold_data.duplicate(true)
			gold_entry["num_stacks"] = int(round(gold_needed))
			generated.append(gold_entry)
	return generated

func _gather_faction_filtered_items(faction_id: String) -> Array:
	var pool: Array = []
	for db in [ItemDatabase.weapons, ItemDatabase.equipment, ItemDatabase.items]:
		for item_key in db.keys():
			var data: Dictionary = db[item_key]
			if int(data.get("num_slots", 0)) > 0:
				continue  # don't nest chests inside chests
			if str(data.get("id", "")) == "gold":
				continue  # gold is the remainder filler, never drawn as loot
			if FactionDatabase.item_passes_faction_filter(data, faction_id):
				pool.append(data)
	return pool

func _lookup_item_data_by_id(item_id: String) -> Dictionary:
	if ItemDatabase.items.has(item_id):
		return ItemDatabase.items[item_id]
	if ItemDatabase.weapons.has(item_id):
		return ItemDatabase.weapons[item_id]
	if ItemDatabase.equipment.has(item_id):
		return ItemDatabase.equipment[item_id]
	return {}

func _lookup_item_data() -> Dictionary:
	"""Find this item's data across all database categories."""
	var item_key = Globals.name_to_id(str(id))
	if ItemDatabase.weapons.has(item_key):
		return ItemDatabase.weapons[item_key]
	if ItemDatabase.equipment.has(item_key):
		return ItemDatabase.equipment[item_key]
	if ItemDatabase.items.has(item_key):
		return ItemDatabase.items[item_key]
	# Also try the raw id directly
	if ItemDatabase.weapons.has(str(id)):
		return ItemDatabase.weapons[str(id)]
	if ItemDatabase.equipment.has(str(id)):
		return ItemDatabase.equipment[str(id)]
	if ItemDatabase.items.has(str(id)):
		return ItemDatabase.items[str(id)]
	return {}

# ===== STACK MANAGEMENT =====

func _update_stack_label():
	if stack_label:
		if is_stackable and stack_count > 1:
			stack_label.text = str(stack_count)
			stack_label.visible = true
		else:
			stack_label.visible = false

func add_to_stack(amount: int = 1) -> int:
	"""Add to stack. Returns the overflow (amount that didn't fit)."""
	var space = max_stack_size - stack_count
	var added = mini(amount, space)
	stack_count += added
	_update_stack_label()
	emit_signal("stack_changed", stack_count, self)
	return amount - added

func remove_from_stack(amount: int = 1) -> int:
	"""Remove from stack. Returns actual amount removed."""
	var removed = mini(amount, stack_count)
	stack_count -= removed
	_update_stack_label()
	emit_signal("stack_changed", stack_count, self)
	if stack_count <= 0:
		_destroy_item()
	return removed

# ===== DAMAGE =====

func take_damage(amount: Dictionary, success_level: int = 0):
	var damage_multiplier = pow(1.5, success_level)
	for damage_type in amount.keys():
		var resistance = damage_resistances.get(damage_type, 0)
		current_health = max(0, current_health - int(amount[damage_type] * damage_multiplier - resistance))

		var color = _get_damage_color(damage_type)
		show_floating_text(str(amount[damage_type]), color, success_level)

	var tween = create_tween()
	tween.tween_property(sprite, "modulate", Color.RED, 0.1)
	tween.tween_property(sprite, "modulate", Color.WHITE, 0.1)

	emit_signal("health_changed", current_health, max_health, self)

	if current_health <= 0:
		_destroy_item()

func _get_damage_color(damage_type: String) -> Color:
	match damage_type:
		"fire": return Color.CRIMSON
		"electric": return Color.YELLOW
		"cold": return Color.ALICE_BLUE
		"acid": return Color.DARK_GREEN
		"radiant": return Color.LIGHT_GOLDENROD
		"necrotic": return Color.BLACK
		"poison": return Color.BLUE_VIOLET
		_: return Color.WHITE_SMOKE

func show_floating_text(text: String, color: Color = Color.WHITE, success_level: int = 0):
	var formatted_text = "[b]" + text + "[/b]" if success_level else text
	floating_text_label.text = formatted_text
	floating_text_label.modulate = color
	var scale_multiplier = 0.91 * success_level if success_level else 0.7
	floating_text_label.scale = Vector2(scale_multiplier, scale_multiplier)
	floating_text_label.visible = true

	var tween = create_tween().set_parallel()
	tween.tween_property(floating_text_label, "position", Vector2(0, -70), 0.9).from(Vector2(0, -40))
	tween.tween_property(floating_text_label, "modulate:a", 0.0, 0.9)
	tween.chain().tween_callback(func(): floating_text_label.visible = false)

func _destroy_item():
	GridManager.unregister_object(_grid_pos, self)
	emit_signal("destroyed", self)
	sprite.visible = false
	collision_shape.disabled = true
	queue_free()

# ===== UTILITY =====

func change_texture(texture_path: String):
	sprite.texture = load(texture_path)

func scale_sprite(new_size: Vector2):
	var initial_texture_size = sprite.texture.get_size()
	var size_ratio = new_size.x / initial_texture_size.x
	sprite.scale = Vector2(size_ratio, size_ratio)
