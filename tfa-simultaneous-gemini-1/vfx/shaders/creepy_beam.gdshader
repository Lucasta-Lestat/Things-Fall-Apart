// creepy_beam.gdshader - Necrotic life-drain beam strip overlay
shader_type canvas_item;

uniform float time : hint_range(0.0, 100.0) = 0.0;
uniform float flow_speed : hint_range(0.0, 5.0) = 1.6;
uniform vec4 core_color : source_color = vec4(0.95, 0.75, 1.0, 1.0);
uniform vec4 glow_color : source_color = vec4(0.55, 0.18, 0.7, 1.0);
uniform vec4 halo_color : source_color = vec4(0.25, 0.05, 0.4, 1.0);
uniform float stripe_density : hint_range(1.0, 30.0) = 7.0;
uniform float intensity : hint_range(0.0, 2.0) = 1.0;

float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void fragment() {
    // Vertical falloff (soft edges along the perpendicular axis)
    float d = abs(UV.y - 0.5) * 2.0;
    float vert = pow(max(0.0, 1.0 - d), 2.5);

    // Length-axis taper so the strip fades into caster/impact endpoints
    float taper = smoothstep(0.0, 0.04, UV.x) * smoothstep(0.0, 0.04, 1.0 - UV.x);

    // Energy stripes flowing toward the caster (UV.x = 0)
    float t = UV.x + time * flow_speed;
    float wave = sin(t * stripe_density * 6.2831853 + UV.y * 6.0) * 0.5 + 0.5;

    // Color gradient by distance from the center axis
    vec3 col = mix(halo_color.rgb, glow_color.rgb, smoothstep(0.0, 0.55, vert));
    col = mix(col, core_color.rgb, smoothstep(0.7, 1.0, vert));

    // Stripe highlight modulation
    col += glow_color.rgb * wave * 0.4 * vert;

    // Sparkling embers along the beam
    float sparkle = step(0.97, hash(floor(UV * vec2(42.0, 8.0)) + floor(time * 4.0))) * vert;
    col += core_color.rgb * sparkle * 0.9;

    float alpha = vert * taper * (0.6 + 0.4 * wave) * intensity;
    COLOR = vec4(col, alpha);
}
