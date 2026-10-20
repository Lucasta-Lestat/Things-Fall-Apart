# =====================
# UI/WorldHoverInfo.gd - What the cursor is pointing at in the world, as text
# providers on Game.world_tooltip (UI/WorldHoverTooltip.gd). It draws nothing
# itself. Game._ready adds it as a child of Game.
#
#   characters (priority 30, paused or not): name and title, a health word
#     (exact HP for the party), stance toward the party, active conditions.
#     Only characters the party can see (Game.hidden_from_party: seen, and
#     drawn in this view layer), so hidden NPCs aren't revealed.
#     Over an overhead condition icon: that condition.
#   structures (priority 20, paused or not): name, door status, damage state
#     and HP. Structures are drawn regardless of fog, so no sight gate; the
#     exploration mask keeps never-seen buildings quiet.
#   hazards (priority 10, paused only, for planning): fire, fluids, ice,
#     electrified ground and clouds under the cursor, what each applies and
#     how often (SurfaceManager.hazard_tooltip_text).
# =====================

extends Node

const PICK_RADIUS := 40.0            # world px from a character's origin (covers its overhead icons)
const STRUCTURE_PICK_RADIUS := 8.0
const ICON_PICK_MARGIN := 1.0        # world px of slack around an overhead condition icon
const ICON_SEARCH_RADIUS := 160.0    # characters whose icon row could be under the cursor
const MAX_CONDITION_LINES := 8
const ICON_PX := 14
const NAME_FONT_SIZE := 16
const SHOW_FACTION_NAME := false     # stance only; some factions may be meant to stay secret
const PRIORITY_CHARACTERS := 30
const PRIORITY_STRUCTURES := 20
const PRIORITY_HAZARDS := 10

const COLOR_UNHURT := Color(0.2, 0.8, 0.2)
const COLOR_WOUNDED := Color(0.9, 0.8, 0.1)
const COLOR_BADLY := Color(1.0, 0.55, 0.15)
const COLOR_NEAR_DEATH := Color(0.9, 0.2, 0.15)
const COLOR_DEAD := Color(0.6, 0.6, 0.6)
const COLOR_HOSTILE := Color(1.0, 0.35, 0.3)
const COLOR_NEUTRAL := Color(0.85, 0.82, 0.7)
const COLOR_ALLY := Color(0.45, 0.75, 1.0)
const COLOR_PARTY := Color(0.55, 0.9, 0.55)
const COLOR_MUTED := Color(0.65, 0.62, 0.56)

var game: Node = null

var _struct_query: PhysicsShapeQueryParameters2D = null

func _ready() -> void:
	name = "WorldHoverInfo"
	process_mode = Node.PROCESS_MODE_ALWAYS
	if game == null:
		game = get_parent()
	var tip = game.get("world_tooltip") if game != null else null
	if tip != null:
		tip.add_provider("characters", character_text, false, PRIORITY_CHARACTERS)
		tip.add_provider("structures", structure_text, false, PRIORITY_STRUCTURES)
		tip.add_provider("hazards", hazard_text, true, PRIORITY_HAZARDS)

func _exit_tree() -> void:
	var tip = game.get("world_tooltip") if game != null and is_instance_valid(game) else null
	if tip != null and is_instance_valid(tip):
		tip.remove_provider("characters")
		tip.remove_provider("structures")
		tip.remove_provider("hazards")

## True when the world readouts should stay quiet: world map (banners, and
## its fast clock makes timers meaningless), downtime board, or a mouse
## button held (path drags, clicks).
func _quiet() -> bool:
	if game == null or not is_instance_valid(game):
		return true
	if game.get("downtime_mode_active") == true:
		return true
	var md = game.get("current_map_data")
	if md is Dictionary and md.get("is_world_map", false):
		return true
	return Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) \
		or Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT) \
		or Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE)

# ---------------------------------------------------------------------------
# Characters
# ---------------------------------------------------------------------------

