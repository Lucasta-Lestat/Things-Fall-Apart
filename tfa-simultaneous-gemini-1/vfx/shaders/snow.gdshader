shader_type canvas_item;

uniform vec4 snow_color : source_color = vec4(0.95, 0.95, 1.0, 0.5);
uniform float density : hint_range(0.0, 1.0) = 0.35;
uniform float speed : hint_range(0.1, 3.0) = 0.6;
uniform float sway_amount : hint_range(0.0, 2.0) = 0.8;
uniform float sway_speed : hint_range(0.1, 5.0) = 1.5;
uniform float wind_offset : hint_range(-2.0, 2.0) = 0.0;
uniform float intensity : hint_range(0.0, 1.0) = 1.0;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

void fragment() {
	vec2 uv = UV;
	float alpha = 0.0;

	// Multiple layers for parallax depth
	for (int layer = 0; layer < 4; layer++) {
		float layer_f = float(layer);
		float layer_speed = speed * (0.5 + layer_f * 0.25);
		float layer_size = 0.008 + layer_f * 0.004;
		float layer_alpha = 0.6 + layer_f * 0.1;

		// Grid cells
		float cell_size = 0.04 + layer_f * 0.015;
		vec2 moved_uv = uv;
		moved_uv.y -= TIME * layer_speed;
		moved_uv.x += TIME * wind_offset * 0.1 * (1.0 + layer_f * 0.3);

		vec2 grid = moved_uv / cell_size;
		vec2 cell_id = floor(grid);
		vec2 cell_uv = fract(grid);

		float r = hash(cell_id + layer_f * 73.0);
		if (r < density) {
			// Random position within cell
			float fx = hash(cell_id * 1.3 + layer_f * 41.0);
			float fy = hash(cell_id * 2.7 + layer_f * 17.0);

			// Gentle sway
			float sway = sin(TIME * sway_speed + cell_id.x * 3.0 + layer_f * 2.0) * sway_amount * 0.1;
			fx += sway;

			vec2 flake_center = vec2(fx, fy);
			float dist = length(cell_uv - flake_center);

			// Soft circle
			float flake = smoothstep(layer_size, layer_size * 0.3, dist);
			alpha += flake * layer_alpha;
		}
	}

	alpha = clamp(alpha, 0.0, 1.0) * intensity;
	COLOR = vec4(snow_color.rgb, alpha * snow_color.a);
}
