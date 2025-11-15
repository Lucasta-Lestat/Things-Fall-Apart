shader_type canvas_item;

// Flow direction and speed
uniform vec2 flow_direction = vec2(0.0, 0.0); // Normalized direction vector
uniform float flow_speed = 0.5; // Overall flow speed multiplier
uniform float wave_speed = 2.0; // Speed of wave animation

// Wave appearance
uniform float wave_frequency = 4.0; // How many waves across the tile
uniform float wave_amplitude = 0.08; // Height of the waves
uniform float wave_sharpness = 3.0; // How defined the wave crests are

// Colors
uniform vec4 water_color : source_color = vec4(0.0, 0.5, 0.8, 0.7);
uniform vec4 wave_color : source_color = vec4(0.2, 0.8, 1.0, 0.4);
uniform float wave_brightness = 0.3; // How bright the wave highlights are

// Distortion
uniform float distortion_strength = 0.02; // UV distortion amount
uniform float distortion_speed = 1.0;

void fragment() {
    vec2 uv = UV;
    float time = TIME;
    
    // Calculate flow influence
    float flow_magnitude = length(flow_direction);
    vec2 flow_dir_norm = flow_magnitude > 0.001 ? normalize(flow_direction) : vec2(0.0, 0.0);
    
    // Create distortion that moves with flow
    vec2 distort_offset = vec2(
        sin(uv.y * 10.0 + time * distortion_speed) * distortion_strength,
        cos(uv.x * 10.0 + time * distortion_speed) * distortion_strength
    );
    vec2 distorted_uv = uv + distort_offset;
    
    // Calculate wave pattern along flow direction
    // Project UV onto flow direction to create waves perpendicular to flow
    float wave_coord;
    if (flow_magnitude > 0.001) {
        // Create waves perpendicular to flow direction
        vec2 perpendicular = vec2(-flow_dir_norm.y, flow_dir_norm.x);
        wave_coord = dot(distorted_uv, perpendicular) * wave_frequency;
        
        // Move waves in flow direction
        wave_coord -= time * wave_speed * flow_speed * flow_magnitude;
    } else {
        // No flow - gentle ambient waves
        wave_coord = (distorted_uv.x + distorted_uv.y) * wave_frequency * 0.5;
        wave_coord -= time * wave_speed * 0.3;
    }
    
    // Create wave pattern using sine
    float wave_pattern = sin(wave_coord * 6.28318); // 2*PI
    
    // Sharpen the waves to create more defined crests
    wave_pattern = pow(abs(wave_pattern), 1.0 / wave_sharpness) * sign(wave_pattern);
    
    // Convert to 0-1 range and apply amplitude
    float wave_intensity = (wave_pattern * 0.5 + 0.5) * wave_amplitude;
    
    // Add secondary wave layer for more detail
    float wave_coord2;
    if (flow_magnitude > 0.001) {
        vec2 perpendicular2 = vec2(-flow_dir_norm.y, flow_dir_norm.x);
        wave_coord2 = dot(distorted_uv, perpendicular2) * wave_frequency * 1.7;
        wave_coord2 -= time * wave_speed * flow_speed * flow_magnitude * 0.7;
    } else {
        wave_coord2 = (distorted_uv.x - distorted_uv.y) * wave_frequency * 0.7;
        wave_coord2 -= time * wave_speed * 0.2;
    }
    
    float wave_pattern2 = sin(wave_coord2 * 6.28318) * 0.5;
    float wave_intensity2 = (wave_pattern2 * 0.5 + 0.5) * wave_amplitude * 0.5;
    
    // Combine wave layers
    float combined_waves = wave_intensity + wave_intensity2;
    
    // Create wave highlights
    float wave_highlight = smoothstep(0.1, 0.15, combined_waves) * wave_brightness;
    
    // Flow-based opacity variation (more visible where flowing faster)
    float flow_alpha = mix(0.8, 1.0, flow_magnitude * flow_speed);
    
    // Mix base water color with wave highlights
    vec3 final_color = mix(water_color.rgb, wave_color.rgb, wave_highlight);
    
    // Add subtle shimmer along flow direction
    float shimmer = 0.0;
    if (flow_magnitude > 0.001) {
        float shimmer_coord = dot(distorted_uv, flow_dir_norm) * 8.0 - time * 3.0;
        shimmer = pow(abs(sin(shimmer_coord * 6.28318)), 8.0) * 0.2 * flow_magnitude;
    }
    final_color += vec3(shimmer);
    
    // Output
    COLOR = vec4(final_color, water_color.a * flow_alpha);
}
