shader_type canvas_item;

#include "res://vfx/shaders/lib/fluid_common.gdshaderinc"

uniform vec2 flow_direction = vec2(0.0, 0.0);
uniform float flow_speed = 0.2;

uniform vec4 water_color : source_color = vec4(0.12, 0.1, 0.07, 0.75);
uniform vec4 wave_color : source_color = vec4(0.2, 0.15, 0.1, 0.4);

uniform float sheen_intensity = 0.25;
uniform float sheen_scale = 1.2;
uniform float sheen_speed = 0.15;

// Edge/fill/noise helpers + their uniforms live in fluid_common.gdshaderinc.

void fragment() {
    vec2 uv = UV;
    float time = TIME;
    vec2 world_uv = tile_position + uv;

    vec2 drift = vec2(
        sin(world_uv.y * 3.0 + time * 0.2) * 0.01,
        cos(world_uv.x * 3.0 + time * 0.15) * 0.01
    );
    vec2 wuv = world_uv + drift;

    float angle = dot(wuv, vec2(cos(time * sheen_speed * 0.7), sin(time * sheen_speed))) * sheen_scale;
    angle += sin(wuv.x * 2.5 + time * 0.2) * 0.3 + cos(wuv.y * 2.0 - time * 0.15) * 0.25;

    vec3 sheen;
    sheen.r = sin(angle * 2.0) * 0.5 + 0.5;
    sheen.g = sin(angle * 2.0 + 2.094) * 0.5 + 0.5;
    sheen.b = sin(angle * 2.0 + 4.189) * 0.5 + 0.5;
    sheen = mix(vec3(dot(sheen, vec3(0.299, 0.587, 0.114))), sheen, 0.5);

    float surface_var = fbm(wuv * 2.0 + time * 0.1);
    surface_var = mix(0.85, 1.0, surface_var);

    vec3 base = water_color.rgb * surface_var;
    vec3 final_color = mix(base, base + sheen * 0.3, sheen_intensity * surface_var);

    float spec = fbm(wuv * 3.0 - time * 0.15);
    spec = pow(spec, 3.0) * 0.1;
    final_color += vec3(spec);

    float edge_alpha = compute_edge_alpha(uv, world_uv);
    float fill_alpha = compute_fill_alpha(uv, world_uv);
    COLOR = vec4(final_color, water_color.a * edge_alpha * fill_alpha);
}
