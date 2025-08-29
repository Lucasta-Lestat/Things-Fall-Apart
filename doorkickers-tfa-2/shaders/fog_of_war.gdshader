// fog_of_war.gdshader
shader_type canvas_item;

uniform sampler2D visibility_texture : source_color;
uniform float tile_size : hint_range(16.0, 64.0) = 32.0;
uniform vec4 fog_color : source_color = vec4(0.0, 0.0, 0.0, 0.9);
uniform vec4 explored_color : source_color = vec4(0.0, 0.0, 0.0, 0.3);
uniform float edge_smoothness : hint_range(0.0, 1.0) = 0.2;

varying vec2 world_position;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

void fragment() {
	// Convert world position to tile coordinates
	vec2 tile_coord = world_position / tile_size;
	vec2 uv = tile_coord / textureSize(visibility_texture, 0);
	
	// Sample visibility
	vec4 visibility = texture(visibility_texture, uv);
	
	// Create smooth edges between visibility levels
	float visibility_factor = visibility.a;
	
	// Add some noise for organic fog edges
	float noise = fract(sin(dot(tile_coord, vec2(12.9898, 78.233))) * 43758.5453);
	visibility_factor += (noise - 0.5) * edge_smoothness;
	visibility_factor = clamp(visibility_factor, 0.0, 1.0);
	
	// Interpolate between fog and clear
	vec4 final_color = mix(vec4(0.0), fog_color, visibility_factor);
	