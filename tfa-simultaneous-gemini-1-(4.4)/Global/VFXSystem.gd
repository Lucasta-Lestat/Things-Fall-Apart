# VFXSystem.gd - Autoload Singleton
extends Node

class_name VFXSystem

# Effect node pool for performance
var effect_pool: Array = []
var active_effects: Array = []
var max_pool_size: int = 50

# Shader cache
var shader_cache: Dictionary = {}

# Light2D settings
var light_texture: Texture2D

func _ready():
	# Create a gradient texture for lights
	var gradient = GradientTexture2D.new()
	gradient.gradient = Gradient.new()
	gradient.gradient.set_color(0, Color.WHITE)
	gradient.gradient.set_color(1, Color(1, 1, 1, 0))
	gradient.width = 256
	gradient.height = 256
	gradient.fill = GradientTexture2D.FILL_RADIAL
	gradient.fill_from = Vector2(0.5, 0.5)
	gradient.fill_to = Vector2(1.0, 0.5)
	light_texture = gradient
	
	# Pre-warm the pool
	for i in range(10):
		var effect_node = _create_effect_node()
		effect_node.z_index = 100
		effect_pool.append(effect_node)

func create_effect(position: Vector2, size: Vector2, shape: String, effect_type: String, params: Dictionary = {}):
	"""
	Main function to create VFX
	Parameters:
	- position: World position for the effect
	- size: Size of the effect (Vector2)
	- shape: "rectangle", "circle", or "triangle"
	- effect_type: Type of effect (e.g., "fire", "lightning", "cloud_poison", "particles_blue")
	- params: Additional parameters specific to each effect type
	"""
	
	var effect_node = _get_effect_node()
	
	# Configure base properties
	effect_node.position = position
	effect_node.size = size
	effect_node.z_index =100
	effect_node.shape = shape
	
	# Parse effect type and configure
	var effect_parts = effect_type.split("_")
	var base_effect = effect_parts[0]
	
	match base_effect:
		"fire":
			_setup_fire_effect(effect_node, 4*size, shape, params)
			#_setup_particle_effect(effect_node, size, shape, "yellow", params)
			#_setup_cloud_effect(effect_node, size, shape, "smoke", params)

		"lightning":
			_setup_lightning_effect(effect_node, size, shape, params)
		"cloud":
			if effect_parts.size() > 1:
				_setup_cloud_effect(effect_node, size, shape, effect_parts[1], params)
			else:
				_setup_cloud_effect(effect_node, size, shape, "smoke", params)
		"particles":
			if effect_parts.size() > 1:
				_setup_particle_effect(effect_node, size, shape, effect_parts[1], params)
			else:
				_setup_particle_effect(effect_node, size, shape, "white", params)
	
	# Add to scene
	if not effect_node.get_parent():
		get_tree().current_scene.add_child(effect_node)
	
	effect_node.visible = true
	active_effects.append(effect_node)
	
	# Auto cleanup after duration
	var duration = params.get("duration", 5.0)
	if duration > 0:
		await get_tree().create_timer(duration).timeout
		_return_effect_node(effect_node)
	
	return effect_node

func _create_effect_node() -> Node2D:
	var node = Node2D.new()
	node.set_script(load("res://VFXEffectNode.gd"))  # Use load instead of preload
	node.visible = false
	add_child(node)
	return node

func _get_effect_node() -> Node2D:
	if effect_pool.is_empty():
		return _create_effect_node()
	else:
		return effect_pool.pop_back()

func _return_effect_node(node: Node2D):
	if node in active_effects:
		active_effects.erase(node)
	
	node.visible = false
	node.cleanup()
	
	if effect_pool.size() < max_pool_size:
		effect_pool.append(node)
	else:
		node.queue_free()

