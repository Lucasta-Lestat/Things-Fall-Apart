# =====================
# Items/equipment_effects.gd - What gear does beyond armour DR and weapon
# damage, read from Items.json fields:
#   adds_condition_on_equip  a condition held while the item is worn (armour)
#                            or drawn (a weapon); ProceduralCharacter applies them
#   num_slots                extra carry slots from a worn pack
#   emits_light              a light radius level (0..1) while worn or held
#   light_color              optional [r, g, b] (0..1) for that light; absent =
#                            the colour of the item's traits (light_color())
# Static helpers only and no class_name (the class cache is static), so load
#   const EquipmentEffects = preload("res://Items/equipment_effects.gd")
# Callers pass characters and weapons untyped (duck typing): naming
# ProceduralCharacter or WeaponShape here would make a preload cycle.
# =====================

extends RefCounted

## Light radius in px: LIGHT_MIN_RADIUS_PX + LIGHT_RADIUS_PER_LEVEL_PX * level,
## so emits_light 1.0 lights 4 tiles and 0.1 about 1.3.
const LIGHT_MIN_RADIUS_PX := 64.0
const LIGHT_RADIUS_PER_LEVEL_PX := 192.0
const LIGHT_MIN_ENERGY := 0.35
const LIGHT_ENERGY_PER_LEVEL := 0.65
const LIGHT_TEX_SIZE := 128
## Tile size the tooltips measure light radius in.
const TILE_PX := 64.0
## Hand-slot item dicts mirror a WeaponShape (shields included) and are hidden.
const HAND_SLOTS := ["Main Hand", "Off Hand"]
## equip_slot values worn on the body (capes share the BACK slot).
const WEAR_SLOTS := ["Head", "Torso", "Back", "Legs", "Feet", "Cape"]
## Light colour by item trait; the item's highest-tier one wins.
const LIGHT_TRAIT_COLORS := {
	"fire": Color(1.0, 0.6, 0.25),
	"cold": Color(0.6, 0.85, 1.0),
	"holy": Color(1.0, 0.95, 0.7),
	"noble": Color(1.0, 0.85, 0.4),
}
const LIGHT_DEFAULT_COLOR := Color(1.0, 0.9, 0.75)

static var _light_tex: Texture2D = null
static var _warned_condition_ids := {}

## Player-facing item name: display_name, else name, else the id spaced out.
static func item_name(item_data: Dictionary) -> String:
	for k in ["display_name", "name"]:
		var v = item_data.get(k)
		if v != null and str(v) != "":
			return str(v)
	var id = item_data.get("id")
	return str(id).replace("_", " ") if id != null else "item"

## The registered condition ids an adds_condition_on_equip value names: a bare
## String ("inking"), a {condition_id: ...} Dictionary (how WeaponShape stores
## it) or an Array. Items author display-style names ("Inspired") while
## condition ids are lowercase_snake, so names are normalised. Unregistered
## ids are skipped with one warning each, never a per-frame error.
static func resolve_condition_ids(raw) -> Array:
	var ids: Array = []
	if raw is String and raw != "" and raw != "null":
		ids = [raw]
	elif raw is Dictionary and raw.has("condition_id"):
		ids = [raw["condition_id"]]
	elif raw is Array:
		ids = raw
	var out: Array = []
	for cid in ids:
		if cid == null:
			continue
		var key := String(cid).strip_edges().to_lower().replace(" ", "_")
		if key == "" or key in out:
			continue
		if ConditionManager.condition_registry.has(key):
			out.append(key)
		elif not _warned_condition_ids.has(key):
			_warned_condition_ids[key] = true
			push_warning("equip condition '%s' is not a registered condition" % cid)
	return out

## Condition ids an item dict or a WeaponShape grants while worn or drawn.
static func condition_ids_for(source) -> Array:
	if source is Dictionary:
		return resolve_condition_ids(source.get("adds_condition_on_equip"))
	if source is Object and is_instance_valid(source):
		return resolve_condition_ids(source.get("adds_condition_on_equip"))
	return []

## True for an item dict worn on the body (Head, Torso, Back, Legs, Feet, Cape).
static func is_wearable(item_data: Dictionary) -> bool:
	var slot = item_data.get("equip_slot")
	return slot != null and str(slot) in WEAR_SLOTS

## Extra inventory slots the item gives while worn: num_slots on a wearable
## item. 0 for anything else, so a chest's 20 never counts.
static func container_slots(item_data: Dictionary) -> int:
	if not is_wearable(item_data):
		return 0
	var n = item_data.get("num_slots")
	if n == null:
		return 0
	return maxi(0, int(n))

## True for hand-slot item dicts (Main/Off Hand): a weapon's data in a chest
## or on a corpse, or, in a save from before round 3, the hidden copy a
## starting weapon left beside its WeaponShape (Inventory.migrate_hand_dicts
## drops those on load). A carried weapon is its WeaponShape, never a dict.
static func is_hand_ghost(item) -> bool:
	if not (item is Dictionary):
		return false
	var slot = item.get("equip_slot")
	return slot != null and str(slot) in HAND_SLOTS

## emits_light of an item dict or a WeaponShape, clamped to 0..1. It used to
## be parsed as a bool; true reads as 1.0.
static func light_level(source) -> float:
	var v = null
	if source is Dictionary:
		v = source.get("emits_light")
	elif source is Object and is_instance_valid(source):
		v = source.get("emits_light")
	if v == null:
		return 0.0
	if v is bool:
		return 1.0 if v else 0.0
	if v is String and not v.is_valid_float():
		return 0.0
	return clampf(float(v), 0.0, 1.0)

