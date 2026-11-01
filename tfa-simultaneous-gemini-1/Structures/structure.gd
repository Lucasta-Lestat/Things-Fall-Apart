# res://Structures/Structure.gd
extends StaticBody2D
class_name Structure

signal destroyed(structure, grid_position)
signal health_changed(current_health, max_health, structure)

@export var structure_id: StringName

var current_health: int
var max_health: int
var size: Vector2
var resources: Dictionary = {} # e.g., {"wood": 20}
var damage_resistances = {"slashing": 0, "bludgeoning": 0, "piercing": 0, "fire": 0, "cold": 0, "electric": 0, "sonic":0, "poison":0, "acid":0, "radiant":0, "necrotic":0 }
var damage: Dictionary = {"bludgeoning": 1} 
var flammable: bool = false
var use_custom_texture: bool = false
var custom_texture: ImageTexture
var skip_grid_snap: bool = false
var custom_size: Vector2 = Vector2.ZERO
var occupied_tiles: Array[Vector2i] = []
# Tiles the structure's REAL geometry covers (no pathing margin). Structured
# maps inflate occupied_tiles by a body-width so pathfinding keeps clear --
# the fire system must not treat that halo as "a structure stands here", or
# invisible stone-wall margins veto ignition of plain grass around buildings.
# Empty = legacy map -> consumers fall back to occupied_tiles (tile-exact there).
var fire_blocking_tiles: Array[Vector2i] = []
# Per-hit console log. Off: a spreading fire damages ~100 walls every second
# and each print_rich is a synchronous stdout write (a measurable hitch).
const LOG_DAMAGE := false
# Walkable elevated deck (structured maps, "walk_elev" instances): the body sits
# on VISION_BLOCKERS only and registers deck elevations instead of obstacles.
var is_deck: bool = false
var deck_elevation: float = 0.0
var deck_tiles: Array[Vector2i] = []

# Damage states, by fraction of max_health: Damaged below full, Cracking at
# half, Crumbling at a quarter. Each darkens the art a step (DAMAGE_TINT, RGB
# of self_modulate) and a hit that crosses into Cracking/Crumbling floats the
# word once. _refresh_tint is the only writer of _visual().self_modulate;
# Door folds its open-door fade in through _tint_alpha().
enum DamageState { INTACT, DAMAGED, CRACKING, CRUMBLING }
const CRACKING_FRAC := 0.5
const CRUMBLING_FRAC := 0.25
const DAMAGE_TINT := [1.0, 1.0, 0.75, 0.55]
const DAMAGE_STATE_NOTICE_COLOR := Color(0.9, 0.75, 0.55)
var _display_name := ""


@onready var floating_text_label: RichTextLabel = $FloatingTextLabel
@onready var sprite: Sprite2D = $Sprite
@onready var collision_shape: CollisionShape2D = $CollisionShape2D

func _ready():
	# Group used by CollisionDebugVisualizer to draw structure colliders.
	add_to_group("structures")
	_apply_structure_data()
	# Snap to the grid
	floating_text_label.visible = false
	floating_text_label.z_index = 200
	floating_text_label.z_as_relative = false
	if not skip_grid_snap:
		var grid_pos = GridManager.world_to_map(global_position)
		global_position = GridManager.map_to_world(grid_pos)

func _apply_structure_data():
	var data = StructureDatabase.get_structure_data(structure_id)
	if not data:
		printerr("Failed to get data for structure_id: ", structure_id)
		return
		
	max_health = data.max_health
	current_health = max_health
	resources = data.resources.duplicate()
	flammable = data.flammable
	if use_custom_texture and custom_texture:
		sprite.texture = custom_texture
		# Texture is already cropped to the correct size, no scaling needed
		sprite.scale = Vector2(1.0, 1.0)
		if custom_size != Vector2.ZERO:
			size = custom_size
		elif size == Vector2.ZERO:
			size = sprite.texture.get_size()
	else:
		sprite.texture = load(data.texture)
		size = data.size
		var initial_texture_size = sprite.texture.get_size()
		var size_ratio = size.x / initial_texture_size.x
		sprite.scale = Vector2(size_ratio, size_ratio)

	_setup_collision_shape()

