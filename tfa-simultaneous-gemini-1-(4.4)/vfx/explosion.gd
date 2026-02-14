extends GPUParticles2D

@onready var light = $PointLight2D 

func explode(size_scale: float = 1.0):
	# --- PARTICLE LOGIC  ---
	var mat = process_material.duplicate() as ParticleProcessMaterial
	process_material = mat
	mat.scale_min *= size_scale
	mat.scale_max *= size_scale
	mat.initial_velocity_min *= size_scale
	mat.initial_velocity_max *= size_scale
	amount = int(amount * (size_scale * size_scale))
	lifetime *= sqrt(size_scale)
	
	# --- LIGHTING LOGIC  ---
	# 1. Scale the light's physical size
	# We multiply by an arbitrary base (e.g., 3.0) to ensure the light 
	# reaches further than the fire particles themselves.
	light.texture_scale = size_scale * 3.0
	
	# 2. Set initial brightness
	# Larger explosions are usually brighter.
	var start_energy = 2.0 * size_scale
	light.energy = start_energy
	
	# 3. Animate the light fading out
	var tween = create_tween()
	
	# "TRANS_CIRC" and "EASE_OUT" creates a realistic "Flash" curve.
	# It drops intensity quickly at first, then slowly fades the rest.
	# We fade to 0 over the duration of the particle's lifetime.
	tween.tween_property(light, "energy", 0.0, lifetime).set_trans(Tween.TRANS_CIRC).set_ease(Tween.EASE_OUT)
	
	# --- START ---
	emitting = true
	await finished
	queue_free()
