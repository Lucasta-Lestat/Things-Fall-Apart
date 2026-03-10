# BackgroundDatabase.gd
# Autoload singleton - add to Project > AutoLoad as "BackgroundDatabase"
extends Node

var _backgrounds: Dictionary = {}

func _ready() -> void:
	_load_database()

func _load_database() -> void:
	var file_path = "res://data/backgrounds.json"
	if not FileAccess.file_exists(file_path):
		push_error("Background Database not found at: " + file_path)
		return

	var file = FileAccess.open(file_path, FileAccess.READ)
	var content = file.get_as_text()
	var json = JSON.new()
	var error = json.parse(content)
	print("====== Background Database =======")
	if error == OK:
		var data = json.get_data()
		for entry in data.get("backgrounds", []):
			_backgrounds[entry["id"]] = entry
		print("Loaded %d backgrounds" % _backgrounds.size())
	else:
		push_error("Failed to parse Background JSON: " + json.get_error_message())
	print("====== End Background Database ======")

# ---------------------------------------------------------------------------
# Lookup helpers
# ---------------------------------------------------------------------------

func get_background_data(bg_id: String) -> Dictionary:
	if _backgrounds.has(bg_id):
		return _backgrounds[bg_id]
	push_error("Background ID not found: " + bg_id)
	return {}

func get_all_background_ids() -> Array:
	return _backgrounds.keys()

# ---------------------------------------------------------------------------
# Apply background to a character node
# ---------------------------------------------------------------------------
# Expects `character` with:
#   - traits: Dictionary
#   - Child "Inventory" with add_item(item_data) and add_ability_by_id(id)
#   - Child "ConditionManager" with apply_condition(id, source, stacks, dur)
#
# `options` dict for player choices:
#   - "chosen_abilities" : Dictionary mapping choose_from category -> ability_id
#                          e.g. {"Clauses": "dark_pact", "Occult Spells": "hex"}
#   - "chosen_traits"    : Array of trait names for "_choice" style entries

func apply_background_to_character(character, bg_id: String, options: Dictionary = {}) -> void:
	var bg = get_background_data(bg_id)
	if bg.is_empty():
		push_error("Cannot apply unknown background: " + bg_id)
		return

	_set_if_exists(character, "background_id", bg_id)

	# --- Fixed traits ---
	var bg_traits: Dictionary = bg.get("traits", {})
	if not character.get("traits") is Dictionary:
		character.traits = {}
	for trait_name in bg_traits:
		character.traits[trait_name] = bg_traits[trait_name]

	# --- Generated traits (random_from) ---
	var trait_gen: Array = bg.get("trait_generation", [])
	for entry in trait_gen:
		var category: String = entry.get("random_from", "")
		var count: int = entry.get("count", 1)
		var tier: int = entry.get("tier", 1)
		var picked = _pick_random_from_category(category, count)
		for trait_name in picked:
			character.traits[trait_name] = tier

	# --- Conditions ---
	_apply_background_conditions(character, bg.get("conditions", []))

	# --- Abilities (added to inventory, not equipped) ---
	_grant_background_abilities(character, bg.get("abilities", []), options)

	# --- Items ---
	_grant_background_items(character, bg.get("items", []))

# ---------------------------------------------------------------------------
# Conditions
# ---------------------------------------------------------------------------

func _apply_background_conditions(character, condition_entries: Array) -> void:
	if condition_entries.is_empty():
		return

	var cond_mgr = _find_child_by_name(character, "ConditionManager")
	if not cond_mgr:
		if character.has_method("apply_condition"):
			cond_mgr = character
		else:
			push_warning("No ConditionManager on %s - skipping background conditions" % character.name)
			return

	for entry in condition_entries:
		if entry.has("id"):
			# Direct condition
			var instance = cond_mgr.apply_condition(entry["id"], null, 1, -1.0)
			if instance:
				print("[BackgroundDB] Applied condition '%s' on %s" % [entry["id"], character.name])
			else:
				push_warning("[BackgroundDB] Condition '%s' not registered or %s is immune" % [entry["id"], character.name])

		elif entry.has("random_from"):
			# Random pick from a condition category (e.g. Mutations)
			var category: String = entry["random_from"]
			var count: int = entry.get("count", 1)
			var picked = _pick_random_from_category(category, count)
			for cond_id in picked:
				var instance = cond_mgr.apply_condition(cond_id, null, 1, -1.0)
				if instance:
					print("[BackgroundDB] Applied random condition '%s' from '%s' on %s" % [cond_id, category, character.name])

