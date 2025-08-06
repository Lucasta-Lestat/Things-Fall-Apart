# Add this script to your Game scene as a temporary test
# res://ClickTest.gd
extends Node2D

func _ready():
	print("DEBUG: ClickTest ready, waiting 2 seconds then enabling input")
	await get_tree().create_timer(2.0).timeout
	set_process_input(true)
	print("DEBUG: ClickTest input enabled - try clicking on characters")

func _input(event: InputEvent):
	return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		print("DEBUG: ClickTest detected mouse click at screen pos: ", event.position)
		
		# Get world position
		var cam = get_viewport().get_camera_2d()
		var world_pos = cam.get_global_mouse_position() if cam else event.position
		print("DEBUG: World position: ", world_pos)
		
		# Try to find what's at this position
		var space_state = get_world_2d().direct_space_state
		var query = PhysicsPointQueryParameters2D.new()
		query.position = world_pos
		query.collision_mask = 0xFFFFFFFF  # Check all layers
		
		var results = space_state.intersect_point(query)
		print("DEBUG: Found ", results.size(), " physics bodies at this position:")
		
		for result in results:
			var body = result.collider
			print("  - Body: ", body.name, " (", body.get_class(), ")")
			if body.has_method("get_parent"):
				var parent = body.get_parent()
				print("    Parent: ", parent.name if parent else "none", " (", parent.get_class() if parent else "none", ")")
				if parent is CombatCharacter:
					print("    This is a CombatCharacter: ", parent.character_name)
		
		# Also check for ClickArea specifically
		print("DEBUG: Looking for characters in scene...")
		var characters_container = get_node_or_null("../CharactersContainer")
		if characters_container:
			for child in characters_container.get_children():
				if child is CombatCharacter:
					print("  Character: ", child.character_name, " at ", child.global_position)
					var click_area = child.get_node_or_null("ClickArea")
					if click_area:
						print("    Has ClickArea: ", click_area.name)
						var collision = click_area.get_node_or_null("CollisionShape2D")
						if collision and collision.shape:
							print("    ClickArea collision shape: ", collision.shape.get_class())
							if collision.shape is RectangleShape2D:
								print("    ClickArea size: ", collision.shape.size)
		else:
			print("DEBUG: No CharactersContainer found")
		
		get_viewport().set_input_as_handled()
