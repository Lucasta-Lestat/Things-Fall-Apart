## DowntimeEffectApplier
## Maps a downtime result's `effects` dict to the game's existing systems
## (ConditionManager, Inventory, ProceduralCharacter favorability). Static-style
## helper — call DowntimeEffectApplier.apply(...).
##
## Supported keys (any subset may appear on a single result):
##   hp                 : int. Positive heals (apply "healing_pulse"); negative damages (apply "bleed").
##   money              : int or "all". Positive adds gold (× max(success_tier, 1)); negative removes.
##   favorability       : int. Delta applied via apply_favorability_delta.
##   stress             : int. Added to the stress meter (negative relieves it).
##   remove_mental_affliction   : int (truthy). Removes conditions tagged with the "mental" trait.
##   remove_physical_affliction : int (truthy). Removes conditions tagged with "physical".
##   add_condition      : String (condition id) OR Dict {"id": ..., "stacks": ...}.
##   remove_condition   : String (condition id).
##   grant_ability      : String (ability id).
##   learn_spell        : String. "random_spell" picks a not-yet-known spell-tagged ability.
##   add_trait          : Dict {trait_name: tier} OR String (defaults tier 1).
##   remove_trait       : String.
##   soul_exchange      : Dict {"patron": "<id>", "count": int}. Offers up to
##                        `count` of the character's captured souls (those whose
##                        patron preference score is positive); each consumed
##                        soul applies the patron's rewards once.
##   holy_tier_next_day : int. Queues a Holy tier bonus that VowManager applies
##                        on the next date_changed rollover.
##   vow_set            : Dict {"vow_id": String, "active": bool}. Toggles a vow.
##   ration_delta       : int. Adjusts the character's ration stack (used by the
##                        burn-ration camp action).
##
## Money is the only effect that scales with success_tier (per design comment in
## the original downtime.json draft).
class_name DowntimeEffectApplier
extends RefCounted

const GOLD_ID := "gold"

static func apply(character, effects: Dictionary, success_tier: int = 1) -> void:
	if character == null or not is_instance_valid(character):
		return
	if effects == null or effects.is_empty():
		return

	for key in effects.keys():
		var value = effects[key]
		match String(key):
			"hp":
				_apply_hp(character, int(value))
			"money":
				_apply_money(character, value, success_tier)
			"favorability":
				if character.has_method("apply_favorability_delta"):
					character.apply_favorability_delta(int(value), "downtime")
			"stress":
				if character.has_method("gain_stress"):
					character.gain_stress(int(value))
			"remove_mental_affliction":
				_remove_with_trait(character, "mental")
			"remove_physical_affliction":
				_remove_with_trait(character, "physical")
			"add_condition":
				_apply_add_condition(character, value)
			"remove_condition":
				_apply_remove_condition(character, String(value))
			"grant_ability":
				_apply_grant_ability(character, String(value))
			"learn_spell":
				_apply_learn_spell(character, String(value))
			"add_trait":
				_apply_add_trait(character, value)
			"remove_trait":
				_apply_remove_trait(character, String(value))
			"soul_exchange":
				_apply_soul_exchange(character, value, success_tier)
			"holy_tier_next_day":
				_apply_holy_tier_next_day(character, int(value))
			"vow_set":
				_apply_vow_set(character, value)
			"ration_delta":
				_apply_ration_delta(character, int(value))
			_:
				push_warning("DowntimeEffectApplier: unknown effect key '%s'" % String(key))

# ---------------------------------------------------------------------------
# Per-key handlers
# ---------------------------------------------------------------------------

static func _apply_hp(character, amount: int) -> void:
	# Single-bar HP: downtime heals/damage just push current_health up or down.
	# `take_damage` would apply DR — downtime mishaps are abstract, not weapon
	# hits, so we bypass it and subtract directly. Still routes through the
	# health_changed signal so UI updates.
	if amount == 0:
		return
	if not ("current_health" in character) or not ("max_health" in character):
		return
	if amount > 0:
		if character.has_method("heal"):
			character.heal(amount)
		else:
			character.current_health = min(character.current_health + amount, character.max_health)
			character.health_changed.emit(character.current_health, character.max_health, character)
	else:
		character.current_health = max(0, character.current_health - abs(amount))
		character.health_changed.emit(character.current_health, character.max_health, character)
		if character.has_method("_check_death"):
			character._check_death()

