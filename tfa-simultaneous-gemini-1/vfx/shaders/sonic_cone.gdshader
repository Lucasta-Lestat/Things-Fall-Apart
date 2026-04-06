// sonic_cone.gdshader - Sound Wave Effect constrained to a cone
shader_type canvas_item;

uniform float time : hint_range(0.0, 10.0) = 0.0;
uniform float wave_frequency : hint_range(1.0, 10.0) = 4.0;
uniform float wave_amplitude : hint_range(0.1, 1.0) = 0.3;
uniform vec2 resolution = vec2(100.0, 100.0);
uniform float cone_half_angle : hint_range(0.0, 3.14159) = 0.524; // radians, default ~30 deg

void fragment() {
    vec2 uv = UV;
    // Cone originates from center-left (0.0, 0.5), opening to the right (+X)
    vec2 origin = vec2(0.0, 0.5);
    vec2 pos = uv - origin;

    float dist = length(pos);
    float angle = atan(pos.y, pos.x); // angle from +X axis

    // Cone mask: only render within the cone angle
    float cone_mask = 1.0 - smoothstep(cone_half_angle - 0.05, cone_half_angle + 0.05, abs(angle));

    // Create concentric sound waves from origin
    float wave = sin(dist * wave_frequency * 6.28 - time * 8.0) * wave_amplitude;
    wave *= exp(-dist * 2.0);

    float wave2 = sin(dist * wave_frequency * 4.0 - time * 6.0) * wave_amplitude * 0.6;
    wave2 *= exp(-dist * 1.5);

    float wave3 = sin(dist * wave_frequency * 8.0 - time * 10.0) * wave_amplitude * 0.4;
    wave3 *= exp(-dist * 3.0);

    float total_wave = wave + wave2 + wave3;

    // Sound wave colors (blue-white)
    vec3 wave_color = vec3(0.5, 0.8, 1.0);
    float intensity = abs(total_wave);

    // Ring highlights
    float ring = 1.0 - smoothstep(0.02, 0.06, abs(total_wave));
    ring *= (1.0 - dist);

    vec3 final_color = wave_color * intensity + ring * vec3(1.0);
    float alpha = (intensity + ring * 0.8) * cone_mask;

    // Soft edge falloff at max range
    alpha *= 1.0 - smoothstep(0.8, 1.0, dist);

    COLOR = vec4(final_color, alpha);
}
