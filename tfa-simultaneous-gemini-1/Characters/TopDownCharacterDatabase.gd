# TopDownCharacterDatabase.gd
# Autoload singleton - add to Project > AutoLoad as "TopDownCharacterDatabase"
#
# Depends on: RaceDatabase, BackgroundDatabase, FactionDatabase,
#             AbilityDatabase, ItemDatabase (item_database.gd)
# (all must be loaded as autoloads above this one)
#
# ItemDatabase is accessed via its .weapons and .equipment dicts directly,
# and via get_weapon_data(name) for full item lookup.
extends Node

var _templates: Dictionary = {}

func _ready() -> void:
	_load_database()

func _load_database() -> void:
	var file_path = "res://data/TopDownCharacters.json"
	if not FileAccess.file_exists(file_path):
		push_error("Character Database not found at: " + file_path)
		return

	var file = FileAccess.open(file_path, FileAccess.READ)
	var json_text = file.get_as_text()
	var json = JSON.new()
	var error = json.parse(json_text)
	print("====== Character Database =======")
	if error == OK:
		var data = json.get_data()
		for entry in data.get("characters", []):
			_templates[entry["id"]] = entry
		print("Loaded %d character templates" % _templates.size())
	else:
		push_error("Failed to parse Character JSON: " + json.get_error_message())
	print("====== End Character Database ======")

# ---------------------------------------------------------------------------
# Lookup
# ---------------------------------------------------------------------------

func get_template(template_id: String) -> Dictionary:
	if _templates.has(template_id):
		return _templates[template_id]
	push_error("Character template not found: " + template_id)
	return {}

func get_all_template_ids() -> Array:
	return _templates.keys()

# ---------------------------------------------------------------------------
# Spawn a fully resolved character from a template
# ---------------------------------------------------------------------------
# `character` is the character node to populate.
# `template_id` is the key into characters.json.
# `overrides` lets the caller force specific values:
#   "race"       : override the race_id
#   "background" : override the background_id
#   "gender"     : "male" / "female"
#   "options"    : passed through to RaceDatabase/BackgroundDatabase apply

func build_character(character, template_id: String, overrides: Dictionary = {}) -> void:
	var template = get_template(template_id)
	if template.is_empty():
		return

	var faction_id: String = overrides.get("faction", template.get("faction", "neutral"))
	var faction_data: Dictionary = FactionDatabase.get_faction_data(faction_id)

	# --- Set faction ---
	character.faction_id = faction_id
	character.display_name = template.get("name", "Unknown")

	# --- Resolve race ---
	var race_id: String = _resolve_race(template, faction_data, overrides)

	# --- Resolve background ---
	var bg_id: String = _resolve_background(template, faction_data, overrides)

	# --- Apply base stats (before race/background modifiers) ---
	var stats: Dictionary = template.get("stats", {})
	_apply_base_stats(character, stats)

	# --- Apply race (if not a pure creature) ---
	var race_options: Dictionary = overrides.get("options", {})
	if not overrides.get("gender", "").is_empty():
		race_options["gender"] = overrides["gender"]

	if not race_id.is_empty():
		RaceDatabase.apply_race_to_character(character, race_id, race_options)

	# --- Apply background ---
	if not bg_id.is_empty():
		var bg_options: Dictionary = overrides.get("bg_options", {})
		BackgroundDatabase.apply_background_to_character(character, bg_id, bg_options)

	# --- Resolve and grant equipment ---
	var equipment = _resolve_equipment(template, faction_data, overrides)
	_grant_equipment(character, equipment)

	# --- Appearance overrides (skeleton bones, wolf fur, etc.) ---
	# Applied LAST so they stomp race defaults when needed
	var appearance: Dictionary = template.get("appearance_override", {})
	_apply_appearance_overrides(character, appearance)

	# --- Dialogue and interaction ---
	var dialogue_id = template.get("dialogue", "")
	if dialogue_id and dialogue_id is String and not dialogue_id.is_empty():
		_set_if_exists(character, "dialogues", [dialogue_id])
	var interact_opts = template.get("interact_options", [])
	if not interact_opts.is_empty():
		_set_if_exists(character, "interact_options", interact_opts)

	# --- Extra inventory items (non-equipment) ---
	var extra_items = template.get("extra_items", [])
	if not extra_items.is_empty():
		var inv = _find_child_by_name(character, "Inventory")
		if inv:
			for item_id in extra_items:
				var item_data = ItemDatabase.get_item_data(item_id)
				if not item_data.is_empty():
					inv.add_item(item_data)
				else:
					push_warning("extra_items: item '%s' not found in ItemDatabase" % str(item_id))

	# --- Creature flag ---
	if template.get("is_creature", false):
		_set_if_exists(character, "is_creature", true)

# ---------------------------------------------------------------------------
# Race resolution
# ---------------------------------------------------------------------------

