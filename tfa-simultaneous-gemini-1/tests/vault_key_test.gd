# res://tests/vault_key_test.gd
# Headless harness for P1-A (TG docs/roadmap.md): the Perrow vault keys are
# CARRIED BY NPCs. Drives the REAL game scene (law_persist_test's boot) through
# the hillside bands with the player's own verbs: the context menu's Trade /
# Search Body / Open Door, the TradeWindow + PartySidePanel transfer path, the
# corpse loot window.
#   upper  - the Bank Steward (merchant) carries hillside_bank_treasury_key: BUY
#            it (300 gold through Trade) and open the bank vault door. A* finds
#            no way into the treasury while it is locked, and one once it opens.
#   middle - the bank's context:shell copy opens with the bought key; the Gate
#            Sergeant (town_guard) carries hillside_gate_strongroom_key: kill him,
#            Search Body, take the key, open the strongroom.
#   lower  - the strongroom's context:shell copy opens with the looted key.
#   back   - warp out and back: the sold / looted key stays gone, each carrier
#            keeps its state under its template/unique_name uid, and ordinary
#            town_guards keep their ordinal uids (town_guard#0...).
#   last   - murdering a protected carrier (the steward) is recorded as a crime,
#            and the dead carrier stays dead across a warp.
# Until Perrow train 1 exports the carrier rows into Maps.json, the test appends
# the rows the converter emits (TG tools/grasslab maps_config.json at_room rows,
# px = 2 x layout wu) to the in-memory map data, LAST like the converter, so
# load_map spawns them through the real _spawn_npcs path. Once the rows ship they
# are used as is (and checked to be the last row).
# Run:  godot --headless --path . res://tests/vault_key_test.tscn
# Judge by PASS/FAIL lines and "VAULT KEY DONE failures=N" (exit 1 on failures).
extends Node2D

const BANK_KEY := "hillside_bank_treasury_key"
const GATE_KEY := "hillside_gate_strongroom_key"
const UPPER := "tg_hillside_upper"
const MIDDLE := "tg_hillside_middle"
const LOWER := "tg_hillside_lower"
const STEWARD := "Bank Steward"
const SERGEANT := "Gate Sergeant"
const PRICE := 300
# The converter's carrier rows (layouts/hillside_upper.json and hillside_middle.json
# npc_spawns, as MapExporter writes them). Injected only when Maps.json lacks them.
const CARRIER_ROWS := {
	UPPER: {"template_id": "merchant", "position": [5280, 2208], "count": 1, "spread_radius": 60,
		"unique_name": STEWARD, "extra_items": [BANK_KEY]},
	MIDDLE: {"template_id": "town_guard", "position": [6624, 2912], "count": 1, "spread_radius": 60,
		"unique_name": SERGEANT, "extra_items": [GATE_KEY]},
}
# Perrow is under mob rule ON PURPOSE (docs/law_crime_stealth_plan.md): its law
# faction is liziti, liziti counts golden_guard an enemy, and liziti custom only
# protects factions it is not hostile to. So killing the Gate Sergeant (a
# town_guard: golden_guard) is NO crime in Perrow, where killing the steward (a
# neutral merchant) is murder. The roadmap assumed the sergeant's death "a crime";
# this pins what the law says. Flip it if his row gets a protected "faction".
const GATE_SERGEANT_KILL_IS_CRIME := false
# A tile centre inside the bank treasury on tg_hillside_upper (tile (80, 31)). The
# hall/treasury partition beside the vault door sits on a tile boundary (half
# 7 px, obstacle reach 29.4 < 32 px): only MapLoader's seam tiles keep A* from
# planning a way in around the locked door.
const TREASURY_PX := Vector2(5152, 2016)

var failures := 0
var game = null
var crimes: Array = []              # every CrimeManager.crime_committed
var guard_ordinals_first: Array = []
var sergeant_ordinal: int = -1
var steward_ordinal: int = -1
var steward_gold_after_trade: int = -1

