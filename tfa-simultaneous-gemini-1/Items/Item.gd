# res://Items/Item.gd
extends AnimatableBody2D
class_name Item

const EquipmentEffects = preload("res://Items/equipment_effects.gd")

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
# Per-step noise contribution when this item is worn/equipped. Overridable
# from Items.json via the "noise_per_step" key; otherwise inferred from
# type + name by EquipmentShape.noise_for_item_data (same as when worn).
var noise_per_step: float = 0.0

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

# --- Ownership (law/crime system, docs/law_crime_stealth_plan.md Phase 4) ---
# NOT named `owner` — Node.owner already exists, and ai.gd's
# is_item_owned_by_ally was a live bug caused by exactly that shadowing.
var owner_faction: String = ""   # "" == unowned, free to take
var owner_uid: String = ""       # optional specific NPC; the seam for per-NPC grudges
var stolen_from: String = ""     # stamped on take; drives confiscation and fencing

# --- Provenance (quest proof) ---
# Stamped when a trophy is harvested from a corpse; {template_id, name, race,
# taken_on_day}. Empty on ordinary items. This is what makes a bounty head
# *this* victim's head rather than any head, so it has to survive a drop and a
# map unload the same way stolen_from does. `origin_display_name` carries the
# per-instance name ("Severed Head of Ser Brannoc") because _apply_item_data
# otherwise overwrites display_name from the database entry.
var origin: Dictionary = {}
var origin_display_name: String = ""

# --- RUN furniture (Items/RunLayout.gd) ---
# A spawn carrying "length" is a RUN: one continuous strip (a banquet table, a
# bar counter, a pew) drawn by a RunRenderer child at any length, instead of N
# butt-joined sprites. Set by Game.create_item (extras.run) before _ready.
# Runs are FIXED furniture: no Pick Up, no NPC theft, no hover (collision
# layer 0 -- also invisible to projectiles/force fields; AoE still finds the
# centre through items_in_scene). Durability scales with the length.
var run: Dictionary = {}
var fixed: bool = false

@onready var floating_text_label: RichTextLabel = $FloatingTextLabel
@onready var sprite: Sprite2D = $Sprite
@onready var collision_shape: CollisionShape2D = $CollisionShape2D
@onready var stack_label: RichTextLabel = $StackLabel

var _grid_pos: Vector2i = Vector2i.ZERO
var _cursor_active: bool = false

const PICKUP_CURSOR_TEXTURE := preload("res://UI/pickup-cursor.png")
# First-interact options that should swap the cursor to the pickup cursor while hovered.
const _PICKUP_CURSOR_OPTIONS := ["Open", "Pickup"]
# Readables (notes/books) swap to a book cursor instead. Loaded at hover time
# (not preloaded) so the project still parses before the art is generated.
const READABLE_CURSOR_PATH := "res://UI/readable-cursor.png"

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
	# Register on the grid WITHOUT snapping the visual to the tile centre:
	# authored furniture (map item_spawns) is composed sub-tile, and the old
	# 32px quantization shoved ring stools onto tables, butted adjacent
	# banquet tables into each other, and pushed wall pieces into the
	# masonry. The registry only needs the tile key, not a centred sprite.
	_grid_pos = GridManager.world_to_map(global_position)
	GridManager.register_object(_grid_pos, self)
	# Enable mouse hover signals so we can swap the cursor for pickup-style items.
	input_pickable = true
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)

func _on_mouse_entered() -> void:
	if options.is_empty():
		return
	if item_type == "readable" or str(options[0]) == "Read":
		# Readables show a book cursor. Single cursor (no read/unread variant):
		# reading or taking removes the world object, so a hovered readable is
		# always one the player hasn't acquired yet.
		if ResourceLoader.exists(READABLE_CURSOR_PATH):
			Input.set_custom_mouse_cursor(load(READABLE_CURSOR_PATH))
		else:
			Input.set_custom_mouse_cursor(PICKUP_CURSOR_TEXTURE)
		_cursor_active = true
	elif options[0] in _PICKUP_CURSOR_OPTIONS:
		Input.set_custom_mouse_cursor(PICKUP_CURSOR_TEXTURE)
		_cursor_active = true

