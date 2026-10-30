# res://tests/item_owner_theft_test.gd
# Headless assertion harness for the TG export contract's row schema (P2-E):
# per-item owners on Maps.json item_spawns rows reach the law. Every item is
# built the way Game._spawn_items builds it (SpawnRowSchema.item_owner_faction,
# then create_item's owner_faction / owner_uid), on the REAL tg_hillside_upper
# row (settlement: true, region perrow -> liziti law); the take is reported
# through CrimeManager with the real take_payload.
#   * a Devil-owned bank item (the owner_faction TG stamps on the bank's items
#     under contract 2) is Theft under liziti law, witnessed by a liziti clerk
#     whose fuse reports it to the law (crime_reported);
#   * an item row with no owner keys falls back to the settlement owner (the
#     jurisdiction), exactly as before the schema;
#   * an owner_uid row is owned by that character's faction (the Bank Steward:
#     devil) over the settlement fallback; an absent owner falls back;
#   * owner_uid only names the map's own spawns (SpawnRowSchema.faction_of_uid):
#     a party member or a summon carrying the same template / name never
#     matches, and "template#N" needs the spawn_ordinal meta (no default 0);
#   * a per-item owner the law does not protect (golden_guard, liziti's enemy)
#     bypasses the settlement fallback: taking it is no crime;
#   * a map that is no settlement: a row without keys stays unowned;
#   * the npc override list is the old hard-coded one (rows without the keys
#     spawn as before);
#   * end to end on the SHIPPED row (Perrow train 2, export contract 2): the
#     real game.tscn loads tg_hillside_upper through Game._spawn_items, every
#     Devil-owned bank row comes up as a devil-owned item, the rest fall back to
#     liziti, and the party taking a bank item is Theft under liziti law.
# Real ProceduralCharacter.tscn instances with AI off: fuses never tick here
# (until the last case, which boots the real game and steps out of its way).
# Run:  godot --headless --path . res://tests/item_owner_theft_test.tscn
# Judge by PASS/FAIL lines, not exit code alone (startup noise is normal).
extends Node2D

const PC_SCENE := preload("res://Characters/ProceduralCharacter.tscn")
const ITEM_SCENE := preload("res://Structures/Objects/Item.tscn")
const PERROW_MAP := "tg_hillside_upper"

var failures := 0

# --- Game stub surface ---
var current_map_id: String = PERROW_MAP
var characters_in_scene: Array = []
var party_chars: Array = []
var items_in_scene: Array = []
var stealth_mode: bool = false

var crimes: Array = []     # captured crime_committed emissions
var reported: Array = []   # captured crime_reported emissions (the law heard it)

func _check(check_name: String, cond: bool, detail: String = "") -> void:
	if cond:
		print("PASS %s" % check_name)
	else:
		failures += 1
		print("FAIL %s: %s" % [check_name, detail])

func _spawn(faction: String, pos: Vector2, char_name: String, face_up: bool = true) -> ProceduralCharacter:
	var pc: ProceduralCharacter = PC_SCENE.instantiate()
	add_child(pc)
	pc.global_position = pos
	pc.faction_id = faction
	pc.Name = char_name
	if not face_up:
		pc.rotation = PI
	characters_in_scene.append(pc)
	return pc

## One item_spawns row -> a world Item, owned the way Game._spawn_items owns it.
func _spawn_row(item_def: Dictionary, map_id: String) -> Item:
	var map_data: Dictionary = MapDatabase.get_map_data(map_id)
	var item: Item = ITEM_SCENE.instantiate() as Item
	item.id = str(item_def.get("id", ""))
	var owner_f: String = SpawnRowSchema.item_owner_faction(item_def, map_data, map_id, characters_in_scene,
		party_chars)
	if not owner_f.is_empty():
		item.owner_faction = owner_f
	if item_def.has("owner_uid"):
		item.owner_uid = str(item_def["owner_uid"])
	var pa: Array = item_def.get("position", [0, 0])
	item.global_position = Vector2(float(pa[0]), float(pa[1]))
	add_child(item)
	items_in_scene.append(item)
	return item

func _clear_scene() -> void:
	for c in characters_in_scene:
		if is_instance_valid(c):
			c.queue_free()
	for it in items_in_scene:
		if is_instance_valid(it):
			it.queue_free()
	characters_in_scene = []
	party_chars = []
	items_in_scene = []
	await get_tree().physics_frame
	await get_tree().physics_frame

func _await_frames(n: int) -> void:
	for _i in range(n):
		await get_tree().physics_frame

func _pending(pc: ProceduralCharacter) -> Dictionary:
	var ai_node = pc.get_node_or_null("AI")
	return ai_node.pending_outcry if ai_node != null else {}