func _check(check_name: String, cond: bool, detail: String = "") -> void:
	if cond:
		print("PASS %s" % check_name)
	else:
		failures += 1
		print("FAIL %s: %s" % [check_name, detail])

func _await_frames(n: int) -> void:
	for _i in range(n):
		await get_tree().physics_frame

func _on_crime(actor, verdict: Dictionary, payload: Dictionary) -> void:
	crimes.append({"actor": actor, "verdict": verdict, "payload": payload})

func _crimes_against(victim) -> Array:
	var out: Array = []
	for c in crimes:
		# victims of earlier maps are freed by the warps since
		var v = (c["payload"] as Dictionary).get("victim")
		if is_instance_valid(v) and v == victim:
			out.append(c)
	return out

# Door.interact refuses while the tactical pause is on (a dialogue can set it).
func _unpause() -> void:
	if PauseManager.is_paused:
		PauseManager.unpause()

# ---------------------------------------------------------------------------
# Finders
# ---------------------------------------------------------------------------

func _carrier(unique_name: String):
	for c in game.characters_in_scene:
		if is_instance_valid(c) and str(c.get_meta("unique_name", "")) == unique_name:
			return c
	return null

func _doors(key_id: String) -> Array:
	var out: Array = []
	for s in game.structures_in_scene:
		if is_instance_valid(s) and s is Door and (s as Door).key_id == key_id:
			out.append(s)
	return out

func _count(c, item_id: String) -> int:
	var n: int = 0
	if not is_instance_valid(c) or c.inventory == null:
		return 0
	for it in c.inventory.items:
		if str(it.get("id", "")) == item_id:
			var s = it.get("num_stacks", 1)
			n += int(s) if s != null else 1
	return n

func _party_count(item_id: String) -> int:
	var n: int = 0
	for c in game.party_chars:
		n += _count(c, item_id)
	return n

func _ordinary_guards() -> Array:
	var out: Array = []
	for c in game.characters_in_scene:
		if is_instance_valid(c) and str(c.get_meta("template_id", "")) == "town_guard" \
				and str(c.get_meta("unique_name", "")) == "":
			out.append(c)
	return out

func _ordinary_guard_ordinals() -> Array:
	var out: Array = []
	for c in _ordinary_guards():
		out.append(int(c.get_meta("spawn_ordinal", -1)))
	out.sort()
	return out

## How many town_guards the rows above the carrier's row spawn: the ordinals
## 0..n-1 that the dead-guard uids (town_guard#k) are keyed by.
func _guards_before_carrier(map_id: String, unique_name: String) -> int:
	var n: int = 0
	for r in MapDatabase.get_map_data(map_id).get("npc_spawns", []):
		if not (r is Dictionary):
			continue
		var row: Dictionary = r
		if str(row.get("unique_name", "")) == unique_name:
			break
		if str(row.get("template_id", "")) == "town_guard":
			n += int(row.get("count", 1))
	return n

func _menu_for(target):
	var kids: Array = game.get_node("GameUI").get_children()
	for i in range(kids.size() - 1, -1, -1):
		var m = kids[i]
		if not m.is_queued_for_deletion() and "target_character" in m \
				and is_instance_valid(m.target_character) and m.target_character == target:
			return m
	return null

## The options Game.show_context_menu offers on `target` (the menu is closed again).
func _menu_options(target, actor) -> Array:
	game.show_context_menu(target, Vector2.ZERO, actor)
	var opts: Array = []
	var menu = _menu_for(target)
	if menu != null:
		for b in menu.vbox.get_children():
			if b is Button:
				opts.append(str((b as Button).text))
		menu.queue_free()
	game.context_menu_open = false
	return opts

## Pick `option` from the real context menu on `target` (as a click would).
func _choose(target, actor, option: String) -> bool:
	game.show_context_menu(target, Vector2.ZERO, actor)
	var menu = _menu_for(target)
	if menu == null:
		return false
	menu._on_option_selected(option)
	return true