func _resolve_race(template: Dictionary, faction_data: Dictionary, overrides: Dictionary) -> String:
	# Explicit override from caller
	if overrides.has("race") and overrides["race"] != "from_faction":
		return overrides["race"]

	# Template specifies a concrete race
	var template_race = template.get("race", "")
	if template_race is String and template_race != "from_faction" and not template_race.is_empty():
		return template_race

	# Roll from faction race_weights
	return _weighted_pick(faction_data.get("race_weights", {}))

func _weighted_pick(weights: Dictionary) -> String:
	if weights.is_empty():
		return ""
	var total: float = 0.0
	for w in weights.values():
		total += float(w)
	if total <= 0:
		return ""

	var roll: float = randf() * total
	var cumulative: float = 0.0
	for key in weights:
		cumulative += float(weights[key])
		if roll <= cumulative:
			return key
	# Fallback to last key
	return weights.keys().back()

# ---------------------------------------------------------------------------
# Background resolution
# ---------------------------------------------------------------------------

func _resolve_background(template: Dictionary, faction_data: Dictionary, overrides: Dictionary) -> String:
	if overrides.has("background") and overrides["background"] != "from_faction":
		return overrides["background"]

	var template_bg = template.get("background", "")
	if template_bg is String and template_bg != "from_faction" and not template_bg.is_empty():
		return template_bg

	# Pick random from faction defaults
	var defaults: Array = faction_data.get("default_backgrounds", [])
	if defaults.is_empty():
		return ""
	return defaults[randi() % defaults.size()]

# ---------------------------------------------------------------------------
# Equipment resolution
# ---------------------------------------------------------------------------
# Maps the equip_slot strings from Items.json to loadout categories.
# Items use "Main Hand", "Off Hand", "Head", "Torso", etc.
const SLOT_TO_CATEGORY: Dictionary = {
	"Main Hand": "main_hand",
	"Off Hand": "off_hand",
	"Head": "head",
	"Torso": "torso",
	"Back": "back",
	"Legs": "legs",
	"Feet": "feet",
}
# Which categories we try to fill when rolling a random loadout
const LOADOUT_SLOTS: Array = ["main_hand", "torso", "head"]

func _resolve_equipment(template: Dictionary, faction_data: Dictionary, overrides: Dictionary) -> Array:
	# Explicit equipment list on the template
	var equip = template.get("equipment", [])

	# "from_faction" - build a random loadout from ItemDatabase
	if equip is String and equip == "from_faction":
		return _roll_faction_loadout(faction_data)

	if equip is Array:
		# Normalize: support both simple ID strings and full dict entries.
		# e.g. ["longsword", "breastplate_2"] or [{"id": "longsword", "slot": "Main Hand"}]
		var normalized: Array = []
		for entry in equip:
			if entry is String:
				# Simple ID string — look up equip_slot from the item database
				var item_data = ItemDatabase.get_item_data(entry)
				normalized.append({
					"id": entry,
					"quantity": 1,
					"equip_slot": item_data.get("equip_slot", "") if not item_data.is_empty() else ""
				})
			elif entry is Dictionary:
				normalized.append(entry)
		return normalized

	return []

func _roll_faction_loadout(faction_data: Dictionary) -> Array:
	## Queries ItemDatabase for every weapon and equipment piece, filters by
	## the faction's required/forbidden trait rules, groups by slot category,
	## and picks one random item per loadout slot.
	var required: Dictionary = faction_data.get("equipment_traits", {}).get("required", {})
	var forbidden: Dictionary = faction_data.get("equipment_traits", {}).get("forbidden", {})
	var faction_tier: int = int(faction_data.get("tier", 0))

	# Build per-category pools of eligible items
	var slot_pools: Dictionary = {}  # category -> Array of item dicts

	# Scan weapons
	for weapon_name in ItemDatabase.weapons:
		var item: Dictionary = ItemDatabase.weapons[weapon_name]
		if not _item_passes_trait_filter(item, required, forbidden):
			continue
		if faction_tier > 0 and item.get("tier", 0) > faction_tier:
			continue
		var category = _get_slot_category(item)
		if category.is_empty():
			continue
		if not slot_pools.has(category):
			slot_pools[category] = []
		slot_pools[category].append(item)

	# Scan equipment (armor, etc.)
	for equip_name in ItemDatabase.equipment:
		var item: Dictionary = ItemDatabase.equipment[equip_name]
		if not _item_passes_trait_filter(item, required, forbidden):
			continue
		if faction_tier > 0 and item.get("tier", 0) > faction_tier:
			continue
		var category = _get_slot_category(item)
		if category.is_empty():
			continue
		if not slot_pools.has(category):
			slot_pools[category] = []
		slot_pools[category].append(item)

	# Pick one item per loadout slot
	var loadout: Array = []
	for category in LOADOUT_SLOTS:
		var pool: Array = slot_pools.get(category, [])
		if pool.is_empty():
			continue
		var picked: Dictionary = pool[randi() % pool.size()]
		loadout.append({
			"id": picked.get("id", picked.get("name", "")),
			"name": picked.get("name", ""),
			"equip_slot": picked.get("equip_slot", ""),
			"quantity": 1
		})

	# 60% chance to also roll an off-hand item if the pool exists
	var off_pool: Array = slot_pools.get("off_hand", [])
	if not off_pool.is_empty() and randf() > 0.4:
		var picked: Dictionary = off_pool[randi() % off_pool.size()]
		loadout.append({
			"id": picked.get("id", picked.get("name", "")),
			"name": picked.get("name", ""),
			"equip_slot": "Off Hand",
			"quantity": 1
		})

	return loadout