func _ready() -> void:
	add_to_group("game")
	TimeManager.pause_time()
	CrimeManager.crime_committed.connect(func(actor, verdict, _payload): crimes.append({"actor": actor, "verdict": verdict}))
	CrimeManager.crime_reported.connect(func(enforcer, payload): reported.append({"enforcer": enforcer, "payload": payload}))
	_case_perrow_is_liziti()
	await _case_devil_bank_item()
	await _case_unowned_falls_back()
	await _case_owner_uid()
	await _case_uid_only_map_spawns()
	await _case_unprotected_owner()
	await _case_not_a_settlement()
	_case_npc_overrides()
	await _case_real_bank_row()
	print("HARNESS DONE failures=%d" % failures)
	get_tree().quit(1 if failures > 0 else 0)

func _last_verdict() -> Dictionary:
	if crimes.is_empty():
		return {}
	return crimes.back()["verdict"]

func _case_perrow_is_liziti() -> void:
	var md: Dictionary = MapDatabase.get_map_data(PERROW_MAP)
	_check("perrow.row-is-settlement", bool(md.get("settlement", false)), str(md.get("settlement")))
	_check("perrow.jurisdiction-liziti", LawDatabase.jurisdiction_for_map(PERROW_MAP) == "liziti",
		LawDatabase.jurisdiction_for_map(PERROW_MAP))
	_check("perrow.devil-protected", not FactionDatabase.are_hostile("devil", "liziti"))

func _case_devil_bank_item() -> void:
	current_map_id = PERROW_MAP
	var thief := _spawn("player", Vector2(0, -300), "Burglar")
	party_chars = [thief]
	var clerk := _spawn("liziti", Vector2(0, 0), "Clerk")   # faces up: sees the thief
	var chest := _spawn_row({"id": "desk", "position": [0, -300], "owner_faction": "devil"}, PERROW_MAP)
	_check("devil.row-owner-wins", chest.owner_faction == "devil", chest.owner_faction)
	var before: int = crimes.size()
	CrimeManager.report(thief, "take", CrimeManager.take_payload(chest))
	_check("devil.take-is-a-crime", crimes.size() == before + 1)
	var v: Dictionary = _last_verdict()
	_check("devil.statute-theft", str(v.get("statute", "")) == "theft", str(v))
	_check("devil.liziti-law", str(v.get("law_faction", "")) == "liziti", str(v))
	var pending: Dictionary = _pending(clerk)
	_check("devil.liziti-witness-fuse", not pending.is_empty())
	_check("devil.witness-identified", bool(pending.get("identified", false)))
	_check("devil.witness-reports-liziti-theft", str(pending.get("law_faction", "")) == "liziti"
		and str(pending.get("statute", "")) == "theft", str(pending))
	# the clerk is liziti law herself: her fuse delivers the report directly
	var heard: int = reported.size()
	var ai_node = clerk.get_node_or_null("AI")
	if ai_node != null and ai_node._outcry_timer > 0.0:
		ai_node._tick_outcry(ai_node._outcry_timer + 0.01)
	_check("devil.liziti-law-heard-it", reported.size() == heard + 1 and reported.back()["enforcer"] == clerk,
		"%d reports" % (reported.size() - heard))
	CrimeManager.settle_with("liziti", "")
	await _clear_scene()

func _case_unowned_falls_back() -> void:
	current_map_id = PERROW_MAP
	var thief := _spawn("player", Vector2(0, -300), "Pilferer")
	party_chars = [thief]
	var apple := _spawn_row({"id": "apple", "position": [0, -300]}, PERROW_MAP)
	_check("fallback.settlement-owner", apple.owner_faction == "liziti", apple.owner_faction)
	var before: int = crimes.size()
	CrimeManager.report(thief, "take", CrimeManager.take_payload(apple))
	_check("fallback.theft-as-before", crimes.size() == before + 1
		and str(_last_verdict().get("statute", "")) == "theft", str(_last_verdict()))
	await _clear_scene()