func _trade_window():
	for w in get_tree().get_nodes_in_group("trade_window"):
		if not w.is_queued_for_deletion():
			return w
	return null

func _loot_window(corpse):
	for c in game.get_node("GameUI").get_children():
		if c is ChestInventoryWindow and not c.is_queued_for_deletion() \
				and (c as ChestInventoryWindow).chest_item == corpse:
			return c
	return null

func _reachable(from_char, to_char) -> bool:
	var path: Array = GridManager.find_path(GridManager.world_to_map(from_char.global_position),
		GridManager.world_to_map(to_char.global_position))
	return not path.is_empty()

# ---------------------------------------------------------------------------
# Carrier rows (before train 1: inject the converter's rows)
# ---------------------------------------------------------------------------

func _ensure_carrier_rows() -> void:
	for map_id in CARRIER_ROWS:
		var want: Dictionary = CARRIER_ROWS[map_id]
		var data: Dictionary = MapDatabase.get_map_data(map_id)
		if data.is_empty():
			_check("rows.%s-exists" % map_id, false, "map missing from Maps.json")
			continue
		if not (data.get("npc_spawns") is Array):
			data["npc_spawns"] = []
		var rows: Array = data["npc_spawns"]
		var at: int = -1
		for i in range(rows.size()):
			if rows[i] is Dictionary and str((rows[i] as Dictionary).get("unique_name", "")) == str(want["unique_name"]):
				at = i
		if at == -1:
			rows.append(want.duplicate(true))
			print("NOTE %s: no %s row in Maps.json yet (before Perrow train 1): injected the converter's row"
				% [map_id, want["unique_name"]])
			continue
		var row: Dictionary = rows[at]
		print("NOTE %s: the shipped %s row is used" % [map_id, want["unique_name"]])
		_check("rows.%s-carrier-row-is-last" % map_id, at == rows.size() - 1,
			"row %d of %d: the per-template ordinals above it would move" % [at, rows.size()])
		_check("rows.%s-carrier-row-matches" % map_id, str(row.get("template_id", "")) == str(want["template_id"])
			and row.get("extra_items", []) == want["extra_items"], str(row))

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

func _ready() -> void:
	TimeManager.pause_time()
	CrimeManager.crime_committed.connect(_on_crime)
	_ensure_carrier_rows()
	# Let the initial scene-ready cascade finish first (law_persist_test): a node
	# added to root DURING it never receives NOTIFICATION_READY.
	await get_tree().process_frame
	var game_scene: PackedScene = load("res://game.tscn")
	game = game_scene.instantiate()
	game.current_map_id = ""   # _ready's load_map("") early-returns; we load below
	get_tree().root.add_child(game)
	get_tree().current_scene = game
	await _await_frames(2)
	game.load_map(UPPER)
	await _await_frames(6)
	_unpause()

	await _case_buy_bank_key()
	await _case_loot_gate_key()
	await _case_shells_on_lower()
	await _case_back_on_middle()
	await _case_back_on_upper()
	await _case_carrier_murder_recorded()

	print("VAULT KEY DONE failures=%d" % failures)
	get_tree().quit(1 if failures > 0 else 0)

