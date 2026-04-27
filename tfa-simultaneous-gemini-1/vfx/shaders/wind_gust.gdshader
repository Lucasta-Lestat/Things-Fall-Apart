shader_type canvas_item;

// Cartoon-style wind gust lines: thin streaks with a spiral curl at the end.
// Each gust appears sporadically in a band, travels in the wind direction,
// and has a logarithmic-spiral-like curl at the leading tip.

uniform vec4 line_color : source_color = vec4(0.9, 0.9, 0.95, 0.55);
uniform float wind_angle : hint_range(0.0, 6.283) = 0.0;
uniform float gust_speed : hint_range(0.5, 10.0) = 3.0;
uniform float line_density : hint_range(0.0, 1.0) = 0.4;
uniform float line_thickness : hint_range(0.0005, 0.02) = 0.0025;
uniform float line_length : hint_range(0.1, 0.8) = 0.45;
uniform float curl_size : hint_range(0.01, 0.1) = 0.045;
uniform float intensity : hint_range(0.0, 1.0) = 1.0;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

// Distance from point p to a path that starts at origin, travels along +x
// for a straight segment, then spirals inward (counterclockwise) at the tip.
float path_sdf(vec2 p, float total_length, float tip_curl) {
	float straight_frac = 0.62;
	float min_d = 1e10;
	for (int i = 0; i < 24; i++) {
		float t = float(i) / 23.0;
		vec2 pt;
		if (t < straight_frac) {
			float st = t / straight_frac;
			pt = vec2(st * total_length, 0.0);
		} else {
			float ct = (t - straight_frac) / (1.0 - straight_frac);
			float angle = ct * 3.2 * 3.14159;
			float radius = tip_curl * (1.0 - ct * 0.55);
			vec2 center = vec2(total_length, -tip_curl);
			float base_angle = 1.5707963;
			pt = center + vec2(cos(base_angle + angle), sin(base_angle + angle)) * radius;
		}
		min_d = min(min_d, length(p - pt));
	}
	return min_d;
}

void fragment() {
	// Rotate UV so wind blows along +x in local coords
	vec2 centered = UV - vec2(0.5);
	float ca = cos(-wind_angle);
	float sa = sin(-wind_angle);
	vec2 wuv = vec2(centered.x * ca - centered.y * sa, centered.x * sa + centered.y * ca) + vec2(0.5);

	float alpha = 0.0;
	float band_count = 7.0;
	float center_band = floor(wuv.y * band_count);

	// Check this band and adjacent ones (gusts can extend vertically via curl)
	for (int offset = -1; offset <= 1; offset++) {
		float band_id = center_band + float(offset);
		float band_center_y = (band_id + 0.5) / band_count;

		// Time slot: each gust has ~1.7s lifespan, staggered per band
		float slot_speed = 0.58 * gust_speed / 3.0;
		float time_slot = floor(TIME * slot_speed + band_id * 1.31);
		float appear_roll = hash(vec2(band_id, time_slot));

		if (appear_roll >= line_density) continue;

		// Life cycle within the slot
		float life_frac = fract(TIME * slot_speed + band_id * 1.31);
		float life_fade = smoothstep(0.0, 0.12, life_frac) * smoothstep(1.0, 0.85, life_frac);

		// Gust travels across screen over its life
		float progress = life_frac;
		float start_x = -0.25 + progress * 1.4;

		// Small vertical jitter so lines aren't perfectly aligned to band center
		float y_jitter = (hash(vec2(band_id * 0.37, time_slot + 3.0)) - 0.5) * 0.6 / band_count;
		float start_y = band_center_y + y_jitter;

		// Per-gust variation
		float this_length = line_length * (0.75 + hash(vec2(band_id + 7.0, time_slot)) * 0.5);
		float this_curl = curl_size * (0.8 + hash(vec2(band_id + 13.0, time_slot)) * 0.5);
		float curl_flip = step(0.5, hash(vec2(band_id + 19.0, time_slot))) * 2.0 - 1.0;

		// Pixel relative to gust origin, in wind-aligned coords
		vec2 local = wuv - vec2(start_x, start_y);
		local.y *= curl_flip;

		float d = path_sdf(local, this_length, this_curl);
		float line = smoothstep(line_thickness, 0.0, d);

		alpha += line * life_fade;
	}

	alpha = clamp(alpha, 0.0, 1.0) * intensity;
	COLOR = vec4(line_color.rgb, alpha * line_color.a);
}
