# VowManager.gd
# Autoload singleton — register in project.godot as "VowManager".
# Daily tick that updates Holy-Vow state on every party character.
# - Applies queued holy_tier_next_day_pending bonuses
# - Chastity: +1 vow_holy_bonus per day maintained, with a level-up chance
# - Poverty: +1 vow_poverty_points per day with no gold; broken & zeroed otherwise
# Tracks per-character per-day gold-pickup state via Inventory.item_added.
extends Node

const CHASTITY_LEVELUP_CHANCE := 0.05
const POVERTY_GOLD_ITEM_IDS := ["gold", "silver", "money"]

var _gold_touched_today: Dictionary = {}  # character_uid -> bool

func _ready() -> void:
	# Defer connection — TimeManager autoload may not be fully constructed yet
	# when VowManager's _ready fires depending on autoload order. call_deferred
	# is safe even if TimeManager is already up.
	call_deferred("_connect_signals")

func _connect_signals() -> void:
	if TimeManager and not TimeManager.date_changed.is_connected(_on_date_changed):
		TimeManager.date_changed.connect(_on_date_changed)

func _on_date_changed(_day: int, _month: int, _year: int) -> void:
	var game = get_tree().root.get_node_or_null("Game")
	if game == null:
		return
	var party: Array = game.get("party_chars") if "party_chars" in game else []
	for character in party:
		if not is_instance_valid(character):
			continue
		_process_daily_tick(character)
	_gold_touched_today.clear()

func _process_daily_tick(character) -> void:
	# Apply any queued bonus from meditation / devotion / flagellation / ration burn.
	if "holy_tier_next_day_pending" in character and int(character.holy_tier_next_day_pending) > 0:
		character.vow_holy_bonus = int(character.vow_holy_bonus) + int(character.holy_tier_next_day_pending)
		character.holy_tier_next_day_pending = 0

	if not ("active_vows" in character) or character.active_vows.is_empty():
		return

	var uid: String = _character_uid(character)
	var touched_gold: bool = _gold_touched_today.get(uid, false)

	for vow_id in character.active_vows.keys():
		var entry: Dictionary = character.active_vows[vow_id]
		match vow_id:
			"chastity":
				if entry.get("broken", false):
					continue
				entry["days_maintained"] = int(entry.get("days_maintained", 0)) + 1
				character.vow_holy_bonus = int(character.vow_holy_bonus) + 1
				if randf() < CHASTITY_LEVELUP_CHANCE and "traits" in character:
					character.traits["Holy"] = int(character.traits.get("Holy", 0)) + 1
			"poverty":
				if touched_gold:
					entry["broken"] = true
					if "vow_poverty_points" in character:
						character.vow_poverty_points = 0
				else:
					entry["broken"] = false
					entry["days_maintained"] = int(entry.get("days_maintained", 0)) + 1
					if "vow_poverty_points" in character:
						character.vow_poverty_points = int(character.vow_poverty_points) + 1

# Called by Inventory when a character receives any item. Inventory wires this
# up at character construction in Game.gd after Vow data is set up.
func register_inventory(character) -> void:
	if character == null or not is_instance_valid(character):
		return
	var inv = character.get_node_or_null("Inventory")
	if inv == null:
		return
	if not inv.item_added.is_connected(_on_item_added):
		inv.item_added.connect(_on_item_added.bind(character))

func _on_item_added(item_data: Dictionary, character) -> void:
	if character == null or not is_instance_valid(character):
		return
	if not ("active_vows" in character):
		return
	if not character.active_vows.has("poverty"):
		return
	var item_id := String(item_data.get("id", "")).to_lower()
	for gold_id in POVERTY_GOLD_ITEM_IDS:
		if item_id == gold_id or item_id.begins_with(gold_id):
			var uid := _character_uid(character)
			_gold_touched_today[uid] = true
			# Also zero the bonus immediately so the UI reflects the break.
			if "vow_poverty_points" in character:
				character.vow_poverty_points = 0
			var vow: Dictionary = character.active_vows.get("poverty", {})
			vow["broken"] = true
			character.active_vows["poverty"] = vow
			return

func _character_uid(character) -> String:
	var tid = String(character.get("template_id")) if "template_id" in character else ""
	if not tid.is_empty():
		return tid + "_" + str(character.get_instance_id())
	return str(character.get_instance_id())
