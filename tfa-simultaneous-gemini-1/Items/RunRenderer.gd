# res://Items/RunRenderer.gd
# Draws a RUN item (Items/RunLayout.gd): the 3-slice strip at its spawn length
# and width, then its drawn-only decor in the same local frame -- cloth runners
# (strip decor through that id's own run atlas), item sprites (Items.json art at
# base_width * scale px, the Item.scale_sprite rule: food, and under export
# contract 2 the plate / cup / candle items) and the built-in procedural
# _plate / _cup / _candle (contract 1). Sprites and built-ins share one draw
# order: RunLayout.decor_layer, then list order. Decor is paint, never items:
# no loot, no theft, no extra LOS rays. Decor whose item emits_light (the
# candle) gets a small shadowed light, capped per run (RunLayout.lit_decor)
# and per map (DECOR_LIGHTS_MAP_MAX). Child of the Item; the Item's sprite is
# hidden.
class_name RunRenderer
extends Node2D

const EquipmentEffects = preload("res://Items/equipment_effects.gd")
## Decor lights across every run on the map; past it a candle is drawn unlit.
## It also bounds their shadow passes (each candle casts one).
const DECOR_LIGHTS_MAP_MAX := 24

static var _tex_cache: Dictionary = {}   # res path -> Texture2D (null = missing art)
static var _decor_lights: Array = []     # a WeakRef per decor light made (pruned when counted)
static var _warned_light_cap := false

var meta: Dictionary = {}
var run: Dictionary = {}
var length: float = 0.0
var width: float = 0.0
var _tex: Texture2D = null
var _tiles: Array = []
var _strips: Array = []     # [{tex, tiles, at, rot, tint}]
var _sprites: Array = []    # [{tex, at, rot, k, layer}]
var _builtins: Array = []   # [{id, at, rot, scale, v, layer}]
var _draw_list: Array = []  # _sprites + _builtins by layer, then decor order
var _lights: Array = []     # this run's decor PointLight2Ds


static func texture_for(path: String) -> Texture2D:
	if _tex_cache.has(path):
		return _tex_cache[path]
	var t: Texture2D = null
	if path != "" and ResourceLoader.exists(path):
		t = load(path) as Texture2D
	_tex_cache[path] = t
	return t


# Item data for a decor id (same lookup order as Item._lookup_item_data_by_id).
static func _item_def(item_id: String) -> Dictionary:
	if ItemDatabase == null:
		return {}
	if ItemDatabase.items.has(item_id):
		return ItemDatabase.items[item_id]
	return {}


# the decor's world-fixed shading reads global_rotation: redraw when the
# Item's transform settles (AnimatableBody2D applies it on a physics frame)
func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED:
		queue_redraw()


func setup(p_meta: Dictionary, p_run: Dictionary) -> void:
	set_notify_transform(true)
	meta = p_meta
	run = p_run
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	length = float(run.get("length", 0.0))
	width = float(run.get("width", -1.0))
	if width <= 0.0:
		width = float(meta.get("across", 40.0))
	_tex = texture_for(String(meta.get("atlas", "")))
	_tiles = RunLayout.tiles(length, width, meta, int(run.get("caps", 3)), int(run.get("seed", 0)))
	_strips.clear()
	_sprites.clear()
	_builtins.clear()
	_draw_list.clear()
	for l in _lights:
		if is_instance_valid(l):
			(l as Node).queue_free()
	_lights.clear()
	var by_layer: Array = [[], [], [], []]
	var warned := false
	var decor: Array = run.get("decor", [])
	for dv in decor:
		if not (dv is Dictionary):
			continue
		var d: Dictionary = dv
		var did := String(d.get("id", ""))
		var aa: Array = d.get("at", [0.0, 0.0])
		var at := Vector2(float(aa[0]), float(aa[1]))
		var rot := float(d.get("rot", 0.0))
		if RunLayout.BUILTIN_DECOR.has(did):
			var b := {"id": did, "at": at, "rot": rot, "scale": float(d.get("scale", 1.0)),
				"v": int(d.get("v", 0)), "layer": RunLayout.decor_layer(did)}
			_builtins.append(b)
			by_layer[int(b["layer"])].append(b)
			continue
		var idef: Dictionary = _item_def(did)
		if idef.is_empty():
			if not warned:
				push_warning("RunRenderer: decor id '%s' not in Items.json (skipped)" % did)
				warned = true
			continue
		if d.has("length"):
			var smv: Variant = idef.get("run")
			if not (smv is Dictionary):
				continue
			var sm: Dictionary = smv
			var stex := texture_for(String(sm.get("atlas", "")))
			if stex == null:
				continue
			var tint := Color.WHITE
			var tv: Variant = d.get("tint")
			if tv is Array and (tv as Array).size() >= 3:
				var ta: Array = tv
				tint = Color(float(ta[0]), float(ta[1]), float(ta[2]), float(ta[3]) if ta.size() > 3 else 1.0)
			_strips.append({"tex": stex, "at": at, "rot": rot, "tint": tint,
				"tiles": RunLayout.tiles(float(d["length"]), float(d.get("width", sm.get("across", 20.0))),
					sm, int(d.get("caps", 3)), int(d.get("seed", 0)))})
			continue
		var tex := texture_for(String(idef.get("sprite_path", "")))
		if tex == null:
			continue
		var bw := float(idef.get("base_width", 16.0)) * float(d.get("scale", 1.0))
		var sp := {"tex": tex, "at": at, "rot": rot, "k": bw / maxf(1.0, float(tex.get_width())),
			"layer": RunLayout.decor_layer(did, idef)}
		_sprites.append(sp)
		by_layer[int(sp["layer"])].append(sp)
	# stable by layer: plates (0) < food sprites (1) < cups (2) < candles (3)
	_draw_list = by_layer[0] + by_layer[1] + by_layer[2] + by_layer[3]
	_add_decor_lights(decor)
	queue_redraw()


