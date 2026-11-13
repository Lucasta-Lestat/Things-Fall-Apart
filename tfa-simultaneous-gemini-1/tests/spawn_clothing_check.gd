extends Node2D
# Spawn-wardrobe regression probe: NPCs on the launch map spawned NAKED (a
# template naming an item that does not exist, "slot": "body" never equipping,
# empty equipment lists, no default clothing) and a halfling rendered on the
# legacy BodyPartSprites path (no rig_scene). Spawns the launch map's templates
# the way Game does (instantiate -> add_child -> build_character) for EVERY
# race x gender their faction can roll and asserts each lands on the current
# CharacterRig wearing exactly one fitted torso garment; then sweeps every
# template's data for wearable entries that can never be worn.
# Headless-safe (reads node state, not pixels).
# Run:  godot --headless --path . res://tests/spawn_clothing_check.tscn
const CHAR_SCENE := preload("res://Characters/ProceduralCharacter.tscn")
const LAUNCH_MAP := "tg_hillside_lower"
const PARTY := ["protagonist", "jacana", "djargo"]
const TEMPLATE_SLOTS := ["main_hand", "off_hand", "head", "torso", "back", "legs", "feet", "cape"]

var fails := 0
var checks := 0
var warns := 0


func _check(name: String, ok: bool, detail: String = "") -> void:
	checks += 1
	if not ok:
		fails += 1
		print("FAIL %s %s" % [name, detail])


func _warn(msg: String) -> void:
	warns += 1
	print("WARN %s" % msg)


func _visual_mode(c: ProceduralCharacter) -> String:
	if c.character_rig != null and is_instance_valid(c.character_rig):
		return "rig"
	if c.skeletal_rig != null:
		return "skeletal"
	if c.body_part_sprites != null:
		return "sprites"
	return "procedural"


func _visible_garments(c: ProceduralCharacter) -> Array:
	var out := []
	if c.character_rig == null or not is_instance_valid(c.character_rig):
		return out
	var stack: Array = [c.character_rig]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		for ch in n.get_children():
			stack.append(ch)
		var nm := String(n.name)
		if n is CanvasItem and nm.begins_with("G_") and nm.ends_with("_mesh"):
			if (n as CanvasItem).visible:
				out.append(nm)
	out.sort()
	return out


func _spawn(template_id: String, overrides: Dictionary = {}) -> ProceduralCharacter:
	var c: ProceduralCharacter = CHAR_SCENE.instantiate()
	c.position = Vector2(400, 400)
	add_child(c)                       # _ready first, like Game._spawn_character
	TopDownCharacterDatabase.build_character(c, template_id, overrides)
	return c


## "" when the character is on the current rig in exactly one fitted garment.
func _clothed_on_rig(c: ProceduralCharacter) -> String:
	var mode := _visual_mode(c)
	if mode != "rig":
		return "body=%s (not the CharacterRig)" % mode
	if c.torso_equipment == null or not is_instance_valid(c.torso_equipment):
		return "no torso item worn"
	var vis := _visible_garments(c)
	if vis.size() != 1:
		return "visible garments=%s" % str(vis)
	return ""


func _launch_templates() -> Array:
	var out := []
	for row in MapDatabase.get_map_data(LAUNCH_MAP).get("npc_spawns", []):
		var tid := String(row.get("template_id", ""))
		if tid != "" and not out.has(tid):
			out.append(tid)
	return out


