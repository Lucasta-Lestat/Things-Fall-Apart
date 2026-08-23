class_name RoofLayer
extends Node2D
# DF-style roof cover for structured maps, drawn from GridManager.roof_elevations.
# The exported ground PNG is ROOFLESS with interiors painted in (the terrain
# editor strips its own roof render on export), so HIDING this node IS the
# interior/ground view — no cutaway shader needed. Tier-2 art: flat palette
# quads with a stable per-tile hash tint, tile seams, and an eave shadow on
# unroofed borders; replace with a painted <id>_roofs.png export pass from the
# terrain editor (C:\dev\Terrain Generation) when that lands.
#
# Parent under MapLoader: its children are freed on map unload, so teardown
# across warps is automatic. Game owns visibility via roof_view.

const ROOF_Z := 120          # above characters (5), VFX (<=50), overhead widgets (~115)
const TILE_TERRACOTTA := Color(0.52, 0.26, 0.18)
const TILE_SLATE := Color(0.35, 0.37, 0.42)   # tall roofs read as slate


func _ready() -> void:
	z_as_relative = false
	z_index = ROOF_Z
	light_mask = 0           # sight-cone PointLight2Ds must not paint the roof
	queue_redraw()


func _draw() -> void:
	var ts := float(GridManager.TILE_SIZE)
	var half := Vector2(ts, ts) * 0.5
	for t in GridManager.roof_elevations:
		var p: Vector2 = GridManager.map_to_world(t) - half
		var h: float = float(GridManager.roof_elevations[t])
		# stable per-tile hash -> tone variation reads as shingling
		var n: float = float(((int(t.x) * 73856093) ^ (int(t.y) * 19349663)) & 0xFFFF) / 65535.0
		var base := TILE_SLATE if h >= 2.5 else TILE_TERRACOTTA
		var c := base.darkened(n * 0.18)
		draw_rect(Rect2(p, Vector2(ts, ts)), c)
		# tile seams (top/left) keep the field from reading as one flat slab
		draw_rect(Rect2(p, Vector2(ts, 2.0)), c.darkened(0.3))
		draw_rect(Rect2(p, Vector2(2.0, ts)), c.darkened(0.3))
		# eave shadow along any edge that borders unroofed ground
		var edge := c.darkened(0.55)
		if not GridManager.roof_elevations.has(t + Vector2i(0, -1)):
			draw_rect(Rect2(p, Vector2(ts, 5.0)), edge)
		if not GridManager.roof_elevations.has(t + Vector2i(0, 1)):
			draw_rect(Rect2(p + Vector2(0.0, ts - 5.0), Vector2(ts, 5.0)), edge)
		if not GridManager.roof_elevations.has(t + Vector2i(-1, 0)):
			draw_rect(Rect2(p, Vector2(5.0, ts)), edge)
		if not GridManager.roof_elevations.has(t + Vector2i(1, 0)):
			draw_rect(Rect2(p + Vector2(ts - 5.0, 0.0), Vector2(5.0, ts)), edge)