func _on_mouse_exited() -> void:
	if _cursor_active:
		CursorManager.reset()
		_cursor_active = false

func _exit_tree() -> void:
	# Reset the cursor if this item was the active hover target when freed —
	# otherwise the pickup cursor would persist after the item disappears.
	if _cursor_active:
		CursorManager.reset()
		_cursor_active = false

# Texture for the hover cursor while the player's mouse is over this item.
# Driven per-frame by ProceduralCharacter._update_hover_cursor (the mouse_entered
# signal is unreliable here — the GUI layer suppresses physics mouse picking).
# Readables show the book cursor; every other world item shows the pickup cursor
# (all world items can be picked up).
func get_hover_cursor_texture() -> Texture2D:
	if item_type == "readable" or (options.size() > 0 and str(options[0]) == "Read"):
		if ResourceLoader.exists(READABLE_CURSOR_PATH):
			return load(READABLE_CURSOR_PATH) as Texture2D
		return PICKUP_CURSOR_TEXTURE
	return PICKUP_CURSOR_TEXTURE

func _apply_item_data():
	# Readables resolve their title/text from ReadableDatabase, not the item
	# database. Branch first so the item-DB miss printerr below never fires for
	# them and they never need a stub entry in Items.json.
	if ReadableDatabase != null and ReadableDatabase.has_readable(str(id)):
		_apply_readable_data(ReadableDatabase.get_readable(str(id)))
		return
	var data = _lookup_item_data()
	if not data:
		printerr("Failed to get data for item_id: ", id)
		return

	# Name — items use display_name, weapons/equipment use name.
	# A harvested trophy's per-instance name wins over the database entry, so a
	# dropped head stays "Severed Head of Ser Brannoc" instead of reverting to
	# the generic "Severed Head".
	display_name = data.get("display_name", data.get("name", str(id)))
	if not origin_display_name.is_empty():
		display_name = origin_display_name

	# Health — items use max_hp/hp, weapons/equipment use max_health/current_health
	max_health = int(data.get("max_health", data.get("max_hp", 1)))
	current_health = int(data.get("current_health", data.get("hp", max_health)))

	# Resources (only some items have these)
	var res_data = data.get("resources", {})
	resources = res_data.duplicate() if res_data else {}

	# Sprite
	var _spr = data.get("sprite_path", "res://Structures/Item.png")
	sprite_path = str(_spr) if _spr != null else "res://Structures/Item.png"
	if not FileAccess.file_exists(sprite_path):
		sprite_path = "res://Structures/Item.png"

	# Core properties with safe defaults. NOTE: .get() defaults do NOT protect
	# against explicit JSON nulls ("equip_slot": null returns null, not "") —
	# every typed-String field must coerce.
	var _desc = data.get("description", "")
	description = str(_desc) if _desc != null else ""
	weight = float(data.get("weight", 0.5) if data.get("weight") != null else 0.5)
	cost = float(data.get("cost", 1.0) if data.get("cost") != null else 1.0)
	var _slot = data.get("equip_slot", "")
	equip_slot = str(_slot) if _slot != null else ""
	use_ability = data.get("use_ability", null)
	healing = float(data.get("healing", 0.0) if data.get("healing") != null else 0.0)
	weapon_range = float(data.get("range", 50.0) if data.get("range") != null else 50.0)
	walkability = float(data.get("walkability", 1.1) if data.get("walkability") != null else 1.1)
	var _itype = data.get("type", "item")
	item_type = str(_itype) if _itype != null else "item"
	noise_per_step = EquipmentShape.noise_for_item_data(data)

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

	# A dropped glowing item (Flaming Sword, Golden Crown) keeps glowing; the
	# light hides with the item when the party can't see it.
	var glow := EquipmentEffects.light_level(data)
	if glow > 0.0 and get_node_or_null("EmittedLight") == null:
		add_child(EquipmentEffects.make_light(glow, traits))

	# Size (equipment has base_width/base_height, others may not)
	var w = float(data.get("base_width", 16.0))
	var h = float(data.get("base_height", 16.0))
	size = Vector2(w, h)

	# Apply sprite and scale to base_width/base_height
	sprite.texture = load(sprite_path)
	if sprite.texture:
		scale_sprite(size)
	if not run.is_empty():
		_apply_run(data, w)

	# Default loot_value to this item's cost if no per-spawn override was provided.
	if loot_value < 0.0:
		loot_value = cost

	# Faction-controlled chests: if no explicit contents were defined, fill the
	# chest with random faction-appropriate items + gold totalling loot_value.
	if num_slots > 0 and controlling_faction != "":
		var has_explicit_contents := contents is Array and not (contents as Array).is_empty()
		if not has_explicit_contents:
			contents = _generate_chest_contents(controlling_faction, loot_value)