# ---------------------------------------------------------------------------
# Abilities - granted to inventory
# ---------------------------------------------------------------------------

func _grant_background_abilities(character, ability_entries: Array, options: Dictionary) -> void:
	if ability_entries.is_empty():
		return

	var inventory = _find_child_by_name(character, "Inventory")
	if not inventory:
		push_warning("No Inventory on %s - skipping background abilities" % character.name)
		return

	var chosen_abilities: Dictionary = options.get("chosen_abilities", {})

	for entry in ability_entries:
		if entry.has("id"):
			# Direct ability
			var success = inventory.add_ability_by_id(entry["id"])
			if success:
				print("[BackgroundDB] Granted ability '%s' to %s" % [entry["id"], character.name])
			else:
				push_warning("[BackgroundDB] Failed to grant ability '%s' to %s" % [entry["id"], character.name])

		elif entry.has("choose_from"):
			# Player chooses from a trait-filtered category
			var category: String = entry["choose_from"]
			if chosen_abilities.has(category):
				# Player already made their pick
				var ability_id: String = chosen_abilities[category]
				var success = inventory.add_ability_by_id(ability_id)
				if success:
					print("[BackgroundDB] Granted chosen ability '%s' from '%s' to %s" % [ability_id, category, character.name])
			else:
				# Store pending choice for UI to resolve
				_add_pending_choice(character, "ability", category, entry.get("count", 1))

		elif entry.has("random_from"):
			# Random pick from a trait-filtered ability category
			var category: String = entry["random_from"]
			var count: int = entry.get("count", 1)
			var picked = _pick_random_abilities_from_category(category, count)
			for ability_id in picked:
				var success = inventory.add_ability_by_id(ability_id)
				if success:
					print("[BackgroundDB] Granted random ability '%s' from '%s' to %s" % [ability_id, category, character.name])

# ---------------------------------------------------------------------------
# Items - granted to inventory
# ---------------------------------------------------------------------------

func _grant_background_items(character, item_entries: Array) -> void:
	if item_entries.is_empty():
		return

	var inventory = _find_child_by_name(character, "Inventory")
	if not inventory:
		push_warning("No Inventory on %s - skipping background items" % character.name)
		return

	for entry in item_entries:
		var item_data: Dictionary = entry.duplicate()
		item_data["source"] = "background"
		# Add quantity items (e.g. Gold:3 adds 3 gold entries, or your
		# inventory can handle stacking via the quantity field)
		var success = inventory.add_item(item_data)
		if success:
			print("[BackgroundDB] Granted item '%s' x%d to %s" % [entry.get("name", entry["id"]), entry.get("quantity", 1), character.name])
		else:
			push_warning("[BackgroundDB] Failed to grant item '%s' to %s" % [entry.get("name", entry["id"]), character.name])

# ---------------------------------------------------------------------------
# Category resolution - filters databases by trait tags
# ---------------------------------------------------------------------------

func _pick_random_from_category(category: String, count: int) -> Array:
	## Picks `count` random entries from a category by filtering the
	## AbilityDatabase (or ConditionManager registry) for entries whose
	## traits or tags match the category string.
	## Override or extend this to search additional databases.
	var pool: Array = _get_pool_for_category(category)
	if pool.is_empty():
		push_warning("[BackgroundDB] No entries found for category '%s'" % category)
		return []
	pool.shuffle()
	return pool.slice(0, mini(count, pool.size()))

