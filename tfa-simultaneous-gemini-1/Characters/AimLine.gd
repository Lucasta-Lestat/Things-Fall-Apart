class_name AimLine
extends Node2D

## Reusable aim preview: a direction-flowing ribbon from the actor to where the
## action will actually land. Owner instantiates it once, adds it as a child,
## then calls show_aim / update_aim / hide_aim as targeting state changes.
##
## Three callers, one look, distinguished only by `default_color` — throw (white),
## dash (amber), bite (red). Set it before show_aim; the ribbon derives its whole
## palette from that hue and treats the alpha as the intended overall opacity.
##
## `truncate_mask` (a physics layer bitmask) raycasts from `from` to `to` and
## stops the ribbon at the first hit, giving the player a "you'll bump into this"
## preview. Pass 0 to skip the raycast.
## `max_range` clamps the length to that distance even if the cursor is further;
## pass 0.0 for no clamp. When both are non-zero, max_range is applied first and
## the raycast scans the clamped segment.
## On relief maps a non-zero `truncate_mask` also stops the ribbon at the first
## tile whose terrain rises above the eye line (a cliff, a terrace brow, cave
## rock), the same terrain test sight and hearing use, before the physics ray.
##
## `compute_aim` and `draw_ribbon` are exposed as statics so consumers that don't
## own an AimLine instance — PathDrawer previewing an already-queued dash — get
## identical math AND identical pixels without duplicating either.
##
## Was a Line2D. A flat 1.5px segment vanished over pale stone, said nothing about
## which way the lunge went, and gave no hint that a wall had cut it short.

# Above floors (-4) and structures (-3), below the character root (5) — same
# ground layer as the movement path, so a trajectory never slices a body in half.
const Z_GROUND := 2

# Two passes: dark shadow, bright core. Holds contrast on light and dark ground.
const SHADOW_COLOR := Color(0.02, 0.03, 0.06)
const SHADOW_WIDTH := 5.0
const CORE_WIDTH := 2.0

# Chevrons drifting toward the endpoint. Much faster and tighter than the walking
# path's flow — this is a lunge, and the read should be "snap", not "stroll".
const FLOW_SPACING := 24.0     # px between chevrons
const FLOW_SPEED := 105.0      # px/sec of drift
const FLOW_SIZE := 5.0
const FLOW_WIDTH := 1.8

# Landing reticle at the far end.
const RETICLE_RADIUS := 7.0
const RETICLE_WIDTH := 1.8
# When a wall cut the aim short, the reticle becomes an impact bracket in this
# hue instead — the endpoint is no longer where you asked to go, and that is
# worth saying loudly.
const BLOCKED_COLOR := Color(0.97, 0.42, 0.28)
# A terrain stop lands this far short of the blocking tile's edge, so the
# endpoint stays on the last clear tile (world_to_map floors onto the boundary).
const TERRAIN_STOP_BACKOFF := 1.0

var default_color: Color = Color(1, 1, 1, 0.5)
## Retained so existing callers that poke it keep parsing; the ribbon uses
## CORE_WIDTH/SHADOW_WIDTH.
var width: float = 1.5

var _from: Vector2 = Vector2.ZERO
var _to: Vector2 = Vector2.ZERO
var _blocked: bool = false
var _phase: float = 0.0


func _init() -> void:
	z_index = Z_GROUND
	z_as_relative = false
	top_level = true
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false


func _process(delta: float) -> void:
	if not visible:
		return
	_phase = fposmod(_phase + FLOW_SPEED * delta, FLOW_SPACING)
	queue_redraw()


func _draw() -> void:
	draw_ribbon(self, _from, _to, default_color, _phase, _blocked)


func show_aim(from: Vector2, to: Vector2, truncate_mask: int = 0, max_range: float = 0.0) -> void:
	visible = true
	update_aim(from, to, truncate_mask, max_range)


func update_aim(from: Vector2, to: Vector2, truncate_mask: int = 0, max_range: float = 0.0) -> void:
	if not visible:
		return
	var world: World2D = get_world_2d() if is_inside_tree() else null
	var aim := compute_aim(world, from, to, truncate_mask, max_range)
	_from = from
	_to = aim["endpoint"]
	_blocked = aim["blocked"]
	queue_redraw()


func hide_aim() -> void:
	visible = false
	_from = Vector2.ZERO
	_to = Vector2.ZERO
	_blocked = false
	queue_redraw()


