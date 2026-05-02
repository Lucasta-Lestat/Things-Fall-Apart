shader_type canvas_item;

uniform vec4 base_color : source_color = vec4(0.12, 0.32, 0.10, 0.9);
uniform vec4 mid_color : source_color = vec4(0.28, 0.58, 0.18, 0.95);
uniform vec4 tip_color : source_color = vec4(0.62, 0.85, 0.32, 1.0);
uniform vec4 shadow_color : source_color = vec4(0.05, 0.18, 0.05, 1.0);
uniform float clump_scale : hint_range(2.0, 24.0) = 8.0;
uniform float blade_scale : hint_range(8.0, 64.0) = 28.0;
uniform float wind_strength : hint_range(0.0, 0.15) = 0.025;
uniform float wind_speed : hint_range(0.1, 3.0) = 1.2;
uniform float tip_threshold : hint_range(0.4, 0.95) = 0.72;
uniform float edge_softness : hint_range(0.0, 0.5) = 0.15;

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
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 3; i++) {
		v += a * noise(p);
		p *= 2.07;
		a *= 0.5;
	}
	return v;
}

void fragment() {
	vec2 uv = UV;

	// Wind sway: gently displace UVs over time so the field feels alive.
	float sway_phase = TIME * wind_speed + uv.x * 5.0 + uv.y * 7.0;
	vec2 wind_offset = vec2(sin(sway_phase), cos(sway_phase * 0.7)) * wind_strength;
	vec2 wuv = uv + wind_offset;

	// Soft clumps of green — broad patches of varying lightness.
	float clumps = fbm(wuv * clump_scale);

	// Per-blade speckle — fine, vertically-biased noise reads as blade tips
	// from a top-down view (slightly squashed in y so features feel taller).
	float blades = noise(vec2(wuv.x * blade_scale, wuv.y * blade_scale * 0.55));
	blades = pow(blades, 2.5);

	// Combine: clumps drive base color, blades sprinkle bright tips.
	vec3 col = mix(base_color.rgb, mid_color.rgb, smoothstep(0.25, 0.75, clumps));
	float tip_mask = smoothstep(tip_threshold, 0.95, blades) * (0.5 + clumps * 0.5);
	col = mix(col, tip_color.rgb, tip_mask);

	// Darker contour where clumps meet — feels like soil between tufts.
	float contour = abs(clumps - 0.5) * 2.0;
	col = mix(col, shadow_color.rgb, (1.0 - contour) * 0.18);

	// Soft edge fade so adjacent tiles blend without a hard seam.
	float edge_dist = min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y));
	float edge_alpha = smoothstep(0.0, edge_softness, edge_dist);

	COLOR = vec4(col, base_color.a * edge_alpha);
}
