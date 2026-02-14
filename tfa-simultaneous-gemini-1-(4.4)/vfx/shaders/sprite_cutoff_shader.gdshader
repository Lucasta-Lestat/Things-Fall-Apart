shader_type canvas_item;

// How much of the sprite to cut off from bottom (0.0 = none, 1.0 = everything)
uniform float cutoff_amount : hint_range(0.0, 1.0) = 0.0;

// Optional: Add a fade at the water line
uniform float fade_width : hint_range(0.0, 0.2) = 0.05;

// Optional: Water tint for submerged part
uniform vec4 water_tint : source_color = vec4(0.5, 0.7, 1.0, 0.3);
uniform float tint_strength : hint_range(0.0, 1.0) = 0.2;

void fragment() {
	vec4 tex_color = texture(TEXTURE, UV);
	
	// Calculate cutoff threshold (1.0 is top, 0.0 is bottom)
	float cutoff_threshold = 1.0 - cutoff_amount;
	
	// Discard pixels below the water line
	if (UV.y > cutoff_threshold + fade_width) {
		discard;
	}
	
	// Apply fade at the water line
	float fade_factor = 1.0;
	if (UV.y > cutoff_threshold) {
		fade_factor = 1.0 - ((UV.y - cutoff_threshold) / fade_width);
		fade_factor = clamp(fade_factor, 0.0, 1.0);
	}
	
	// Apply water tint to parts near water line
	vec4 final_color = tex_color;
	if (UV.y > cutoff_threshold - 0.1 && UV.y <= cutoff_threshold + fade_width) {
		float tint_factor = tint_strength * (1.0 - (cutoff_threshold - UV.y) / 0.1);
		tint_factor = clamp(tint_factor, 0.0, 1.0);
		final_color = mix(tex_color, tex_color * water_tint, tint_factor);
	}
	
	COLOR = final_color;
	COLOR.a *= fade_factor * tex_color.a;
}
