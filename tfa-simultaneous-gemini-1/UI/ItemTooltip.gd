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

## PartySidePanel (default): the name.
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
## windup can be broken by a hit, knockback or being incapacitated,
## "Concentration" for a spell that holds its focus, and each equipment need
## ("Needs a shield") before a cast fails on it.
static func ability_lines(entry: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	var aid := str(entry.get("ability_id", ""))
	# Checked first: get_ability_data reports unknown ids as errors.
	if entry.get("kind", "") != "ability" or not AbilityDatabase.get_all_ability_ids().has(aid):
		return out
	var data: Dictionary = AbilityDatabase.get_ability_data(aid)
	if float(data.get("cast_time", 0.0)) > 0.0 and bool(data.get("interruptible", true)):
		out.append("Interruptible")
	# Holds its focus while what it installed lasts (lavender focus pips).
	var ab_traits = data.get("traits", {})
	if ab_traits is Dictionary and (ab_traits.has("Concentration") or ab_traits.has("concentration")):
		out.append("Concentration")
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
