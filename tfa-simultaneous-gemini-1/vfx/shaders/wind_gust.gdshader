shader_type canvas_item;

uniform vec4 line_color : source_color = vec4(0.9, 0.9, 0.95, 0.3);
uniform float wind_angle : hint_range(0.0, 6.283) = 0.0;
uniform float gust_speed : hint_range(0.5, 10.0) = 3.0;
uniform float line_density : hint_range(0.0, 1.0) = 0.25;
uniform float intensity : hint_range(0.0, 1.0) = 1.0;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

void fragment() {
	vec2 uv = UV;

	// Rotate UV space so gusts travel in wind direction
	float ca = cos(-wind_angle);
	float sa = sin(-wind_angle);
	vec2 ruv = vec2((uv.x - 0.5) * ca - (uv.y - 0.5) * sa, (uv.x - 0.5) * sa + (uv.y - 0.5) * ca) + vec2(0.5);

	float alpha = 0.0;

	// Sparse cartoon gust lines across the screen
	for (int layer = 0; layer < 2; layer++) {
		float layer_f = float(layer);
		float band_h = 0.12 + layer_f * 0.05;
		float speed_mult = gust_speed * (0.8 + layer_f * 0.5);

		// Scroll along wind direction
		vec2 scrolled = ruv;
		scrolled.x -= TIME * speed_mult * 0.1;

		// Divide into horizontal bands (in rotated space)
		float band_id = floor(scrolled.y / band_h);
		float band_local_y = fract(scrolled.y / band_h);

		// Gusts appear sporadically in each band over time
		float time_slot = floor(TIME * 0.6 + band_id * 0.7 + layer_f * 2.3);
		float appear_roll = hash(vec2(band_id + layer_f * 97.0, time_slot));

		if (appear_roll < line_density) {
			// Life cycle of this gust (0 to 1 over ~1.5s)
			float life_frac = fract(TIME * 0.6 + band_id * 0.7 + layer_f * 2.3);
			float life_fade = smoothstep(0.0, 0.2, life_frac) * smoothstep(1.0, 0.7, life_frac);

			// Line position & length within the band
			float line_start = hash(vec2(band_id * 1.9, time_slot)) * 0.5;
			float line_length = 0.15 + hash(vec2(band_id * 2.7, time_slot + 5.0)) * 0.25;
			float line_end = line_start + line_length;

			// Scrolled horizontal position for this gust's line
			float gust_x = scrolled.x + hash(vec2(time_slot, band_id)) * 2.0;
			float local_x = fract(gust_x);

			// Slight sinusoidal curve for cartoon feel
			float curve = sin((local_x - line_start) / line_length * 3.14159) * 0.03;
			float y_offset = band_local_y - 0.5 - curve;

			// Taper: sharp falloff at both ends of the line
			float taper = smoothstep(line_start, line_start + 0.04, local_x)
						* smoothstep(line_end, line_end - 0.04, local_x);

			// Thin horizontal line with soft vertical falloff
			float thickness = 0.12;
			float vert = smoothstep(thickness, 0.0, abs(y_offset));

			alpha += taper * vert * life_fade * 0.7;
		}
	}

	alpha = clamp(alpha, 0.0, 1.0) * intensity;
	COLOR = vec4(line_color.rgb, alpha * line_color.a);
}
