# res://tests/world_info_test.gd
# Headless checks for the world hover readouts (UI/WorldHoverInfo.gd on
# Game.world_tooltip): characters (name, health word or party HP, stance from
# FactionDatabase, conditions) and the shared condition wording
# (ConditionInstance.get_summary / get_tooltip_text, also the party panel's).
# Drives the real Game on town_square.
# Run:  godot --headless --path . res://tests/world_info_test.tscn
# Judge by PASS/FAIL lines, not exit code alone (startup noise is normal).
extends Node2D

const HOVER = preload("res://UI/WorldHoverInfo.gd")

var failures := 0
var game = null

func _check(check_name: String, ok: bool, detail = "") -> void:
	if ok:
		print("PASS %s" % check_name)
	else:
		failures += 1
		print("FAIL %s: %s" % [check_name, str(detail)])

func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame

func _physics_frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame

func _ready() -> void:
	# A SCRIPT ERROR aborts the coroutine; don't hang waiting for quit().
	get_tree().create_timer(240.0, true).timeout.connect(func():
		print("FAIL watchdog timeout (coroutine aborted?) failures=%d" % failures)
		get_tree().quit(99))
	_case_pure()
	await get_tree().process_frame
	game = load("res://game.tscn").instantiate()
	game.current_map_id = ""
	get_tree().root.add_child(game)
	get_tree().current_scene = game
	await _frames(2)
	game.load_map("town_square")
	await _frames(10)
	if PauseManager.is_paused:
		PauseManager.unpause()
	await _case_characters()
	await _case_party_panel()
	await _case_structures()
	print("HARNESS DONE failures=%d" % failures)
	get_tree().quit(1 if failures > 0 else 0)

# ---------------------------------------------------------------------------

func _case_pure() -> void:
	var cases := {[20, 20]: "Unhurt", [11, 20]: "Wounded", [10, 20]: "Badly wounded", [6, 20]: "Badly wounded", [5, 20]: "Near death", [1, 20]: "Near death", [0, 20]: "Dead", [-3, 20]: "Dead"}
	for k in cases:
		var got: String = HOVER.health_descriptor(k[0], k[1])
		_check("health_descriptor %s" % [k], got == cases[k], got)
	_check("stance words", HOVER.stance_word("hostile") == "Hostile" and HOVER.stance_word("ally") == "Ally" and HOVER.stance_word("neutral") == "Neutral" and HOVER.stance_word("party") == "Party")

	var cond = Condition.create_from_data({"id": "t_test", "display_name": "Test", "description": "Does a test.", "duration": 30, "stackable": true, "max_tier": 5})
	var inst = ConditionInstance.new(cond)
	inst.apply(100.0)
	inst.stacks = 3
	_check("get_summary stacks + time", inst.get_summary(112.0) == "Test x3 (18s)", inst.get_summary(112.0))
	_check("get_summary without time", inst.get_summary() == "Test x3", inst.get_summary())
	inst.is_suppressed = true
	_check("get_summary suppressed", inst.get_summary(112.0) == "Test x3 (18s) (suppressed)", inst.get_summary(112.0))
	inst.is_suppressed = false
	_check("get_tooltip_text adds description", inst.get_tooltip_text(112.0) == "Test x3 (18s)\nDoes a test.", inst.get_tooltip_text(112.0))
	# Durations run to days on the absolute clock.
	inst.expires_at = 100.0 + 7500.0
	_check("get_summary hours", inst.get_summary(100.0) == "Test x3 (2h 05m)", inst.get_summary(100.0))
	var perm = ConditionInstance.new(Condition.create_from_data({"id": "no_name_cond"}))
	perm.apply(5.0)
	_check("permanent: no time, id fallback name", perm.get_summary(10.0) == "No Name Cond", perm.get_summary(10.0))

# ---------------------------------------------------------------------------

func _away_npc(party: Array):
	for c in game.characters_in_scene:
		if not is_instance_valid(c) or c in party or not c.is_alive() or not c.has_node("AI"):
			continue
		var far := true
		for p in party:
			if p.global_position.distance_to(c.global_position) < 120.0:
				far = false
		if far:
			return c
	return null