func character_text(world_pos: Vector2) -> String:
	if _quiet():
		return ""
	# Over one of a character's overhead condition icons: that condition.
	var icon_text := condition_icon_text(world_pos)
	if icon_text != "":
		return icon_text
	var c = pick_character(world_pos)
	if c == null:
		return ""
	return describe_character(c)

## The nearest character the party can see within PICK_RADIUS, or null.
func pick_character(world_pos: Vector2):
	if game == null or not ("characters_in_scene" in game):
		return null
	var best = null
	var best_d := PICK_RADIUS
	for c in game.characters_in_scene:
		if not is_instance_valid(c) or not c.visible:
			continue
		var d: float = world_pos.distance_to(c.global_position)
		if d > best_d:
			continue
		if _hidden_from_party(c):
			continue
		best = c
		best_d = d
	return best

## Not for the hover: a character the player can't see right now, by the
## same rule as the click probe and the other pickers (Game.hidden_from_party:
## not perceived, or not drawn in this view layer).
func _hidden_from_party(c) -> bool:
	if game.has_method("hidden_from_party"):
		return game.hidden_from_party(c)
	return game.has_method("is_seen_by_party") and not game.is_seen_by_party(c)

func describe_character(c) -> String:
	var lines: PackedStringArray = []
	var title := "[font_size=%d][b]%s[/b][/font_size]" % [NAME_FONT_SIZE, _esc(character_name(c))]
	var titles = c.get("titles")
	if titles is Array and not titles.is_empty() and str(titles[0]) != "":
		title += " [color=#%s]· %s[/color]" % [COLOR_MUTED.to_html(false), _esc(str(titles[0]))]
	lines.append(title)

	if c.has_method("is_alive") and not c.is_alive():
		lines.append(_col("Dead", COLOR_DEAD))
		return "\n".join(lines)

	var cur: int = int(c.current_health)
	var max_hp: int = int(c.max_health)
	var word := health_descriptor(cur, max_hp)
	var stance := stance_for(c)
	if stance == "party":
		lines.append("%s · %s" % [_col("%d/%d HP" % [cur, max_hp], health_color(word)), _col(stance_word(stance), stance_color(stance))])
	else:
		var stance_text := stance_word(stance)
		if SHOW_FACTION_NAME:
			var fid := str(c.get("faction_id"))
			var fname := str(FactionDatabase.get_faction_data(fid).get("name", "")) if FactionDatabase.has_faction(fid) else ""
			if fname != "":
				stance_text += " (%s)" % fname
		lines.append("%s · %s" % [_col(word, health_color(word)), _col(_esc(stance_text), stance_color(stance))])
		# An invisible NPC the party sees anyway says why ("Invisible — you
		# saw it vanish (4s)", "... seen by Djargo's true sight").
		if game != null and game.has_method("invisible_perception_text"):
			var inv_line: String = game.invisible_perception_text(c)
			if inv_line != "":
				lines.append(_col(_esc(inv_line), COLOR_MUTED))

	var cond_lines := condition_lines(c)
	lines.append_array(cond_lines)
	return "\n".join(lines)

## One line per active condition: icon, "Name xN (time)", "(suppressed)".
## VFX-shown conditions (no overhead icon) are listed too.
func condition_lines(c) -> PackedStringArray:
	var out: PackedStringArray = []
	var cm = c.get("condition_manager")
	if cm == null or not is_instance_valid(cm):
		return out
	var now: float = TimeManager.absolute_time()
	var shown := 0
	var hidden := 0
	for inst in cm.conditions.values():
		if inst == null or inst.stacks <= 0:
			continue
		if shown >= MAX_CONDITION_LINES:
			hidden += 1
			continue
		var line := _icon_bb(inst) + _esc(inst.get_summary(now))
		if inst.is_suppressed or inst.is_revealed(now):
			line = _col(line, COLOR_MUTED)
		out.append(line)
		shown += 1
	if hidden > 0:
		out.append(_col("+%d more" % hidden, COLOR_MUTED))
	return out

