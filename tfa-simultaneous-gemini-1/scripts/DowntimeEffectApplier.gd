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
##   remove_mental_affliction   : int (truthy). Removes non-buff conditions tagged "mental".
##   remove_physical_affliction : int (truthy). Removes non-buff conditions tagged "physical".
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
##
## apply() returns one short player-facing line per change it actually made
## ("+8 HP", "+20 Gold", "Cleared: Paranoid") for the resolver's log summary.
class_name DowntimeEffectApplier
extends RefCounted

const GOLD_ID := "gold"
# Spell-tagged abilities Research must not teach: these don't work for the
# party yet. Debug abilities (test_*) are filtered by prefix.
const UNTEACHABLE_SPELLS := ["magnetic_pull", "vortex", "repulsion_wave"]

static func apply(character, effects: Dictionary, success_tier: int = 1) -> Array:
	var lines: Array = []
	if character == null or not is_instance_valid(character):
		return lines
	if effects == null or effects.is_empty():
		return lines

	for key in effects.keys():
		var value = effects[key]
		match String(key):
			"hp":
				lines.append_array(_apply_hp(character, int(value)))
			"money":
				lines.append_array(_apply_money(character, value, success_tier))
			"favorability":
				# apply_favorability_delta announces the change (with the new
				# total) itself, so it isn't repeated in the summary.
				if character.has_method("apply_favorability_delta"):
					character.apply_favorability_delta(int(value), "downtime")
			"stress":
				lines.append_array(_apply_stress(character, int(value)))
			"remove_mental_affliction":
				lines.append_array(_remove_with_trait(character, "mental"))
			"remove_physical_affliction":
				lines.append_array(_remove_with_trait(character, "physical"))
			"add_condition":
				lines.append_array(_apply_add_condition(character, value))
			"remove_condition":
				lines.append_array(_apply_remove_condition(character, String(value)))
			"grant_ability":
				lines.append_array(_apply_grant_ability(character, String(value)))
			"learn_spell":
				lines.append_array(_apply_learn_spell(character, String(value)))
			"add_trait":
				lines.append_array(_apply_add_trait(character, value))
			"remove_trait":
				lines.append_array(_apply_remove_trait(character, String(value)))
			"soul_exchange":
				lines.append_array(_apply_soul_exchange(character, value, success_tier))
			"holy_tier_next_day":
				lines.append_array(_apply_holy_tier_next_day(character, int(value)))
			"vow_set":
				lines.append_array(_apply_vow_set(character, value))
			"ration_delta":
				lines.append_array(_apply_ration_delta(character, int(value)))
			_:
				push_warning("DowntimeEffectApplier: unknown effect key '%s'" % String(key))
	return lines

# ---------------------------------------------------------------------------
# Per-key handlers. Each returns the summary lines for what it changed.
# ---------------------------------------------------------------------------

static func _apply_hp(character, amount: int) -> Array:
	# Single-bar HP: downtime heals/damage just push current_health up or down.
	# `take_damage` would apply DR — downtime mishaps are abstract, not weapon
	# hits, so we bypass it and subtract directly. Still routes through the
	# health_changed signal so UI updates.
	if amount == 0:
		return []
	if not ("current_health" in character) or not ("max_health" in character):
		return []
	if amount > 0:
		var healed: int = 0
		if character.has_method("heal"):
			healed = int(character.heal(amount))
		else:
			var before_heal: int = int(character.current_health)
			character.current_health = min(character.current_health + amount, character.max_health)
			character.health_changed.emit(character.current_health, character.max_health, character)
			healed = int(character.current_health) - before_heal
		return ["+%d HP" % healed] if healed > 0 else []
	var before: int = int(character.current_health)
	character.current_health = max(0, character.current_health - abs(amount))
	character.health_changed.emit(character.current_health, character.max_health, character)
	if character.has_method("_check_death"):
		character._check_death()
	var lost: int = before - int(character.current_health)
	if lost <= 0:
		return []
	# The death itself is announced by the character; this names the cause.
	if before > 0 and int(character.current_health) <= 0:
		return ["-%d HP (fatal)" % lost]
	return ["-%d HP" % lost]

