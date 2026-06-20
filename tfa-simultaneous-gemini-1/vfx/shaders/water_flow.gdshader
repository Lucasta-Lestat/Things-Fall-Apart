shader_type canvas_item;

// Rich-stylized top-down water. Builds an animated height field (flow waves +
// flow-advected fbm + reactive ripples), derives a surface normal from it, and
// lights it with an art-directed sun (no engine lights exist) for moving
// crests, Blinn-Phong specular and sharp sun-glitter. Adds animated caustics,
// churning shoreline foam (hugging the organic eroded edge), depth-graded
// translucency, and optional screen-space refraction of the floor beneath.
// Shared noise / edge / fill / lighting / ripple helpers come from the include.

#include "res://vfx/shaders/lib/fluid_common.gdshaderinc"

// Refraction of the floor behind the water (water-only; needs the BackBufferCopy
// under the fluid layer). 0 = no wobble (safe fallback); still samples the floor
// for the wet look.
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform float refraction_strength = 0.012;

// Flow (set per tile by FluidManager)
uniform vec2 flow_direction = vec2(0.0, 0.0);
uniform float flow_speed = 0.5;

// Wave shape
uniform float wave_speed = 2.0;
uniform float wave_frequency = 3.2;
uniform float wave_amplitude : hint_range(0.0, 1.5) = 0.6; // MASTER surface relief: calm<->choppy
uniform float distortion_strength = 0.02;
uniform float distortion_speed = 1.0;
uniform float viscosity = 1.0; // >1 = thicker/slower (blood, oil); scales animation

// Colors
uniform vec4 water_color : source_color = vec4(0.1, 0.35, 0.62, 0.78);
uniform vec4 wave_color : source_color = vec4(0.35, 0.75, 0.95, 0.5);
uniform vec4 foam_color : source_color = vec4(0.92, 0.97, 1.0, 1.0);
uniform float wave_brightness : hint_range(0.0, 1.0) = 0.16; // crest tint toward wave_color

// Lighting (art-directed sun, upper-left, slightly toward camera)
uniform vec3 light_dir = vec3(-0.5, -0.6, 0.62);
uniform float normal_strength : hint_range(0.5, 6.0) = 1.7; // higher = flatter surface
uniform float shininess : hint_range(2.0, 80.0) = 22.0;
uniform float specular_intensity : hint_range(0.0, 2.0) = 0.5;
uniform float sparkle_intensity : hint_range(0.0, 2.0) = 0.5;
// Strength of the light/shadow across the wave relief (the main diffuse "punch").
uniform float shading_contrast : hint_range(0.0, 0.6) = 0.18;

// Caustics
uniform float caustic_intensity : hint_range(0.0, 1.5) = 0.25;
uniform float caustic_scale : hint_range(1.0, 12.0) = 5.0;

// Foam
uniform float foam_amount : hint_range(0.0, 1.0) = 0.9;
uniform float foam_width : hint_range(0.0, 0.5) = 0.1;

// Depth grading: edge distance over which shallow->deep; emissive self-glow.
uniform float depth_width : hint_range(0.05, 1.0) = 0.5;
uniform float emissive : hint_range(0.0, 1.0) = 0.0;

// Global quality lever (set per tile by FluidManager). Scales the expensive
// effects (caustics, sun-glitter, refraction wobble) so they can be dialed down
// on low-end hardware. 1.0 = full, 0.0 = off.
uniform float effects_quality : hint_range(0.0, 1.0) = 1.0;

// Base surface height (broad 2D waves + flow-advected fbm), WITHOUT ripples.
// Two cross-running wave trains give the surface 2D structure (not 1D stripes)
// so the derived normal produces rolling light/shadow; fbm adds gentle detail.
float base_height(vec2 wp, float t) {
    float fmag = length(flow_direction);
    vec2 fdir = fmag > 0.001 ? normalize(flow_direction) : vec2(0.0);
    vec2 wperp = fmag > 0.001 ? vec2(-fdir.y, fdir.x) : vec2(0.7071, 0.7071);
    vec2 wperp2 = vec2(wperp.y, -wperp.x); // orthogonal train
    float wts = wave_speed * (fmag > 0.001 ? (0.25 + flow_speed * fmag * 0.5) : 0.25);
    wts /= max(viscosity, 0.25);

    // Domain-warp the wave coordinate so the wave lines wander (organic, not
    // a regular corduroy grid).
    float warp = (fbm(wp * 1.4 + t * 0.05) - 0.5) * 0.9;
    float c1 = (dot(wp, wperp) + warp) * wave_frequency - t * wts;
    float h = sin(c1 * 6.28318) * 0.6;
    float c2 = (dot(wp, wperp2) + warp * 0.7) * wave_frequency * 0.8 + t * wts * 0.7;
    h += sin(c2 * 6.28318) * 0.4;
    h += sin(c1 * 2.3) * 0.12; // harmonic ripple

    // Flow-advected fbm detail (scrolls along the current).
    vec2 adv = wp - fdir * t * flow_speed * 0.15;
    h += (fbm(adv * 2.0) - 0.5) * 0.45;
    h += (fbm(adv * 4.5 + 11.0) - 0.5) * 0.18;
    // wave_amplitude is the MASTER surface-relief knob: it scales the whole
    // height field, so it sets how choppy the surface looks AND how strong the
    // normal-derived lighting / specular / glitter / whitecaps are.
    return h * wave_amplitude;
}

