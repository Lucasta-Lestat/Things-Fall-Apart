extends Node2D
# Shrouded and Inspired condition icons (cond_shrouded.png, cond_inspired.png,
# made by tools/generate_condition_icons_gemini.py).
#   - data: both conditions point at their own cond_* art, with the icon they
#     borrowed before (Invisible, Courageous) as "icon_fallback"
#   - files: the PNGs are in the project and match the cond_* set: 256x256,
#     transparent corners, a full-frame sage "buff" disc, a centred glyph at 72%
#   - lookup: Condition.create_from_data uses "icon_fallback" only while the
#     new PNG is not loadable (not imported yet), never the placeholder
#   - feedback: a character wearing either shows a real icon in its condition
#     row and in the world hover line
# Real ProceduralCharacter.tscn instances on a stub Game surface (as in
# equipment_effects_test). Headless-safe; passes both before and after the
# editor has imported the new PNGs.
#   godot --headless --path . res://tests/icons_r3_test.tscn
# Judge by the PASS/FAIL lines and "HARNESS DONE failures=0".

const PC_SCENE := preload("res://Characters/ProceduralCharacter.tscn")
const HOVER = preload("res://UI/WorldHoverInfo.gd")

const DUMMY := "res://Icons/dummy_icon.png"
const NEW_ICONS := {
	"shrouded": "res://UI/UI Icons/cond_shrouded.png",
	"inspired": "res://UI/UI Icons/cond_inspired.png",
}
const OLD_ICONS := {
	"shrouded": "res://UI/UI Icons/invisible.png",
	"inspired": "res://UI/UI Icons/cond_courageous.png",
}
# Rim colour of the existing buff icons (cond_courageous, cond_perceptive, ...).
const SET_BUFF_DISC := Color8(166, 196, 157)

# ProceduralCharacter._process reads this off the game root (_process_approach).
const MELEE_ELEV_TOLERANCE: float = 0.5

# --- Game stub surface (ai.gd and ProceduralCharacter touch these) ---
var characters_in_scene: Array = []
var items_in_scene: Array = []
var structures_in_scene: Array = []
var party_chars: Array = []
var stealth_mode: bool = false
var surface_manager = null
var fluid_manager = null
var fog_manager = null
var context_menu_open := false
var primary_selected = null
var current_map_id: String = "test"

func can_hit_target(_a: Node2D, _t: Node2D) -> bool: return true
func register_hit(_a: Node2D, _t: Node2D) -> void: pass
func register_attack_start(_a: Node2D) -> void: pass
func register_attack_end(_a: Node2D) -> void: pass
func resolve_melee_swing(_a: Node2D, _hand: String) -> void: pass
func process_weapon_hit(_a, _t, _p, _w, _v) -> void: pass
func process_object_hit(_a, _t, _p, _w, _v) -> void: pass
func trigger_hearing_pulse(_source) -> void: pass

const ORIGIN := Vector2(2048, 2048)

var failures := 0
var checks := 0


func _check(check_name: String, cond: bool, detail: String = "") -> void:
	checks += 1
	if cond:
		print("PASS %s" % check_name)
	else:
		failures += 1
		print("FAIL %s: %s" % [check_name, detail])


func _ready() -> void:
	add_to_group("game")
	GridManager.TILE_SIZE = 64
	GridManager.initialize(4096, 4096)
	await get_tree().process_frame
	_run_data()
	_run_files()
	_run_lookup()
	await _run_feedback()
	print("HARNESS DONE failures=%d checks=%d" % [failures, checks])
	get_tree().quit(1 if failures > 0 else 0)


func _db_entry(id: String) -> Dictionary:
	for d in ConditionDatabase.get_all_conditions():
		if d.get("id", "") == id:
			return d
	return {}


## The path the game should be showing for this condition right now: the new
## art once the editor has imported it, the borrowed art until then.
func _expected_path(id: String) -> String:
	return NEW_ICONS[id] if ResourceLoader.exists(NEW_ICONS[id]) else OLD_ICONS[id]


# ---------------------------------------------------------------------------
# Data
# ---------------------------------------------------------------------------

func _run_data() -> void:
	for id in NEW_ICONS:
		var d := _db_entry(id)
		_check("data.%s-icon" % id, str(d.get("icon", "")) == NEW_ICONS[id], str(d.get("icon", "")))
		_check("data.%s-fallback" % id, str(d.get("icon_fallback", "")) == OLD_ICONS[id],
			str(d.get("icon_fallback", "")))


# ---------------------------------------------------------------------------
# Files: decoded straight from the PNG, so this holds before import too
# ---------------------------------------------------------------------------