static func _apply_stress(character, amount: int) -> Array:
	if amount == 0 or not character.has_method("gain_stress"):
		return []
	var before: int = int(character.stress) if "stress" in character else 0
	character.gain_stress(amount)
	if amount > 0:
		return ["Stress +%d" % amount]
	var relieved: int = before - (int(character.stress) if "stress" in character else before)
	return ["Stress -%d" % relieved] if relieved > 0 else []

static func _apply_money(character, value, success_tier: int) -> Array:
	# `Inventory` has a class_name, so typing the local lets the parser see
	# add_stack / find_item_by_id and stops "cannot infer type" on the
	# return-value assignments below.
	var inv: Inventory = character.get_node_or_null("Inventory")
	if inv == null:
		return []
	# "all" means lost everything — remove every currency the character holds.
	if typeof(value) == TYPE_STRING and String(value).to_lower() == "all":
		return _remove_currency(inv, -1)
	var amount: int = int(value)
	if amount == 0:
		return []
	if amount < 0:
		return _remove_currency(inv, abs(amount))
	var tier_mult: int = max(success_tier, 1)
	var scaled: int = amount * tier_mult
	# Pay out in a random Currency-trait item (gold, cigarette, ...).
	var cur_data: Dictionary = ItemDatabase.random_currency_data(GOLD_ID)
	if cur_data.is_empty():
		return []
	# A full pack with no room for the drawn currency pays in gold instead,
	# which usually merges into a stack the character already carries.
	if String(cur_data.get("id", "")) != GOLD_ID and not _has_room_for(inv, cur_data):
		var gold_data: Dictionary = ItemDatabase.items.get(GOLD_ID, {})
		if not gold_data.is_empty():
			cur_data = gold_data
	var entry: Dictionary = cur_data.duplicate(true)
	entry["num_stacks"] = scaled
	entry["is_stackable"] = true
	var cur_name := String(cur_data.get("display_name", "Gold"))
	var placed: int = scaled
	if not inv.add_stack(entry):
		# add_stack leaves the unplaced remainder in entry, and Inventory's
		# add_failed has already told the player the pack is full.
		placed = scaled - int(entry.get("num_stacks", scaled))
	var lines: Array = []
	if placed > 0:
		var line := "+%d %s" % [placed, cur_name]
		if tier_mult > 1:
			line += " (x%d for the check)" % tier_mult
		lines.append(line)
	if placed < scaled:
		lines.append("%d %s left behind" % [scaled - placed, cur_name])
	return lines

# Deducts `amount` across the character's currency holdings (gold first), or
# everything when amount < 0. Goes through remove_amount so emptied slots are
# dropped and the inventory UI refreshes. One line per currency lost.
static func _remove_currency(inv: Inventory, amount: int) -> Array:
	var lines: Array = []
	var take_all: bool = amount < 0
	var remaining: int = amount
	for cid in _ordered_currency_ids():
		if not take_all and remaining <= 0:
			break
		var lost: int = 0
		var cur_name := String(cid)
		var idx: int = inv.find_item_by_id(cid)
		while idx >= 0 and (take_all or remaining > 0):
			var current: int = int(inv.items[idx].get("num_stacks", 1))
			cur_name = String(inv.items[idx].get("display_name", cid))
			if current <= 0:
				# Empty stack left behind by older saves; just clear the slot.
				inv.remove_item(idx)
			else:
				var take: int = current if take_all else mini(current, remaining)
				inv.remove_amount(idx, take)
				lost += take
				remaining -= take
			idx = inv.find_item_by_id(cid)
		if lost > 0:
			lines.append("-%d %s" % [lost, cur_name])
	if lines.is_empty():
		lines.append("No coin to lose")
	return lines