func _setup_collision_shape() -> void:
	collision_layer = CollisionLayers.STRUCTURE_LAYERS
	collision_mask = 0
	var rect := RectangleShape2D.new()
	rect.size = size
	collision_shape.shape = rect
	collision_shape.disabled = false
	
func take_damage(amount: Dictionary, success_level:int = 0):
	if amount.is_empty():
		# a no-damage hit must not flash/emit -- it reads as "wall is immortal"
		push_warning("%s hit with an empty damage dict" % name)
		return
	var state_before := get_damage_state()
	var damage_multiplier = pow(1.5,success_level)
	var took_fire_damage = false
	var any_dealt := false
	var any_blocked := false

	for damage_type in amount.keys():
		# clamp per type: resistance exceeding damage must never HEAL, and an
		# unknown damage type must not abort the hit. Rounded to the whole HP
		# actually lost, which is also the number shown (like character hits).
		var dealt := int(round(maxf(0.0, float(amount[damage_type]) * damage_multiplier - float(self.damage_resistances.get(damage_type, 0)))))
		current_health = max(0, current_health - dealt)
		if LOG_DAMAGE:
			print_rich(name, " takes ", amount[damage_type], damage_type,  " damage.", "crit tier:", success_level, " Health: ", current_health, "/", max_health)
		if damage_type == "fire":
			took_fire_damage = true
		if dealt > 0:
			any_dealt = true
			show_floating_text(str(dealt), Globals.damage_color(damage_type), success_level)
		elif float(amount[damage_type]) > 0.0:
			any_blocked = true
	# One shared label: a fully resisted rider type must not overwrite the
	# number of a type that got through, so "Blocked" only when nothing did.
	if any_blocked and not any_dealt:
		show_floating_text("Blocked", Color(0.75, 0.75, 0.75), success_level)

	# Fire damage on flammable structures triggers ignition on occupied tiles.
	# Silent: this is how a burning fire spreads into walls/trees (CellFire._damage
	# hits them every second), and a spell's fire damage has its own sound.
	if took_fire_damage and flammable:
		var game = get_tree().get_first_node_in_group("game")
		if not game:
			game = get_tree().current_scene
		if game and "surface_manager" in game and game.surface_manager:
			for tile_pos in occupied_tiles:
				game.surface_manager.try_ignite(tile_pos, false)

	var tween = create_tween()
	var vis: CanvasItem = _visual()
	tween.tween_property(vis, "modulate", Color.RED, 0.1)
	tween.tween_property(vis, "modulate", Color.WHITE, 0.1)

	emit_signal("health_changed", current_health, max_health, self)

	# A new damage state darkens the art; crossing into Cracking/Crumbling says
	# so once (a hit that skips a state names the worst). Globals' float, not
	# the shared label above, so the damage number isn't overwritten.
	var state_after := get_damage_state()
	if state_after != state_before:
		_refresh_tint()
		if current_health > 0 and state_after > state_before and state_after >= DamageState.CRACKING:
			_show_damage_state_notice(damage_state_word(state_after))
			# A quiet splinter under the notice; throttled because a fire
			# spreading along a wall cracks many segments in one tick.
			SfxManager.play_throttled("structure_crack", 0.2, "crate_break", global_position, Vector2(0.8, 0.95), -12.0)

	if current_health <= 0:
		_play_break_sound()
		_destroy_structure()

func show_floating_text(text: String, color: Color = Color.WHITE, success_level = 0):
	# The label rides at absolute z 200, above the unexplored-fog quad (140) —
	# and structures are never LOS-hidden, so a fire chewing through a
	# never-seen building would pop crisp damage numbers on top of the fog and
	# leak the layout. Gate on the exploration mask (cheap array read, no
	# raycast): once-explored rooms are permanently fog-free, so their text
	# still shows even with nobody currently watching.
	if ExplorationManager.active \
			and not ExplorationManager.is_explored(GridManager.world_to_map(global_position)):
		return
	var formatted_text = "[b]" + text + "[/b]" if success_level else text
	floating_text_label.text = formatted_text; floating_text_label.modulate = color
	# Make critical hit text bigger too
	var scale_multiplier = 0.91 * success_level if success_level else 0.7
	floating_text_label.scale = Vector2(scale_multiplier, scale_multiplier)
	
	floating_text_label.visible = true
	
	var tween = create_tween().set_parallel()
	tween.tween_property(floating_text_label, "position", Vector2(0, -70), 0.9).from(Vector2(0, -40))
	tween.tween_property(floating_text_label, "modulate:a", 0.0, 0.9)
	tween.chain().tween_callback(func(): floating_text_label.visible = false)
	
