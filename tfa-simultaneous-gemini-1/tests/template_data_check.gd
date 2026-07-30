extends Node2D
# Template data audit: every explicit equipment item id and extra_ability id
# in TopDownCharacters.json must resolve in its database. Three characters
# shipped silently bare-handed from lookup misses (greataxe vs great_axe,
# war_axe vs battle_axe, lowercase slot names) — this makes the next one loud.
# Run:  godot --headless --path . res://tests/template_data_check.tscn


func _ready() -> void:
	var fails := 0
	var checks := 0
	var f := FileAccess.open("res://data/TopDownCharacters.json", FileAccess.READ)
	var raw: Dictionary = JSON.parse_string(f.get_as_text())
	f.close()
	for c in raw.get("characters", []):
		var cid := String(c.get("id", "?"))
		var eq = c.get("equipment", [])
		if eq is Array:
			for entry in eq:
				var iid := String(entry) if entry is String else String((entry as Dictionary).get("id", ""))
				if iid == "":
					continue
				checks += 1
				if ItemDatabase.get_item_data(iid).is_empty():
					fails += 1
					print("FAIL %s: equipment item '%s' not in ItemDatabase" % [cid, iid])
		for aid in c.get("extra_abilities", []):
			checks += 1
			if AbilityDatabase.get_ability_data(String(aid)).is_empty():
				fails += 1
				print("FAIL %s: ability '%s' not in AbilityDatabase" % [cid, String(aid)])
	print("template_data_check: %d checks, %d FAIL" % [checks, fails])
	get_tree().quit(1 if fails > 0 else 0)