## Where the aim actually ends, and whether something stopped it short.
## `blocked` means a body on `truncate_mask` (or, on relief maps, the terrain)
## interrupted the segment — NOT that the cursor was merely out of range, which
## is an ordinary clamp.
static func compute_aim(world: World2D, from: Vector2, to: Vector2, truncate_mask: int = 0, max_range: float = 0.0) -> Dictionary:
	var endpoint := to
	# Clamp first so the raycast only scans the segment the ribbon actually covers.
	if max_range > 0.0:
		var to_target := to - from
		var distance := to_target.length()
		if distance > max_range:
			endpoint = from + to_target / distance * max_range
	var blocked := false
	# Terrain first (relief maps): one tile walk over the clamped segment, eye
	# to eye on the ground under each end, roofs left to the physics ray (their
	# walls carry bodies). The physics ray then scans only what is left of it.
	if truncate_mask != 0 and GridManager.relief_los:
		var h0: float = GridManager.effective_elev(GridManager.world_to_map(from)) + GridManager.EYE_HEIGHT_STORIES
		var h1: float = GridManager.effective_elev(GridManager.world_to_map(endpoint)) + GridManager.EYE_HEIGHT_STORIES
		var cut: float = GridManager.terrain_line_hit(from, endpoint, h0, h1, false)
		if cut >= 0.0:
			var seg := endpoint - from
			endpoint = from + seg * cut - seg.normalized() * TERRAIN_STOP_BACKOFF
			blocked = true
	if truncate_mask != 0 and world:
		var space := world.direct_space_state
		if space:
			var params := PhysicsRayQueryParameters2D.create(from, endpoint, truncate_mask)
			params.collide_with_areas = false
			params.collide_with_bodies = true
			var result := space.intersect_ray(params)
			if not result.is_empty():
				var hit = result.get("position", null)
				if hit != null:
					endpoint = hit
					blocked = true
	return {"endpoint": endpoint, "blocked": blocked}


## Back-compat thin wrapper — endpoint only.
static func compute_endpoint(world: World2D, from: Vector2, to: Vector2, truncate_mask: int = 0, max_range: float = 0.0) -> Vector2:
	var aim := compute_aim(world, from, to, truncate_mask, max_range)
	var endpoint: Vector2 = aim["endpoint"]
	return endpoint


## Paint the ribbon onto any canvas. `phase` animates the chevron drift; pass a
## value that advances with time (see _process) or 0.0 for a static preview.
static func draw_ribbon(canvas: CanvasItem, from: Vector2, to: Vector2, color: Color, phase: float, blocked: bool) -> void:
	var delta := to - from
	var length := delta.length()
	if length < 2.0:
		return
	var dir := delta / length

	# The caller's alpha is the intended overall opacity; build both passes from it
	# so throw/dash/bite keep their existing relative weights.
	var op := color.a
	var shadow := SHADOW_COLOR
	shadow.a = minf(1.0, 0.85 * op)
	var core := Color(color.r, color.g, color.b, minf(1.0, 1.45 * op))

	canvas.draw_line(from, to, shadow, SHADOW_WIDTH, true)
	canvas.draw_line(from, to, core, CORE_WIDTH, true)

	# Launch tick: a short bar across the origin, so the ribbon reads as leaving
	# the actor rather than merely passing through them.
	var perp := dir.rotated(PI / 2.0)
	canvas.draw_line(from - perp * 3.5, from + perp * 3.5, core, FLOW_WIDTH, true)

	_draw_flow(canvas, from, dir, length, core, phase)

	var tip_color := core
	if blocked:
		tip_color = Color(BLOCKED_COLOR.r, BLOCKED_COLOR.g, BLOCKED_COLOR.b, minf(1.0, 1.45 * op))
	_draw_reticle(canvas, to, dir, tip_color, blocked)


static func _draw_flow(canvas: CanvasItem, from: Vector2, dir: Vector2, length: float, color: Color, phase: float) -> void:
	if length < FLOW_SPACING:
		return
	var back := -dir * FLOW_SIZE
	var a := back.rotated(0.6)
	var b := back.rotated(-0.6)
	var mark := fposmod(phase, FLOW_SPACING)
	# Stop short of the reticle so the chevrons don't pile into it.
	var limit := length - RETICLE_RADIUS * 1.6
	while mark < limit:
		if mark > FLOW_SIZE:
			var p := from + dir * mark
			canvas.draw_line(p, p + a, color, FLOW_WIDTH, true)
			canvas.draw_line(p, p + b, color, FLOW_WIDTH, true)
		mark += FLOW_SPACING


static func _draw_reticle(canvas: CanvasItem, at: Vector2, dir: Vector2, color: Color, blocked: bool) -> void:
	if blocked:
		# Impact bracket: a bar across the obstruction plus two swept-back ticks.
		var perp := dir.rotated(PI / 2.0)
		canvas.draw_line(at - perp * RETICLE_RADIUS, at + perp * RETICLE_RADIUS, color, RETICLE_WIDTH + 0.6, true)
		var splay := -dir * RETICLE_RADIUS * 0.8
		canvas.draw_line(at, at + splay.rotated(0.9), color, RETICLE_WIDTH, true)
		canvas.draw_line(at, at + splay.rotated(-0.9), color, RETICLE_WIDTH, true)
		return
	# Clean landing: ring plus centre dot.
	canvas.draw_arc(at, RETICLE_RADIUS, 0, TAU, 20, color, RETICLE_WIDTH, true)
	canvas.draw_circle(at, RETICLE_RADIUS * 0.32, color)
