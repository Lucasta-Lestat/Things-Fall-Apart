# =====================
# UI/WorldHoverInfo.gd - What the cursor is pointing at in the world, as text
# providers on Game.world_tooltip (UI/WorldHoverTooltip.gd). It draws nothing
# itself. Game._ready adds it as a child of Game.
#
#   characters (priority 30, paused or not): name and title, a health word
#     (exact HP for the party), stance toward the party, active conditions.
#     Only characters the party can see (Game.is_seen_by_party, and drawn:
#     ground view hides roof-walkers), so hidden NPCs aren't revealed.
# =====================

extends Node

const PICK_RADIUS := 40.0            # world px from a character's origin (covers its overhead icons)
const MAX_CONDITION_LINES := 8
const ICON_PX := 14
const NAME_FONT_SIZE := 16
const SHOW_FACTION_NAME := false     # stance only; some factions may be meant to stay secret
const PRIORITY_CHARACTERS := 30

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

func _ready() -> void:
	name = "WorldHoverInfo"
	process_mode = Node.PROCESS_MODE_ALWAYS
	if game == null:
		game = get_parent()
	var tip = game.get("world_tooltip") if game != null else null
	if tip != null:
		tip.add_provider("characters", character_text, false, PRIORITY_CHARACTERS)

func _exit_tree() -> void:
	var tip = game.get("world_tooltip") if game != null and is_instance_valid(game) else null
	if tip != null and is_instance_valid(tip):
		tip.remove_provider("characters")

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
		if game.has_method("is_seen_by_party") and not game.is_seen_by_party(c):
			continue
		best = c
		best_d = d
	return best

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
		if inst.is_suppressed:
			line = _col(line, COLOR_MUTED)
		out.append(line)
		shown += 1
	if hidden > 0:
		out.append(_col("+%d more" % hidden, COLOR_MUTED))
	return out

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
