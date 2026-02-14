shader_type canvas_item;

uniform float time : hint_range(0.0, 10.0) = 0.0;
uniform float bolt_intensity : hint_range(0.5, 3.0) = 2.0;
uniform float flicker_speed : hint_range(1.0, 20.0) = 10.0;
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

// Function to create jagged lightning bolt
float lightning_bolt(vec2 uv, float seed) {
    float bolt = 0.0;

    // Main lightning path
    vec2 start = vec2(0.5, 0.1);
    vec2 end = vec2(0.5, 0.9);

    // Create multiple segments with random deviation
    int segments = 8;
    vec2 current = start;

    for (int i = 0; i < segments; i++) {
        float t = float(i) / float(segments - 1);
        vec2 target = mix(start, end, t);

        // Add random deviation
        float deviation = (noise(vec2(float(i) + seed, time * 2.0)) - 0.5) * 0.3;
        target.x += deviation;

        // Calculate distance from UV to line segment
        vec2 next_pos = (i == segments - 1) ? end : target;
        float dist_to_segment = distance_to_line(uv, current, next_pos);

        // Create bolt thickness
        float thickness = 0.01 + (noise(vec2(float(i), time * 5.0)) * 0.005);
        bolt += 1.0 - smoothstep(0.0, thickness, dist_to_segment);

        current = target;
    }

    return bolt;
}

float distance_to_line(vec2 p, vec2 a, vec2 b) {
    vec2 pa = p - a;
    vec2 ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h);
}

void fragment() {
    vec2 uv = UV;

    // Create multiple lightning bolts
    float main_bolt = lightning_bolt(uv, 1.0);
    float branch1 = lightning_bolt(uv + vec2(0.1, 0.0), 2.0) * 0.6;
    float branch2 = lightning_bolt(uv - vec2(0.1, 0.0), 3.0) * 0.4;

    // Combine bolts
    float total_lightning = main_bolt + branch1 + branch2;

    // Add electrical discharge effect around bolts
    float electric_field = 0.0;
    for (int i = 0; i < 3; i++) {
        vec2 spark_pos = vec2(
            0.5 + sin(time * 15.0 + float(i) * 2.0) * 0.2,
            0.2 + float(i) * 0.3
        );
        float dist_to_spark = distance(uv, spark_pos);
        electric_field += (0.02 / (dist_to_spark + 0.01)) *
                         (0.5 + 0.5 * sin(time * 20.0 + float(i) * 3.14));
    }

    // Create lightning colors
    vec3 lightning_core = vec3(1.0, 1.0, 1.0);      // White core
    vec3 lightning_glow = vec3(0.7, 0.9, 1.0);      // Blue glow
    vec3 electric_color = vec3(0.5, 0.8, 1.0);      // Electric blue

    // Combine effects
    vec3 final_color = vec3(0.0);
    float total_alpha = 0.0;

    if (total_lightning > 0.0) {
        final_color += lightning_core * total_lightning;
        final_color += lightning_glow * total_lightning * 0.5;
        total_alpha += total_lightning;
    }

    if (electric_field > 0.0) {
        final_color += electric_color * electric_field;
        total_alpha += electric_field;
    }

    // Apply intensity and flickering
    final_color *= bolt_intensity;

    // Random flicker effect
    float flicker = 0.7 + 0.3 * noise(vec2(time * flicker_speed));
    final_color *= flicker;
    total_alpha *= flicker;

    // Clamp values
    final_color = clamp(final_color, 0.0, 1.0);
    total_alpha = clamp(total_alpha, 0.0, 1.0);

    COLOR = vec4(final_color, total_alpha);
}