func _run_files() -> void:
	for id in NEW_ICONS:
		var path: String = NEW_ICONS[id]
		_check("file.%s-present" % id, FileAccess.file_exists(path), path)
		if not FileAccess.file_exists(path):
			continue
		var img := Image.new()
		var err := img.load_png_from_buffer(FileAccess.get_file_as_bytes(path))
		_check("file.%s-decodes" % id, err == OK, str(err))
		if err != OK:
			continue
		_check("file.%s-256" % id, img.get_size() == Vector2i(256, 256), str(img.get_size()))
		var corners := [img.get_pixel(0, 0), img.get_pixel(255, 0), img.get_pixel(0, 255), img.get_pixel(255, 255)]
		var clear := corners.all(func(c): return c.a < 0.02)
		_check("file.%s-transparent-corners" % id, clear, str(corners))
		# Just inside the rim at the top, the bottom and both sides: the disc.
		var worst := 0.0
		for p in [Vector2i(128, 8), Vector2i(128, 247), Vector2i(8, 128), Vector2i(247, 128)]:
			var c := img.get_pixel(p.x, p.y)
			var dist := Vector3(c.r - SET_BUFF_DISC.r, c.g - SET_BUFF_DISC.g, c.b - SET_BUFF_DISC.b).length() * 255.0
			worst = maxf(worst, dist if c.a > 0.98 else 999.0)
		_check("file.%s-set-disc" % id, worst < 6.0, "worst rim distance %.1f" % worst)
		# The glyph's box: 72% of the frame on its longest side and centred, as
		# rework_ui_icons leaves every cond_* glyph (a stray speck in the raw
		# print would shrink the symbol and pull it off centre).
		var lo := Vector2i(256, 256)
		var hi := Vector2i(-1, -1)
		for y in 256:
			for x in 256:
				var px := img.get_pixel(x, y)
				if px.a < 0.98 or Vector2(x - 127.5, y - 127.5).length() > 122.0:
					continue
				var off := Vector3(px.r - SET_BUFF_DISC.r, px.g - SET_BUFF_DISC.g, px.b - SET_BUFF_DISC.b).length() * 255.0
				if off > 20.0:
					lo = Vector2i(mini(lo.x, x), mini(lo.y, y))
					hi = Vector2i(maxi(hi.x, x), maxi(hi.y, y))
		var fill := float(maxi(hi.x - lo.x, hi.y - lo.y) + 1) / 256.0
		var centre := Vector2(lo + hi) / 2.0
		_check("file.%s-glyph-72pct" % id, absf(fill - 0.72) < 0.02, "longest side %.3f of the frame" % fill)
		_check("file.%s-glyph-centred" % id, centre.distance_to(Vector2(127.5, 127.5)) < 4.0,
			"glyph box centre %s" % centre)


# ---------------------------------------------------------------------------
# Lookup: Condition.create_from_data
# ---------------------------------------------------------------------------

func _run_lookup() -> void:
	var blessed := "res://UI/UI Icons/cond_blessed.png"
	var focused := "res://UI/UI Icons/cond_focused.png"
	var a := Condition.create_from_data({"id": "t_fb", "icon": "res://nowhere/missing.png", "icon_fallback": blessed})
	_check("lookup.fallback-used", a.icon != null and a.icon.resource_path == blessed,
		a.icon.resource_path if a.icon else "null")
	var b := Condition.create_from_data({"id": "t_ok", "icon": focused, "icon_fallback": blessed})
	_check("lookup.loadable-icon-wins", b.icon != null and b.icon.resource_path == focused,
		b.icon.resource_path if b.icon else "null")
	var c := Condition.create_from_data({"id": "t_none", "icon": "res://nowhere/missing.png"})
	_check("lookup.no-fallback-placeholder", c.icon != null and c.icon.resource_path == DUMMY,
		c.icon.resource_path if c.icon else "null")
	var e := Condition.create_from_data({"id": "t_badfb", "icon": "res://nowhere/missing.png",
		"icon_fallback": "res://nowhere/also_missing.png"})
	_check("lookup.bad-fallback-placeholder", e.icon != null and e.icon.resource_path == DUMMY,
		e.icon.resource_path if e.icon else "null")

	for id in NEW_ICONS:
		var cond = ConditionManager.condition_registry.get(id)
		var got: String = cond.icon.resource_path if cond and cond.icon else "null"
		var want := _expected_path(id)
		if want != NEW_ICONS[id]:
			print("NOTE %s: %s not imported yet, showing %s" % [id, NEW_ICONS[id].get_file(), want.get_file()])
		_check("lookup.%s-registered" % id, got == want, "%s (want %s)" % [got, want])
		_check("lookup.%s-not-placeholder" % id, got != DUMMY, got)


# ---------------------------------------------------------------------------
# Feedback: the condition row over the character and the world hover line
# ---------------------------------------------------------------------------

func _run_feedback() -> void:
	var c: ProceduralCharacter = PC_SCENE.instantiate()
	c.AI_enabled = false
	c.is_player_controlled = true
	add_child(c)
	TopDownCharacterDatabase.build_character(c, "default_human")
	c.game = self
	c.Name = "Wearer"
	c.global_position = ORIGIN
	party_chars = [c]
	characters_in_scene = [c]
	await get_tree().process_frame

	for id in NEW_ICONS:
		var inst = c.condition_manager.apply_condition(id)
		await get_tree().process_frame
		_check("feedback.%s-applied" % id, inst != null)
		if inst == null:
			continue
		var want := _expected_path(id)
		var row_tex: Texture2D = null
		var display = c.get_node_or_null("ConditionDisplay")
		if display:
			for ch in display.get_children():
				if ch is TextureRect and not ch.is_queued_for_deletion() and ch.get_meta("cond_id", "") == id:
					row_tex = ch.texture
		_check("feedback.%s-row-icon" % id, row_tex != null and row_tex.resource_path == want,
			row_tex.resource_path if row_tex else "no icon in the row")
		var bb: String = HOVER._icon_bb(inst)
		_check("feedback.%s-hover-icon" % id, bb.contains(want) and not bb.contains(DUMMY), bb)
		c.condition_manager.remove_condition(id)
		await get_tree().process_frame
	c.queue_free()