## The overhead condition icon (ProceduralCharacter's ConditionDisplay) under
## world_pos, explained: icon, name, stacks, time left, description. "" when
## the cursor isn't on one. The icons stay MOUSE_FILTER_IGNORE, so this hit
## test (in each icon's own frame: they turn with the character) stands in
## for a Control tooltip without taking clicks from the character.
func condition_icon_text(world_pos: Vector2) -> String:
	if game == null or not ("characters_in_scene" in game):
		return ""
	for c in game.characters_in_scene:
		if not is_instance_valid(c) or not c.visible:
			continue
		# A corpse reads only "Dead": its frozen conditions are not explained.
		if c.has_method("is_alive") and not c.is_alive():
			continue
		if world_pos.distance_to(c.global_position) > ICON_SEARCH_RADIUS:
			continue
		var display = c.get_node_or_null("ConditionDisplay")
		if display == null or not display.visible:
			continue
		if _hidden_from_party(c):
			continue
		for icon in display.get_children():
			if not (icon is Control) or icon.is_queued_for_deletion() or not icon.has_meta("cond_id"):
				continue
			var local: Vector2 = icon.get_global_transform().affine_inverse() * world_pos
			if not Rect2(Vector2.ZERO, icon.size).grow(ICON_PICK_MARGIN).has_point(local):
				continue
			var cm = c.get("condition_manager")
			var inst = cm.conditions.get(icon.get_meta("cond_id")) if cm != null and is_instance_valid(cm) else null
			if inst != null:
				return describe_condition(inst, c)
	return ""

func describe_condition(inst, c = null) -> String:
	var line := "%s[b]%s[/b]" % [_icon_bb(inst), _esc(inst.get_summary(TimeManager.absolute_time()))]
	var lines: PackedStringArray = [line]
	if inst.condition and inst.condition.description != "":
		lines.append(_esc(inst.condition.description))
	if c != null:
		lines.append(_col("on " + _esc(character_name(c)), COLOR_MUTED))
	return "\n".join(lines)

func character_name(c) -> String:
	var n := str(c.get("Name")) if c.get("Name") != null else ""
	if n == "":
		n = str(c.get("display_name")) if c.get("display_name") != null else ""
	if n == "":
		n = str(c.name)
	return n

## "party", "hostile", "ally" or "neutral", as the party should read it.
## The faction answer is FactionDatabase's (the oracle the attack cursor uses,
## with standing and outlaw marks). On top of it, anyone attacking a party
## member right now, or whose AI counts one as an enemy (a manhunt, a
## compulsion), is hostile whatever its faction says.
func stance_for(c) -> String:
	if c.has_method("is_party_member") and c.is_party_member():
		return "party"
	var ai = c.get_node_or_null("AI")
	if ai != null and c.get("AI_enabled") != false and game != null and "party_chars" in game:
		var t = ai.get("current_target")
		if t != null and is_instance_valid(t) and t in game.party_chars:
			return "hostile"
		if ai.has_method("_is_enemy"):
			for pc in game.party_chars:
				if is_instance_valid(pc) and pc.is_alive() and ai._is_enemy(pc):
					return "hostile"
	return FactionDatabase.get_stance("player", str(c.get("faction_id")))

static func health_descriptor(current: int, max_hp: int) -> String:
	if current <= 0:
		return "Dead"
	if max_hp <= 0:
		return "Unhurt"
	var frac := float(current) / float(max_hp)
	if frac >= 1.0:
		return "Unhurt"
	if frac > 0.5:
		return "Wounded"
	if frac > 0.25:
		return "Badly wounded"
	return "Near death"

static func health_color(word: String) -> Color:
	match word:
		"Unhurt": return COLOR_UNHURT
		"Wounded": return COLOR_WOUNDED
		"Badly wounded": return COLOR_BADLY
		"Near death": return COLOR_NEAR_DEATH
		_: return COLOR_DEAD

static func stance_word(stance: String) -> String:
	match stance:
		"hostile": return "Hostile"
		"ally": return "Ally"
		"party": return "Party"
		_: return "Neutral"

