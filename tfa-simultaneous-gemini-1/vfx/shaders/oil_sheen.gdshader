shader_type canvas_item;

// Flow
uniform vec2 flow_direction = vec2(0.0, 0.0);
uniform float flow_speed = 0.2;

// Base oil color
uniform vec4 water_color : source_color = vec4(0.12, 0.1, 0.07, 0.75);
uniform vec4 wave_color : source_color = vec4(0.2, 0.15, 0.1, 0.4);

// Iridescence — kept subtle and low-frequency
uniform float sheen_intensity = 0.25;
uniform float sheen_scale = 1.2; // low = large continuous bands across many tiles
uniform float sheen_speed = 0.15;

// World-space tile position for cross-tile continuity
uniform vec2 tile_position = vec2(0.0);

// Edge noise
uniform vec4 edge_mask = vec4(0.0);
uniform float edge_fade_width = 0.35;
uniform float edge_noise_scale = 6.0;

// --- Noise ---
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

float fbm(vec2 p) {
    float v = 0.0;
    v += value_noise(p) * 0.5;
    v += value_noise(p * 2.0 + 17.0) * 0.25;
    v += value_noise(p * 4.0 + 31.0) * 0.125;
    return v / 0.875;
}

float compute_edge_alpha(vec2 uv, vec2 world_uv) {
    float alpha = 1.0;
    vec2 noise_pos = world_uv * edge_noise_scale;

    if (edge_mask.x > 0.5) {
        float dist = 1.0 - uv.x;
        float n = fbm(noise_pos + vec2(37.0, 0.0));
        alpha = min(alpha, smoothstep(0.0, edge_fade_width * n * 0.5 + 0.02, dist));
    }
    if (edge_mask.y > 0.5) {
        float dist = uv.x;
        float n = fbm(noise_pos + vec2(0.0, 71.0));
        alpha = min(alpha, smoothstep(0.0, edge_fade_width * n * 0.5 + 0.02, dist));
    }
    if (edge_mask.z > 0.5) {
        float dist = 1.0 - uv.y;
        float n = fbm(noise_pos + vec2(113.0, 0.0));
        alpha = min(alpha, smoothstep(0.0, edge_fade_width * n * 0.5 + 0.02, dist));
    }
    if (edge_mask.w > 0.5) {
        float dist = uv.y;
        float n = fbm(noise_pos + vec2(0.0, 157.0));
        alpha = min(alpha, smoothstep(0.0, edge_fade_width * n * 0.5 + 0.02, dist));
    }
    return alpha;
}

void fragment() {
    vec2 uv = UV;
    float time = TIME;
    // World-continuous coordinate
    vec2 world_uv = tile_position + uv;

    // Slow organic drift — world-space so it's continuous
    vec2 drift = vec2(
        sin(world_uv.y * 3.0 + time * 0.2) * 0.01,
        cos(world_uv.x * 3.0 + time * 0.15) * 0.01
    );
    vec2 wuv = world_uv + drift;

    // Thin-film interference at LOW frequency across the whole fluid body
    // The key: sheen_scale is low (~1.2) so color bands span multiple tiles
    float angle = dot(wuv, vec2(cos(time * sheen_speed * 0.7), sin(time * sheen_speed))) * sheen_scale;
    angle += sin(wuv.x * 2.5 + time * 0.2) * 0.3 + cos(wuv.y * 2.0 - time * 0.15) * 0.25;

    // Muted rainbow from thin-film interference
    vec3 sheen;
    sheen.r = sin(angle * 2.0) * 0.5 + 0.5;
    sheen.g = sin(angle * 2.0 + 2.094) * 0.5 + 0.5;
    sheen.b = sin(angle * 2.0 + 4.189) * 0.5 + 0.5;
    // Desaturate the rainbow — real oil sheen is subtle, not neon
    sheen = mix(vec3(dot(sheen, vec3(0.299, 0.587, 0.114))), sheen, 0.5);

    // Gentle surface variation
    float surface_var = fbm(wuv * 2.0 + time * 0.1);
    surface_var = mix(0.85, 1.0, surface_var);

    // Combine: dark oil base with subtle sheen on top
    vec3 base = water_color.rgb * surface_var;
    vec3 final_color = mix(base, base + sheen * 0.3, sheen_intensity * surface_var);

    // Subtle specular highlight
    float spec = fbm(wuv * 3.0 - time * 0.15);
    spec = pow(spec, 3.0) * 0.1;
    final_color += vec3(spec);

    float edge_alpha = compute_edge_alpha(uv, world_uv);
    COLOR = vec4(final_color, water_color.a * edge_alpha);
}