func _ready() -> void:
	add_to_group("game")
	GridManager.TILE_SIZE = 64
	GridManager.initialize(2048, 2048)
	await get_tree().process_frame

	var launch := _launch_templates()
	_check("launch-map.has-npcs", not launch.is_empty(), str(launch))
	print("INFO launch templates: %s" % str(launch))

	# --- T1: every race x gender each launch template's faction can roll ---
	for tid in launch:
		var tpl: Dictionary = TopDownCharacterDatabase.get_template(tid)
		var fac: Dictionary = FactionDatabase.get_faction_data(String(tpl.get("faction", "neutral")))
		var races: Array = fac.get("race_weights", {}).keys()
		if String(tpl.get("race", "")) != "from_faction":
			races = [String(tpl.get("race", ""))]
		for rid in races:
			for g in ["male", "female"]:
				var c := _spawn(tid, {"race": rid, "gender": g})
				await get_tree().process_frame
				var why := _clothed_on_rig(c)
				_check("T1.%s.%s.%s" % [tid, rid, g], why == "", why)
				c.queue_free()
				await get_tree().process_frame

	# --- T2: unforced spawns, as the game rolls them ---
	seed(12345)
	for tid in launch:
		var bad := {}
		for i in 40:
			var c := _spawn(tid)
			await get_tree().process_frame
			var why := _clothed_on_rig(c)
			if why != "":
				var key := "%s/%s: %s" % [c.race_id, c.gender, why]
				bad[key] = int(bad.get(key, 0)) + 1
			c.queue_free()
			await get_tree().process_frame
		_check("T2.%s.40-rolls" % tid, bad.is_empty(), str(bad))

	# --- T3: "slot": "body" on a real item must be worn ---
	var dh := _spawn("default_human")
	await get_tree().process_frame
	_check("T3.default_human.wears-leather", _visible_garments(dh) == ["G_leather_armor_mesh"],
		str(_visible_garments(dh)))
	dh.queue_free()

	# --- T4: deliberately bare templates and creatures stay bare ---
	for tid in ["nude_elf", "wild_wolf"]:
		if TopDownCharacterDatabase.get_template(tid).is_empty():
			continue
		var c := _spawn(tid)
		await get_tree().process_frame
		_check("T4.%s.stays-bare" % tid, c.torso_equipment == null, "torso item worn")
		c.queue_free()

	# --- T5: the party ---
	for tid in PARTY:
		if TopDownCharacterDatabase.get_template(tid).is_empty():
			continue
		var c := _spawn(tid)
		await get_tree().process_frame
		var why := _clothed_on_rig(c)
		_check("T5.party.%s" % tid, why == "", why)
		c.queue_free()

	# --- T5b: the fallback outfit is stable per template (a named NPC must not
	# change clothes on every map reload) ---
	for tid in ["hunter_john", "obediah", "cletus_samson"]:
		if TopDownCharacterDatabase.get_template(tid).is_empty():
			continue
		var seen := {}
		for i in 6:
			var c := _spawn(tid)
			await get_tree().process_frame
			seen[str(_visible_garments(c))] = true
			c.queue_free()
			await get_tree().process_frame
		_check("T5b.%s.stable-outfit" % tid, seen.size() == 1, str(seen.keys()))

	# --- T5c: a race with no rig keeps its painted legacy body undressed ---
	for tid in ["carapacian_hermit", "rodney_the_rat"]:
		if TopDownCharacterDatabase.get_template(tid).is_empty():
			continue
		var c := _spawn(tid)
		await get_tree().process_frame
		_check("T5c.%s.legacy-not-dressed" % tid, c.torso_equipment == null, "torso item worn")
		c.queue_free()

	# --- T5d: an NPC restored bare from an old snapshot is dressed once ---
	var bare := _spawn("cheese_monger", {"race": "human", "gender": "male"})
	await get_tree().process_frame
	bare.unequip_slot(EquipmentShape.EquipmentSlot.TORSO)
	await get_tree().process_frame
	_check("T5d.setup.bare", bare.torso_equipment == null and _visible_garments(bare).is_empty())
	TopDownCharacterDatabase.clothe_if_bare(bare)
	await get_tree().process_frame
	_check("T5d.clothe_if_bare.dresses", _clothed_on_rig(bare) == "", _clothed_on_rig(bare))
	var worn := _visible_garments(bare)
	TopDownCharacterDatabase.clothe_if_bare(bare)
	await get_tree().process_frame
	_check("T5d.clothe_if_bare.idempotent", _visible_garments(bare) == worn, str(_visible_garments(bare)))
	bare.queue_free()

	# --- T6: static sweep — wearable entries that can never be worn ---
	for tid in TopDownCharacterDatabase.get_all_template_ids():
		var tpl: Dictionary = TopDownCharacterDatabase.get_template(tid)
		var eq: Variant = tpl.get("equipment", [])
		if not (eq is Array):
			continue
		for entry in (eq as Array):
			if not (entry is Dictionary):
				continue
			var id := String(entry.get("id", ""))
			var slot := String(entry.get("slot", "")).to_lower()
			var known: bool = ItemDatabase.items.has(Globals.name_to_id(id)) \
				or ItemDatabase.weapons.has(Globals.name_to_id(id)) \
				or ItemDatabase.equipment.has(Globals.name_to_id(id))
			if slot != "" and not TEMPLATE_SLOTS.has(slot):
				_check("T6.%s.%s.slot" % [tid, id], false, "slot '%s' is never equipped" % slot)
			if not known:
				if slot in ["torso", "body", "chest", "armor"]:
					_check("T6.%s.%s.exists" % [tid, id], false, "torso item not in ItemDatabase")
				else:
					_warn("%s: item '%s' not in ItemDatabase" % [tid, id])

	# --- T7: every clothed-by-design template, once ---
	var off_rig := []
	for tid in TopDownCharacterDatabase.get_all_template_ids():
		var tpl: Dictionary = TopDownCharacterDatabase.get_template(tid)
		if tpl.get("is_creature", false) or tpl.get("unclothed", false):
			continue
		var c := _spawn(tid)
		await get_tree().process_frame
		var mode := _visual_mode(c)
		if mode != "rig":
			off_rig.append("%s(%s:%s)" % [tid, c.race_id, mode])
		elif c.body_type == 0:
			var why := _clothed_on_rig(c)
			_check("T7.%s" % tid, why == "", "%s/%s %s" % [c.race_id, c.gender, why])
		c.queue_free()
		await get_tree().process_frame
	print("INFO not on a CharacterRig (no rig art for the race): %s" % str(off_rig))

	print("SUMMARY checks=%d fails=%d warns=%d" % [checks, fails, warns])
	get_tree().quit(1 if fails > 0 else 0)