static func light_color(traits) -> Color:
	if not (traits is Dictionary):
		return LIGHT_DEFAULT_COLOR
	var best_tier := 0
	var best := LIGHT_DEFAULT_COLOR
	for k in traits:
		var key := str(k).to_lower()
		if not LIGHT_TRAIT_COLORS.has(key) or traits[k] == null:
			continue
		var tier := int(traits[k])
		if tier > best_tier:
			best_tier = tier
			best = LIGHT_TRAIT_COLORS[key]
	return best

## An explicit light colour as a Color: an Items.json "light_color" or a
## Maps.json lights[].color ([r, g, b] numbers 0..1; a 4th is ignored), or a
## Color. null when absent or malformed, so the caller falls back.
static func explicit_light_color(v) -> Variant:
	if v is Color:
		return v
	if not (v is Array) or (v as Array).size() < 3:
		return null
	var a: Array = v
	for i in 3:
		if not (a[i] is float or a[i] is int):
			return null
	return Color(clampf(float(a[0]), 0.0, 1.0), clampf(float(a[1]), 0.0, 1.0), clampf(float(a[2]), 0.0, 1.0))

static func light_radius_px(level: float) -> float:
	return LIGHT_MIN_RADIUS_PX + LIGHT_RADIUS_PER_LEVEL_PX * clampf(level, 0.0, 1.0)

## A shadowed PointLight2D named "EmittedLight" for a light level of 0..1.
## Every structure occluder carries a LIGHT_SHADOW_MASK bit (bit 1 on flat
## maps, bit 2 on relief maps), so it stops at walls; cliffs don't shadow it.
## color: an explicit colour (explicit_light_color: an Items.json
## "light_color"); null or malformed = the traits' colour.
static func make_light(level: float, traits, color = null) -> PointLight2D:
	level = clampf(level, 0.0, 1.0)
	var light := PointLight2D.new()
	light.name = "EmittedLight"
	light.texture = _light_texture()
	light.texture_scale = 2.0 * light_radius_px(level) / float(LIGHT_TEX_SIZE)
	light.energy = LIGHT_MIN_ENERGY + LIGHT_ENERGY_PER_LEVEL * level
	var explicit: Variant = explicit_light_color(color)
	if explicit is Color:
		light.color = explicit
	else:
		light.color = light_color(traits)
	light.shadow_enabled = true
	light.shadow_item_cull_mask = CollisionLayers.LIGHT_SHADOW_MASK
	# an ordinary light: it lights what the sight cones may not (P3-B's crowns)
	light.range_item_cull_mask = CollisionLayers.LAMP_RANGE_MASK
	return light

static func _light_texture() -> Texture2D:
	if _light_tex == null:
		var g := Gradient.new()
		g.set_color(0, Color(1, 1, 1, 1))
		g.set_color(1, Color(1, 1, 1, 0))
		var t := GradientTexture2D.new()
		t.gradient = g
		t.width = LIGHT_TEX_SIZE
		t.height = LIGHT_TEX_SIZE
		t.fill = GradientTexture2D.FILL_RADIAL
		t.fill_from = Vector2(0.5, 0.5)
		t.fill_to = Vector2(1.0, 0.5)
		_light_tex = t
	return _light_tex

## Short effect names while worn, e.g. ["Shrouded", "+10 inventory slots",
## "Glows"]. Used by the equip notices; tooltips use worn_lines.
static func describe_worn(item_data: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	if not is_wearable(item_data):
		return out
	for cid in condition_ids_for(item_data):
		out.append(_condition_name(cid))
	var slots := container_slots(item_data)
	if slots > 0:
		out.append("+%d inventory slots" % slots)
	if light_level(item_data) > 0.0:
		out.append("Glows")
	return out

## Tooltip lines for an item dict: what a wearable does while worn (each
## granted condition with what it does, extra slots, light radius), or for a
## hand-slot dict what it does while held. Empty for items with none of these.
static func worn_lines(item_data: Dictionary) -> PackedStringArray:
	if is_hand_ghost(item_data):
		return held_lines(item_data)
	var out := PackedStringArray()
	if not is_wearable(item_data):
		return out
	for cid in condition_ids_for(item_data):
		out.append("While worn: " + _condition_line(cid))
	var slots := container_slots(item_data)
	if slots > 0:
		out.append("While worn: +%d inventory slots" % slots)
	var lv := light_level(item_data)
	if lv > 0.0:
		out.append("While worn: glows (light radius %.1f tiles)" % (light_radius_px(lv) / TILE_PX))
	return out

## Tooltip lines for a weapon (a WeaponShape or its item dict): the
## conditions it gives its wielder while drawn, and its light.
static func held_lines(weapon) -> PackedStringArray:
	var out := PackedStringArray()
	if weapon == null:
		return out
	for cid in condition_ids_for(weapon):
		out.append("While held: " + _condition_line(cid))
	var lv := light_level(weapon)
	if lv > 0.0:
		out.append("While held: glows (light radius %.1f tiles)" % (light_radius_px(lv) / TILE_PX))
	return out

static func _condition_line(cid: String) -> String:
	var tmpl = ConditionManager.condition_registry.get(cid)
	var desc: String = tmpl.description if tmpl != null else ""
	return _condition_name(cid) + ((" - " + desc) if desc != "" else "")

static func _condition_name(cid: String) -> String:
	var tmpl = ConditionManager.condition_registry.get(cid)
	if tmpl != null and tmpl.display_name != "":
		return tmpl.display_name
	return cid.capitalize()
