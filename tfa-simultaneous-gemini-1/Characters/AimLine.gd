class_name AimLine
extends Line2D

## Reusable aim-line preview. Owner instantiates it once, adds it as a child,
## then calls show_aim / update_aim / hide_aim as targeting state changes.
##
## The optional `truncate_mask` (a physics layer bitmask) raycasts from
## `from` to `to` and stops the rendered line at the first hit, giving the
## player a "you'll bump into this" preview. Pass 0 to draw the full line.
##
## Visual defaults (color, width, z_index) are set in _init for sensible
## out-of-the-box behavior; override on the owner side after construction.

func _init() -> void:
	width = 1.5
	default_color = Color(1, 1, 1, 0.5)
	z_index = 45
	top_level = true
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false


func show_aim(from: Vector2, to: Vector2, truncate_mask: int = 0) -> void:
	visible = true
	update_aim(from, to, truncate_mask)


func update_aim(from: Vector2, to: Vector2, truncate_mask: int = 0) -> void:
	if not visible:
		return
	var endpoint := to
	if truncate_mask != 0 and is_inside_tree():
		var space := get_world_2d().direct_space_state
		if space:
			var params := PhysicsRayQueryParameters2D.create(from, to, truncate_mask)
			params.collide_with_areas = false
			params.collide_with_bodies = true
			var result := space.intersect_ray(params)
			if not result.is_empty():
				endpoint = result.get("position", to)
	clear_points()
	add_point(from)
	add_point(endpoint)


func hide_aim() -> void:
	visible = false
	clear_points()
