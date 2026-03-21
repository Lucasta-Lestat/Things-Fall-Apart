shader_type canvas_item;

uniform vec4 fog_color : source_color = vec4(0.8, 0.8, 0.8, 0.5);
uniform float density : hint_range(0.0, 1.0) = 0.5;
uniform vec2 speed = vec2(0.02, 0.01);
uniform float scale = 4.0;
uniform float falloff_radius : hint_range(0.0, 1.0) = 0.8;
uniform float falloff_softness : hint_range(0.01, 1.0) = 0.3;
uniform float color_shift : hint_range(0.0, 0.3) = 0.08;
uniform float warp_strength : hint_range(0.0, 2.0) = 0.8;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
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
	for (int i = 0; i < 5; i++) {
		value += amplitude * noise(p);
		p *= 2.0;
		amplitude *= 0.5;
	}
	return value;
}

void fragment() {
	vec2 uv = UV * scale;
	vec2 movement = TIME * speed;

	// Domain warping: layer 1 (q) distorts the base, layer 2 (r) distorts further
	vec2 q = vec2(
		fbm(uv + movement),
		fbm(uv + vec2(5.2, 1.3) + movement * 0.6)
	);

	vec2 r = vec2(
		fbm(uv + warp_strength * q + vec2(1.7, 9.2) - movement * 0.4),
		fbm(uv + warp_strength * q + vec2(8.3, 2.8) + movement * 0.3)
	);

	float fog = fbm(uv + warp_strength * r);

	// Density threshold
	fog = smoothstep(1.0 - density, 1.0, fog);

	// Soft circular falloff from center of UV space
	vec2 center_offset = UV - vec2(0.5);
	float dist = length(center_offset);
	float vignette = 1.0 - smoothstep(falloff_radius - falloff_softness, falloff_radius, dist);
	fog *= vignette;

	// Color variation: derive two tints from fog_color
	// Slightly warmer (brighter) and cooler (darker) versions
	float luma = dot(fog_color.rgb, vec3(0.299, 0.587, 0.114));
	vec3 warm = fog_color.rgb + vec3(color_shift, color_shift * 0.5, -color_shift);
	vec3 cool = fog_color.rgb + vec3(-color_shift, -color_shift * 0.3, color_shift);

	// Blend between the two based on the warp pattern
	float color_mix = smoothstep(0.3, 0.7, r.x);
	vec3 final_color = mix(warm, cool, color_mix);

	COLOR = vec4(final_color, fog * fog_color.a);
}