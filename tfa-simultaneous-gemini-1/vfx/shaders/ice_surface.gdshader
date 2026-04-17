shader_type canvas_item;

uniform vec4 ice_color : source_color = vec4(0.7, 0.85, 0.95, 0.7);
uniform vec4 frost_color : source_color = vec4(0.9, 0.95, 1.0, 0.5);
uniform float crack_density : hint_range(0.0, 1.0) = 0.3;
uniform float shimmer_speed : hint_range(0.1, 3.0) = 0.8;
uniform float frost_amount : hint_range(0.0, 1.0) = 0.4;

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

float voronoi_cracks(vec2 uv) {
	vec2 i = floor(uv);
	vec2 f = fract(uv);
	float min_dist = 1.0;
	float second_dist = 1.0;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 neighbor = vec2(float(x), float(y));
			vec2 point = vec2(hash(i + neighbor), hash(i + neighbor + vec2(37.0, 17.0)));
			float d = length(neighbor + point - f);
			if (d < min_dist) {
				second_dist = min_dist;
				min_dist = d;
			} else if (d < second_dist) {
				second_dist = d;
			}
		}
	}
	// Edge detection: thin cracks where two cells meet
	return smoothstep(0.0, 0.08, second_dist - min_dist);
}

void fragment() {
	vec2 uv = UV;

	// Base ice color with subtle noise variation
	float n = noise(uv * 8.0);
	vec3 base = mix(ice_color.rgb, ice_color.rgb * 1.15, n * 0.3);

	// Cracks pattern
	float cracks = voronoi_cracks(uv * 6.0);
	float crack_lines = 1.0 - smoothstep(0.0, crack_density, 1.0 - cracks);
	base = mix(base, base * 0.6, crack_lines * 0.5);

	// Frost crystals at edges
	float frost_noise = noise(uv * 12.0 + TIME * 0.02);
	float frost_edge = smoothstep(0.3, 0.0, min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y)));
	float frost = frost_edge * frost_noise * frost_amount;
	base = mix(base, frost_color.rgb, frost);

	// Shimmer / specular highlight
	float shimmer = noise(uv * 4.0 + vec2(TIME * shimmer_speed, TIME * shimmer_speed * 0.7));
	shimmer = smoothstep(0.6, 0.9, shimmer) * 0.25;
	base += vec3(shimmer);

	COLOR = vec4(base, ice_color.a);
}
