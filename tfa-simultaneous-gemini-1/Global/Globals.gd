extends Node
const FloatingTextScene = preload("res://UI/FloatingText.tscn")
var world_state = {"Perrow Destroyed": false, "Justinia Remaining Loops": 7}

## Suppresses the character-creation gate in Game._ready. Set once a card has
## been issued (so pressing R to reload doesn't reopen the immigration office),
## and settable up front by a dev harness that wants to boot straight into the
## world. The --skip-creation command-line flag does the same thing per run.
var skip_character_creation: bool = false
var dialogue_interaction_distance = 250.0
var default_body_proportions = {}
var default_leg_swing_time: float = 0.0
const SIGHT_TEXTURE = preload("res://sight_cone_smooth.png")
var default_body_scale = 1.7
@export var default_leg_swing_speed: float = 12.0  # How fast default_legs oscillate
@export var default_leg_swing_amount: float = 8.0  # How far default_legs swing

@export var default_leg_length: float = 16.0 * default_body_scale     # Length of each default_leg
@export var default_leg_width: float = 6.0   * default_body_scale       # Thickness of default_legs
@export var default_leg_spacing: float = 6.0  * default_body_scale      # Distance between legs (left-right)
# Body dimensions (top-down view: width is left-right, height is front-back)
@export var default_body_width: float = 28.0 * default_body_scale   # Shoulder width (horizontal)
@export var default_body_height: float = 14.0 * default_body_scale  # Body depth/thickness (vertical in top-down)
@export var default_head_width: float = 14.0 * default_body_scale   # Head width (left-right)
@export var default_head_length: float = 14.0 * default_body_scale  # Head length (front-back, oval shape)
@export var default_shoulder_y_offset: float = 4.0  * default_body_scale  # How far back shoulders are from head center (positive = back)
# Every resistible type in AbilityEffect.DAMAGE_TYPES. "true" is deliberately
# absent — it ignores resistance by definition, so a DR entry for it would be a
# knob that does nothing. Reads go through .get(type, 0), so a missing key was
# never a crash; it just meant the type couldn't be armoured against at all.
const DR_0 = {"slashing":0, "bludgeoning": 0, "piercing": 0, "sonic": 0, "radiant":0, "necrotic": 0, "fire":0, "cold":0, "acid":0, "poison":0, "force":0, "psychic":0, "electric":0 }
const dmg_0_dict = {"slashing":0, "bludgeoning": 0, "piercing": 0, "sonic": 0, "radiant":0, "necrotic": 0, "fire":0, "cold":0, "acid":0, "poison":0, "force":0, "psychic":0, "electric":0 }
# Arm IK settings (smaller for top-down proportions)


var DEFAULT_ARM_SEGMENT_LENGTHS: Array[float] = [11.0 * default_body_scale, 9.0 * default_body_scale, 5.5 * default_body_scale]
const ARM_JOINT_CONSTRAINTS: Array[Vector2] = [
	Vector2(-135, 135),  # Shoulder
	Vector2(0, 145),      # Elbow
	Vector2(-45, 45)      # Wrist
]
# Floats spawned at the same spot in quick succession (one per damage type of
# a single hit, a burst of DoT ticks) stack upward instead of overlapping.
# Key: parent instance + coarse world cell -> {"t": msec, "n": stack index}.
const FLOAT_STACK_MS := 300
const FLOAT_STACK_STEP := 30.0
const FLOAT_STACK_MAX := 4
var _float_stack := {}

# === GLOBAL FUNCTIONS ===
func show_floating_text(text: String, world_pos: Vector2, parent: Node, color: Color = Color.WHITE, success_level: int = 0, font_size: int = 0) -> void:
	var key := str(parent.get_instance_id()) + ":" + str(Vector2i(world_pos / 24.0))
	var now := Time.get_ticks_msec()
	var rec = _float_stack.get(key)
	var n := 0
	if rec != null and now - int(rec.t) < FLOAT_STACK_MS:
		n = (int(rec.n) + 1) % FLOAT_STACK_MAX
	if _float_stack.size() > 64:
		_float_stack.clear()
	_float_stack[key] = {"t": now, "n": n}
	world_pos.y -= FLOAT_STACK_STEP * n

	var ft := FloatingTextScene.instantiate()
	# Notices raised while paused (planning refusals) must still float and fade.
	# Only then: numbers already on screen when the player pauses stay frozen
	# so they can still be read.
	if get_tree().paused:
		ft.process_mode = Node.PROCESS_MODE_ALWAYS
	if font_size > 0:
		ft.add_theme_font_size_override("font_size", font_size)
	parent.add_child(ft)
	ft.setup(text, color, success_level, world_pos)

## Font size for word notices ("Immune", "Out of ammo") — smaller than the
## 30 px damage numbers so a sentence fits over a character.
const NOTICE_FONT_SIZE := 18

## Damage-number colour per type. Each must read against FloatingText's black
## outline under the world's CanvasModulate, and stand apart from the
## WHITE_SMOKE used for physical damage and the green of "+N" heal numbers.
func damage_color(damage_type: String) -> Color:
	match damage_type:
		"fire": return Color.CRIMSON
		"electric", "lightning": return Color.YELLOW
		"cold": return Color(0.45, 0.8, 1.0)
		"acid": return Color(0.6, 1.0, 0.2)
		"radiant": return Color.LIGHT_GOLDENROD
		"necrotic": return Color(0.35, 0.9, 0.8)
		"poison": return Color.BLUE_VIOLET
		"psychic": return Color.MEDIUM_ORCHID
		"force": return Color(0.8, 0.6, 1.0)
		"sonic": return Color(1.0, 0.6, 0.8)
		_: return Color.WHITE_SMOKE

func clamp_to_screen(pos: Vector2, screen_size: Vector2) -> Vector2:
	return Vector2(
		clamp(pos.x, 0, screen_size.x),
		clamp(pos.y, 0, screen_size.y)
	)

func format_time(seconds: float) -> String:
	var mins = int(seconds) / 60
	var secs = int(seconds) % 60
	return "%02d:%02d" % [mins, secs]
	
func name_to_id(input_name: String) -> String:
	return input_name.to_lower().replace(" ", "_")