# Collapse: flammable structures (wood walls, doors, trees, hedges) splinter,
# the rest (stone) crumble. Loud enough to carry a room or two: the AI hears a
# wall come down about as well as a melee hit. Throttled — a fire eating along
# a wall drops several segments in the same tick.
func _play_break_sound() -> void:
	var key := "structure_break_wood" if flammable else "structure_break_stone"
	SfxManager.play_throttled("structure_break", 0.12, key, global_position, Vector2(0.9, 1.05), -4.0)
	HearingManager.emit(global_position, 1.0, null)

func _destroy_structure():
	# Unregister all occupied tiles from the grid. Decks never registered
	# obstacles — unregistering them anyway would corrupt refcounts shared
	# with abutting wall segments. (A character standing on a destroyed deck
	# auto-grounds next frame; elevation is positional.)
	if is_deck:
		for t in deck_tiles:
			GridManager.unregister_deck(t, deck_elevation)
	else:
		for tile_pos in occupied_tiles:
			GridManager.unregister_obstacle(tile_pos)
	emit_signal("destroyed", self, global_position)
	_visual().visible = false
	collision_shape.disabled = true
	queue_free()

# The node damage flashes / death hides: structured-format maps replace the
# Sprite with an "Art" Polygon2D (an exact geometry slice of the structures
# overlay); legacy maps keep using the Sprite.
func _visual() -> CanvasItem:
	var art := get_node_or_null("Art")
	return art if art != null else sprite

func get_damage_state() -> int:
	if max_health <= 0 or current_health >= max_health:
		return DamageState.INTACT
	var frac := float(current_health) / float(max_health)
	if frac <= CRUMBLING_FRAC:
		return DamageState.CRUMBLING
	if frac <= CRACKING_FRAC:
		return DamageState.CRACKING
	return DamageState.DAMAGED

static func damage_state_word(state: int) -> String:
	return ["Intact", "Damaged", "Cracking", "Crumbling"][clampi(state, 0, 3)]

## Player-facing name ("Stone wall"), for the hover readout.
func get_display_name() -> String:
	if _display_name == "":
		_display_name = StructureDatabase.get_structure_label(structure_id)
	return _display_name

## Extra state for the hover readout after the name ("Locked"); "" for none.
func get_hover_status() -> String:
	return ""

## Alpha folded into the damage tint (Door fades while open).
func _tint_alpha() -> float:
	return 1.0

# self_modulate, NOT modulate: take_damage's hit-flash tween owns modulate.
func _refresh_tint() -> void:
	var vis: CanvasItem = _visual()
	if vis == null:
		return
	var v: float = DAMAGE_TINT[get_damage_state()]
	vis.self_modulate = Color(v, v, v, _tint_alpha())

# The same exploration gate as show_floating_text: a fire chewing through a
# never-seen building must not announce its walls through the fog.
func _show_damage_state_notice(text: String) -> void:
	if ExplorationManager.active \
			and not ExplorationManager.is_explored(GridManager.world_to_map(global_position)):
		return
	var parent := get_parent()
	if parent == null:
		return
	Globals.show_floating_text(text, global_position, parent, DAMAGE_STATE_NOTICE_COLOR, 0, Globals.NOTICE_FONT_SIZE)

func change_texture(texture_path):
	#print("attempting to update structure texture with: ", texture_path)
	$Sprite.texture = load(texture_path)
	
func scale_sprite(new_size):
	var initial_texture_size = sprite.texture.get_size()
	var size_ratio = size.x/initial_texture_size.x
	sprite.scale = Vector2(size_ratio,size_ratio)