# The RUN branch of _apply_item_data: hide the plain sprite, draw the strip
# through a RunRenderer, become fixed furniture, scale hp with the length.
# A missing/unloadable "run" block falls back to stretching the sprite along
# x (with a warning) so a stale import never leaves a hole in the room.
func _apply_run(data: Dictionary, base_w: float) -> void:
	var length: float = float(run.get("length", 0.0))
	fixed = true
	collision_layer = 0
	var hp_k: float = maxf(1.0, length / maxf(base_w, 1.0))
	max_health = int(round(float(max_health) * hp_k))
	current_health = max_health
	var mv: Variant = data.get("run")
	var meta: Dictionary = mv if mv is Dictionary else {}
	if meta.is_empty() or RunRenderer.texture_for(String(meta.get("atlas", ""))) == null:
		push_warning("Item %s: run spawn without a loadable Items.json run atlas; stretching the sprite" % str(id))
		if sprite.texture:
			sprite.scale.x *= length / maxf(base_w, 1.0)
		return
	sprite.visible = false
	var rr := RunRenderer.new()
	rr.name = "RunRenderer"
	rr.setup(meta, run)
	add_child(rr)

func _apply_readable_data(data: Dictionary) -> void:
	# Minimal world setup for a readable. Title/body live in ReadableDatabase;
	# here we only configure the world object so it renders, is hoverable, and
	# offers the "Read"/"Take" context options. Readables never enter inventory.
	item_type = "readable"
	display_name = str(data.get("title", str(id)))
	description = ""
	var raw_options = data.get("interact_options", ["Read", "Take"])
	options = raw_options if raw_options is Array else ["Read", "Take"]

	# World sprite (with the shared Item.png fallback).
	sprite_path = str(data.get("world_sprite_path", "res://Structures/Item.png"))
	if not FileAccess.file_exists(sprite_path):
		sprite_path = "res://Structures/Item.png"

	var w: float = float(data.get("world_width", 18.0))
	var h: float = float(data.get("world_height", 18.0))
	size = Vector2(w, h)
	sprite.texture = load(sprite_path)
	if sprite.texture:
		scale_sprite(size)

	# Weightless, free, never stacks, not a container.
	weight = 0.0
	cost = 0.0
	is_stackable = false
	max_stack_size = 1
	stack_count = 1
	num_slots = 0
	contents = null
	walkability = 1.1
	noise_per_step = 0.0

# Options interact() actually handles. Game._world_item_options hides any other
# data option on a world container (e.g. "Inspect", or a backpack's
# inventory-only "Drop"/"Equip") rather than offer a click that does nothing.
# "Open" is handled by the context menu itself. Keep in sync with interact().
const INTERACT_OPTIONS := ["Read", "Take", "Pick Up", "Pick Up (owned)"]

# Called by the context menu (UI/context_menu.gd default branch) and by the
# left-click fast-path in ProceduralCharacter. Reading or taking a readable
# files it into the journal and removes the world object.
func interact(option: String) -> void:
	match option:
		"Read":
			_read_from_world()
		"Take":
			_take_from_world()
		"Pick Up", "Pick Up (owned)":
			var g = get_node_or_null("/root/Game")
			if g != null and g.has_method("pick_up_item"):
				g.pick_up_item(self)
		_:
			pass

