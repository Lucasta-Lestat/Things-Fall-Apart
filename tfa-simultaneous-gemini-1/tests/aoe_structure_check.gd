extends Node2D
# AoE-vs-structure regression check: an Ice-Storm-style damage resolve whose
# target list contains a bare wall collider (StaticBody2D, no script) must not
# crash on the traits lookup, and traitless entities must read as {}.
# Headless-safe.  Run:  godot --headless --path . res://tests/aoe_structure_check.tscn
var fails := 0
var checks := 0


func _check(name: String, ok: bool) -> void:
	checks += 1
	if not ok:
		fails += 1
		print("FAIL ", name)


func _ready() -> void:
	# 1. Traits helper: bare bodies and nodes read as traitless, not a crash.
	var wall := StaticBody2D.new()
	add_child(wall)
	_check("traits.static-body-empty", AbilityEffect._get_entity_traits(wall) == {})
	var plain := Node2D.new()
	add_child(plain)
	_check("traits.plain-node-empty", AbilityEffect._get_entity_traits(plain) == {})

	# 2. Full damage resolve with a wall in the target list (the Ice Storm
	# overlap case). The caster is a bare node too — the guard covers both ends.
	var ability := Ability.new()
	ability.traits = {}
	var effect := {"damage": {"cold": 12}}
	var result: Dictionary = AbilityEffect._resolve_damage(effect, plain, [wall], ability)
	_check("resolve.success", result.get("success", false) == true)
	_check("resolve.no-hp-invented", result.get("total_damage", -1.0) >= 0.0)

	# 3. target_traits filter must silently exclude the traitless wall instead
	# of crashing (required-traits path reads target traits before dealing).
	var filtered: Dictionary = AbilityEffect._resolve_damage(
		{"damage": {"cold": 12}, "target_traits": ["living"]}, plain, [wall], ability)
	_check("resolve.trait-filter-excludes-wall", filtered.get("targets_affected", [null]).is_empty())

	print("aoe_structure_check: %d checks, %d FAIL" % [checks, fails])
	get_tree().quit(1 if fails > 0 else 0)
