extends Node2D
# Race-configurable unarmed strikes: races.json "unarmed_strike" sets damage
# type / damage / on_hit_ability (claws instead of the default punch), and
# slashing claws inherit the bleed-on-hit damage-type side effect.
# Headless-safe.  Run:  godot --headless --path . res://tests/unarmed_strike_check.tscn
const CHAR_SCENE := preload("res://Characters/ProceduralCharacter.tscn")

var fails := 0
var checks := 0


func _check(name: String, ok: bool, detail: String = "") -> void:
	checks += 1
	if not ok:
		fails += 1
	print("%s %s %s" % ["PASS" if ok else "FAIL", name, detail])


func _spawn_race(rid: String, pos: Vector2) -> ProceduralCharacter:
	var c: ProceduralCharacter = CHAR_SCENE.instantiate()
	c.position = pos
	add_child(c)
	RaceDatabase.apply_race_to_character(c, rid, {"gender": "male"})
	return c


func _ready() -> void:
	add_to_group("game")
	GridManager.TILE_SIZE = 64
	GridManager.initialize(2048, 2048)
	await get_tree().process_frame

	# --- race wiring: claws for grimalkin/saurian, default punch for human ---
	var h := _spawn_race("human", Vector2(200, 200))
	_check("human.type", h.unarmed_strike_damage_type == "bludgeoning",
		h.unarmed_strike_damage_type)
	_check("human.no-proc", h.unarmed_on_hit_ability == "")

	var g := _spawn_race("grimalkin", Vector2(300, 200))
	_check("grimalkin.type", g.unarmed_strike_damage_type == "slashing",
		g.unarmed_strike_damage_type)
	_check("grimalkin.damage-default", g.unarmed_strike_damage == 5,
		str(g.unarmed_strike_damage))

	var s := _spawn_race("saurian", Vector2(400, 200))
	_check("saurian.type", s.unarmed_strike_damage_type == "slashing",
		s.unarmed_strike_damage_type)

	# --- claw hits bleed (slashing damage-type side effect), punches don't ---
	var d1 := _spawn_race("human", Vector2(500, 200))
	d1.take_damage({"slashing": 5}, d1.global_position, g)
	await get_tree().process_frame
	_check("claw.bleeds", d1.condition_manager.has_active_condition("bleeding"))

	var d2 := _spawn_race("human", Vector2(600, 200))
	d2.take_damage({"bludgeoning": 5}, d2.global_position, h)
	await get_tree().process_frame
	_check("punch.no-bleed", not d2.condition_manager.has_active_condition("bleeding"))

	print("unarmed_strike_check: %d checks, %d FAIL" % [checks, fails])
	get_tree().quit(1 if fails > 0 else 0)
