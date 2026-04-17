shader_type canvas_item;

uniform vec4 line_color : source_color = vec4(0.9, 0.9, 0.95, 0.25);
uniform float wind_angle : hint_range(0.0, 6.283) = 0.0;
uniform float gust_speed : hint_range(0.5, 10.0) = 3.0;
uniform float line_density : hint_range(0.0, 1.0) = 0.3;
uniform float intensity : hint_range(0.0, 1.0) = 1.0;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

float hash2(vec2 p) {
	return fract(sin(dot(p, vec2(269.5, 183.3))) * 43758.5453123);
}

void fragment() {
	vec2 uv = UV;

	// Rotate UV space so lines travel in wind direction
	float ca = cos(-wind_angle);
	float sa = sin(-wind_angle);
	vec2 ruv = vec2(uv.x * ca - uv.y * sa, uv.x * sa + uv.y * ca);

	float alpha = 0.0;

	// Multiple sporadic gust line layers
	for (int layer = 0; layer < 3; layer++) {
		float layer_f = float(layer);
		float cell_h = 0.06 + layer_f * 0.03;
		float speed_mult = gust_speed * (0.8 + layer_f * 0.4);

		// Scroll along the wind direction
		vec2 scrolled = ruv;
		scrolled.x -= TIME * speed_mult;

		// Divide into horizontal bands
		float band_id = floor(scrolled.y / cell_h);
		float band_uv_y = fract(scrolled.y / cell_h);

		// Each band has sporadic appearance (time-based hash)
		float time_cell = floor(TIME * (0.5 + layer_f * 0.2) + band_id * 0.7);
		float appear = hash(vec2(band_id, time_cell + layer_f * 10.0));

		// Only show some bands (sporadic)
		if (appear < line_density) {
			// Line segment positioning
			float seg_x_start = hash(vec2(band_id * 1.3, time_cell + layer_f * 20.0));
			float seg_length = 0.08 + hash2(vec2(band_id, time_cell)) * 0.15;
			float local_x = fract(scrolled.x * 0.5 + seg_x_start);

			// Horizontal streak shape
			float line_mask = smoothstep(0.0, 0.02, local_x)
							* smoothstep(seg_length + 0.02, seg_length, local_x);

			// Thin vertical profile (centered in band)
			float thickness = 0.15 + hash(vec2(band_id * 3.0, layer_f)) * 0.1;
			float y_dist = abs(band_uv_y - 0.5);
			float vert_mask = smoothstep(thickness, thickness * 0.3, y_dist);

			// Fade in/out over the gust's lifetime
			float life_frac = fract(TIME * (0.3 + layer_f * 0.1) + band_id * 0.5);
			float fade = smoothstep(0.0, 0.2, life_frac) * smoothstep(1.0, 0.7, life_frac);

			alpha += line_mask * vert_mask * fade * (0.5 + layer_f * 0.2);
		}
	}

	alpha = clamp(alpha, 0.0, 1.0) * intensity;
	COLOR = vec4(line_color.rgb, alpha * line_color.a);
}