# upper: buy the treasury key from the Bank Steward, open the vault.
func _case_buy_bank_key() -> void:
	var steward = _carrier(STEWARD)
	_check("buy.steward-spawned", steward != null, "no NPC named %s on %s" % [STEWARD, UPPER])
	if steward == null or game.party_chars.is_empty():
		return
	var buyer = game.party_chars[0]
	steward_ordinal = int(steward.get_meta("spawn_ordinal", -1))
	_check("buy.steward-is-merchant", str(steward.get_meta("template_id", "")) == "merchant")
	_check("buy.steward-persist-unique", bool(steward.get_meta("persist_unique", false)))
	_check("buy.steward-not-a-service-npc", not game._is_service_npc(steward),
		"a title would move him to the service uid path and Town Services")
	_check("buy.steward-carries-key", _count(steward, BANK_KEY) == 1, "count %d" % _count(steward, BANK_KEY))
	_check("buy.steward-reachable", _reachable(buyer, steward),
		"no A* path from the arrival %s to %s" % [buyer.global_position, steward.global_position])
	var vaults: Array = _doors(BANK_KEY)
	_check("buy.vault-door-present", vaults.size() == 1, "%d doors keyed %s" % [vaults.size(), BANK_KEY])
	if vaults.is_empty():
		return
	var vault: Door = vaults[0]
	_check("buy.vault-locked", vault.locked)
	_choose(vault, buyer, "Open Door")
	_check("buy.vault-refuses-without-key", vault.locked and not vault.is_open)
	var hall: Vector2i = GridManager.world_to_map(steward.global_position)
	var treasury: Vector2i = GridManager.world_to_map(TREASURY_PX)
	_check("buy.treasury-sealed-to-astar", GridManager.find_path(hall, treasury).is_empty(),
		"A* plans %s -> %s around the locked vault door (through the partition)" % [hall, treasury])
	var opts: Array = _menu_options(steward, buyer)
	_check("buy.trade-offered", "Trade" in opts, str(opts))
	var gold: Dictionary = ItemDatabase.get_item_data("gold")
	gold["num_stacks"] = PRICE
	gold["is_stackable"] = true
	_check("buy.buyer-has-gold", bool(buyer.inventory.add_stack(gold)))
	var buyer_gold: int = _count(buyer, "gold")
	var npc_gold: int = _count(steward, "gold")
	var crimes_before: int = crimes.size()
	_choose(steward, buyer, "Trade")
	await _await_frames(1)
	var tw = _trade_window()
	_check("buy.trade-window-open", tw != null)
	if tw == null:
		return
	# The key: NPC grid -> the buyer's party-panel row (PartySidePanel._drop_data's
	# trade arm). The gold: one coin per drop onto the trade window, as dragging
	# from the party panel does (TradeWindow._drop_data).
	var panel = game.get_node("GameUI/PartySidePanel")
	panel._transfer_one_item(steward, buyer, steward.inventory.find_item_by_id(BANK_KEY))
	_check("buy.unpaid-refused", bool(tw._accept_button.disabled), str(tw._balance_label.text))
	for _i in range(PRICE):
		var gi: int = buyer.inventory.find_item_by_id("gold")
		if gi == -1:
			break
		var raw: Dictionary = buyer.inventory.items[gi]
		tw._drop_data(Vector2.ZERO, {"source_character": buyer,
			"entry": {"kind": "item", "source_index": gi, "raw": raw, "display_name": "Gold"}})
	_check("buy.paid-accepted", not bool(tw._accept_button.disabled), str(tw._balance_label.text))
	tw._on_accept_pressed()
	await _await_frames(1)
	_check("buy.buyer-holds-key", _count(buyer, BANK_KEY) == 1)
	_check("buy.steward-sold-key", _count(steward, BANK_KEY) == 0)
	_check("buy.gold-changed-hands", _count(buyer, "gold") == buyer_gold - PRICE
		and _count(steward, "gold") == npc_gold + PRICE,
		"buyer %d -> %d, steward %d -> %d" % [buyer_gold, _count(buyer, "gold"), npc_gold, _count(steward, "gold")])
	steward_gold_after_trade = _count(steward, "gold")
	_check("buy.buying-is-legal", crimes.size() == crimes_before, str(crimes.slice(crimes_before)))
	_unpause()
	_choose(vault, buyer, "Open Door")
	_check("buy.vault-opens-with-bought-key", not vault.locked and vault.is_open,
		"locked=%s open=%s" % [vault.locked, vault.is_open])
	_check("buy.treasury-pathable-once-open", not GridManager.find_path(hall, treasury).is_empty(),
		"no A* path %s -> %s through the open vault door" % [hall, treasury])