func _case_owner_uid() -> void:
	current_map_id = PERROW_MAP
	var thief := _spawn("player", Vector2(0, -300), "Embezzler")
	party_chars = [thief]
	var steward := _spawn("devil", Vector2(400, 400), "Bank Steward", false)
	steward.set_meta("template_id", "merchant")
	steward.set_meta("unique_name", "Bank Steward")
	var guard := _spawn("liziti", Vector2(-400, 400), "Watchman", false)
	guard.set_meta("template_id", "town_guard")
	guard.set_meta("unique_name", "")
	guard.set_meta("spawn_ordinal", 1)
	var ledger := _spawn_row({"id": "loose_papers", "position": [0, -300],
		"owner_uid": "merchant/Bank Steward"}, PERROW_MAP)
	_check("uid.owner-faction-from-character", ledger.owner_faction == "devil", ledger.owner_faction)
	_check("uid.owner-uid-kept", ledger.owner_uid == "merchant/Bank Steward", ledger.owner_uid)
	var before: int = crimes.size()
	CrimeManager.report(thief, "take", CrimeManager.take_payload(ledger))
	_check("uid.theft-from-the-steward", crimes.size() == before + 1
		and str(_last_verdict().get("statute", "")) == "theft", str(_last_verdict()))
	var ordinal := _spawn_row({"id": "apple", "position": [0, -300], "owner_uid": "town_guard#1"}, PERROW_MAP)
	_check("uid.ordinal-form", ordinal.owner_faction == "liziti", ordinal.owner_faction)
	var absent := _spawn_row({"id": "apple", "position": [0, -300], "owner_uid": "merchant/Nobody"}, PERROW_MAP)
	_check("uid.absent-owner-falls-back", absent.owner_faction == "liziti", absent.owner_faction)
	_check("uid.absent-owner-uid-kept", absent.owner_uid == "merchant/Nobody")
	await _clear_scene()

## faction_of_uid matches only the map's own spawns. Every impostor below is
## listed BEFORE the real spawn it shadows, so a first-hit match on it shows.
func _case_uid_only_map_spawns() -> void:
	current_map_id = PERROW_MAP
	# a recruited party member keeps the steward's spawn meta (join_party)
	var recruit := _spawn("player", Vector2(0, -300), "Bank Steward")
	recruit.set_meta("template_id", "merchant")
	recruit.set_meta("unique_name", "Bank Steward")
	recruit.set_meta("spawn_ordinal", 0)
	recruit.set_meta("party_index", 1)
	# the same, known only through the party list (no party_index meta)
	var listed := _spawn("player", Vector2(40, -300), "Bank Steward")
	listed.set_meta("template_id", "merchant")
	listed.set_meta("unique_name", "Bank Steward")
	party_chars = [listed]
	# a summon whose template matches a spawn's ordinal uid
	var imp := _spawn("golden_guard", Vector2(80, -300), "Rat Swarm")
	imp.set_meta("template_id", "town_guard")
	imp.set_meta("unique_name", "")
	imp.set_meta("spawn_ordinal", 0)
	imp.set_meta("summoned_by", recruit)
	# a character that never got a spawn ordinal (rival, test, hand-placed)
	var stray := _spawn("golden_guard", Vector2(120, -300), "Stray Guard")
	stray.set_meta("template_id", "town_guard")
	stray.set_meta("unique_name", "")
	# the map's real spawns
	var steward := _spawn("devil", Vector2(400, 400), "Bank Steward", false)
	steward.set_meta("template_id", "merchant")
	steward.set_meta("unique_name", "Bank Steward")
	steward.set_meta("spawn_ordinal", 0)
	var guard := _spawn("liziti", Vector2(-400, 400), "Watchman", false)
	guard.set_meta("template_id", "town_guard")
	guard.set_meta("unique_name", "")
	guard.set_meta("spawn_ordinal", 0)
	_check("uidspawn.named-skips-party", SpawnRowSchema.faction_of_uid("merchant/Bank Steward",
		characters_in_scene, party_chars) == "devil",
		SpawnRowSchema.faction_of_uid("merchant/Bank Steward", characters_in_scene, party_chars))
	_check("uidspawn.ordinal-skips-summon-and-unstamped", SpawnRowSchema.faction_of_uid("town_guard#0",
		characters_in_scene, party_chars) == "liziti",
		SpawnRowSchema.faction_of_uid("town_guard#0", characters_in_scene, party_chars))
	_check("uidspawn.merchant-ordinal-skips-recruit", SpawnRowSchema.faction_of_uid("merchant#0",
		characters_in_scene, party_chars) == "devil",
		SpawnRowSchema.faction_of_uid("merchant#0", characters_in_scene, party_chars))
	# with the real spawns gone, nothing else may stand in for them
	characters_in_scene.erase(steward)
	characters_in_scene.erase(guard)
	_check("uidspawn.party-member-never-owns", SpawnRowSchema.faction_of_uid("merchant/Bank Steward",
		characters_in_scene, party_chars) == "")
	_check("uidspawn.summon-never-owns", SpawnRowSchema.faction_of_uid("town_guard#0",
		[imp], []) == "")
	_check("uidspawn.no-ordinal-meta-no-ordinal-match", SpawnRowSchema.faction_of_uid("town_guard#0",
		[stray], []) == "")
	_check("uidspawn.bare-template-still-names-it", SpawnRowSchema.faction_of_uid("town_guard",
		[stray], []) == "golden_guard")
	var ledger := _spawn_row({"id": "loose_papers", "position": [0, -300],
		"owner_uid": "merchant/Bank Steward"}, PERROW_MAP)
	_check("uidspawn.row-falls-back-not-to-the-party", ledger.owner_faction == "liziti", ledger.owner_faction)
	steward.queue_free()
	guard.queue_free()
	await _clear_scene()