static func _apply_money(character, value, success_tier: int) -> void:
	# `Inventory` has a class_name, so typing the local lets the parser see
	# add_stack / find_item_by_id and stops "cannot infer type" on the
	# return-value assignments below.
	var inv: Inventory = character.get_node_or_null("Inventory")
	if inv == null:
		return
	# "all" means lost everything — zero out every currency the character holds.
	if typeof(value) == TYPE_STRING and String(value).to_lower() == "all":
		for cid in _ordered_currency_ids():
			var idx_all: int = inv.find_item_by_id(cid)
			if idx_all >= 0:
				inv.items[idx_all]["num_stacks"] = 0
		return
	var amount: int = int(value)
	if amount == 0:
		return
	if amount > 0:
		var scaled: int = amount * max(success_tier, 1)
		# Pay out in a random Currency-trait item (gold, cigarette, ...).
		var cur_data: Dictionary = ItemDatabase.random_currency_data(GOLD_ID)
		if cur_data.is_empty():
			return
		var entry: Dictionary = cur_data.duplicate(true)
		entry["num_stacks"] = scaled
		entry["is_stackable"] = true
		inv.add_stack(entry)
	else:
		# Deduct across the character's currency holdings (gold first).
		var remaining: int = abs(amount)
		for cid in _ordered_currency_ids():
			if remaining <= 0:
				break
			var idx: int = inv.find_item_by_id(cid)
			if idx < 0:
				continue
			var current: int = int(inv.items[idx].get("num_stacks", 0))
			var take: int = min(current, remaining)
			inv.items[idx]["num_stacks"] = current - take
			remaining -= take

static func _ordered_currency_ids() -> Array:
	# Currency ids with GOLD_ID first (so removal/"all" prefers gold), then the
	# rest in a stable order.
	var ids: Array = ItemDatabase.currency_item_ids()
	ids.sort()
	if GOLD_ID in ids:
		ids.erase(GOLD_ID)
		ids.push_front(GOLD_ID)
	return ids

static func _remove_with_trait(character, trait_tag: String) -> int:
	var cm = character.get_node_or_null("ConditionManager")
	if cm == null:
		return 0
	if not cm.has_method("remove_conditions_with_trait"):
		return 0
	return int(cm.remove_conditions_with_trait(trait_tag))

static func _apply_add_condition(character, value) -> void:
	var cm = character.get_node_or_null("ConditionManager")
	if cm == null:
		return
	var cid := ""
	var stacks := 1
	if typeof(value) == TYPE_DICTIONARY:
		cid = String(value.get("id", ""))
		stacks = int(value.get("stacks", 1))
	else:
		cid = String(value)
	if cid.is_empty():
		return
	cm.apply_condition(cid, character, stacks, -1, null)

static func _apply_remove_condition(character, cid: String) -> void:
	var cm = character.get_node_or_null("ConditionManager")
	if cm == null or cid.is_empty():
		return
	cm.remove_condition(cid)

static func _apply_grant_ability(character, ability_id: String) -> void:
	if ability_id.is_empty():
		return
	var inv = character.get_node_or_null("Inventory")
	if inv == null or not inv.has_method("add_ability_by_id"):
		return
	inv.add_ability_by_id(ability_id)

static func _apply_learn_spell(character, spell_id: String) -> void:
	if spell_id == "random_spell":
		spell_id = _pick_random_unknown_spell(character)
		if spell_id.is_empty():
			return
	_apply_grant_ability(character, spell_id)

static func _pick_random_unknown_spell(character) -> String:
	# AbilityDatabase exposes get_all_abilities() (see AbilityUpgradeScreen.gd).
	# A "spell" is an ability whose traits include {"spell": >=1}.
	if not Engine.has_singleton("AbilityDatabase") and not (typeof(AbilityDatabase) == TYPE_OBJECT):
		return ""
	if not AbilityDatabase.has_method("get_all_abilities"):
		return ""
	var all: Array = AbilityDatabase.get_all_abilities()
	var known: Array = []
	var inv = character.get_node_or_null("Inventory")
	if inv != null:
		for it in inv.stowed_items:
			if it != null and "raw_data" in it:
				known.append(String(it.raw_data.get("id", "")))
	var candidates: Array = []
	for ab in all:
		if typeof(ab) != TYPE_DICTIONARY:
			continue
		var traits_dict: Dictionary = ab.get("traits", {})
		if int(traits_dict.get("spell", 0)) < 1:
			continue
		var aid := String(ab.get("id", ""))
		if aid.is_empty() or aid in known:
			continue
		candidates.append(aid)
	if candidates.is_empty():
		return ""
	return String(candidates[randi() % candidates.size()])

