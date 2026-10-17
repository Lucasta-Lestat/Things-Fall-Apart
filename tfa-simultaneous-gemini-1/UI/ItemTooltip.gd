# =====================
# UI/ItemTooltip.gd - Hover text for inventory item slots, shared by every
# window that shows them: PartySidePanel, TradeWindow, ChestInventoryWindow
# (chests and corpse loot) and the TownServicesPanel cards. Static helpers only
# and no class_name, so call
#   preload("res://UI/ItemTooltip.gd").detail_text(entry, context)
#
# `entry` is the slot dict those windows build:
#   {kind: "item" | "weapon" | "ability", display_name, sprite_path,
#    num_stacks, equipped, hand, source_index,
#    raw: item Dictionary | WeaponShape | AbilityShape, ...}
#
# Each window opens with its own first line (see the CONTEXT_ consts). All of
# them then get the same extra lines from the hooks at the bottom, so a feature
# that fills a hook shows in every window at once. Plain text: Control
# tooltips don't render BBCode.
# =====================

extends RefCounted

const EquipmentEffects = preload("res://Items/equipment_effects.gd")

## PartySidePanel (default): the name, its gold value as the trade window
## prices it, then what it does (see party_text).
const CONTEXT_PARTY := ""
## TradeWindow: "Name (N gold)".
const CONTEXT_TRADE := "trade"
## TownServicesPanel card slots: "Name (N gold)".
const CONTEXT_SERVICE := "service"
## TownServicesPanel's greyed weapons of an away NPC (entry kind
## "weapon_preview", raw = the snapshot's weapon data dict):
## "Name (N gold) - visit to trade".
const CONTEXT_SERVICE_PREVIEW := "service_preview"
## ChestInventoryWindow (chests and corpses): the name only, as contents
## aren't priced there.
const CONTEXT_CHEST := "chest"

static func detail_text(entry: Dictionary, context: String = CONTEXT_PARTY) -> String:
	var tip: String
	match context:
		CONTEXT_TRADE:
			tip = "%s (%.0f gold)" % [entry.get("display_name", "Unknown"), trade_value(entry)]
		CONTEXT_SERVICE:
			tip = "%s (%.0f gold)" % [entry.get("display_name", "?"), trade_value(entry)]
		CONTEXT_SERVICE_PREVIEW:
			tip = "%s (%.0f gold) - visit to trade" % [entry.get("display_name", "?"), trade_value(entry)]
		CONTEXT_CHEST:
			tip = str(entry.get("display_name", "Unknown"))
		_:
			# Party panel: name, value, then what it does.
			tip = party_text(entry)
	for line in armour_lines(entry):
		tip += "\n" + line
	for line in noise_lines(entry):
		tip += "\n" + line
	for line in effect_lines(entry):
		tip += "\n" + line
	for line in ability_lines(entry):
		tip += "\n" + line
	return tip

## The slot's trade value as the trade and services windows price it: a
## WeaponShape's cost, or an item's cost times the item dict's own num_stacks.
static func trade_value(entry: Dictionary) -> float:
	if entry.get("kind", "") == "weapon":
		var w = entry.get("raw")
		if w != null and "cost" in w:
			return float(w.cost)
		return 0.0
	var raw = entry.get("raw", {})
	if not (raw is Dictionary):
		return 0.0
	var stacks_val = raw.get("num_stacks", 1)
	var stacks: int = int(stacks_val) if stacks_val != null else 1
	return float(raw.get("cost", 0.0)) * max(stacks, 1)