func _pick_random_abilities_from_category(category: String, count: int) -> Array:
	## Same as above but specifically for the ability database.
	var pool: Array = _get_ability_pool_for_category(category)
	if pool.is_empty():
		push_warning("[BackgroundDB] No abilities found for category '%s'" % category)
		return []
	pool.shuffle()
	return pool.slice(0, mini(count, pool.size()))

func _get_pool_for_category(category: String) -> Array:
	## Returns an array of ids from any database matching the category trait.
	## Searches abilities first, then conditions.
	var results = _get_ability_pool_for_category(category)
	if results.is_empty():
		# Fall back to condition registry
		results = _get_condition_pool_for_category(category)
	return results

func _get_ability_pool_for_category(category: String) -> Array:
	## Filters AbilityDatabase2 for abilities tagged with the category.
	## Matches against the ability's "tags", "traits", or "category" fields.
	var pool: Array = []
	var cat_lower = category.to_lower()
	for ability_id in AbilityDatabase2.get_all_ability_ids():
		var data = AbilityDatabase2.get_ability_data(ability_id)
		if _entry_matches_category(data, cat_lower):
			pool.append(ability_id)
	return pool

func _get_condition_pool_for_category(category: String) -> Array:
	## Filters the ConditionManager registry for conditions matching category.
	var pool: Array = []
	var cat_lower = category.to_lower()

	# Directly access the static dictionary on the class
	for cond_id in ConditionManager.condition_registry:
		var template = ConditionManager.condition_registry[cond_id]
		if template and _entry_matches_category(template, cat_lower):
			pool.append(cond_id)        
	return pool

func _entry_matches_category(data: Dictionary, cat_lower: String) -> bool:
	## Checks if a database entry matches a category by examining its
	## traits dict, tags array, or category string field.

	# Check traits dictionary (the same format as faction/race equipment traits)
	var traits: Dictionary = data.get("traits", {})
	for trait_key in traits:
		if trait_key.to_lower() == cat_lower:
			return true

	# Check tags array
	var tags: Array = data.get("tags", [])
	for tag in tags:
		if str(tag).to_lower() == cat_lower:
			return true

	# Check category string
	var cat_field = str(data.get("category", "")).to_lower()
	if cat_field == cat_lower:
		return true

	# Check type field (for "Feats", "Clauses", etc.)
	var type_field = str(data.get("type", "")).to_lower()
	if type_field == cat_lower:
		return true

	return false

# ---------------------------------------------------------------------------
# Pending choices (for UI to resolve)
# ---------------------------------------------------------------------------

func _add_pending_choice(character, choice_type: String, category: String, count: int) -> void:
	## Stores a pending choice on the character for the UI to present later.
	## The character creation screen can read pending_choices and show a picker.
	if not "pending_choices" in character:
		return
	if not character.pending_choices is Array:
		character.pending_choices = []
	character.pending_choices.append({
		"type": choice_type,
		"category": category,
		"count": count,
	})
	print("[BackgroundDB] Added pending %s choice from '%s' (pick %d) for %s" % [choice_type, category, count, character.name])

# ---------------------------------------------------------------------------
# Utility to get valid abilities for a choose_from category (for UI)
# ---------------------------------------------------------------------------

func get_chooseable_abilities(category: String) -> Array:
	## Returns array of {id, display_name, ...} dicts the player can pick from.
	## Call this from your character creation UI when presenting choose_from options.
	var pool = _get_ability_pool_for_category(category)
	var results: Array = []
	for ability_id in pool:
		var data = AbilityDatabase2.get_ability_data(ability_id)
		if not data.is_empty():
			results.append(data)
	return results

func get_chooseable_conditions(category: String) -> Array:
	## Same but for conditions (e.g. Mutations).
	var pool = _get_condition_pool_for_category(category)
	var results: Array = []
	
	for cond_id in pool:
		# Directly grab the template from the static registry
		var template = ConditionManager.condition_registry.get(cond_id)
		if template:
			results.append(template)        
	return results

# ---------------------------------------------------------------------------
# Internal helpers
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