# Whether add_stack can place at least part of this item: a free slot, or a
# matching stack with space. The slot count is items.size() (Inventory's own
# full check); switch to slots_used() if Inventory grows one.
static func _has_room_for(inv: Inventory, item_data: Dictionary) -> bool:
	if inv.items.size() < inv.max_slots:
		return true
	var item_id := String(item_data.get("id", ""))
	var max_stack := int(item_data.get("max_stack_size", 20))
	for it in inv.items:
		if String(it.get("id", "")) == item_id and int(it.get("num_stacks", 1)) < max_stack:
			return true
	return false

static func _ordered_currency_ids() -> Array:
	# Currency ids with GOLD_ID first (so removal/"all" prefers gold), then the
	# rest in a stable order.
	var ids: Array = ItemDatabase.currency_item_ids()
	ids.sort()
	if GOLD_ID in ids:
		ids.erase(GOLD_ID)
		ids.push_front(GOLD_ID)
	return ids

static func _condition_name(cid: String) -> String:
	var cond = ConditionManager.condition_registry.get(cid)
	if cond != null and not String(cond.display_name).is_empty():
		return String(cond.display_name)
	return cid.replace("_", " ")

static func _remove_with_trait(character, trait_tag: String) -> Array:
	# Afflictions only. Buffs and stress virtues (Blessed, Courageous, Mighty)
	# share the "mental"/"physical" tags and must survive a night out, and
	# curses such as Scarred (cancelled by remove_curse) need stronger magic.
	var cm = character.get_node_or_null("ConditionManager")
	if cm == null:
		return []
	var ids: Array = []
	var names: Array = []
	for cid in cm.conditions.keys():
		var cond = cm.conditions[cid].condition
		if not cond.traits.has(trait_tag) or cond.traits.has("buff"):
			continue
		if "remove_curse" in cond.canceled_by_trait:
			continue
		ids.append(cid)
		names.append(_condition_name(String(cid)))
	for cid in ids:
		cm.remove_condition(cid)
	if names.is_empty():
		return []
	return ["Cleared: " + ", ".join(names)]

static func _apply_add_condition(character, value) -> Array:
	var cm = character.get_node_or_null("ConditionManager")
	if cm == null:
		return []
	var cid := ""
	var stacks := 1
	if typeof(value) == TYPE_DICTIONARY:
		cid = String(value.get("id", ""))
		stacks = int(value.get("stacks", 1))
	else:
		cid = String(value)
	if cid.is_empty():
		return []
	# -2.0 = the template's default duration. -1 is an explicit "permanent"
	# override, which made every downtime condition (Hungover, Blessed, Pox)
	# last forever. `wanted` is permanent by template, so it still is.
	var lines: Array = []
	if cm.apply_condition(cid, character, stacks, -2.0, null) != null:
		lines.append("Gained: " + _condition_name(cid))
	elif ConditionManager.condition_registry.has(cid):
		# A known condition that didn't land was blocked by an immunity or the
		# apply-time save.
		lines.append("Resisted: " + _condition_name(cid))
	# The shipped "caught stealing" downtime outcome applies `wanted`; make
	# it mean something — the local law faction turns hostile (law/crime
	# Phase 6). The wanted condition itself is a display derivative.
	if cid == "wanted":
		var tree = character.get_tree() if character is Node else null
		var game = tree.current_scene if tree != null else null
		if game != null and ("current_map_id" in game):
			var law_faction: String = LawDatabase.jurisdiction_for_map(str(game.current_map_id))
			if not law_faction.is_empty():
				FactionDatabase.mark_outlaw(law_faction)
				var faction_name: String = str(FactionDatabase.get_faction_data(law_faction).get("name", law_faction)) \
						if FactionDatabase.has_faction(law_faction) else law_faction
				lines.append("Wanted by " + faction_name)
	return lines

