class_name AimLine
extends Line2D

## Reusable aim-line preview. Owner instantiates it once, adds it as a child,
## then calls show_aim / update_aim / hide_aim as targeting state changes.
##
## `truncate_mask` (a physics layer bitmask) raycasts from `from` to `to` and
## stops the rendered line at the first hit, giving the player a "you'll bump
## into this" preview. Pass 0 to skip the raycast.
## `max_range` clamps the line length to that distance even if the cursor is
## further; pass 0.0 for no clamp. When both are non-zero, max_range is
## applied first and the raycast scans the clamped segment.
##
## `compute_endpoint` is exposed as a static helper so consumers that don't
## use a Line2D instance (e.g. PathDrawer's _draw()) can reuse the same math
## without duplicating it.

func _init() -> void:
	width = 1.5
	default_color = Color(1, 1, 1, 0.5)
	z_index = 45
	top_level = true
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false


func show_aim(from: Vector2, to: Vector2, truncate_mask: int = 0, max_range: float = 0.0) -> void:
	visible = true
	update_aim(from, to, truncate_mask, max_range)


func update_aim(from: Vector2, to: Vector2, truncate_mask: int = 0, max_range: float = 0.0) -> void:
	if not visible:
		return
	var world: World2D = get_world_2d() if is_inside_tree() else null
	var endpoint := compute_endpoint(world, from, to, truncate_mask, max_range)
	clear_points()
	add_point(from)
	add_point(endpoint)


func hide_aim() -> void:
	visible = false
	clear_points()


static func compute_endpoint(world: World2D, from: Vector2, to: Vector2, truncate_mask: int = 0, max_range: float = 0.0) -> Vector2:
	var endpoint := to
	# Clamp first so the raycast only scans the segment the line actually covers.
	if max_range > 0.0:
		var to_target := to - from
		var distance := to_target.length()
		if distance > max_range:
			endpoint = from + to_target / distance * max_range
	if truncate_mask != 0 and world:
		var space := world.direct_space_state
		if space:
			var params := PhysicsRayQueryParameters2D.create(from, endpoint, truncate_mask)
			params.collide_with_areas = false
			params.collide_with_bodies = true
			var result := space.intersect_ray(params)
			if not result.is_empty():
				endpoint = result.get("position", endpoint)
	return endpoint

