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

## PartySidePanel (default): the name, its gold value as the trade window
## prices it, then what it does (see party_text).
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
		CONTEXT_CHEST:
			tip = str(entry.get("display_name", "Unknown"))
		_:
			tip = party_text(entry)
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

# ---------------------------------------------------------------------------
# Hooks: extra lines appended in every window, one line per array element.
# Each gets the slot entry and returns nothing for entries it doesn't cover.
# ---------------------------------------------------------------------------

## Armour: limbs covered and damage blocked per hit.
static func armour_lines(_entry: Dictionary) -> PackedStringArray:
	return PackedStringArray()

## Noise the item makes when worn or carried.
static func noise_lines(_entry: Dictionary) -> PackedStringArray:
	return PackedStringArray()

## Effects while equipped (conditions granted, light, on-hit abilities).
static func effect_lines(_entry: Dictionary) -> PackedStringArray:
	return PackedStringArray()
