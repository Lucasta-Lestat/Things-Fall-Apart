shader_type canvas_item;

// Flow direction and speed
uniform vec2 flow_direction = vec2(0.0, 0.0);
uniform float flow_speed = 0.5;
uniform float wave_speed = 2.0;

// Wave appearance
uniform float wave_frequency = 4.0;
uniform float wave_amplitude = 0.08;
uniform float wave_sharpness = 3.0;

// Colors
uniform vec4 water_color : source_color = vec4(0.0, 0.5, 0.8, 0.7);
uniform vec4 wave_color : source_color = vec4(0.2, 0.8, 1.0, 0.4);
uniform float wave_brightness = 0.3;

// Distortion
uniform float distortion_strength = 0.02;
uniform float distortion_speed = 1.0;

// Edge noise displacement — vec4(right, left, bottom, top)
// 1.0 = exposed boundary edge, 0.0 = neighbor present
uniform vec4 edge_mask = vec4(0.0);
uniform float edge_fade_width = 0.35; // how far the ragged edge extends inward (0-0.5)
uniform float edge_noise_scale = 8.0;  // frequency of the ragged pattern

// Simple hash-based noise
float hash(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

float value_noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f); // smoothstep
    float a = hash(i);
    float b = hash(i + vec2(1.0, 0.0));
    float c = hash(i + vec2(0.0, 1.0));
    float d = hash(i + vec2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm_noise(vec2 p) {
    float v = 0.0;
    v += value_noise(p) * 0.5;
    v += value_noise(p * 2.0) * 0.25;
    v += value_noise(p * 4.0) * 0.125;
    return v / 0.875;
}

float compute_edge_alpha(vec2 uv) {
    // For each exposed edge, compute a noise-modulated fade
    float alpha = 1.0;
    vec2 noise_pos = uv * edge_noise_scale;

    // Right edge (uv.x approaching 1.0)
    if (edge_mask.x > 0.5) {
        float dist = 1.0 - uv.x; // distance from right edge
        float noise_val = fbm_noise(noise_pos + vec2(37.0, 0.0));
        float threshold = edge_fade_width * noise_val;
        alpha = min(alpha, smoothstep(0.0, threshold * 0.5 + 0.02, dist));
    }
    // Left edge (uv.x approaching 0.0)
    if (edge_mask.y > 0.5) {
        float dist = uv.x;
        float noise_val = fbm_noise(noise_pos + vec2(0.0, 71.0));
        float threshold = edge_fade_width * noise_val;
        alpha = min(alpha, smoothstep(0.0, threshold * 0.5 + 0.02, dist));
    }
    // Bottom edge (uv.y approaching 1.0)
    if (edge_mask.z > 0.5) {
        float dist = 1.0 - uv.y;
        float noise_val = fbm_noise(noise_pos + vec2(113.0, 0.0));
        float threshold = edge_fade_width * noise_val;
        alpha = min(alpha, smoothstep(0.0, threshold * 0.5 + 0.02, dist));
    }
    // Top edge (uv.y approaching 0.0)
    if (edge_mask.w > 0.5) {
        float dist = uv.y;
        float noise_val = fbm_noise(noise_pos + vec2(0.0, 157.0));
        float threshold = edge_fade_width * noise_val;
        alpha = min(alpha, smoothstep(0.0, threshold * 0.5 + 0.02, dist));
    }

    return alpha;
}

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
    float wave_coord;
    if (flow_magnitude > 0.001) {
        vec2 perpendicular = vec2(-flow_dir_norm.y, flow_dir_norm.x);
        wave_coord = dot(distorted_uv, perpendicular) * wave_frequency;
        wave_coord -= time * wave_speed * flow_speed * flow_magnitude;
    } else {
        wave_coord = (distorted_uv.x + distorted_uv.y) * wave_frequency * 0.5;
        wave_coord -= time * wave_speed * 0.3;
    }

    float wave_pattern = sin(wave_coord * 6.28318);
    wave_pattern = pow(abs(wave_pattern), 1.0 / wave_sharpness) * sign(wave_pattern);
    float wave_intensity = (wave_pattern * 0.5 + 0.5) * wave_amplitude;

    // Secondary wave layer
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

    float combined_waves = wave_intensity + wave_intensity2;
    float wave_highlight = smoothstep(0.1, 0.15, combined_waves) * wave_brightness;

    float flow_alpha = mix(0.8, 1.0, flow_magnitude * flow_speed);

    vec3 final_color = mix(water_color.rgb, wave_color.rgb, wave_highlight);

    // Shimmer along flow direction
    float shimmer = 0.0;
    if (flow_magnitude > 0.001) {
        float shimmer_coord = dot(distorted_uv, flow_dir_norm) * 8.0 - time * 3.0;
        shimmer = pow(abs(sin(shimmer_coord * 6.28318)), 8.0) * 0.2 * flow_magnitude;
    }
    final_color += vec3(shimmer);

    // Apply edge noise displacement
    float edge_alpha = compute_edge_alpha(uv);

    COLOR = vec4(final_color, water_color.a * flow_alpha * edge_alpha);
}