// Total height used for the normal (so ripples catch the light too).
float total_height(vec2 wp, float t) {
    return base_height(wp, t) + ripple_height(wp) * 0.7;
}

void fragment() {
    vec2 uv = UV;
    float t = TIME / max(viscosity, 0.25);
    vec2 world_uv = tile_position + uv;

    // Small domain distortion (keeps the surface from looking gridded).
    vec2 dist_off = vec2(
        sin(world_uv.y * 10.0 + t * distortion_speed),
        cos(world_uv.x * 10.0 + t * distortion_speed)
    ) * distortion_strength;
    vec2 wp = world_uv + dist_off;

    // --- Surface normal from the height field (finite differences) ---
    float e = 0.02;
    float hL = total_height(wp - vec2(e, 0.0), t);
    float hR = total_height(wp + vec2(e, 0.0), t);
    float hD = total_height(wp + vec2(0.0, e), t);
    float hU = total_height(wp - vec2(0.0, e), t);
    vec3 N = normal_from_heights(hL, hR, hD, hU, normal_strength);
    vec3 L = normalize(light_dir);
    vec2 lit = water_lighting(N, L, shininess); // (diffuse, specular)
    float h_center = total_height(wp, t);

    // --- Depth grading (shore = lighter & clearer, interior = deeper) ---
    float edge_d = nearest_edge_distance(uv);
    float depth_t = smoothstep(0.0, depth_width, edge_d);
    vec3 shallow_col = mix(water_color.rgb, wave_color.rgb, 0.6) * 1.18;
    vec3 deep_col = water_color.rgb * 0.78;
    vec3 base = mix(shallow_col, deep_col, depth_t);

    // Diffuse shading from the wave normal (stylized — never crushes to black).
    base *= mix(1.0 - shading_contrast, 1.0 + shading_contrast, lit.x);

    // Wave-crest tint from the height field.
    float crest = smoothstep(0.1, 0.7, h_center * 0.5 + 0.5);
    base = mix(base, wave_color.rgb, crest * wave_brightness);

    // --- Caustics (bright web, stronger in shallows) ---
    float caus = caustics(world_uv * caustic_scale, t);
    vec3 caustic_col = mix(wave_color.rgb, vec3(1.0), 0.45);
    base += caustic_col * caus * caustic_intensity * (1.0 - depth_t * 0.5) * effects_quality;

    // --- Specular + sun glitter (warm sun) ---
    vec3 sun = vec3(1.0, 0.97, 0.88);
    base += sun * lit.y * specular_intensity;
    base += sun * sun_glitter(N, L, world_uv, t) * sparkle_intensity * effects_quality;

    // Emissive self-glow (toxic fluids); 0 for water.
    base += water_color.rgb * emissive;

    // --- Foam: shoreline band + fast-flow crests + ripple crests ---
    float churn = fbm(world_uv * 7.0 + vec2(t * 0.6, -t * 0.4));
    float foam = smoothstep(foam_width, 0.0, edge_d) * smoothstep(0.25, 0.7, churn);
    foam += smoothstep(0.5, 1.0, flow_speed)
            * smoothstep(0.7, 0.95, value_noise(world_uv * 5.0 - flow_direction * t)) * 0.6;
    foam = max(foam, ripple_foam(world_uv) * 0.9);
    foam = max(foam, smoothstep(0.85, 1.0, h_center * 0.5 + 0.5) * 0.22); // whitecaps
    foam = clamp(foam, 0.0, 1.0) * foam_amount;
    base = mix(base, foam_color.rgb, foam);

    // --- Opacity: shallow water hides the floor less; foam is opaque ---
    float water_opacity = mix(0.28, 0.82, depth_t);
    water_opacity = max(water_opacity, foam);

    // --- Compose with refraction of the floor behind ---
    vec2 off = N.xy * refraction_strength * effects_quality;
    // Chromatic dispersion at crests for a jewel-like edge sparkle.
    float chroma = lit.y * 0.4;
    vec3 floor_col;
    floor_col.r = texture(screen_tex, SCREEN_UV + off * (1.0 + chroma)).r;
    floor_col.g = texture(screen_tex, SCREEN_UV + off).g;
    floor_col.b = texture(screen_tex, SCREEN_UV + off * (1.0 - chroma)).b;

    vec3 out_rgb = mix(floor_col, base, water_opacity);

    float shape_alpha = compute_edge_alpha(uv, world_uv) * compute_fill_alpha(uv, world_uv);
    COLOR = vec4(out_rgb, shape_alpha);
}