func _case_characters() -> void:
	var hover = game.get_node_or_null("WorldHoverInfo")
	_check("WorldHoverInfo under Game", hover != null)
	if hover == null:
		return
	var providers: Dictionary = game.world_tooltip._providers
	_check("characters provider registered", providers.has("characters"), providers.keys())
	_check("characters provider not paused-only", providers.has("characters") and providers["characters"].paused_only == false)

	var party: Array = game.party_chars
	_check("party present", party.size() > 0)
	if party.is_empty():
		return
	var p0 = party[0]
	var ptext: String = hover.describe_character(p0)
	print("party hover: ", ptext.replace("\n", " | "))
	_check("party: exact HP + Party", ptext.contains("%d/%d HP" % [p0.current_health, p0.max_health]) and ptext.contains("Party"), ptext)
	_check("party: name shown", ptext.contains(hover.character_name(p0)), ptext)

	# An NPC well away from the party, so the nearest-pick isn't a party member.
	var npc = _away_npc(party)
	_check("found an NPC away from the party", npc != null)
	if npc == null:
		return
	var saved_faction: String = npc.faction_id
	var ai = npc.get_node("AI")
	var saved_target = ai.current_target
	var saved_ai: bool = npc.AI_enabled
	npc.AI_enabled = true
	ai.current_target = null

	# Stance is the faction oracle's (the same answer as the attack cursor),
	# for every faction id.
	var bad := []
	var ids: Array = FactionDatabase.get_all_faction_ids().duplicate()
	ids.append("druids")   # undefined: quietly neutral
	for f in ids:
		if f == "player":
			continue
		npc.faction_id = f
		var want: String = "hostile" if FactionDatabase.are_hostile("player", f) \
			else ("ally" if FactionDatabase.player_stance_toward(f) == "friendly" else "neutral")
		if hover.stance_for(npc) != want:
			bad.append("%s=%s want %s" % [f, hover.stance_for(npc), want])
	_check("stance follows FactionDatabase (%d ids)" % ids.size(), bad.is_empty(), bad)
	npc.faction_id = "bandits"
	_check("bandits read Hostile", hover.stance_for(npc) == "hostile" and hover.describe_character(npc).contains("Hostile"), hover.describe_character(npc))
	npc.faction_id = "druids"
	_check("unknown faction -> neutral", hover.stance_for(npc) == "neutral")

	# Standing and outlaw marks show through, then everything is put back.
	var saved_standing: Dictionary = FactionDatabase._player_standing.duplicate()
	var saved_override: Dictionary = FactionDatabase._hostile_override.duplicate()
	npc.faction_id = "golden_guard"
	FactionDatabase._player_standing["golden_guard"] = 100
	_check("high standing reads Ally", hover.stance_for(npc) == "ally", hover.stance_for(npc))
	FactionDatabase._hostile_override["golden_guard"] = true
	_check("outlaw mark reads Hostile", hover.stance_for(npc) == "hostile", hover.stance_for(npc))
	FactionDatabase._player_standing = saved_standing
	FactionDatabase._hostile_override = saved_override

	# Personal hostility beats the faction: attacking a party member, or a
	# manhunt on one.
	npc.faction_id = "neutral"
	_check("neutral -> Neutral", hover.stance_for(npc) == "neutral")
	ai.current_target = p0
	_check("attacking a party member reads Hostile", hover.stance_for(npc) == "hostile")
	ai.current_target = null
	if "manhunt_target" in ai:
		var saved_hunt = ai.manhunt_target
		ai.manhunt_target = p0
		_check("a manhunt on a party member reads Hostile", hover.stance_for(npc) == "hostile")
		ai.manhunt_target = saved_hunt
	ai.current_target = saved_target
	npc.AI_enabled = saved_ai

	# Health words follow HP.
	var saved_hp: int = npc.current_health
	npc.current_health = max(1, int(npc.max_health * 0.2))
	_check("near death word", hover.describe_character(npc).contains("Near death"), hover.describe_character(npc))
	npc.current_health = 0
	var dead_text: String = hover.describe_character(npc)
	_check("corpse reads Dead, no stance", dead_text.contains("Dead") and not dead_text.contains("Neutral"), dead_text)
	npc.current_health = saved_hp

	# Conditions: one line each with the icon and the shared summary, on the
	# absolute clock.
	var inst = npc.condition_manager.apply_condition("mighty", null, 2, 45.0)
	if inst:
		var lines: PackedStringArray = hover.condition_lines(npc)
		print("condition lines: ", lines)
		var hit := false
		for l in lines:
			if l.contains(inst.get_display_name()) and l.contains("[img=") and l.contains("s)"):
				hit = true
		_check("condition line: icon + name + time", hit, lines)
		npc.condition_manager.remove_condition("mighty")
	else:
		print("SKIP mighty not applied")

	# The provider only answers for characters the party can see.
	# (visible as during a hearing pulse: drawn, but not actually seen)
	var pos: Vector2 = npc.global_position + Vector2(10, 0)
	var was_visible: bool = npc.visible
	var was_seen = game._npc_was_truly_seen.get(npc)
	npc.visible = true
	game._npc_was_truly_seen[npc] = false
	_check("unseen NPC: no hover text", hover.character_text(pos) == "", hover.character_text(pos))
	game._npc_was_truly_seen[npc] = true
	var seen_text: String = hover.character_text(pos)
	_check("seen NPC: hover names it", seen_text.contains(hover.character_name(npc)), seen_text)
	# Ground view hides a seen roof-walker: not drawn, not described.
	npc.visible = false
	_check("seen but not drawn: no hover text", hover.character_text(pos) == "")
	npc.visible = true
	_check("outside pick radius: nothing", not hover.character_text(npc.global_position + Vector2(200, 200)).contains(hover.character_name(npc)))
	game.downtime_mode_active = true
	_check("quiet in downtime mode", hover.character_text(pos) == "")
	game.downtime_mode_active = false
	game.current_map_data["is_world_map"] = true
	_check("quiet on the world map", hover.character_text(pos) == "")
	game.current_map_data.erase("is_world_map")
	# Through the real tooltip host.
	_check("world_tooltip answers with the NPC", game.world_tooltip._query(pos).contains(hover.character_name(npc)))
	npc.visible = was_visible
	if was_seen == null:
		game._npc_was_truly_seen.erase(npc)
	else:
		game._npc_was_truly_seen[npc] = was_seen
	npc.faction_id = saved_faction