func _setup_fire_effect(node: Node2D, size: Vector2, shape: String, params: Dictionary):
	var shader_code = _get_fire_shader(shape)
	var shader = _get_or_create_shader(shader_code, "fire_" + shape)
	var material = ShaderMaterial.new()
	material.shader = shader
	
	# Debug: Print the shader code to verify it's correct
	print("Setting up fire effect with shape: ", shape)
	
	# Set shader parameters BEFORE applying to node
	material.set_shader_parameter("effect_size", size)
	material.set_shader_parameter("flame_color", params.get("color", Color(1.0, 0.4, 0.0)))
	material.set_shader_parameter("intensity", params.get("intensity", 1.0))
	material.set_shader_parameter("speed", params.get("speed", 3.0))
	
	node.setup_effect(material, size, shape)
	
	# Add light
	var light_color = params.get("light_color", Color(1.0, 0.5, 0.0))
	var light_energy = params.get("light_energy", 2.0)
	node.add_light(light_color, .5*light_energy, size.length() * 2.0, light_texture)

func _setup_lightning_effect(node: Node2D, size: Vector2, shape: String, params: Dictionary):
	var shader_code = _get_lightning_shader(shape)
	var material = ShaderMaterial.new()
	material.shader = _get_or_create_shader(shader_code, "lightning_" + shape)
	
	material.set_shader_parameter("effect_size", size)
	material.set_shader_parameter("lightning_color", params.get("color", Color(0.7, 0.7, 1.0)))
	material.set_shader_parameter("intensity", params.get("intensity", 2.0))
	material.set_shader_parameter("branches", params.get("branches", 5))
	
	node.setup_effect(material, size, shape)
	
	# Add light
	var light_color = params.get("light_color", Color(0.7, 0.7, 1.0))
	var light_energy = params.get("light_energy", 3.0)
	node.add_light(light_color, light_energy, size.length() * 1.5, light_texture)

func _setup_cloud_effect(node: Node2D, size: Vector2, shape: String, cloud_type: String, params: Dictionary):
	var shader_code = _get_cloud_shader(shape)
	var material = ShaderMaterial.new()
	material.shader = _get_or_create_shader(shader_code, "cloud_" + shape)
	
	# Set cloud type specific parameters
	var cloud_color: Color
	var opacity: float
	var light_enabled: bool = false
	var light_color: Color
	var light_energy: float = 0.5
	
	match cloud_type:
		"poison":
			cloud_color = params.get("color", Color(0.2, 0.8, 0.2, 0.7))
			opacity = params.get("opacity", 0.7)
			light_enabled = params.get("emit_light", true)
			light_color = Color(0.2, 0.8, 0.2)
			light_energy = 0.8
		"smoke":
			cloud_color = params.get("color", Color(0.3, 0.3, 0.3, 0.8))
			opacity = params.get("opacity", 0.8)
		"steam":
			cloud_color = params.get("color", Color(0.9, 0.9, 0.9, 0.5))
			opacity = params.get("opacity", 0.5)
			light_enabled = params.get("emit_light", true)
			light_color = Color.WHITE
			light_energy = 0.3
		_:
			cloud_color = params.get("color", Color(0.5, 0.5, 0.5, 0.6))
			opacity = params.get("opacity", 0.6)
	
	material.set_shader_parameter("effect_size", size)
	material.set_shader_parameter("cloud_color", cloud_color)
	material.set_shader_parameter("opacity", opacity)
	material.set_shader_parameter("turbulence", params.get("turbulence", 0.5))
	material.set_shader_parameter("speed", params.get("speed", 1.0))
	
	node.setup_effect(material, size, shape)
	
	if light_enabled:
		node.add_light(light_color, light_energy, size.length() * 1.2, light_texture)

func _setup_particle_effect(node: Node2D, size: Vector2, shape: String, color_name: String, params: Dictionary):
	var shader_code = _get_particle_shader(shape)
	var material = ShaderMaterial.new()
	material.shader = _get_or_create_shader(shader_code, "particles_" + shape)
	
	# Parse color
	var particle_color: Color
	match color_name:
		"red": particle_color = Color.RED
		"blue": particle_color = Color.BLUE
		"green": particle_color = Color.GREEN
		"yellow": particle_color = Color.YELLOW
		"purple": particle_color = Color.PURPLE
		"white": particle_color = Color.WHITE
		_: particle_color = Color.WHITE
	
	particle_color = params.get("color", particle_color)
	
	material.set_shader_parameter("effect_size", size)
	material.set_shader_parameter("particle_color", particle_color)
	material.set_shader_parameter("particle_count", params.get("count", 50))
	material.set_shader_parameter("swirl_speed", params.get("swirl_speed", 2.0))
	material.set_shader_parameter("particle_size", params.get("particle_size", 0.05))
	
	node.setup_effect(material, size, shape)
	
	# Add light if requested
	if params.get("emit_light", true):
		var light_energy = params.get("light_energy", 1.0)
		node.add_light(particle_color, light_energy, size.length() * 1.5, light_texture)

