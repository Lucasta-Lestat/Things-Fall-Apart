# res://tests/crime_gate_test.gd
# Headless assertion harness for Phase 4 — ownership and the four gates
# (docs/law_crime_stealth_plan.md). Exercises CrimeManager's preview/report
# contract end-to-end against the REAL LawDatabase/FactionDatabase data:
# verdicts, statute-keyed debounce, summon attribution, applies_to gating,
# the cast-again confirmation flow, and the ownership-laundering leak closures
# (add_stack merge, WeaponShape round-trip).
# The harness root stands in for Game: CrimeManager reads current_map_id off
# the current scene, so flipping the var here moves the jurisdiction.
# Run:  godot --headless --path . res://tests/crime_gate_test.tscn
# Judge by PASS/FAIL lines, not exit code alone (startup noise is normal).
extends Node2D

var failures := 0

# --- Game stub surface ---
var current_map_id: String = "town_square"   # real map, real region: liziti law
var characters_in_scene: Array = []
var party_chars: Array = []
var items_in_scene: Array = []
var stealth_mode: bool = false

var crimes: Array = []   # captured crime_committed emissions

class StubChar:
	extends Node2D
	var faction_id: String = "player"
	var Name: String = "Stub"
	var alive: bool = true
	func is_alive() -> bool:
		return alive

class StubAbility:
	extends RefCounted
	var id: String = ""
	var display_name: String = ""
	var traits: Dictionary = {}
	func _init(p_id: String, p_traits: Dictionary) -> void:
		id = p_id
		display_name = p_id
		traits = p_traits

func _check(check_name: String, cond: bool, detail: String = "") -> void:
	if cond:
		print("PASS %s" % check_name)
	else:
		failures += 1
		print("FAIL %s: %s" % [check_name, detail])

func _mk_char(faction: String, char_name: String) -> StubChar:
	var c := StubChar.new()
	c.faction_id = faction
	c.Name = char_name
	add_child(c)
	return c

func _ready() -> void:
	add_to_group("game")
	TimeManager.pause_time()
	CrimeManager.crime_committed.connect(_on_crime)
	_case_take_verdicts()
	_case_debounce()
	_case_attack()
	_case_summon_attribution()
	_case_cast_confirmation()
	_case_inventory_merge_leak()
	_case_weapon_round_trip()
	print("HARNESS DONE failures=%d" % failures)
	get_tree().quit(1 if failures > 0 else 0)

func _on_crime(actor: Node, verdict: Dictionary, _payload: Dictionary) -> void:
	crimes.append({"actor": actor, "verdict": verdict})

func _last_statute() -> String:
	if crimes.is_empty():
		return ""
	return str(crimes.back()["verdict"].get("statute", ""))

func _case_take_verdicts() -> void:
	var player := _mk_char("player", "Ana")
	var npc := _mk_char("liziti", "Thug")
	var owned := _mk_char("player", "target_owned")   # any Object works as debounce target
	crimes.clear()
	CrimeManager.report(player, "take", {"owner_faction": "liziti", "item_cost": 10.0, "debounce_target": owned})
	_check("take.owned-is-theft", crimes.size() == 1 and _last_statute() == "theft", str(crimes))
	CrimeManager.report(player, "take", {"owner_faction": "", "item_cost": 10.0})
	_check("take.unowned-clean", crimes.size() == 1)
	CrimeManager.report(npc, "take", {"owner_faction": "liziti", "item_cost": 10.0, "debounce_target": player})
	_check("take.npc-actor-outside-applies-to", crimes.size() == 1, "NPC theft must not report in v1")

func _case_debounce() -> void:
	var player := _mk_char("player", "Bel")
	var chest_a := _mk_char("player", "chest_a")
	var chest_b := _mk_char("player", "chest_b")
	crimes.clear()
	CrimeManager.report(player, "loot", {"owner_faction": "liziti", "debounce_target": chest_a})
	CrimeManager.report(player, "loot", {"owner_faction": "liziti", "debounce_target": chest_a})
	CrimeManager.report(player, "loot", {"owner_faction": "liziti", "debounce_target": chest_a})
	_check("debounce.same-target-once", crimes.size() == 1, "%d crimes" % crimes.size())
	CrimeManager.report(player, "loot", {"owner_faction": "liziti", "debounce_target": chest_b})
	_check("debounce.new-target-fires", crimes.size() == 2)