# Candles that light: RunLayout.lit_decor picks at most RUN_LIGHTS_MAX of the
# decor whose item emits_light, and DECOR_LIGHTS_MAP_MAX bounds them across the
# map. Shadowed like every item light (make_light: LIGHT_SHADOW_MASK): a
# candle's ~93 px pool (level 0.15) reaches a tile and a half, so a table
# against a wall used to light the room behind it, floor the party cannot
# see. A candle never stands inside a wall (its table would), so its own
# shadow never traps it. Children of this renderer, so they turn with the run.
func _add_decor_lights(decor: Array) -> void:
	var levels: Dictionary = {}
	for dv in decor:
		if not (dv is Dictionary):
			continue
		var did := String((dv as Dictionary).get("id", ""))
		if did == "" or levels.has(did) or RunLayout.BUILTIN_DECOR.has(did):
			continue
		levels[did] = EquipmentEffects.light_level(_item_def(did))
	var lit: Array = RunLayout.lit_decor(decor, levels)
	if lit.is_empty():
		return
	var live := _live_decor_lights()
	for i in lit:
		if live >= DECOR_LIGHTS_MAP_MAX:
			if not _warned_light_cap:
				_warned_light_cap = true
				push_warning("RunRenderer: more than %d decor lights on the map; the rest stay unlit" % DECOR_LIGHTS_MAP_MAX)
			return
		var d: Dictionary = decor[i]
		var did := String(d.get("id", ""))
		var idef: Dictionary = _item_def(did)
		var aa: Array = d.get("at", [0.0, 0.0])
		var l: PointLight2D = EquipmentEffects.make_light(float(levels[did]), idef.get("traits", {}),
			idef.get("light_color"))
		l.name = "DecorLight%d" % _lights.size()
		l.position = Vector2(float(aa[0]), float(aa[1]))
		add_child(l)
		_lights.append(l)
		_decor_lights.append(weakref(l))
		live += 1


# Decor lights alive on the map: freed ones drop out of the registry, and one
# whose run is being torn down (an ancestor queued for deletion: the warp
# sweep) no longer counts.
static func _live_decor_lights() -> int:
	var keep: Array = []
	var n := 0
	for w in _decor_lights:
		var o: Variant = (w as WeakRef).get_ref()
		if o == null:
			continue
		keep.append(w)
		var node: Node = o
		var dying := false
		while node != null:
			if node.is_queued_for_deletion():
				dying = true
				break
			node = node.get_parent()
		if not dying:
			n += 1
	_decor_lights = keep
	return n


func _draw() -> void:
	var sh := float(meta.get("shadow", 0.0))
	if sh > 0.0:
		# optional hard contact shadow, world-fixed (down-right) at any rotation
		var off := Vector2(2.0, 3.0).rotated(-global_rotation)
		draw_rect(Rect2(Vector2(-length * 0.5, -width * 0.5) + off, Vector2(length, width)),
			Color(0.0, 0.0, 0.0, sh))
	if _tex != null:
		for t in _tiles:
			draw_texture_rect_region(_tex, t["dst"], t["src"], Color.WHITE, false, true)
	for s in _strips:
		draw_set_transform(s["at"], float(s["rot"]))
		for t in s["tiles"]:
			draw_texture_rect_region(s["tex"], t["dst"], t["src"], s["tint"], false, true)
	draw_set_transform_matrix(Transform2D.IDENTITY)
	var wr := global_rotation
	for e in _draw_list:
		var dd: Dictionary = e
		if dd.has("tex"):
			var tex: Texture2D = dd["tex"]
			var k := float(dd["k"])
			draw_set_transform(dd["at"], float(dd["rot"]), Vector2(k, k))
			draw_texture(tex, -tex.get_size() * 0.5)
			draw_set_transform_matrix(Transform2D.IDENTITY)
		else:
			RunLayout.draw_builtin(self, String(dd["id"]), dd["at"], float(dd["rot"]), float(dd["scale"]), int(dd["v"]), wr)
