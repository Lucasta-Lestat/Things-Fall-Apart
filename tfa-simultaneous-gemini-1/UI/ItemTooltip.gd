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

## PartySidePanel (default): the name.
const CONTEXT_PARTY := ""
## TradeWindow: "Name (N gold)".
const CONTEXT_TRADE := "trade"
## TownServicesPanel card slots: "Name (N gold)".
const CONTEXT_SERVICE := "service"
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
		_:
			# Party panel and chest: the bare name.
			tip = str(entry.get("display_name", "Unknown"))
	for line in armour_lines(entry):
		tip += "\n" + line
	for line in noise_lines(entry):
		tip += "\n" + line
	for line in effect_lines(entry):
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

## Noise the item makes when worn or carried.
static func noise_lines(_entry: Dictionary) -> PackedStringArray:
	return PackedStringArray()

## Effects while equipped (conditions granted, light, on-hit abilities).
static func effect_lines(_entry: Dictionary) -> PackedStringArray:
	return PackedStringArray()