# middle: the bank's shell copy opens with the bought key; kill the Gate Sergeant,
# Search Body, take the strongroom key, open the strongroom.
func _case_loot_gate_key() -> void:
	game.load_map(MIDDLE, UPPER)
	await _await_frames(6)
	_unpause()
	if game.party_chars.is_empty():
		_check("loot.party-arrived", false)
		return
	var hero = game.party_chars[0]
	_check("loot.bought-key-crossed-the-warp", _party_count(BANK_KEY) == 1, "count %d" % _party_count(BANK_KEY))
	var shells: Array = _doors(BANK_KEY)
	_check("shell.bank-copy-on-middle", shells.size() == 1, "%d doors keyed %s" % [shells.size(), BANK_KEY])
	if not shells.is_empty():
		var shell: Door = shells[0]
		_check("shell.bank-copy-locked", shell.locked)
		_choose(shell, hero, "Open Door")
		_check("shell.bank-copy-opens-with-bought-key", not shell.locked and shell.is_open)

	var sergeant = _carrier(SERGEANT)
	_check("loot.sergeant-spawned", sergeant != null, "no NPC named %s on %s" % [SERGEANT, MIDDLE])
	if sergeant == null:
		return
	_check("loot.sergeant-is-town-guard", str(sergeant.get_meta("template_id", "")) == "town_guard")
	_check("loot.sergeant-persist-unique", bool(sergeant.get_meta("persist_unique", false)))
	_check("loot.sergeant-not-a-service-npc", not game._is_service_npc(sergeant))
	_check("loot.sergeant-carries-key", _count(sergeant, GATE_KEY) == 1, "count %d" % _count(sergeant, GATE_KEY))
	_check("loot.sergeant-reachable", _reachable(hero, sergeant),
		"no A* path from %s to %s" % [hero.global_position, sergeant.global_position])
	# golden_guard must stay non-hostile to the player, or Trade is not offered
	_check("loot.sergeant-not-hostile", not FactionDatabase.are_hostile("player", sergeant.faction_id),
		"faction %s" % sergeant.faction_id)
	var opts: Array = _menu_options(sergeant, hero)
	_check("loot.trade-offered", "Trade" in opts, str(opts))

	# Ordinal uids: the ordinary guards keep 0..n-1; the carrier (last row) is
	# stamped n but persists under town_guard/Gate Sergeant.
	var n: int = _guards_before_carrier(MIDDLE, SERGEANT)
	var want: Array = []
	for k in range(n):
		want.append(k)
	guard_ordinals_first = _ordinary_guard_ordinals()
	_check("uid.ordinary-guard-ordinals", guard_ordinals_first == want, "%s vs %s" % [guard_ordinals_first, want])
	sergeant_ordinal = int(sergeant.get_meta("spawn_ordinal", -1))
	_check("uid.carrier-ordinal-after-them", sergeant_ordinal == n, "%d vs %d" % [sergeant_ordinal, n])

	var rooms: Array = _doors(GATE_KEY)
	_check("loot.strongroom-door-present", rooms.size() == 1, "%d doors keyed %s" % [rooms.size(), GATE_KEY])
	if rooms.is_empty():
		return
	var strong: Door = rooms[0]
	_choose(strong, hero, "Open Door")
	_check("loot.strongroom-refuses-without-key", strong.locked and not strong.is_open)

	var crimes_before: int = crimes.size()
	sergeant.take_damage({"slashing": 100000}, sergeant.global_position, hero)
	await _await_frames(2)
	_check("loot.sergeant-killed", not sergeant.is_alive())
	var recs: Array = _crimes_against(sergeant)
	_check("loot.kill-verdict-is-perrow-law", (not recs.is_empty()) == GATE_SERGEANT_KILL_IS_CRIME,
		"crimes recorded %s (Perrow law: golden_guard is unprotected under liziti custom)" % [recs])
	var verdict: Dictionary = CrimeManager.preview(hero, "attack", CrimeManager.attack_payload(hero, sergeant))
	_check("loot.law-preview-agrees", verdict.is_empty() != GATE_SERGEANT_KILL_IS_CRIME, str(verdict))
	print("NOTE crimes on the sergeant's death: %d (all crimes this case: %d)" % [recs.size(), crimes.size() - crimes_before])

	# Search Body: the loot window opens only within reach.
	hero.global_position = sergeant.global_position + Vector2(40, 0)
	game.primary_selected = hero
	var corpse_opts: Array = _menu_options(sergeant, hero)
	_check("loot.search-body-offered", "Search Body" in corpse_opts, str(corpse_opts))
	_choose(sergeant, hero, "Search Body")
	await _await_frames(1)
	var lw = _loot_window(sergeant)
	_check("loot.window-open", lw != null)
	if lw != null:
		var slot = null
		for s in lw._grid.get_children():
			if s.is_queued_for_deletion() or not s.has_meta("entry"):
				continue
			var raw = (s.get_meta("entry") as Dictionary).get("raw")
			if raw is Dictionary and str((raw as Dictionary).get("id", "")) == GATE_KEY:
				slot = s
		_check("loot.key-on-the-body", slot != null)
		if slot != null:
			lw._transfer_slot_to_selected(slot)
		lw._on_close_pressed()
	_check("loot.looter-holds-key", _count(hero, GATE_KEY) == 1)
	_check("loot.body-lost-key", _count(sergeant, GATE_KEY) == 0)
	_unpause()
	_choose(strong, hero, "Open Door")
	_check("loot.strongroom-opens-with-looted-key", not strong.locked and strong.is_open,
		"locked=%s open=%s" % [strong.locked, strong.is_open])

