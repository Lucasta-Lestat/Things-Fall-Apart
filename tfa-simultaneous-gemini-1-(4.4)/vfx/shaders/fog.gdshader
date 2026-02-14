shader_type canvas_item;

// Configurable properties
uniform vec4 fog_color : source_color = vec4(0.5, 0.6, 0.7, 1.0);
uniform float density : hint_range(0.0, 2.0) = 1.0;
uniform sampler2D noise_texture : repeat_enable, filter_nearest;

// Wind settings (updated by script)
uniform vec2 wind_velocity = vec2(0.1, 0.0);

// Softness at edges
uniform float edge_softness : hint_range(0.0, 0.5) = 0.1;

void fragment() {
    // 1. Calculate UV scrolling for wind effect
    // We use two layers moving at different speeds to create depth
    vec2 uv_move_1 = UV + (wind_velocity * TIME);
    vec2 uv_move_2 = UV + (wind_velocity * TIME * 0.5) + vec2(0.5); // Offset second layer

    // 2. Sample Noise
    float noise_1 = texture(noise_texture, uv_move_1).r;
    float noise_2 = texture(noise_texture, uv_move_2).r;
    
    // Combine noise layers
    float combined_noise = mix(noise_1, noise_2, 0.5);
    
    // 3. Apply Edge Softness (Fades out near the bounds of the ColorRect)
    vec2 center_dist = abs(UV - 0.5) * 2.0;
    // Calculate distance from edge (0 at center, 1 at edge)
    float mask_x = smoothstep(1.0, 1.0 - edge_softness, center_dist.x);
    float mask_y = smoothstep(1.0, 1.0 - edge_softness, center_dist.y);
    float edge_mask = mask_x * mask_y;

    // 4. Final Output
    // Alpha is determined by noise * density * edge fade * color alpha
    float final_alpha = combined_noise * density * edge_mask * fog_color.a;
    
    COLOR = vec4(fog_color.rgb, final_alpha);
}