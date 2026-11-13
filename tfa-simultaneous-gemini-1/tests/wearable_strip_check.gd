extends Node2D
# Wearable-strip regression probe: exported rig scenes bake every garment mesh
# and (pre-fix) shipped them VISIBLE, so characters spawned wearing the whole
# wardrobe stacked by z_index; unequipping the top layer just revealed the next
# one down. Verifies: a naked spawn shows ZERO wearable layers, equipping shows
# exactly the equipped piece, swapping never stacks, unequipping strips again.
# Headless-safe.  Run:  godot --headless --path . res://tests/wearable_strip_check.tscn
const CHAR_SCENE := preload("res://Characters/ProceduralCharacter.tscn")

var fails := 0
var checks := 0


func _check(name: String, ok: bool, detail: String = "") -> void:
	checks += 1
	if not ok:
		fails += 1
	print("%s %s %s" % ["PASS" if ok else "FAIL", name, detail])


func _visible_wearables(c) -> Array:
	# every visible baked wearable under the rig: G_* garment meshes and EQ_*
	# part-equipment sprites, wherever they sit in the tree (Rig, hand bones...)
	var out := []
	if c.character_rig == null or not is_instance_valid(c.character_rig):
		return out
	var stack: Array = [c.character_rig]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		for ch in n.get_children():
			stack.append(ch)
		if n is CanvasItem and (String(n.name).begins_with("G_")
				or String(n.name).begins_with("EQ_")):
			if (n as CanvasItem).visible:
				out.append(String(n.name))
	out.sort()
	return out


func _spawn_race(rid: String, gender: String, pos: Vector2) -> ProceduralCharacter:
	var c: ProceduralCharacter = CHAR_SCENE.instantiate()
	c.position = pos
	add_child(c)
	RaceDatabase.apply_race_to_character(c, rid, {"gender": gender})
	c.rebuild_visuals()
	return c


func _ready() -> void:
	add_to_group("game")
	GridManager.TILE_SIZE = 64
	GridManager.initialize(2048, 2048)
	await get_tree().process_frame

	# --- naked spawn must wear NOTHING, across races and genders ---
	for probe in [["human", "male"], ["human", "female"], ["orc", "male"],
			["high_elf", "female"], ["half_orc", "female"],
			["halfling", "male"], ["halfling", "female"]]:
		var c := _spawn_race(probe[0], probe[1], Vector2(300, 300))
		await get_tree().process_frame
		if c.character_rig == null:
			print("INFO %s/%s has no rig, skipped" % [probe[0], probe[1]])
			c.queue_free()
			continue
		var vis := _visible_wearables(c)
		_check("naked.%s_%s" % [probe[0], probe[1]], vis.is_empty(), str(vis))
		c.queue_free()

	# --- equip cycle on a human: breastplate_2 -> exactly one garment layer ---
	var h := _spawn_race("human", "male", Vector2(600, 300))
	await get_tree().process_frame
	var bp: Dictionary = ItemDatabase.get_item_data("breastplate_2")
	_check("data.breastplate_2", not bp.is_empty())
	h.equip_equipment(bp.duplicate())
	await get_tree().process_frame
	var vis1 := _visible_wearables(h)
	_check("equip.breastplate_2.single-layer", vis1 == ["G_breastplate_mesh"], str(vis1))

	# --- swap torso piece: legionnaires replaces breastplate, never stacks ---
	var leg: Dictionary = ItemDatabase.get_item_data("legionnaires_armor")
	if not leg.is_empty():
		h.equip_equipment(leg.duplicate())
		await get_tree().process_frame
		var vis2 := _visible_wearables(h)
		_check("swap.legionnaires.single-layer",
			vis2 == ["G_legionnaires_armor_mesh"], str(vis2))

	# --- unequip torso: back to zero ---
	h.unequip_slot(EquipmentShape.EquipmentSlot.TORSO)
	await get_tree().process_frame
	var vis3 := _visible_wearables(h)
	_check("unequip.torso.strips", vis3.is_empty(), str(vis3))

	# --- full_face_helmet renders its OWN fitted art (no more great_helm
	# stand-in), alone, and is controllable through its slot ---
	var ffh: Dictionary = ItemDatabase.get_item_data("full_face_helmet")
	if not ffh.is_empty():
		h.equip_equipment(ffh.duplicate())
		await get_tree().process_frame
		var vis4 := _visible_wearables(h)
		_check("equip.full_face_helmet.own-art",
			vis4 == ["EQ_head_full_face_helmet_c"], str(vis4))
		h.unequip_slot(EquipmentShape.EquipmentSlot.HEAD)
		await get_tree().process_frame
		_check("unequip.head.strips", _visible_wearables(h).is_empty(),
			str(_visible_wearables(h)))

	# --- steel_greaves render their own per-foot art, no sabaton stand-in ---
	var sg: Dictionary = ItemDatabase.get_item_data("steel_greaves")
	if not sg.is_empty():
		h.equip_equipment(sg.duplicate())
		await get_tree().process_frame
		var vis6 := _visible_wearables(h)
		_check("equip.steel_greaves.own-art",
			vis6 == ["EQ_feet_steel_greaves_l", "EQ_feet_steel_greaves_r"], str(vis6))
		h.unequip_slot(EquipmentShape.EquipmentSlot.FEET)
		await get_tree().process_frame
		_check("unequip.feet.strips", _visible_wearables(h).is_empty(),
			str(_visible_wearables(h)))

	# --- rebuild_visuals with armor on keeps exactly the equipped layer ---
	h.equip_equipment(bp.duplicate())
	await get_tree().process_frame
	h.rebuild_visuals()
	await get_tree().process_frame
	var vis5 := _visible_wearables(h)
	_check("rebuild.keeps-equipped-only", vis5 == ["G_breastplate_mesh"], str(vis5))

	print("wearable_strip_check: %d checks, %d FAIL" % [checks, fails])
	get_tree().quit(1 if fails > 0 else 0)