static func _apply_remove_condition(character, cid: String) -> Array:
	var cm = character.get_node_or_null("ConditionManager")
	if cm == null or cid.is_empty():
		return []
	if cm.remove_condition(cid):
		return ["Cleared: " + _condition_name(cid)]
	return []

static func _apply_grant_ability(character, ability_id: String) -> Array:
	if ability_id.is_empty():
		return []
	var inv = character.get_node_or_null("Inventory")
	if inv == null or not inv.has_method("add_ability_by_id"):
		return []
	if not inv.add_ability_by_id(ability_id):
		return []
	var ab: Dictionary = AbilityDatabase.get_ability_data(ability_id)
	return ["Learned: " + String(ab.get("display_name", ability_id.replace("_", " ")))]

static func _apply_learn_spell(character, spell_id: String) -> Array:
	# DowntimeResolver resolves "random_spell" up front so the result text can
	# name the spell; an empty id means there was nothing left to learn.
	if spell_id == "random_spell":
		spell_id = pick_random_unknown_spell(character)
	if spell_id.is_empty():
		return ["Found nothing new to learn"]
	return _apply_grant_ability(character, spell_id)

static func pick_random_unknown_spell(character) -> String:
	# A "spell" is an ability whose traits include {"spell": >=1}.
	# NOTE: AbilityDatabase.get_all_abilities() did not exist until the quest
	# reward work added it, so the has_method guard below always failed and this
	# whole function silently returned "" — the Research activity's "new_spell"
	# outcome had never once granted a spell. The guard is kept as cheap
	# insurance, but it now passes.
	if not Engine.has_singleton("AbilityDatabase") and not (typeof(AbilityDatabase) == TYPE_OBJECT):
		return ""
	if not AbilityDatabase.has_method("get_all_abilities"):
		return ""
	var all: Array = AbilityDatabase.get_all_abilities()
	# Known = stowed, or held in either hand (an equipped copy).
	var known: Array = []
	var inv = character.get_node_or_null("Inventory")
	if inv != null:
		for it in inv.stowed_items:
			if it != null and "raw_data" in it:
				known.append(String(it.raw_data.get("id", "")))
		for held in [inv.main_hand_item, inv.off_hand_item]:
			if held != null and "raw_data" in held:
				known.append(String(held.raw_data.get("id", "")))
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
		# Debug abilities and spells that don't work for the party yet.
		if aid.begins_with("test_") or aid in UNTEACHABLE_SPELLS:
			continue
		candidates.append(aid)
	if candidates.is_empty():
		return ""
	return String(candidates[randi() % candidates.size()])

static func _apply_add_trait(character, value) -> Array:
	if not ("traits" in character):
		return []
	var lines: Array = []
	if typeof(value) == TYPE_DICTIONARY:
		for t in value.keys():
			character.traits[String(t)] = int(value[t])
			lines.append("Trait: %s %d" % [String(t), int(value[t])])
	else:
		var name := String(value)
		if name.is_empty():
			return []
		character.traits[name] = int(character.traits.get(name, 0)) + 1
		lines.append("Trait: %s %d" % [name, int(character.traits[name])])
	return lines

static func _apply_remove_trait(character, trait_name: String) -> Array:
	if trait_name.is_empty() or not ("traits" in character):
		return []
	if character.traits.erase(trait_name):
		return ["Lost trait: " + trait_name]
	return []

# ---------------------------------------------------------------------------
# Soul exchange (Occult patrons)
# ---------------------------------------------------------------------------

