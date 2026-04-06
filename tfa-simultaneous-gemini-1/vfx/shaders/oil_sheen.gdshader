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
    // Use angle-dependent color shift like oil on water
    float angle = dot(uv_d, vec2(cos(time * sheen_speed * 0.7), sin(time * sheen_speed))) * sheen_scale;
    angle += sin(uv_d.x * 8.0 + time * 0.5) * 0.5 + cos(uv_d.y * 6.0 - time * 0.3) * 0.4;

    // Create rainbow-ish color bands from thin-film interference
    vec3 sheen;
    sheen.r = sin(angle * 2.0) * 0.5 + 0.5;
    sheen.g = sin(angle * 2.0 + 2.094) * 0.5 + 0.5; // +2pi/3
    sheen.b = sin(angle * 2.0 + 4.189) * 0.5 + 0.5; // +4pi/3

    // Subtle undulating brightness for oily surface
    float surface_var = sin(uv_d.x * 4.0 + uv_d.y * 3.0 + time * 0.4) * 0.5 + 0.5;
    surface_var = mix(0.8, 1.0, surface_var);

    // Combine base oil color with iridescent sheen
    vec3 base = water_color.rgb * surface_var;
    vec3 final_color = mix(base, sheen, sheen_intensity * surface_var);

    // Subtle highlight at wave peaks
    float wave = sin((uv_d.x + uv_d.y) * 5.0 - time * 0.6) * 0.5 + 0.5;
    wave = pow(wave, 4.0) * 0.15;
    final_color += vec3(wave);

    COLOR = vec4(final_color, water_color.a);
}