func _case_party_panel() -> void:
	# The party panel's condition pips use the same wording, description included.
	var psp = game.get_node("GameUI/PartySidePanel")
	var p0 = game.party_chars[0]
	var cm = p0.condition_manager
	cm.register_condition(Condition.create_from_data({"id": "test_world_info", "display_name": "Probe",
		"description": "Probes things.", "duration": 90.0, "traits": {}}))
	var inst = cm.apply_condition("test_world_info")
	_check("panel probe applied", inst != null)
	await _frames(3)
	var tips := []
	for pd in psp._character_panels:
		if pd["character"] != p0:
			continue
		for icon in pd["condition_container"].get_children():
			tips.append(str(icon.tooltip_text))
	_check("panel tooltip is get_tooltip_text", tips.has(inst.get_tooltip_text(TimeManager.absolute_time())) if inst != null else false, tips)
	_check("panel tooltip carries the description", tips.any(func(t): return t.contains("Probe (") and t.contains("\nProbes things.")), tips)
	cm.remove_condition("test_world_info")

# ---------------------------------------------------------------------------
# Structures (damage states, tint, threshold notices, door status, hover)
# ---------------------------------------------------------------------------

const STRUCTURE_SCENE := preload("res://Structures/Structure.tscn")
const DOOR_SCRIPT := preload("res://Structures/Door.gd")
var _blank: ImageTexture

func _blank_tex() -> ImageTexture:
	if _blank == null:
		_blank = ImageTexture.create_from_image(Image.create(8, 8, false, Image.FORMAT_RGBA8))
	return _blank

func _spawn(id: StringName, pos: Vector2, as_door: bool = false):
	var inst = STRUCTURE_SCENE.instantiate()
	if as_door:
		inst.set_script(DOOR_SCRIPT)
	inst.structure_id = id
	inst.skip_grid_snap = true
	inst.use_custom_texture = true
	inst.custom_texture = _blank_tex()
	inst.custom_size = Vector2(32, 32)
	inst.position = pos
	game.add_child(inst)
	return inst

func _floats_with(parent: Node, text: String) -> int:
	var n := 0
	for ch in parent.get_children():
		if ch is Label and ch.text == text:
			n += 1
	return n

const STATE := {"INTACT": 0, "DAMAGED": 1, "CRACKING": 2, "CRUMBLING": 3}