func _get_or_create_shader(code: String, cache_key: String) -> Shader:
	if cache_key in shader_cache:
		return shader_cache[cache_key]
	
	var shader = Shader.new()
	shader.code = code
	shader_cache[cache_key] = shader
	return shader

# Shader generation functions
func _get_fire_shader(shape: String) -> String:
	var shape_mask_code = _get_shape_mask_for_shader(shape)
	
	return """
shader_type canvas_item;
render_mode blend_add;

uniform vec2 effect_size = vec2(100.0, 100.0);
uniform vec3 flame_color = vec3(1.0, 0.4, 0.0);
uniform float intensity : hint_range(0.0, 3.0) = 1.0;
uniform float speed : hint_range(0.0, 10.0) = 3.0;

// Simple noise function
float hash(vec2 p) {
	p = fract(p * vec2(123.34, 456.78));
	p += dot(p, p + 45.67);
	return fract(p.x * p.y);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	
	float a = hash(i);
	float b = hash(i + vec2(1.0, 0.0));
	float c = hash(i + vec2(0.0, 1.0));
	float d = hash(i + vec2(1.0, 1.0));
	
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p) {
	float value = 0.0;
	float amplitude = 0.5;
	
	for (int i = 0; i < 4; i++) {
		value += amplitude * noise(p);
		p *= 2.0;
		amplitude *= 0.5;
	}
	
	return value;
}

void fragment() {
	vec2 uv = UV;
	
	""" + shape_mask_code + """
	
	// Create fire effect
	float time = TIME * speed;
	
	// Create vertical flow
	vec2 flow_uv = uv;
	flow_uv.y -= time * 0.3;
	
	// Generate fire noise
	float n1 = fbm(flow_uv * 8.0 + vec2(time * 0.5, -time));
	float n2 = fbm(flow_uv * 12.0 + vec2(-time * 0.3, -time * 1.5));
	
	// Shape the fire
	float fire_shape = 1.0 - pow(uv.y, 0.5);  // Bottom heavy
	fire_shape *= 1.0 - abs(uv.x - 0.5) * 2.0;  // Narrower at top
	
	// Combine noise layers
	float fire = n1 + n2 * 0.5;
	fire *= fire_shape;
	
	// Threshold for flame look
	fire = smoothstep(0.0, 1.0, fire * 2.0 - 0.5);
	
	// Apply shape mask
	fire *= shape_mask;
	
	// Color gradient using flame_color as base
	vec3 color = vec3(0.0);
	vec3 base_color = flame_color;
	color = mix(color, base_color * 0.8, smoothstep(0.0, 0.3, fire));  // Dark red/orange
	color = mix(color, base_color, smoothstep(0.3, 0.6, fire));         // Base color  
	color = mix(color, base_color * 1.5, smoothstep(0.6, 0.8, fire));   // Brighter
	color = mix(color, vec3(1.0, 1.0, 0.9), smoothstep(0.8, 1.0, fire)); // White hot
	
	COLOR = vec4(color * intensity, fire * intensity);
}
"""

func _get_shape_mask_for_shader(shape: String) -> String:
	match shape:
		"circle":
			return """
	// Circle mask
	vec2 center = vec2(0.5, 0.5);
	float dist = distance(uv, center);
	float shape_mask = 1.0 - smoothstep(0.4, 0.5, dist);"""
		"triangle":
			return """
	// Triangle mask
	vec2 p = uv - vec2(0.5, 0.0);
	float shape_mask = step(0.0, p.y) * step(p.y, 1.0 - abs(p.x * 2.0));"""
		_:  # rectangle
			return """
	// Rectangle mask (full area)
	float shape_mask = 1.0;"""

