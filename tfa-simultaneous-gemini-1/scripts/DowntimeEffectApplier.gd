## DowntimeEffectApplier
## Maps a downtime result's `effects` dict to the game's existing systems
## (ConditionManager, Inventory, ProceduralCharacter favorability). Static-style
## helper — call DowntimeEffectApplier.apply(...).
##
## Supported keys (any subset may appear on a single result):
##   hp                 : int. Positive heals (apply "healing_pulse"); negative damages (apply "bleed").
##   money              : int or "all". Positive adds gold (× max(success_tier, 1)); negative removes.
##   favorability       : int. Delta applied via apply_favorability_delta.
##   remove_mental_affliction   : int (truthy). Removes conditions tagged with the "mental" trait.
##   remove_physical_affliction : int (truthy). Removes conditions tagged with "physical".
##   add_condition      : String (condition id) OR Dict {"id": ..., "stacks": ...}.
##   remove_condition   : String (condition id).
##   grant_ability      : String (ability id).
##   learn_spell        : String. "random_spell" picks a not-yet-known spell-tagged ability.
##   add_trait          : Dict {trait_name: tier} OR String (defaults tier 1).
##   remove_trait       : String.
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
			"repair":
				_apply_repair(character, int(value))
			"money":
				_apply_money(character, value, success_tier)
			"favorability":
				if character.has_method("apply_favorability_delta"):
					character.apply_favorability_delta(int(value), "downtime")
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
			_:
				push_warning("DowntimeEffectApplier: unknown effect key '%s'" % String(key))

# ---------------------------------------------------------------------------
# Per-key handlers
# ---------------------------------------------------------------------------

static func _apply_hp(character, amount: int) -> void:
	if amount == 0:
		return
	# Healing distributes across the most-damaged limbs first (so a +8 heal on
	# a battered party member spreads rather than topping off a single limb).
	# Damage hits the torso — downtime mishaps are minor and shouldn't sever.
	if not ("limbs" in character) or character.limbs == null or character.limbs.is_empty():
		return
	if amount > 0:
		# Route positive HP through the character-level heal() so the
		# heal_resist stat (e.g. dwarven Stone Body) gates downtime healing
		# the same as ability healing.
		if character.has_method("heal"):
			character.heal(amount)
		else:
			var limbs: Array = character.limbs.values()
			limbs.sort_custom(func(a, b): return float(a.current_hp) / float(max(1, a.max_hp)) < float(b.current_hp) / float(max(1, b.max_hp)))
			var remaining := amount
			for limb in limbs:
				if remaining <= 0:
					break
				var deficit: int = max(0, limb.max_hp - limb.current_hp)
				if deficit <= 0:
					continue
				var heal: int = min(deficit, remaining)
				limb.heal(heal)
				remaining -= heal
	else:
		var torso = character.limbs.values()[0]
		# LimbType.TORSO is enum index 1. Look it up explicitly so the order
		# of limbs.values() doesn't matter.
		for k in character.limbs.keys():
			if int(k) == 1:  # TORSO
				torso = character.limbs[k]
				break
		torso.current_hp = max(0, torso.current_hp - abs(amount))

static func _apply_repair(character, amount: int) -> void:
	if amount <= 0 or character == null:
		return
	if character.has_method("repair"):
		character.repair(amount)

static func _apply_money(character, value, success_tier: int) -> void:
	# `Inventory` has a class_name, so typing the local lets the parser see
	# add_stack / find_item_by_id and stops "cannot infer type" on the
	# return-value assignments below.
	var inv: Inventory = character.get_node_or_null("Inventory")
	if inv == null:
		return
	# "all" means lost everything.
	if typeof(value) == TYPE_STRING and String(value).to_lower() == "all":
		var idx_all: int = inv.find_item_by_id(GOLD_ID)
		if idx_all >= 0:
			inv.items[idx_all]["num_stacks"] = 0
		return
	var amount: int = int(value)
	if amount == 0:
		return
	if amount > 0:
		var scaled: int = amount * max(success_tier, 1)
		inv.add_stack({"id": GOLD_ID, "is_stackable": true, "num_stacks": scaled, "name": "Gold", "max_stack_size": 9999})
	else:
		var idx: int = inv.find_item_by_id(GOLD_ID)
		if idx < 0:
			return
		var current: int = int(inv.items[idx].get("num_stacks", 0))
		inv.items[idx]["num_stacks"] = max(0, current - abs(amount))

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