func _case_unprotected_owner() -> void:
	current_map_id = PERROW_MAP
	var thief := _spawn("player", Vector2(0, -300), "Partisan")
	party_chars = [thief]
	var loot := _spawn_row({"id": "apple", "position": [0, -300], "owner_faction": "golden_guard"}, PERROW_MAP)
	_check("unprotected.row-owner-over-settlement", loot.owner_faction == "golden_guard", loot.owner_faction)
	var before: int = crimes.size()
	CrimeManager.report(thief, "take", CrimeManager.take_payload(loot))
	_check("unprotected.no-crime", crimes.size() == before,
		"liziti law does not protect its enemy's goods: %s" % str(_last_verdict()))
	await _clear_scene()

func _case_not_a_settlement() -> void:
	# tg_export: a procedural export, no settlement, no default_item_owner
	var md: Dictionary = MapDatabase.get_map_data("tg_export")
	_check("wild.row-is-not-a-settlement", not bool(md.get("settlement", false)) and not md.has("default_item_owner"))
	var stray := _spawn_row({"id": "apple", "position": [0, 0]}, "tg_export")
	_check("wild.unowned", stray.owner_faction == "", stray.owner_faction)
	await _clear_scene()

func _case_npc_overrides() -> void:
	var full: Dictionary = {"template_id": "merchant", "position": [0, 0], "count": 1.0,
		"unique_name": "Bank Steward", "titles": ["Steward"], "faction": "devil", "dialogue": "bank_steward",
		"extra_items": ["hillside_bank_treasury_key"], "condition": {"time_hour_min": 8.0},
		"home": {"position": [10, 10], "building": "bank"}, "resident_id": "bank:0"}
	var ov: Dictionary = SpawnRowSchema.npc_overrides(full)
	_check("npc.override-keys", ov.keys() == ["unique_name", "titles", "faction", "dialogue"], str(ov.keys()))
	_check("npc.titles-stay-an-array", ov["titles"] is Array)
	_check("npc.no-keys-no-overrides", SpawnRowSchema.npc_overrides({"template_id": "merchant"}).is_empty())

## The shipped tg_hillside_upper row through the REAL load path: game.tscn
## (vault_key_test's boot), Game.load_map -> _spawn_items ->
## SpawnRowSchema.item_owner_faction. This harness stops being the stand-in
## Game first: CrimeManager reads current_scene, Door/floor code the "game" group.
func _case_real_bank_row() -> void:
	remove_from_group("game")
	var game_scene: PackedScene = load("res://game.tscn")
	var game = game_scene.instantiate()
	game.current_map_id = ""   # _ready's load_map("") early-returns; we load below
	get_tree().root.add_child(game)
	get_tree().current_scene = game
	await _await_frames(2)
	game.load_map(PERROW_MAP)
	await _await_frames(6)
	var md: Dictionary = game.current_map_data
	_check("real.row-is-contract-2", int(md.get("export_contract", 1)) >= 2, str(md.get("export_contract", 1)))
	var want: int = 0
	for row in md.get("item_spawns", []):
		if row is Dictionary and str((row as Dictionary).get("owner_faction", "")) == "devil":
			want += int((row as Dictionary).get("count", 1))
	var devil: Array = []
	var settled: int = 0
	for it in game.items_in_scene:
		if not is_instance_valid(it):
			continue
		if str(it.owner_faction) == "devil":
			devil.append(it)
		elif str(it.owner_faction) == "liziti":
			settled += 1
	print("INFO %s: %d Devil-owned bank rows, %d live devil items, %d liziti" % [
		PERROW_MAP, want, devil.size(), settled])
	_check("real.bank-rows-ship", want > 0, "no item row carries owner_faction devil")
	_check("real.bank-items-load-devil-owned", devil.size() == want, "%d rows, %d live" % [want, devil.size()])
	_check("real.other-items-settlement-owned", settled > 0)
	if devil.is_empty() or game.party_chars.is_empty():
		_check("real.party-present", not game.party_chars.is_empty())
		return
	var before: int = crimes.size()
	CrimeManager.report(game.party_chars[0], "take", CrimeManager.take_payload(devil[0]))
	var v: Dictionary = _last_verdict()
	_check("real.take-bank-item-is-theft", crimes.size() == before + 1
		and str(v.get("statute", "")) == "theft" and str(v.get("law_faction", "")) == "liziti", str(v))
