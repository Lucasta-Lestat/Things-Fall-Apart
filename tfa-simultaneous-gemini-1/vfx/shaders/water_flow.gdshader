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

// World-space tile position for cross-tile continuity
uniform vec2 tile_position = vec2(0.0);

// Edge noise displacement — vec4(right, left, bottom, top)
// 1.0 = exposed boundary edge, 0.0 = neighbor present
uniform vec4 edge_mask = vec4(0.0);
uniform float edge_fade_width = 0.4;
uniform float edge_noise_scale = 6.0;

// Inside-corner fade — vec4(top-right, top-left, bottom-left, bottom-right)
// 1.0 = both adjacent edges have neighbors but the diagonal tile is missing,
// so the corner pixel would otherwise stick out into the gap.
uniform vec4 corner_mask = vec4(0.0);

// --- Noise functions ---
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

    // Per-edge fade: compute distance from each exposed edge
    // and use noise to create an irregular threshold
    float right_a = 1.0, left_a = 1.0, bottom_a = 1.0, top_a = 1.0;

    if (edge_mask.x > 0.5) { // right
        float dist = 1.0 - uv.x;
        float n = fbm(noise_pos + vec2(37.0, 0.0));
        right_a = smoothstep(0.0, edge_fade_width * n * 0.6 + 0.02, dist);
    }
    if (edge_mask.y > 0.5) { // left
        float dist = uv.x;
        float n = fbm(noise_pos + vec2(0.0, 71.0));
        left_a = smoothstep(0.0, edge_fade_width * n * 0.6 + 0.02, dist);
    }
    if (edge_mask.z > 0.5) { // bottom
        float dist = 1.0 - uv.y;
        float n = fbm(noise_pos + vec2(113.0, 0.0));
        bottom_a = smoothstep(0.0, edge_fade_width * n * 0.6 + 0.02, dist);
    }
    if (edge_mask.w > 0.5) { // top
        float dist = uv.y;
        float n = fbm(noise_pos + vec2(0.0, 157.0));
        top_a = smoothstep(0.0, edge_fade_width * n * 0.6 + 0.02, dist);
    }

    // Multiply edges together — corners (2 edges meeting) get much stronger erosion
    alpha = right_a * left_a * bottom_a * top_a;

    // Inside-corner fade: round off any corner whose two adjacent edges are closed
    // but whose diagonal tile is missing, so the corner doesn't poke into the gap.
    if (corner_mask.x > 0.5) { // top-right (UV (1,0))
        float dx = 1.0 - uv.x;
        float dy = uv.y;
        float n = fbm(noise_pos + vec2(43.0, 197.0));
        alpha *= smoothstep(0.0, edge_fade_width * n * 0.6 + 0.02, sqrt(dx*dx + dy*dy));
    }
    if (corner_mask.y > 0.5) { // top-left (UV (0,0))
        float n = fbm(noise_pos + vec2(53.0, 91.0));
        alpha *= smoothstep(0.0, edge_fade_width * n * 0.6 + 0.02, length(uv));
    }
    if (corner_mask.z > 0.5) { // bottom-left (UV (0,1))
        float dx = uv.x;
        float dy = 1.0 - uv.y;
        float n = fbm(noise_pos + vec2(107.0, 211.0));
        alpha *= smoothstep(0.0, edge_fade_width * n * 0.6 + 0.02, sqrt(dx*dx + dy*dy));
    }
    if (corner_mask.w > 0.5) { // bottom-right (UV (1,1))
        float dx = 1.0 - uv.x;
        float dy = 1.0 - uv.y;
        float n = fbm(noise_pos + vec2(67.0, 179.0));
        alpha *= smoothstep(0.0, edge_fade_width * n * 0.6 + 0.02, sqrt(dx*dx + dy*dy));
    }
    return alpha;
}

void fragment() {
    vec2 uv = UV;
    float time = TIME;
    vec2 world_uv = tile_position + uv;

    float flow_magnitude = length(flow_direction);
    vec2 flow_dir_norm = flow_magnitude > 0.001 ? normalize(flow_direction) : vec2(0.0);

    vec2 distort_offset = vec2(
        sin(world_uv.y * 10.0 + time * distortion_speed) * distortion_strength,
        cos(world_uv.x * 10.0 + time * distortion_speed) * distortion_strength
    );
    vec2 wuv_d = world_uv + distort_offset;

    float wave_coord;
    if (flow_magnitude > 0.001) {
        vec2 perp = vec2(-flow_dir_norm.y, flow_dir_norm.x);
        wave_coord = dot(wuv_d, perp) * wave_frequency;
        wave_coord -= time * wave_speed * flow_speed * flow_magnitude;
    } else {
        wave_coord = (wuv_d.x + wuv_d.y) * wave_frequency * 0.5;
        wave_coord -= time * wave_speed * 0.3;
    }

    float wp = sin(wave_coord * 6.28318);
    wp = pow(abs(wp), 1.0 / wave_sharpness) * sign(wp);
    float wi = (wp * 0.5 + 0.5) * wave_amplitude;

    float wave_coord2;
    if (flow_magnitude > 0.001) {
        vec2 perp2 = vec2(-flow_dir_norm.y, flow_dir_norm.x);
        wave_coord2 = dot(wuv_d, perp2) * wave_frequency * 1.7;
        wave_coord2 -= time * wave_speed * flow_speed * flow_magnitude * 0.7;
    } else {
        wave_coord2 = (wuv_d.x - wuv_d.y) * wave_frequency * 0.7;
        wave_coord2 -= time * wave_speed * 0.2;
    }
    float wi2 = (sin(wave_coord2 * 6.28318) * 0.25 + 0.25) * wave_amplitude;

    float wave_highlight = smoothstep(0.1, 0.15, wi + wi2) * wave_brightness;
    float flow_alpha = 1.0;

    vec3 final_color = mix(water_color.rgb, wave_color.rgb, wave_highlight);

    if (flow_magnitude > 0.001) {
        float sc = dot(wuv_d, flow_dir_norm) * 8.0 - time * 3.0;
        final_color += vec3(pow(abs(sin(sc * 6.28318)), 8.0) * 0.2 * flow_magnitude);
    }

    float edge_alpha = compute_edge_alpha(uv, world_uv);
    COLOR = vec4(final_color, water_color.a * flow_alpha * edge_alpha);
}