func _case_attack() -> void:
	var player := _mk_char("player", "Cass")
	var civilian := _mk_char("neutral", "Shopkeep")
	var bandit := _mk_char("bandits", "Cutpurse")
	# Assault cases need a jurisdiction that HAS assault: Perrow (liziti_custom)
	# repeals it — the harness's first draft tripped over the lore. Use a
	# synthetic common-law map for the ladder, then pin Perrow's repeal.
	MapDatabase._maps["__crime_commonlaw"] = {"id": "__crime_commonlaw", "controlling_faction": "alamoneans"}
	current_map_id = "__crime_commonlaw"
	crimes.clear()
	CrimeManager.report(player, "attack", CrimeManager.attack_payload(player, civilian))
	_check("attack.civilian-is-assault", crimes.size() == 1 and _last_statute() == "assault", str(crimes))
	# The killing blow lands inside the debounce window but is a DIFFERENT
	# statute — it must not be swallowed by the assault report.
	civilian.alive = false
	CrimeManager.report(player, "attack", CrimeManager.attack_payload(player, civilian))
	_check("attack.escalates-to-murder", crimes.size() == 2 and _last_statute() == "murder", str(crimes))
	CrimeManager.report(player, "attack", CrimeManager.attack_payload(player, bandit))
	_check("attack.bandit-self-defence-clean", crimes.size() == 2, "fighting hostiles is not assault")
	# Perrow: punching a shopkeep is legal (repealed), killing one is not.
	current_map_id = "town_square"
	var brawl_victim := _mk_char("neutral", "Patron")
	CrimeManager.report(player, "attack", CrimeManager.attack_payload(player, brawl_victim))
	_check("attack.perrow-assault-repealed", crimes.size() == 2, "duelling is a private matter")
	brawl_victim.alive = false
	CrimeManager.report(player, "attack", CrimeManager.attack_payload(player, brawl_victim))
	_check("attack.perrow-murder-still-lands", crimes.size() == 3 and _last_statute() == "murder", str(crimes))
	MapDatabase._maps.erase("__crime_commonlaw")

func _case_summon_attribution() -> void:
	var player := _mk_char("player", "Summoner")
	var rat := _mk_char("player", "Rat")
	rat.set_meta("summoned_by", player)
	var npc := _mk_char("liziti", "NpcSummoner")
	var npc_rat := _mk_char("liziti", "NpcRat")
	npc_rat.set_meta("summoned_by", npc)
	crimes.clear()
	CrimeManager.report(rat, "take", {"owner_faction": "liziti", "debounce_target": npc})
	_check("summon.crime-attributed-to-summoner",
		crimes.size() == 1 and crimes.back()["actor"] == player, str(crimes))
	CrimeManager.report(npc_rat, "take", {"owner_faction": "liziti", "debounce_target": rat})
	_check("summon.npc-summoner-outside-applies-to", crimes.size() == 1)

func _case_cast_confirmation() -> void:
	var player := _mk_char("player", "Mage")
	var necro := StubAbility.new("test_necro_cast", {"necrotic": 3, "Occult": 2})
	var charm := StubAbility.new("test_charm_cast", {"charm": 1})
	# Real liziti jurisdiction: necromancy is legal in Perrow — no prompt.
	current_map_id = "town_square"
	_check("confirm.legal-here-no-prompt", CrimeManager.cast_needs_confirmation(player, necro).is_empty())
	# Synthetic Waldau map via the per-map controlling_faction override.
	MapDatabase._maps["__crime_waldau"] = {"id": "__crime_waldau", "controlling_faction": "waldau"}
	current_map_id = "__crime_waldau"
	var first: Dictionary = CrimeManager.cast_needs_confirmation(player, necro)
	_check("confirm.first-severe-cast-refused",
		str(first.get("verdict", {}).get("statute", "")) == "necromancy", str(first))
	_check("confirm.recast-confirms", CrimeManager.cast_needs_confirmation(player, necro).is_empty())
	_check("confirm.map-flag-holds", CrimeManager.cast_needs_confirmation(player, necro).is_empty())
	# Below the severity threshold (mind_magic 40 < 50): never prompts, but
	# the completed cast still reports.
	_check("confirm.low-severity-no-prompt", CrimeManager.cast_needs_confirmation(player, charm).is_empty())
	crimes.clear()
	CrimeManager.report(player, "cast", CrimeManager.cast_payload(charm))
	_check("confirm.low-severity-still-a-crime",
		crimes.size() == 1 and _last_statute() == "mind_magic", str(crimes))
	MapDatabase._maps.erase("__crime_waldau")
	current_map_id = "town_square"

func _case_inventory_merge_leak() -> void:
	var inv := Inventory.new()
	add_child(inv)
	var clean: Dictionary = {"id": "gold", "is_stackable": true, "num_stacks": 5, "max_stack_size": 100}
	var stolen: Dictionary = {"id": "gold", "is_stackable": true, "num_stacks": 3, "max_stack_size": 100,
		"stolen_from": "liziti", "stolen_value": 3.0}
	inv.add_stack(clean)
	inv.add_stack(stolen)
	_check("leak.merge-preserves-stolen-from",
		inv.items.size() == 1 and str(inv.items[0].get("stolen_from", "")) == "liziti",
		str(inv.items))
	_check("leak.merge-kept-count", int(inv.items[0].get("num_stacks", 0)) == 8)
	inv.queue_free()

func _case_weapon_round_trip() -> void:
	var weapon := WeaponShape.new()
	weapon.stolen_from = "liziti"
	var data: Dictionary = weapon.to_data()
	var restored := WeaponShape.new()
	restored.load_from_data(data)
	_check("leak.weapon-serializes-stolen-from", restored.stolen_from == "liziti",
		str(data.get("stolen_from")))
	weapon.free()
	restored.free()
