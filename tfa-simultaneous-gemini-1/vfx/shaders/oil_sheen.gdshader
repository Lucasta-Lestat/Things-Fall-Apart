shader_type canvas_item;

// Flow direction and speed
uniform vec2 flow_direction = vec2(0.0, 0.0);
uniform float flow_speed = 0.2;

// Base oil color
uniform vec4 water_color : source_color = vec4(0.12, 0.1, 0.07, 0.75);
uniform vec4 wave_color : source_color = vec4(0.2, 0.15, 0.1, 0.4);

// Iridescence parameters
uniform float sheen_intensity = 0.35;
uniform float sheen_scale = 3.0;
uniform float sheen_speed = 0.4;

// Edge noise displacement — vec4(right, left, bottom, top)
uniform vec4 edge_mask = vec4(0.0);
uniform float edge_fade_width = 0.35;
uniform float edge_noise_scale = 8.0;

// Simple hash-based noise
float hash(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

float value_noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
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
    float alpha = 1.0;
    vec2 noise_pos = uv * edge_noise_scale;

    if (edge_mask.x > 0.5) {
        float dist = 1.0 - uv.x;
        float noise_val = fbm_noise(noise_pos + vec2(37.0, 0.0));
        float threshold = edge_fade_width * noise_val;
        alpha = min(alpha, smoothstep(0.0, threshold * 0.5 + 0.02, dist));
    }
    if (edge_mask.y > 0.5) {
        float dist = uv.x;
        float noise_val = fbm_noise(noise_pos + vec2(0.0, 71.0));
        float threshold = edge_fade_width * noise_val;
        alpha = min(alpha, smoothstep(0.0, threshold * 0.5 + 0.02, dist));
    }
    if (edge_mask.z > 0.5) {
        float dist = 1.0 - uv.y;
        float noise_val = fbm_noise(noise_pos + vec2(113.0, 0.0));
        float threshold = edge_fade_width * noise_val;
        alpha = min(alpha, smoothstep(0.0, threshold * 0.5 + 0.02, dist));
    }
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

    float flow_mag = length(flow_direction);
    vec2 flow_norm = flow_mag > 0.001 ? normalize(flow_direction) : vec2(0.0, 0.0);

    // Slow drifting distortion for oily movement
    vec2 drift = vec2(
        sin(uv.y * 6.0 + time * 0.3) * 0.015,
        cos(uv.x * 6.0 + time * 0.25) * 0.015
    );
    vec2 uv_d = uv + drift;

    // Thin-film interference / iridescent sheen
    float angle = dot(uv_d, vec2(cos(time * sheen_speed * 0.7), sin(time * sheen_speed))) * sheen_scale;
    angle += sin(uv_d.x * 8.0 + time * 0.5) * 0.5 + cos(uv_d.y * 6.0 - time * 0.3) * 0.4;

    vec3 sheen;
    sheen.r = sin(angle * 2.0) * 0.5 + 0.5;
    sheen.g = sin(angle * 2.0 + 2.094) * 0.5 + 0.5;
    sheen.b = sin(angle * 2.0 + 4.189) * 0.5 + 0.5;

    float surface_var = sin(uv_d.x * 4.0 + uv_d.y * 3.0 + time * 0.4) * 0.5 + 0.5;
    surface_var = mix(0.8, 1.0, surface_var);

    vec3 base = water_color.rgb * surface_var;
    vec3 final_color = mix(base, sheen, sheen_intensity * surface_var);

    float wave = sin((uv_d.x + uv_d.y) * 5.0 - time * 0.6) * 0.5 + 0.5;
    wave = pow(wave, 4.0) * 0.15;
    final_color += vec3(wave);

    // Apply edge noise displacement
    float edge_alpha = compute_edge_alpha(uv);

    COLOR = vec4(final_color, water_color.a * edge_alpha);
}