# lower: the strongroom's context:shell copy opens with the looted key; the
# carriers left behind persist under their named uids.
func _case_shells_on_lower() -> void:
	game.load_map(LOWER, MIDDLE)
	await _await_frames(6)
	_unpause()
	_check("lower.both-keys-crossed-the-warp", _party_count(BANK_KEY) == 1 and _party_count(GATE_KEY) == 1,
		"bank %d gate %d" % [_party_count(BANK_KEY), _party_count(GATE_KEY)])
	var bucket: Dictionary = game.npc_state_per_region.get(game._npc_bucket_key(), {})
	_check("uid.steward-named-uid", bucket.has("merchant/" + STEWARD), str(bucket.keys()))
	_check("uid.steward-not-under-ordinal", not bucket.has("merchant#%d" % steward_ordinal), str(bucket.keys()))
	_check("uid.sergeant-named-uid", bucket.has("town_guard/" + SERGEANT), str(bucket.keys()))
	_check("uid.sergeant-not-under-ordinal", not bucket.has("town_guard#%d" % sergeant_ordinal), str(bucket.keys()))
	var shells: Array = _doors(GATE_KEY)
	_check("shell.strongroom-copy-on-lower", shells.size() == 1, "%d doors keyed %s" % [shells.size(), GATE_KEY])
	if shells.is_empty() or game.party_chars.is_empty():
		return
	var shell: Door = shells[0]
	_check("shell.strongroom-copy-locked", shell.locked)
	_choose(shell, game.party_chars[0], "Open Door")
	_check("shell.strongroom-copy-opens-with-looted-key", not shell.locked and shell.is_open)

