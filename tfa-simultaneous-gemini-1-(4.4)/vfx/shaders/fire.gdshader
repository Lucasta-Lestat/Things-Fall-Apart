shader_type canvas_item;

uniform float time : hint_range(0.0, 10.0) = 0.0;
uniform float flame_height : hint_range(0.1, 2.0) = 1.0;
uniform float flame_intensity : hint_range(0.5, 3.0) = 1.5;
uniform vec2 resolution = vec2(100.0, 100.0);
uniform float time_seed : hint_range(0.0, 1000.0) = 0.0;

// Noise function for fire turbulence
float noise(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7)) + time_seed) * 43758.5453);
}

float fbm(vec2 p) {
    float value = 0.0;
    float amplitude = 0.5;
    for (int i = 0; i < 4; i++) {
        value += amplitude * noise(p);
        p *= 2.0;
        amplitude *= 0.5;
    }
    return value;
}

void fragment() {
    vec2 uv = UV;
    vec2 pos = uv * 2.0 - 1.0;

    // Create fire shape - taller at bottom, narrower at top
    float fire_shape = (1.0 - uv.y) * (1.0 - abs(pos.x) * (0.5 + uv.y));

    // Add turbulence
    vec2 noise_uv = uv * 3.0 + vec2(time * 0.1, time * 0.3);
    float turbulence = fbm(noise_uv) * 0.5;

    // Animate the fire upward
    float animated_fire = fire_shape + turbulence - (uv.y * flame_height);
    animated_fire += sin(time * 2.0 + uv.x * 10.0) * 0.1;

    // Create fire colors
    vec3 fire_color1 = vec3(1.0, 0.3, 0.0);  // Red-orange
    vec3 fire_color2 = vec3(1.0, 0.8, 0.0);  // Yellow-orange
    vec3 fire_color3 = vec3(0.8, 0.1, 0.0);  // Dark red

    // Color gradient based on height
    vec3 final_color;
    if (uv.y < 0.3) {
        final_color = mix(fire_color3, fire_color1, uv.y / 0.3);
    } else if (uv.y < 0.7) {
        final_color = mix(fire_color1, fire_color2, (uv.y - 0.3) / 0.4);
    } else {
        final_color = mix(fire_color2, vec3(1.0), (uv.y - 0.7) / 0.3);
    }

    // Apply fire intensity
    final_color *= flame_intensity;

    // Alpha based on fire shape
    float alpha = clamp(animated_fire, 0.0, 1.0);
    alpha *= (1.0 - uv.y * 0.3);  // Fade at top

    // Add flicker
    alpha *= (0.8 + 0.2 * sin(time * 8.0 + uv.y * 20.0));

    COLOR = vec4(final_color, alpha);
}