shader_type canvas_item;

uniform vec4 fog_color : source_color = vec4(0.8, 0.8, 0.8, 0.5);
uniform float density : hint_range(0.0, 1.0) = 0.5;
uniform vec2 speed = vec2(0.02, 0.01);
uniform float scale = 4.0;

// Simple hash-based noise (no texture dependency)
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

	float n1 = fbm(uv + movement);
	float n2 = fbm(uv * 1.5 - movement * 0.7);
	float fog = (n1 + n2) * 0.5;

	fog = smoothstep(1.0 - density, 1.0, fog);

	COLOR = vec4(fog_color.rgb, fog * fog_color.a);
}