# middle again: the looted sergeant stays a looted corpse, the ordinals hold, the
# opened locks stay open; then a dead ORDINARY guard is left behind.
func _case_back_on_middle() -> void:
	game.load_map(MIDDLE, LOWER)
	await _await_frames(6)
	_unpause()
	var sergeant = _carrier(SERGEANT)
	_check("back.sergeant-respawned", sergeant != null)
	if sergeant != null:
		_check("back.sergeant-stays-dead", not sergeant.is_alive())
		_check("back.looted-key-stays-gone", _count(sergeant, GATE_KEY) == 0, "count %d" % _count(sergeant, GATE_KEY))
	_check("back.ordinary-guard-ordinals-unchanged", _ordinary_guard_ordinals() == guard_ordinals_first,
		"%s vs %s" % [_ordinary_guard_ordinals(), guard_ordinals_first])
	for d in _doors(GATE_KEY) + _doors(BANK_KEY):
		_check("back.middle-lock-stays-open", not (d as Door).locked, (d as Door).lock_key)
	var g0 = null
	for g in _ordinary_guards():
		if int(g.get_meta("spawn_ordinal", -1)) == 0:
			g0 = g
	_check("back.guard-0-present", g0 != null)
	if g0 != null and not game.party_chars.is_empty():
		g0.take_damage({"slashing": 100000}, g0.global_position, game.party_chars[0])
		await _await_frames(2)
		_check("back.guard-0-killed", not g0.is_alive())

# upper again: the steward kept his state (alive, no key, the gold he was paid),
# the dead ordinary guard persisted under its ordinal uid, the vault stays open.
func _case_back_on_upper() -> void:
	game.load_map(UPPER, MIDDLE)
	await _await_frames(6)
	_unpause()
	var bucket: Dictionary = game.npc_state_per_region.get(game._npc_bucket_key(), {})
	var dead0: Dictionary = bucket.get("town_guard#0", {})
	_check("uid.dead-ordinary-guard-keeps-ordinal-uid", not dead0.is_empty()
		and int(dead0.get("current_health", 1)) <= 0, str(bucket.keys()))
	var steward = _carrier(STEWARD)
	_check("back.steward-respawned", steward != null)
	if steward != null:
		_check("back.steward-alive", steward.is_alive())
		_check("back.sold-key-stays-gone", _count(steward, BANK_KEY) == 0, "count %d" % _count(steward, BANK_KEY))
		_check("back.steward-keeps-his-gold", _count(steward, "gold") == steward_gold_after_trade,
			"%d vs %d" % [_count(steward, "gold"), steward_gold_after_trade])
	for d in _doors(BANK_KEY):
		_check("back.vault-stays-open", not (d as Door).locked, (d as Door).lock_key)
	_check("back.party-keeps-both-keys", _party_count(BANK_KEY) == 1 and _party_count(GATE_KEY) == 1,
		"bank %d gate %d" % [_party_count(BANK_KEY), _party_count(GATE_KEY)])

# Killing a protected carrier is murder under Perrow's law, and a dead carrier
# stays dead (persist_unique covers the dead too).
func _case_carrier_murder_recorded() -> void:
	var steward = _carrier(STEWARD)
	if steward == null or game.party_chars.is_empty():
		_check("murder.steward-present", false)
		return
	var killer = game.party_chars[0]
	steward.take_damage({"slashing": 100000}, steward.global_position, killer)
	await _await_frames(2)
	_check("murder.steward-killed", not steward.is_alive())
	var recs: Array = _crimes_against(steward)
	var statute: String = str((recs[0]["verdict"] as Dictionary).get("statute", "")) if not recs.is_empty() else ""
	_check("murder.crime-recorded", statute == "murder", "crimes %s" % [recs])
	game.load_map(MIDDLE, UPPER)
	await _await_frames(4)
	game.load_map(UPPER, MIDDLE)
	await _await_frames(6)
	var again = _carrier(STEWARD)
	_check("murder.dead-carrier-stays-dead", again != null and not again.is_alive())
	if again != null:
		_check("murder.corpse-keeps-his-gold", _count(again, "gold") == steward_gold_after_trade,
			"%d vs %d" % [_count(again, "gold"), steward_gold_after_trade])