static func _apply_soul_exchange(character, value, success_tier: int) -> Array:
	if typeof(value) != TYPE_DICTIONARY:
		return []
	if not ("captured_souls" in character):
		return []
	var patron_id := String(value.get("patron", ""))
	if patron_id.is_empty() and "patron_id" in character:
		patron_id = String(character.patron_id)
	if patron_id.is_empty():
		return ["No patron to receive the offering"]
	var max_count := int(value.get("count", 1))
	if max_count <= 0:
		return []
	var eligible: Array = PatronDatabase.eligible_souls(patron_id, character.captured_souls)
	if eligible.is_empty():
		return ["No soul their patron will accept"]
	var lines: Array = []
	var consumed_count := 0
	for soul in eligible:
		if consumed_count >= max_count:
			break
		character.captured_souls.erase(soul)
		if "souls" in character and int(character.souls) > 0:
			character.souls = int(character.souls) - 1
		lines.append_array(_apply_patron_rewards(character, patron_id, consumed_count + 1, success_tier))
		consumed_count += 1
	lines.push_front("Offered %d soul%s" % [consumed_count, "" if consumed_count == 1 else "s"])
	return lines

static func _apply_patron_rewards(character, patron_id: String, souls_offered: int, success_tier: int) -> Array:
	var patron := PatronDatabase.get_patron(patron_id)
	if patron.is_empty():
		return []
	var lines: Array = []
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
					lines.append("%s %+d" % [trait_name, amount])
			"grant_ability":
				lines.append_array(_apply_grant_ability(character, String(reward.get("ability_id", ""))))
			"money":
				lines.append_array(_apply_money(character, int(reward.get("amount", 0)), success_tier))
			"condition":
				lines.append_array(_apply_add_condition(character, reward.get("condition", "")))
	return lines

# ---------------------------------------------------------------------------
# Holy Vows
# ---------------------------------------------------------------------------

static func _apply_holy_tier_next_day(character, amount: int) -> Array:
	if amount == 0 or not ("holy_tier_next_day_pending" in character):
		return []
	character.holy_tier_next_day_pending = int(character.holy_tier_next_day_pending) + amount
	return ["%+d max Devotion tomorrow" % amount]

static func _apply_vow_set(character, value) -> Array:
	if typeof(value) != TYPE_DICTIONARY:
		return []
	if not ("active_vows" in character):
		return []
	var vow_id := String(value.get("vow_id", ""))
	if vow_id.is_empty():
		return []
	var active := bool(value.get("active", true))
	if active:
		character.active_vows[vow_id] = {"days_maintained": 0, "broken": false}
		return ["Took the vow of " + vow_id.capitalize()]
	character.active_vows.erase(vow_id)
	return ["Released from the vow of " + vow_id.capitalize()]

static func _apply_ration_delta(character, amount: int) -> Array:
	if amount == 0:
		return []
	var inv: Inventory = character.get_node_or_null("Inventory")
	if inv == null:
		return []
	var idx: int = inv.find_item_by_id("ration")
	if idx < 0:
		# Try the plural / alternate id used by some content
		idx = inv.find_item_by_id("rations")
	if amount < 0:
		if idx < 0:
			return ["No ration to offer"]
		var current: int = int(inv.items[idx].get("num_stacks", 1))
		var ration_name := String(inv.items[idx].get("display_name", "Ration"))
		if current <= 0:
			inv.remove_item(idx)
			return ["No ration to offer"]
		var take: int = mini(current, -amount)
		# remove_amount drops the slot at 0 and emits item_removed for the UI.
		inv.remove_amount(idx, take)
		return ["-%d %s" % [take, ration_name]]
	# Gaining rations: merge into the carried stack, or mint one from the
	# item database.
	var data: Dictionary = {}
	if idx >= 0:
		data = inv.items[idx].duplicate(true)
	else:
		data = ItemDatabase.items.get("ration", ItemDatabase.items.get("rations", {})).duplicate(true)
	if data.is_empty():
		push_warning("DowntimeEffectApplier: no 'ration' item in ItemDatabase; ration_delta %+d dropped" % amount)
		return []
	data["num_stacks"] = amount
	data["is_stackable"] = true
	var gained_name := String(data.get("display_name", "Ration"))
	var placed: int = amount
	if not inv.add_stack(data):
		placed = amount - int(data.get("num_stacks", amount))
	return ["+%d %s" % [placed, gained_name]] if placed > 0 else []
