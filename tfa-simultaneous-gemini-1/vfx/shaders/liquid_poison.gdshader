shader_type canvas_item;

uniform float time : hint_range(0.0, 10.0) = 0.0;
uniform float bubble_size : hint_range(0.05, 0.3) = 0.1;
uniform vec4 liquid_color : source_color = vec4(0.2, 0.8, 0.1, 1.0);
uniform vec2 resolution = vec2(100.0, 100.0);
uniform float time_seed : hint_range(0.0, 1000.0) = 0.0;

float random(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7)) + time_seed) * 43758.5453);
}

float noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);

    return mix(
        mix(random(i + vec2(0.0, 0.0)), random(i + vec2(1.0, 0.0)), u.x),
        mix(random(i + vec2(0.0, 1.0)), random(i + vec2(1.0, 1.0)), u.x),
        u.y
    );
}

// Create bubbles
float bubble(vec2 uv, vec2 center, float radius, float time_offset) {
    float dist = distance(uv, center);
    float bubble_edge = smoothstep(radius - 0.01, radius, dist) -
                       smoothstep(radius, radius + 0.01, dist);

    // Animate bubble size
    float size_variation = sin(time * 3.0 + time_offset) * 0.3 + 1.0;
    radius *= size_variation;

    float bubble_fill = 1.0 - smoothstep(0.0, radius, dist);
    return max(bubble_edge * 3.0, bubble_fill * 0.3);
}

void fragment() {
    vec2 uv = UV;

    // Base liquid color with slight movement
    vec2 liquid_uv = uv + vec2(
        sin(time * 0.5 + uv.y * 8.0) * 0.02,
        cos(time * 0.3 + uv.x * 6.0) * 0.015
    );

    // Create base liquid texture
    float liquid_noise = noise(liquid_uv * 8.0 + time * 0.2) * 0.3;
    vec3 base_color = liquid_color.rgb + liquid_noise * 0.1;

    // Create multiple bubbles
    float bubbles = 0.0;
    int bubble_count = 8;

    for (int i = 0; i < bubble_count; i++) {
        float fi = float(i);

        // Bubble position with some movement
        vec2 bubble_pos = vec2(
            0.2 + (fi / float(bubble_count - 1)) * 0.6,
            0.8 - mod(time * 0.1 + fi * 0.3, 1.0)
        );

        // Add horizontal drift
        bubble_pos.x += sin(time * 0.8 + fi * 2.0) * 0.1;

        float radius = bubble_size * (0.5 + random(vec2(fi)) * 0.5);
        bubbles += bubble(uv, bubble_pos, radius, fi * 1.5);
    }

    // Surface bubbles (smaller, more frequent)
    for (int i = 0; i < 12; i++) {
        float fi = float(i);
        vec2 surface_pos = vec2(
            random(vec2(fi, 1.0)),
            0.9 + sin(time * 2.0 + fi) * 0.05
        );

        float small_radius = bubble_size * 0.3;
        bubbles += bubble(uv, surface_pos, small_radius, fi * 0.8) * 0.5;
    }

    // Add bubble highlights
    vec3 bubble_color = vec3(0.8, 1.0, 0.6); // Lighter green
    vec3 final_color = base_color + bubbles * bubble_color;

    // Add liquid surface distortion
    float surface_y = 0.95 + sin(time * 2.0 + uv.x * 10.0) * 0.02;
    if (uv.y > surface_y) {
        // Surface reflection
        final_color += vec3(0.2, 0.4, 0.1) * (uv.y - surface_y) * 10.0;
    }

    // Add poisonous glow effect
    float edge_glow = 1.0 - smoothstep(0.85, 1.0, length(uv - 0.5));
    final_color += liquid_color.rgb * edge_glow * 0.3;

    // Toxic pulsing
    float toxic_pulse = 0.9 + 0.1 * sin(time * 4.0);
    final_color *= toxic_pulse;

    COLOR = vec4(final_color, liquid_color.a);
}