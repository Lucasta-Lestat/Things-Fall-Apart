shader_type canvas_item;

uniform vec4 rain_color : source_color = vec4(0.7, 0.75, 0.85, 0.35);
uniform float density : hint_range(0.0, 1.0) = 0.4;
uniform float speed : hint_range(0.1, 10.0) = 4.0;
uniform float streak_length : hint_range(0.1, 1.0) = 0.4;
uniform float wind_angle : hint_range(-1.0, 1.0) = 0.15;
uniform float intensity : hint_range(0.0, 1.0) = 1.0;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

void fragment() {
	vec2 uv = UV;

	// Apply wind slant
	uv.x += uv.y * wind_angle;

	float alpha = 0.0;

	// Multiple rain layers for depth
	for (int layer = 0; layer < 3; layer++) {
		float layer_f = float(layer);
		float layer_speed = speed * (0.8 + layer_f * 0.3);
		float layer_density = density * (1.0 - layer_f * 0.2);
		float layer_alpha_scale = 1.0 - layer_f * 0.3;

		// Cell size: ~50 cells across the screen for near layer
		float cell_size = 0.02 + layer_f * 0.008;
		vec2 grid = uv / cell_size;
		grid.y -= TIME * layer_speed;

		vec2 cell_id = floor(grid);
		vec2 cell_uv = fract(grid);

		// Random offset per cell
		float r = hash(cell_id + layer_f * 100.0);

		// Only some cells have a raindrop (density control)
		if (r < layer_density) {
			float x_offset = 0.2 + hash(cell_id * 1.7 + layer_f * 50.0) * 0.6;
			float dx = abs(cell_uv.x - x_offset);

			// Thin vertical streak (cell_uv space — scales with cell_size)
			float streak = smoothstep(0.08, 0.0, dx);

			// Streak occupies streak_length fraction of cell vertically
			float streak_start = hash(cell_id * 2.3 + layer_f * 30.0) * (1.0 - streak_length);
			float v_in = smoothstep(streak_start, streak_start + 0.08, cell_uv.y);
			float v_out = smoothstep(streak_start + streak_length, streak_start + streak_length - 0.08, cell_uv.y);
			float streak_mask = v_in * v_out;

			alpha += streak * streak_mask * layer_alpha_scale;
		}
	}

	alpha = clamp(alpha, 0.0, 1.0) * intensity;
	COLOR = vec4(rain_color.rgb, alpha * rain_color.a);
}