func _case_structures() -> void:
	var hover = game.get_node("WorldHoverInfo")
	_check("structures provider registered", game.world_tooltip._providers.has("structures"))
	# Unexplored fog would (rightly) silence the notices and the hover, so
	# test with the exploration mask off.
	var explore_was: bool = ExplorationManager.active
	ExplorationManager.active = false
	var where: Vector2 = game.party_chars[0].global_position + Vector2(-5000, -5000)
	var wall = _spawn(&"stone_wall", where)
	await _frames(1)
	wall.max_health = 100
	wall.current_health = 100
	_check("label: Stone wall", wall.get_display_name() == "Stone wall", wall.get_display_name())
	_check("unknown ids read from the id", StructureDatabase.get_structure_label(&"iron_gate") == "Iron Gate")
	_check("intact", wall.get_damage_state() == STATE.INTACT)
	wall.take_damage({"bludgeoning": 49})
	_check("51/100 damaged", wall.get_damage_state() == STATE.DAMAGED, wall.current_health)
	_check("damaged keeps full brightness", is_equal_approx(wall._visual().self_modulate.r, 1.0), wall._visual().self_modulate)
	_check("no notice for Damaged", _floats_with(game, "Damaged") == 0)
	wall.take_damage({"bludgeoning": 2})
	_check("49/100 cracking", wall.get_damage_state() == STATE.CRACKING, wall.current_health)
	_check("cracking darkens to 0.75", is_equal_approx(wall._visual().self_modulate.r, 0.75), wall._visual().self_modulate)
	_check("'Cracking' floats once", _floats_with(game, "Cracking") == 1, _floats_with(game, "Cracking"))
	wall.take_damage({"bludgeoning": 1})
	_check("no repeat notice within a state", _floats_with(game, "Cracking") == 1)
	wall.take_damage({"bludgeoning": 24})
	_check("24/100 crumbling", wall.get_damage_state() == STATE.CRUMBLING and wall.current_health == 24, wall.current_health)
	_check("crumbling darkens to 0.55", is_equal_approx(wall._visual().self_modulate.r, 0.55))
	_check("'Crumbling' floats", _floats_with(game, "Crumbling") == 1)
	var desc: String = hover.describe_structure(wall)
	print("structure hover: ", desc.replace("\n", " | "))
	_check("hover: name, state, HP", desc.contains("Stone wall") and desc.contains("Crumbling") and desc.contains("24/100 HP"), desc)

	await _physics_frames(3)
	var picked = hover.pick_structure(where + Vector2(3, 2))
	_check("pick_structure finds the wall", picked == wall, picked)
	var via_provider: String = hover.structure_text(where)
	_check("structures provider text", via_provider.contains("Stone wall"), via_provider)
	_check("nothing off the wall", hover.pick_structure(where + Vector2(200, 0)) == null)

	# Unexplored ground: the notice and the hover stay quiet.
	ExplorationManager.active = true
	var unexplored: bool = not ExplorationManager.is_explored(GridManager.world_to_map(where))
	if unexplored:
		_check("no hover under the unexplored fog", hover.structure_text(where) == "")
		var before: int = _floats_with(game, "Crumbling")
		wall.current_health = 40
		wall.take_damage({"bludgeoning": 20})
		_check("no notice under the unexplored fog", _floats_with(game, "Crumbling") == before)
	else:
		print("SKIP exploration gate (spot already explored)")
	ExplorationManager.active = false

	# Door: the open fade and the damage darkening compose.
	var door = _spawn(&"door_wood", where + Vector2(400, 0), true)
	await _frames(1)
	door.max_health = 80
	door.current_health = 80
	door.take_damage({"bludgeoning": 40})
	_check("door cracking", door.get_damage_state() == STATE.CRACKING, door.current_health)
	door.open_door()
	var m: Color = door._visual().self_modulate
	_check("open door: faded and still dark", is_equal_approx(m.a, 0.85) and is_equal_approx(m.r, 0.75), m)
	_check("open door status", door.get_hover_status() == "Open")
	await _frames(1)
	door.close_door()
	m = door._visual().self_modulate
	_check("closed door: opaque and still dark", is_equal_approx(m.a, 1.0) and is_equal_approx(m.r, 0.75), m)
	door.locked = true
	door.key_id = ""
	_check("locked, no key: Barred", door.get_hover_status() == "Barred")
	door.key_id = "iron_key"
	_check("locked with a key: Locked", door.get_hover_status() == "Locked")
	_check("door hover title", hover.describe_structure(door).contains("Wooden door[/b][/font_size] (Locked)"), hover.describe_structure(door))
	await _physics_frames(3)
	_check("pick_structure prefers the door", hover.pick_structure(door.global_position) == door)
	wall.queue_free()
	door.queue_free()
	ExplorationManager.active = explore_was
