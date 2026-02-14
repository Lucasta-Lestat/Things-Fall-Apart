@tool
extends EditorScript

func _run():
	# --- Config ---
	var size = 1024 
	var center = Vector2(size / 2.0, size / 2.0)
	var internal_radius = size / 2.0 
	var cone_angle_deg = 150
	var file_path = "res://sight_cone_smooth.png"
	
	# --- Setup ---
	var image = Image.create(size, size, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0)) # Transparent background
	
	var half_angle_rad = deg_to_rad(cone_angle_deg / 2.0)
	
	# --- Generation ---
	for y in range(size):
		for x in range(size):
			var pixel_pos = Vector2(x, y)
			var rel_pos = pixel_pos - center
			var dist = rel_pos.length()
			
			# 1. Edge Cleanup (Outer Ring AA)
			# Soften the outer rim of the circle so it's not jagged
			var dist_alpha = 1.0
			if dist > internal_radius - 2.0:
				dist_alpha = clamp((internal_radius - dist) / 2.0, 0.0, 1.0)
			
			if dist > internal_radius:
				continue
				
			# 2. Angle Cleanup (Cone Edges AA)
			var angle = rel_pos.angle()
			var angle_diff = half_angle_rad - abs(angle)
			
			# We determine how "wide" one pixel is in radians at this distance
			# This keeps the edge sharpness consistent from the center to the tip
			var pixel_width_rad = 1.5 / max(dist, 1.0) 
			
			# Smoothstep the alpha based on distance from the edge angle
			var angle_alpha = clamp(angle_diff / pixel_width_rad, 0.0, 1.0)
			
			# 3. Combine & Set
			# If we are inside the cone, set the pixel
			if angle_alpha > 0.0:
				var final_alpha = dist_alpha * angle_alpha
				# You can change Color.WHITE to something else, but white is best for lights
				image.set_pixel(x, y, Color(1, 1, 1, final_alpha))

	# --- Save ---
	image.save_png(file_path)
	print("Saved Smooth Cone to ", file_path)
	get_editor_interface().get_resource_filesystem().scan()