func _read_from_world() -> void:
	var g = get_node_or_null("/root/Game")
	if g != null and g.has_method("show_readable"):
		g.show_readable(str(id))
	_destroy_item()

func _take_from_world() -> void:
	if ReadableManager != null:
		ReadableManager.collect(str(id))
	_destroy_item()

# Container lock gate, same feedback as Door: a container with a "key" opens
# only if a living party member carries that key (not consumed). Returns true
# when the container may open; unlocking clears the key so it stays open.
# Game.show_chest_inventory (the menu's "Open" and the left-click fast path)
# calls it before showing the window.
func try_unlock_for_party(party: Array) -> bool:
	if not (key is String) or (key as String).is_empty():
		return true
	var res: Dictionary = Door.try_party_unlock(party, key, false)
	if not res.ok:
		show_floating_text("Locked", Color.WHITE_SMOKE)
		GameLog.add_entry("The %s is locked." % display_name)
		return false
	GameLog.add_entry("%s unlocks the %s with the %s." % [res.holder_name, display_name, res.key_name])
	key = null
	return true

# Build an inventory item dict for this world item (used by Pick Up). Pulls the
# canonical data from the item database and carries the current stack count.
func to_inventory_data() -> Dictionary:
	var data = _lookup_item_data()
	if data.is_empty():
		return {}
	var dict: Dictionary = data.duplicate(true)
	if is_stackable:
		dict["num_stacks"] = stack_count
	# Ownership rides into the inventory. Free persistence: the party save
	# duplicates inventory dicts wholesale, so these keys round-trip with
	# zero serializer changes.
	if owner_faction != "":
		dict["stolen_from"] = owner_faction
		dict["stolen_value"] = cost
	# Provenance rides back into the inventory the same way, so a head that was
	# dropped and re-taken still satisfies the bounty it was harvested for.
	if not origin.is_empty():
		dict["origin"] = origin.duplicate(true)
	if not origin_display_name.is_empty():
		dict["display_name"] = origin_display_name
	return dict


func _generate_chest_contents(faction_id: String, target_value: float) -> Array:
	var generated: Array = []
	var total: float = 0.0
	var candidates := _gather_faction_filtered_items(faction_id)
	candidates.shuffle()
	for pick in candidates:
		var cost_val = pick.get("cost", 1.0)
		var pick_cost: float = float(cost_val) if cost_val != null else 1.0
		generated.append(pick.duplicate(true))
		total += pick_cost
		if total > target_value:
			generated.pop_back()
			total -= pick_cost
			break
	var change_needed := target_value - total
	if change_needed > 0.0:
		# Fill the remaining value with a random Currency-trait item (gold,
		# cigarette, ...) so chests pay "change" in any tagged currency.
		var cur_data := ItemDatabase.random_currency_data("gold")
		if not cur_data.is_empty():
			var cur_entry := cur_data.duplicate(true)
			cur_entry["num_stacks"] = int(round(change_needed))
			generated.append(cur_entry)
	return generated

func _gather_faction_filtered_items(faction_id: String) -> Array:
	var pool: Array = []
	for db in [ItemDatabase.weapons, ItemDatabase.equipment, ItemDatabase.items]:
		for item_key in db.keys():
			var data: Dictionary = db[item_key]
			# num_slots in JSON is often `null` rather than missing — int(null) is
			# illegal in GDScript, so coerce defensively.
			var slots_val = data.get("num_slots", 0)
			var slots: int = int(slots_val) if slots_val != null else 0
			if slots > 0:
				continue  # don't nest chests inside chests
			if ItemDatabase.is_currency(data):
				continue  # currency items are the change filler, never drawn as loot
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

		var color = Globals.damage_color(damage_type)
		show_floating_text(str(amount[damage_type]), color, success_level)

	var tween = create_tween()
	tween.tween_property(sprite, "modulate", Color.RED, 0.1)
	tween.tween_property(sprite, "modulate", Color.WHITE, 0.1)

	emit_signal("health_changed", current_health, max_health, self)

	if current_health <= 0:
		_destroy_item()

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
