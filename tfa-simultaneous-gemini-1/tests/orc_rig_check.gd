extends Node2D
# Bespoke-art regression probe: players sometimes see the OLD procedural body
# on rig races (orc). Spawns every combat_test template the way Game does
# (instantiate -> add_child -> build_character) and reports which visual path
# each landed on, then runs a runtime-event battery on a rig orc to catch a
# path that tears the rig down without re-establishing it.
# Headless-safe.  Run:  godot --headless --path . res://tests/orc_rig_check.tscn
# (the .tscn, NOT this .gd — a .gd positional arg is ignored and Godot boots
# the full game main scene instead, which never exits headless)
const CHAR_SCENE := preload("res://Characters/ProceduralCharacter.tscn")
const TEMPLATES := ["orc_warrior", "bandit", "bandit_shaman", "bandit_occultist",
	"bandit_archer", "bandit_pyromancer"]

var fails := 0
var checks := 0


func _check(name: String, ok: bool, detail: String = "") -> void:
	checks += 1
	if not ok:
		fails += 1
	print("%s %s %s" % ["PASS" if ok else "FAIL", name, detail])


func _visual_mode(c) -> String:
	if c.character_rig != null and is_instance_valid(c.character_rig):
		return "rig"
	if c.skeletal_rig != null:
		return "skeletal"
	if c.body_part_sprites != null:
		return "sprites"
	return "PROCEDURAL"


func _spawn(template_id: String, pos: Vector2) -> ProceduralCharacter:
	var c: ProceduralCharacter = CHAR_SCENE.instantiate()
	c.position = pos
	add_child(c)                       # _ready first, like Game._spawn_character
	TopDownCharacterDatabase.build_character(c, template_id)
	return c


func _ready() -> void:
	add_to_group("game")
	GridManager.TILE_SIZE = 64
	GridManager.initialize(2048, 2048)
	await get_tree().process_frame

	# --- 1. every arena template, several spawns each. "from_faction" races
	# roll per spawn, so the invariant is NOT sameness — it is: a character
	# whose resolved race declares a rig_scene must actually RENDER the rig.
	# (Races without any art — e.g. troll — legitimately fall back to the
	# procedural body; that is a content gap, not an engine bug.) ---
	var col := 0
	for tid in TEMPLATES:
		var bad := []
		for i in 4:
			var c := _spawn(tid, Vector2(200 + col * 90, 200 + i * 90))
			await get_tree().process_frame
			var mode := _visual_mode(c)
			if c.rig_scene_path != "" and mode != "rig":
				bad.append("%s(race=%s)->%s" % [tid, c.race_id, mode])
		col += 1
		_check("spawn.%s.declared-rigs-render" % tid, bad.is_empty(), str(bad))

	# --- 1b. every race in the bandits table, applied directly ---
	for rid in ["human", "half_orc", "orc", "saurian", "kobold", "halfling",
			"mephistkin", "troll"]:
		var c: ProceduralCharacter = CHAR_SCENE.instantiate()
		c.position = Vector2(1500, 200)
		add_child(c)
		RaceDatabase.apply_race_to_character(c, rid, {"gender": "male"})
		# replicate build_character's race-level body_sprites fallback
		# (TopDownCharacterDatabase ~173-183) so this matches the in-game path
		var bs: Dictionary = RaceDatabase.get_race_data(rid).get("body_sprites", {})
		if bs.has("male") or bs.has("female"):
			bs = bs.get("male", {})
		if not bs.is_empty():
			c.body_sprite_data = bs
		c.rebuild_visuals()
		await get_tree().process_frame
		var mode := _visual_mode(c)
		if c.rig_scene_path != "":
			_check("race.%s.rig-renders" % rid, mode == "rig", mode)
		else:
			# no rig declared: sprites if the race ships them, else procedural
			print("INFO race.%s has no rig -> %s" % [rid, mode])
		c.queue_free()

	# --- 1c. template-authored gender must reach the rig pick (federica is a
	# female half_orc with "gender" in her TEMPLATE; overrides used to be the
	# only source read, so she spawned with the male rig every time) ---
	var fed := _spawn("surgeon_captain_federica", Vector2(1500, 400))
	await get_tree().process_frame
	_check("gender.template-respected", fed.gender == "female"
		and fed.rig_scene_path.contains("female"),
		"gender=%s rig=%s" % [fed.gender, fed.rig_scene_path])

	# --- 2. runtime battery on one rig orc: does anything demote it? ---
	var orc := _spawn("orc_warrior", Vector2(1000, 1000))
	await get_tree().process_frame
	_check("battery.rig-at-spawn", _visual_mode(orc) == "rig", _visual_mode(orc))

	orc.take_damage({"slashing": 5}, orc.global_position)
	await get_tree().process_frame
	_check("battery.after-damage", _visual_mode(orc) == "rig", _visual_mode(orc))

	if orc.condition_manager:
		orc.condition_manager.apply_condition("bleeding", null, 1)
		await get_tree().process_frame
	_check("battery.after-bleed", _visual_mode(orc) == "rig", _visual_mode(orc))

	# armor equip cycle (torso piece) — equip_equipment historically rebuilds visuals
	var armor: Dictionary = ItemDatabase.get_item_data("leather_armor")
	if not armor.is_empty() and orc.has_method("equip_equipment"):
		orc.equip_equipment(armor.duplicate())
		await get_tree().process_frame
		_check("battery.after-equip", _visual_mode(orc) == "rig", _visual_mode(orc))

	orc.heal(3)
	await get_tree().process_frame
	_check("battery.after-heal", _visual_mode(orc) == "rig", _visual_mode(orc))

	# rebuild_visuals directly (the path every appearance change funnels through)
	orc.rebuild_visuals()
	await get_tree().process_frame
	_check("battery.after-rebuild", _visual_mode(orc) == "rig", _visual_mode(orc))

	print("orc_rig_check: %d checks, %d FAIL" % [checks, fails])
	get_tree().quit(1 if fails > 0 else 0)
