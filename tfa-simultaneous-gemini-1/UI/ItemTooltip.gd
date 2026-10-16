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
## windup can be broken by a hit, knockback or being incapacitated, and each
## equipment need ("Needs a shield") before a cast fails on it.
static func ability_lines(entry: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	var aid := str(entry.get("ability_id", ""))
	# Checked first: get_ability_data reports unknown ids as errors.
	if entry.get("kind", "") != "ability" or not AbilityDatabase.get_all_ability_ids().has(aid):
		return out
	var data: Dictionary = AbilityDatabase.get_ability_data(aid)
	if float(data.get("cast_time", 0.0)) > 0.0 and bool(data.get("interruptible", true)):
		out.append("Interruptible")
	var reqs = data.get("requirements", {})
	if reqs is Dictionary:
		for t in reqs.get("traits", []):
			out.append(AbilityManager.requirement_reason(String(t)))
	return out

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