static func stance_color(stance: String) -> Color:
	match stance:
		"hostile": return COLOR_HOSTILE
		"ally": return COLOR_ALLY
		"party": return COLOR_PARTY
		_: return COLOR_NEUTRAL

# ---------------------------------------------------------------------------
# Structures
# ---------------------------------------------------------------------------

func structure_text(world_pos: Vector2) -> String:
	if _quiet():
		return ""
	# The same exploration gate as the structures' own damage text: a building
	# under the unexplored fog isn't named.
	if ExplorationManager.active and not ExplorationManager.is_explored(GridManager.world_to_map(world_pos)):
		return ""
	var s = pick_structure(world_pos)
	if s == null:
		return ""
	return describe_structure(s)

## The structure under world_pos (a Door wins over the wall it sits in), or
## null. Walkable decks are skipped: they're floors the party stands on.
func pick_structure(world_pos: Vector2):
	if game == null or not is_instance_valid(game) or not game.is_inside_tree():
		return null
	var w2d: World2D = game.get_viewport().find_world_2d()
	if w2d == null:
		return null
	var space := w2d.direct_space_state
	if space == null:
		return null
	if _struct_query == null:
		var shape := CircleShape2D.new()
		shape.radius = STRUCTURE_PICK_RADIUS
		_struct_query = PhysicsShapeQueryParameters2D.new()
		_struct_query.shape = shape
		# Open doors sit on INTERACTABLES only.
		_struct_query.collision_mask = CollisionLayers.STRUCTURES | CollisionLayers.INTERACTABLES
		_struct_query.collide_with_bodies = true
		_struct_query.collide_with_areas = false
	_struct_query.transform = Transform2D(0.0, world_pos)
	var best = null
	for hit in space.intersect_shape(_struct_query, 8):
		var col = hit.get("collider")
		if not (col is Structure) or not is_instance_valid(col) or col.is_queued_for_deletion() or col.is_deck:
			continue
		if col is Door:
			return col
		if best == null:
			best = col
	return best

func describe_structure(s) -> String:
	var title := "[font_size=%d][b]%s[/b][/font_size]" % [NAME_FONT_SIZE, _esc(s.get_display_name())]
	var status: String = s.get_hover_status()
	if status != "":
		title += " (%s)" % _esc(status)
	var lines: PackedStringArray = [title]
	if s.max_health > 0:
		var state: int = s.get_damage_state()
		var word := Structure.damage_state_word(state)
		lines.append("%s · %d/%d HP" % [_col(word, structure_state_color(state)), s.current_health, s.max_health])
	return "\n".join(lines)

static func structure_state_color(state: int) -> Color:
	return [COLOR_UNHURT, COLOR_WOUNDED, COLOR_BADLY, COLOR_NEAR_DEATH][clampi(state, 0, 3)]

# ---------------------------------------------------------------------------
# Hazards
# ---------------------------------------------------------------------------

func hazard_text(world_pos: Vector2) -> String:
	if _quiet():
		return ""
	# Never-seen ground stays unnamed, like its buildings.
	if ExplorationManager.active and not ExplorationManager.is_explored(GridManager.world_to_map(world_pos)):
		return ""
	var sm = game.get("surface_manager")
	if sm == null or not is_instance_valid(sm):
		return ""
	return sm.hazard_tooltip_text(world_pos)

# ---------------------------------------------------------------------------
# BBCode helpers
# ---------------------------------------------------------------------------

static func _col(text: String, color: Color) -> String:
	return "[color=#%s]%s[/color]" % [color.to_html(false), text]

## Literal text: a "[" in a name must not open a tag.
static func _esc(text: String) -> String:
	return text.replace("[", "[lb]")

static func _icon_bb(inst) -> String:
	var cond = inst.condition
	if cond == null or cond.icon == null or cond.icon.resource_path == "":
		return ""
	return "[img=%dx%d]%s[/img] " % [ICON_PX, ICON_PX, cond.icon.resource_path]