## Casting rules for an ability slot (party panel): "Interruptible" when a
## windup can be broken by a hit, knockback or being incapacitated,
## "Concentration: spends N focus, then holds up to N more while it lasts" for
## a Concentration spell, and each equipment need ("Needs a shield") before a
## cast fails on it.
static func ability_lines(entry: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	var aid := str(entry.get("ability_id", ""))
	# Checked first: get_ability_data reports unknown ids as errors.
	if entry.get("kind", "") != "ability" or not AbilityDatabase.get_all_ability_ids().has(aid):
		return out
	var data: Dictionary = AbilityDatabase.get_ability_data(aid)
	if float(data.get("cast_time", 0.0)) > 0.0 and bool(data.get("interruptible", true)):
		out.append("Interruptible")
	# Pays its focus (Arcane tier) like any cast, then holds up to as much
	# again while what it installed lasts (lavender focus pips).
	var ab_traits = data.get("traits", {})
	if ab_traits is Dictionary and (ab_traits.has("Concentration") or ab_traits.has("concentration")):
		var focus_cost: int = int(ab_traits.get("Arcane", 0))
		if focus_cost > 0:
			out.append("Concentration: spends %d focus, then holds up to %d more while it lasts" % [focus_cost, focus_cost])
		else:
			out.append("Concentration")
	var reqs = data.get("requirements", {})
	if reqs is Dictionary:
		for t in reqs.get("traits", []):
			out.append(AbilityManager.requirement_reason(String(t)))
	return out

## The party panel's first lines. Items: "Name (N gold)", the description,
## and who it was stolen from. Weapons: "Name (N gold)" and the weapon's base
## damage (strength adds to it in melee, hence "Base"). Abilities: name,
## description, the school-resource cost the panel stores on the entry
## ("costs"; "innate" marks a racial ability, which costs nothing), cast time
## and range. Abilities show no price.
static func party_text(entry: Dictionary) -> String:
	var tip: String = str(entry.get("display_name", "Unknown"))
	var kind: String = str(entry.get("kind", ""))
	var raw = entry.get("raw")
	if kind == "ability":
		if not (is_instance_valid(raw) and "raw_data" in raw and raw.raw_data is Dictionary):
			return tip
		var data: Dictionary = raw.raw_data
		var desc = data.get("description")
		if desc != null and str(desc) != "":
			tip += "\n" + str(desc)
		var costs: Dictionary = entry.get("costs", {})
		var parts: PackedStringArray = []
		for res in costs:
			parts.append("%d %s" % [int(costs[res]), String(res).capitalize()])
		if not parts.is_empty():
			tip += "\nCost: " + ", ".join(parts)
		elif entry.get("innate", false):
			tip += "\nCost: none (innate)"
		else:
			tip += "\nCost: none"
		var stats: PackedStringArray = []
		var ct = data.get("cast_time", 0.0)
		var cast_time: float = float(ct) if ct != null else 0.0
		if cast_time > 0.0:
			stats.append("Cast: %.1fs" % cast_time)
		var targeting = data.get("targeting", {})
		if targeting is Dictionary and targeting.get("range") != null and float(targeting["range"]) > 0.0:
			stats.append("Range: %d" % int(targeting["range"]))
		if not stats.is_empty():
			tip += "\n" + "   ".join(stats)
		return tip
	var value := trade_value(entry)
	if value > 0.0:
		tip += " (%.0f gold)" % value
	var is_node: bool = is_instance_valid(raw)
	if kind == "weapon":
		var dmg = null
		if raw is Dictionary:
			dmg = raw.get("damage")
		elif is_node and "damage" in raw:
			dmg = raw.damage
		if dmg is Dictionary and not dmg.is_empty():
			var dmg_parts: PackedStringArray = []
			for dtype in dmg:
				dmg_parts.append("%d %s" % [int(dmg[dtype]), dtype])
			tip += "\nBase damage: " + ", ".join(dmg_parts)
	elif kind == "item" and raw is Dictionary:
		var d = raw.get("description")
		if d != null and str(d) != "":
			tip += "\n" + str(d)
	# The law system remembers whose property it is: selling or dropping it
	# near them doesn't make it yours.
	var src = null
	if raw is Dictionary:
		src = raw.get("stolen_from")
	elif is_node and "stolen_from" in raw:
		src = raw.stolen_from
	if src != null and str(src) != "":
		var owner_name := str(src)
		if FactionDatabase.has_faction(owner_name):
			owner_name = str(FactionDatabase.get_faction_data(owner_name).get("name", owner_name))
		tip += "\nStolen from " + owner_name
	return tip

# --- Armour ---------------------------------------------------------------
# What a worn piece or a held shield actually does, read the way
# ProceduralCharacter applies it: per-type DR on every limb it covers
# (get_limb_for_equipment_slot for worn slots, _SHIELD_COVERED_LIMBS for a
# shield in the off hand), subtracted from each hit on those limbs.

## Item equip_slot -> EquipmentShape.EquipmentSlot. Mirrors
## PartySidePanel._EQUIP_SLOT_MAP (the slots a piece can be worn in).
const ARMOUR_SLOTS := {"Head": 0, "Torso": 1, "Back": 2, "Legs": 3, "Feet": 4, "Cape": 2}
## Display order for damage types; anything else follows alphabetically.
const DR_ORDER := ["slashing", "bludgeoning", "piercing", "fire", "cold", "electric", "acid", "poison", "sonic", "radiant", "necrotic", "force"]

## The non-zero DR a wearer gets from this item, {} if none. Only worn slots
## qualify (a shield is shield_dr's), and a slot that covers no limb gives
## nothing, as in play.
static func armour_dr(item_data: Dictionary) -> Dictionary:
	var slot_name := str(item_data.get("equip_slot", ""))
	if not ARMOUR_SLOTS.has(slot_name):
		return {}
	if ProceduralCharacter.get_limb_for_equipment_slot(int(ARMOUR_SLOTS[slot_name])).is_empty():
		return {}
	return _nonzero_dr(item_data.get("damage_resitances", item_data.get("damage_resistances")))

## The non-zero DR a shield adds while held in the off hand, {} for anything
## that isn't a shield. Takes the item dict or the held WeaponShape.
static func shield_dr(raw) -> Dictionary:
	if raw is WeaponShape:
		if raw.weapon_type != WeaponShape.WeaponType.SHIELD:
			return {}
		return _nonzero_dr(raw.damage_resitances)
	if raw is Dictionary and str(raw.get("type", "")).to_lower() == "shield":
		return _nonzero_dr(raw.get("damage_resitances", raw.get("damage_resistances")))
	return {}

static func _nonzero_dr(dr) -> Dictionary:
	if not (dr is Dictionary):
		return {}
	var out := {}
	for k in dr:
		if dr[k] != null and int(dr[k]) != 0:
			out[str(k)] = int(dr[k])
	return out

## The limbs a slot protects, in words: "torso and arms", "legs".
static func covered_limbs_text(slot_enum: int) -> String:
	return _limbs_text(ProceduralCharacter.get_limb_for_equipment_slot(slot_enum))

static func _limbs_text(limbs: Array) -> String:
	var words: PackedStringArray = []
	for lt in limbs:
		var w := "legs"
		if lt == ProceduralCharacter.LimbType.HEAD:
			w = "head"
		elif lt == ProceduralCharacter.LimbType.TORSO:
			w = "torso"
		elif lt == ProceduralCharacter.LimbType.LEFT_ARM or lt == ProceduralCharacter.LimbType.RIGHT_ARM:
			w = "arms"
		if not words.has(w):
			words.append(w)
	if words.size() <= 1:
		return "".join(words)
	return ", ".join(words.slice(0, words.size() - 1)) + " and " + words[words.size() - 1]

static func _dr_order(dr: Dictionary) -> Array:
	var keys: Array = []
	for t in DR_ORDER:
		if dr.has(t):
			keys.append(t)
	var rest: Array = []
	for k in dr:
		if not keys.has(k):
			rest.append(k)
	rest.sort()
	return keys + rest

## "Armour (torso and arms): blocks 4 slashing, ... per hit" plus a
## "Weakness: +1 electric damage per hit" line for negative DR.
static func _dr_lines(label: String, dr: Dictionary) -> PackedStringArray:
	var lines := PackedStringArray()
	var blocks: PackedStringArray = []
	var weak: PackedStringArray = []
	for dtype in _dr_order(dr):
		var v: int = int(dr[dtype])
		if v > 0:
			blocks.append("%d %s" % [v, dtype])
		else:
			weak.append("+%d %s" % [-v, dtype])
	if not blocks.is_empty():
		lines.append("%s: blocks %s per hit" % [label, ", ".join(blocks)])
	if not weak.is_empty():
		lines.append("Weakness: %s damage per hit" % ", ".join(weak))
	return lines

# ---------------------------------------------------------------------------
# Hooks: extra lines appended in every window, one line per array element.
# Each gets the slot entry and returns nothing for entries it doesn't cover.
# ---------------------------------------------------------------------------

## Armour: limbs covered and damage blocked per hit.
static func armour_lines(entry: Dictionary) -> PackedStringArray:
	var raw = entry.get("raw")
	var sdr: Dictionary = shield_dr(raw)
	if not sdr.is_empty():
		var shield_limbs: String = _limbs_text(ProceduralCharacter._SHIELD_COVERED_LIMBS)
		return _dr_lines("Shield (%s, held in the off hand)" % shield_limbs, sdr)
	if entry.get("kind", "") != "item" or not (raw is Dictionary):
		return PackedStringArray()
	var dr: Dictionary = armour_dr(raw)
	if dr.is_empty():
		return PackedStringArray()
	var limbs: String = covered_limbs_text(int(ARMOUR_SLOTS[str(raw.get("equip_slot", ""))]))
	return _dr_lines("Armour (%s)" % limbs, dr)

## Noise the item makes when worn: the same per-step number the worn piece
## adds to every footstep NPCs hear (EquipmentShape.noise_for_item_data).
static func noise_lines(entry: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	if entry.get("kind", "") != "item":
		return out
	var item = entry.get("raw", {})
	if not (item is Dictionary) or not (str(item.get("equip_slot", "")) in WEARABLE_SLOTS):
		return out
	var n := EquipmentShape.noise_for_item_data(item)
	if n <= 0.0:
		out.append("Noise when worn: silent")
	else:
		out.append("Noise when worn: %s (+%.2f per step)" % [noise_word(n), n])
	var t := str(item.get("type", "")).to_lower()
	if t == "boots" or t == "greaves":
		out.append("Boots: steps at full floor volume (bare feet: half)")
	return out

## Equip slots a worn piece can go in (PartySidePanel._EQUIP_SLOT_MAP).
const WEARABLE_SLOTS := ["Head", "Torso", "Back", "Cape", "Legs", "Feet"]

## A word for a worn piece's per-step noise. Floors run about 0.25 (grass)
## to 0.9 (water) per step, so these are relative to that scale.
static func noise_word(noise_per_step: float) -> String:
	if noise_per_step <= 0.0:
		return "silent"
	if noise_per_step < 0.05:
		return "faint"
	if noise_per_step < 0.15:
		return "light"
	if noise_per_step < 0.30:
		return "noticeable"
	return "loud"

## Effects while equipped (conditions granted, light, on-hit abilities).
## Worn gear: each condition it grants with what it does, worn-pack slots and
## light; a weapon (WeaponShape, or a hand-slot dict in the chest window): its
## while-drawn conditions and light.
static func effect_lines(entry: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	var raw = entry.get("raw")
	match str(entry.get("kind", "")):
		"item":
			if raw is Dictionary:
				out.append_array(EquipmentEffects.worn_lines(raw))
		"weapon":
			out.append_array(EquipmentEffects.held_lines(raw))
	return out