func _get_slot_category(item: Dictionary) -> String:
	## Maps an item's equip_slot to our internal category string.
	var equip_slot: String = item.get("equip_slot", "")
	return SLOT_TO_CATEGORY.get(equip_slot, "")

func _item_passes_trait_filter(item: Dictionary, required: Dictionary, forbidden: Dictionary) -> bool:
	## Checks if an item's traits satisfy faction equipment requirements.
	var item_traits: Dictionary = item.get("traits", {})

	# Must have all required traits at >= the required tier
	for req_trait in required:
		var req_tier: int = int(required[req_trait])
		var item_tier: int = int(item_traits.get(req_trait, 0))
		if item_tier < req_tier:
			return false

	# Must NOT have any forbidden traits at >= the forbidden tier
	for forb_trait in forbidden:
		var forb_tier: int = int(forbidden[forb_trait])
		var item_tier: int = int(item_traits.get(forb_trait, 0))
		if item_tier >= forb_tier:
			return false

	return true

# ---------------------------------------------------------------------------
# Apply base stats
# ---------------------------------------------------------------------------

func _apply_base_stats(character, stats: Dictionary) -> void:
	for stat_name in stats:
		_set_if_exists(character, stat_name, stats[stat_name])

# ---------------------------------------------------------------------------
# Grant equipment to inventory
# ---------------------------------------------------------------------------

func _grant_equipment(character, equipment: Array) -> void:
	if equipment.is_empty():
		return

	var inventory = _find_child_by_name(character, "Inventory")
	if not inventory:
		push_warning("No Inventory on %s - skipping equipment" % character.name)
		return

	for entry in equipment:
		var item_id: String = entry.get("id", "")
		var item_data: Dictionary = ItemDatabase.get_item_data(item_id)
		if item_data.is_empty():
			push_warning("Equipment item '%s' not found in ItemDatabase" % item_id)
			continue

		# Merge per-character overrides from the entry
		if entry.has("slot"):
			item_data["equip_slot"] = entry["slot"]
		item_data["source"] = "starting_equipment"
		var quantity: int = entry.get("quantity", item_data.get("quantity", 1))

		# Grant the item to inventory
		for i in range(quantity):
			var single = item_data.duplicate()
			single["quantity"] = 1
			inventory.add_item(single)

		# Auto-equip items that have an equip_slot defined
		var equip_slot: String = item_data.get("equip_slot", "")
		var item_name: String = item_data.get("name", item_id)
		if not equip_slot.is_empty() and not item_name.is_empty():
			if equip_slot == "Main Hand" or equip_slot == "Off Hand":
				var hand = "Main" if equip_slot == "Main Hand" else "Off"
				if inventory.has_method("equip_weapon_from_data"):
					inventory.equip_weapon_from_data(item_data, hand)
				elif inventory.has_method("equip_ability_from_id"):
					inventory.equip_ability_from_id(item_name, hand)

		print("[CharDB] Granted %s x%d to %s" % [item_name, quantity, character.name])

# ---------------------------------------------------------------------------
# Appearance overrides (applied after race to stomp specific values)
# ---------------------------------------------------------------------------

func _apply_appearance_overrides(character, overrides: Dictionary) -> void:
	if overrides.is_empty():
		return
	if overrides.has("skin_color"):
		character.skin_color = Color(overrides["skin_color"])
		character.body_color = character.skin_color.darkened(0.15)
	if overrides.has("hair_color"):
		character.hair_color = Color(overrides["hair_color"])
	_set_if_exists(character, "body_width", overrides.get("body_width"))
	_set_if_exists(character, "body_height", overrides.get("body_height"))
	_set_if_exists(character, "head_width", overrides.get("head_width"))
	_set_if_exists(character, "head_length", overrides.get("head_length"))

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _set_if_exists(character, property: String, value) -> void:
	if value == null:
		return
	if property in character:
		character.set(property, value)

func _find_child_by_name(node: Node, child_name: String) -> Node:
	for child in node.get_children():
		if child.name == child_name:
			return child
	return null