func _get_lightning_shader(shape: String) -> String:
	var shape_check = _get_shape_check_code(shape)
	
	return """
shader_type canvas_item;

uniform vec2 effect_size = vec2(100.0, 100.0);
uniform vec3 lightning_color = vec3(0.7, 0.7, 1.0);
uniform float intensity = 2.0;
uniform int branches = 5;

float random(vec2 st) {
	return fract(sin(dot(st.xy, vec2(12.9898,78.233))) * 43758.5453123);
}

float lightning_bolt(vec2 uv, float time, float seed) {
	float bolt = 0.0;
	vec2 pos = uv;
	
	// Main bolt
	float offset = sin(pos.y * 10.0 + time * 10.0 + seed) * 0.1;
	offset += sin(pos.y * 25.0 + time * 15.0 + seed * 2.0) * 0.05;
	
	float dist = abs(pos.x - 0.5 + offset);
	bolt = 1.0 / (dist * 50.0 + 1.0);
	bolt *= step(0.0, pos.y) * step(pos.y, 1.0);
	
	return bolt;
}

""" + shape_check + """

void fragment() {
	vec2 uv = UV;
	vec2 centered_uv = (uv - vec2(0.5)) * 2.0;
	
	if (!is_inside_shape(centered_uv, effect_size)) {
		COLOR = vec4(0.0);
		return;
	}
	
	float time = TIME;
	float bolt = 0.0;
	
	// Multiple lightning branches
	for (int i = 0; i < branches; i++) {
		float seed = float(i) * 123.456;
		vec2 offset = vec2(random(vec2(seed, time)) - 0.5, 0.0) * 0.3;
		bolt += lightning_bolt(uv + offset, time, seed) * random(vec2(time + seed, seed));
	}
	
	// Pulsing effect
	float pulse = sin(time * 20.0) * 0.5 + 0.5;
	bolt *= (pulse * 0.5 + 0.5);
	
	vec3 col = lightning_color * bolt * intensity;
	float alpha = min(bolt * intensity, 1.0);
	
	COLOR = vec4(col, alpha);
}
"""

func _get_cloud_shader(shape: String) -> String:
	var shape_check = _get_shape_check_code(shape)
	
	return """
shader_type canvas_item;

uniform vec2 effect_size = vec2(100.0, 100.0);
uniform vec4 cloud_color = vec4(0.5, 0.5, 0.5, 0.6);
uniform float opacity = 0.6;
uniform float turbulence = 0.5;
uniform float speed = 1.0;

float noise(vec2 st) {
	vec2 i = floor(st);
	vec2 f = fract(st);
	vec2 u = f * f * (3.0 - 2.0 * f);
	
	float a = fract(sin(dot(i, vec2(12.9898,78.233))) * 43758.5453123);
	float b = fract(sin(dot(i + vec2(1.0, 0.0), vec2(12.9898,78.233))) * 43758.5453123);
	float c = fract(sin(dot(i + vec2(0.0, 1.0), vec2(12.9898,78.233))) * 43758.5453123);
	float d = fract(sin(dot(i + vec2(1.0, 1.0), vec2(12.9898,78.233))) * 43758.5453123);
	
	return mix(a, b, u.x) + (c - a)* u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
}

float fbm(vec2 st) {
	float value = 0.0;
	float amplitude = 0.5;
	
	for (int i = 0; i < 6; i++) {
		value += amplitude * noise(st);
		st *= 2.0;
		amplitude *= 0.5;
	}
	
	return value;
}

""" + shape_check + """

void fragment() {
	vec2 uv = UV;
	vec2 centered_uv = (uv - vec2(0.5)) * 2.0;
	
	if (!is_inside_shape(centered_uv, effect_size)) {
		COLOR = vec4(0.0);
		return;
	}
	
	float time = TIME * speed * 0.3;
	
	// Animated cloud texture
	vec2 pos = uv * 3.0;
	pos.x += time * 0.1;
	pos.y += time * 0.05;
	
	float cloud = fbm(pos + vec2(time * 0.1));
	cloud += fbm(pos * 2.0 - vec2(time * 0.15)) * 0.5;
	
	cloud = smoothstep(0.3, 0.7, cloud);
	
	// Apply turbulence
	cloud = mix(cloud, 1.0 - cloud, turbulence * 0.5);
	
	// Edge fade
	float edge_dist = get_shape_distance(centered_uv, effect_size);
	float edge_fade = smoothstep(0.8, 1.0, edge_dist);
	cloud *= (1.0 - edge_fade);
	
	COLOR = vec4(cloud_color.rgb, cloud * opacity * cloud_color.a);
}
"""

