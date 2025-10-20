// sound_waves.gdshader - Sound Wave Effect
shader_type canvas_item;

uniform float time : hint_range(0.0, 10.0) = 0.0;
uniform float wave_frequency : hint_range(1.0, 10.0) = 4.0;
uniform float wave_amplitude : hint_range(0.1, 1.0) = 0.3;
uniform vec2 resolution = vec2(100.0, 100.0);

void fragment() {
    vec2 uv = UV;
    vec2 center = vec2(0.5, 0.5);
    float dist = distance(uv, center);

    // Create concentric sound waves
    float wave = sin(dist * wave_frequency * 6.28 - time * 8.0) * wave_amplitude;
    wave *= exp(-dist * 2.0); // Fade with distance

    // Multiple wave frequencies for complexity
    float wave2 = sin(dist * wave_frequency * 4.0 - time * 6.0) * wave_amplitude * 0.6;
    wave2 *= exp(-dist * 1.5);

    float wave3 = sin(dist * wave_frequency * 8.0 - time * 10.0) * wave_amplitude * 0.4;
    wave3 *= exp(-dist * 3.0);

    float total_wave = wave + wave2 + wave3;

    // Sound wave colors (blue-white)
    vec3 wave_color = vec3(0.5, 0.8, 1.0);
    float intensity = abs(total_wave);

    // Add ring highlights
    float ring = 1.0 - smoothstep(0.02, 0.06, abs(total_wave));
    ring *= (1.0 - dist);

    vec3 final_color = wave_color * intensity + ring * vec3(1.0);
    float alpha = intensity + ring * 0.8;

    COLOR = vec4(final_color, alpha);
}