static func _apply_add_trait(character, value) -> void:
	if not ("traits" in character):
		return
	if typeof(value) == TYPE_DICTIONARY:
		for t in value.keys():
			character.traits[String(t)] = int(value[t])
	else:
		var name := String(value)
		if name.is_empty():
			return
		character.traits[name] = int(character.traits.get(name, 0)) + 1

static func _apply_remove_trait(character, trait_name: String) -> void:
	if trait_name.is_empty() or not ("traits" in character):
		return
	character.traits.erase(trait_name)

# ---------------------------------------------------------------------------
# Soul exchange (Occult patrons)
# ---------------------------------------------------------------------------

static func _apply_soul_exchange(character, value, success_tier: int) -> void:
	if typeof(value) != TYPE_DICTIONARY:
		return
	if not ("captured_souls" in character):
		return
	var patron_id := String(value.get("patron", ""))
	if patron_id.is_empty() and "patron_id" in character:
		patron_id = String(character.patron_id)
	if patron_id.is_empty():
		return
	var max_count := int(value.get("count", 1))
	if max_count <= 0:
		return
	var eligible: Array = PatronDatabase.eligible_souls(patron_id, character.captured_souls)
	if eligible.is_empty():
		return
	var consumed_count := 0
	for soul in eligible:
		if consumed_count >= max_count:
			break
		character.captured_souls.erase(soul)
		if "souls" in character and int(character.souls) > 0:
			character.souls = int(character.souls) - 1
		_apply_patron_rewards(character, patron_id, consumed_count + 1, success_tier)
		consumed_count += 1

static func _apply_patron_rewards(character, patron_id: String, souls_offered: int, success_tier: int) -> void:
	var patron := PatronDatabase.get_patron(patron_id)
	if patron.is_empty():
		return
	var rewards: Array = patron.get("rewards_per_soul", [])
	for reward in rewards:
		if typeof(reward) != TYPE_DICTIONARY:
			continue
		if souls_offered < int(reward.get("min_souls", 1)):
			continue
		var reward_type := String(reward.get("type", ""))
		match reward_type:
			"trait":
				var trait_name := String(reward.get("trait", ""))
				var amount := int(reward.get("amount", 1))
				if not trait_name.is_empty() and "traits" in character:
					character.traits[trait_name] = int(character.traits.get(trait_name, 0)) + amount
			"grant_ability":
				_apply_grant_ability(character, String(reward.get("ability_id", "")))
			"money":
				_apply_money(character, int(reward.get("amount", 0)), success_tier)
			"condition":
				_apply_add_condition(character, reward.get("condition", ""))

# ---------------------------------------------------------------------------
# Holy Vows
# ---------------------------------------------------------------------------

static func _apply_holy_tier_next_day(character, amount: int) -> void:
	if amount == 0 or not ("holy_tier_next_day_pending" in character):
		return
	character.holy_tier_next_day_pending = int(character.holy_tier_next_day_pending) + amount

static func _apply_vow_set(character, value) -> void:
	if typeof(value) != TYPE_DICTIONARY:
		return
	if not ("active_vows" in character):
		return
	var vow_id := String(value.get("vow_id", ""))
	if vow_id.is_empty():
		return
	var active := bool(value.get("active", true))
	if active:
		character.active_vows[vow_id] = {"days_maintained": 0, "broken": false}
	else:
		character.active_vows.erase(vow_id)

static func _apply_ration_delta(character, amount: int) -> void:
	if amount == 0:
		return
	var inv: Inventory = character.get_node_or_null("Inventory")
	if inv == null:
		return
	var idx: int = inv.find_item_by_id("ration")
	if idx < 0:
		# Try the plural / alternate id used by some content
		idx = inv.find_item_by_id("rations")
	if idx < 0:
		return
	var current: int = int(inv.items[idx].get("num_stacks", 1))
	inv.items[idx]["num_stacks"] = max(0, current + amount)
	inv.emit_signal("item_removed", inv.items[idx])