func _get_particle_shader(shape: String) -> String:
	var shape_check = _get_shape_check_code(shape)
	
	return """
shader_type canvas_item;

uniform vec2 effect_size = vec2(100.0, 100.0);
uniform vec3 particle_color = vec3(1.0, 1.0, 1.0);
uniform int particle_count = 50;
uniform float swirl_speed = 2.0;
uniform float particle_size = 0.05;

float random(vec2 st) {
	return fract(sin(dot(st.xy, vec2(12.9898,78.233))) * 43758.5453123);
}

vec2 rotate(vec2 v, float angle) {
	float s = sin(angle);
	float c = cos(angle);
	return vec2(c * v.x - s * v.y, s * v.x + c * v.y);
}

""" + shape_check + """

void fragment() {
	vec2 uv = UV;
	vec2 centered_uv = (uv - vec2(0.5)) * 2.0;
	
	if (!is_inside_shape(centered_uv, effect_size)) {
		COLOR = vec4(0.0);
		return;
	}
	
	float time = TIME;
	float intensity = 0.0;
	
	// Create swirling particles
	for (int i = 0; i < particle_count; i++) {
		float fi = float(i);
		vec2 seed = vec2(fi * 0.1, fi * 0.13);
		
		// Particle position with swirl
		float angle = time * swirl_speed + fi * 0.5;
		float radius = random(seed) * 0.4 + 0.1;
		radius += sin(time * 2.0 + fi) * 0.1;
		
		vec2 pos = vec2(cos(angle), sin(angle)) * radius;
		pos += vec2(0.5);
		
		// Oscillating motion
		pos.x += sin(time * 3.0 + fi) * 0.05;
		pos.y += cos(time * 3.0 + fi * 1.3) * 0.05;
		
		// Calculate distance to particle
		float dist = length(uv - pos);
		float particle = smoothstep(particle_size, 0.0, dist);
		
		// Add glow
		particle += exp(-dist * 30.0) * 0.5;
		
		intensity += particle;
	}
	
	intensity = min(intensity, 1.0);
	
	vec3 col = particle_color * intensity;
	float alpha = intensity;
	
	COLOR = vec4(col, alpha);
}
"""

func _get_shape_check_code(shape: String) -> String:
	match shape:
		"circle":
			return """
bool is_inside_shape(vec2 uv, vec2 size) {
	float aspect = size.x / size.y;
	vec2 scaled_uv = uv * vec2(1.0, aspect);
	return length(scaled_uv) <= 1.0;
}

float get_shape_distance(vec2 uv, vec2 size) {
	float aspect = size.x / size.y;
	vec2 scaled_uv = uv * vec2(1.0, aspect);
	return length(scaled_uv);
}
"""
		"triangle":
			return """
bool is_inside_shape(vec2 uv, vec2 size) {
	vec2 p = uv;
	p.y = -p.y + 0.5;
	return p.y > 0.0 && p.y < 1.0 - abs(p.x);
}

float get_shape_distance(vec2 uv, vec2 size) {
	vec2 p = uv;
	p.y = -p.y + 0.5;
	float dist = max(abs(p.x), -p.y);
	dist = max(dist, p.y - (1.0 - abs(p.x)));
	return abs(dist);
}
"""
		_: # rectangle
			return """
bool is_inside_shape(vec2 uv, vec2 size) {
	return abs(uv.x) <= 1.0 && abs(uv.y) <= 1.0;
}

float get_shape_distance(vec2 uv, vec2 size) {
	return max(abs(uv.x), abs(uv.y));
}
"""
