# res://Items/RunRenderer.gd
# Draws a RUN item (Items/RunLayout.gd): the 3-slice strip at its spawn length
# and width, then its drawn-only decor in the same local frame -- cloth runners
# (strip decor through that id's own run atlas), food sprites (Items.json art at
# base_width * scale px, the Item.scale_sprite rule) and the built-in
# procedural _plate / _cup / _candle. Decor is paint, never items: no loot, no
# theft, no extra LOS rays. Child of the Item; the Item's sprite is hidden.
class_name RunRenderer
extends Node2D

static var _tex_cache: Dictionary = {}   # res path -> Texture2D (null = missing art)

var meta: Dictionary = {}
var run: Dictionary = {}
var length: float = 0.0
var width: float = 0.0
var _tex: Texture2D = null
var _tiles: Array = []
var _strips: Array = []     # [{tex, tiles, at, rot, tint}]
var _sprites: Array = []    # [{tex, at, rot, k}]
var _builtins: Array = []   # [{id, at, rot, scale, v}] (candles sorted last)


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
	var cands: Array = []
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
			var b := {"id": did, "at": at, "rot": rot, "scale": float(d.get("scale", 1.0)), "v": int(d.get("v", 0))}
			if did == "_candle":
				cands.append(b)
			else:
				_builtins.append(b)
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
		_sprites.append({"tex": tex, "at": at, "rot": rot, "k": bw / maxf(1.0, float(tex.get_width()))})
	_builtins.append_array(cands)
	queue_redraw()


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
	for s in _sprites:
		var tex: Texture2D = s["tex"]
		var k := float(s["k"])
		draw_set_transform(s["at"], float(s["rot"]), Vector2(k, k))
		draw_texture(tex, -tex.get_size() * 0.5)
	draw_set_transform_matrix(Transform2D.IDENTITY)
	var wr := global_rotation
	for b in _builtins:
		RunLayout.draw_builtin(self, String(b["id"]), b["at"], float(b["rot"]), float(b["scale"]), int(b["v"]), wr)
