// fluid_common.gdshaderinc
// Shared library for the fluid/water canvas_item shaders (water_flow, oil_sheen,
// poison, blood, ...). Include with:
//     #include "res://vfx/shaders/lib/fluid_common.gdshaderinc"
// NOTE: an include must NOT declare `shader_type` or `render_mode` — those live
// in the including shader. Every effect here is WORLD-CONTINUOUS: it samples
// `world_uv = tile_position + UV` so adjacent tiles line up with no grid seams.

// --- Shared uniforms (edges / fill) -----------------------------------------
// World-space tile position (grid coords) for cross-tile continuity. Set per
// tile from fluid.gd.
uniform vec2 tile_position = vec2(0.0);

// Edge noise displacement — vec4(right, left, bottom, top).
// 1.0 = exposed boundary edge, 0.0 = neighbor present.
uniform vec4 edge_mask = vec4(0.0);
uniform float edge_fade_width = 0.4;
uniform float edge_noise_scale = 6.0;

// Inside-corner fade — vec4(top-right, top-left, bottom-left, bottom-right).
// 1.0 = both adjacent edges have neighbors but the diagonal tile is missing.
uniform vec4 corner_mask = vec4(0.0);

// Directional fill — fill_ratio 0=empty .. 1=full; inflow_direction is the
// direction fluid moves AS IT ENTERS this tile (drives the fill front).
uniform float fill_ratio = 1.0;
uniform vec2 inflow_direction = vec2(0.0);

// --- Noise ------------------------------------------------------------------
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

// --- Organic tile edges -----------------------------------------------------
float compute_edge_alpha(vec2 uv, vec2 world_uv) {
    float alpha = 1.0;
    vec2 noise_pos = world_uv * edge_noise_scale;

    // Per-edge fade: distance from each exposed edge, noise-thresholded for an
    // irregular shoreline.
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

    // Multiply edges together — corners (2 edges meeting) get stronger erosion.
    alpha = right_a * left_a * bottom_a * top_a;

    // Inside-corner fade: round off any corner whose two adjacent edges are
    // closed but whose diagonal tile is missing.
    if (corner_mask.x > 0.5) { // top-right (UV (1,0))
        float dx = 1.0 - uv.x;
        float dy = uv.y;
        float n = fbm(noise_pos + vec2(43.0, 197.0));
        alpha *= smoothstep(0.0, edge_fade_width * n * 0.75 + 0.035, sqrt(dx*dx + dy*dy));
    }
    if (corner_mask.y > 0.5) { // top-left (UV (0,0))
        float n = fbm(noise_pos + vec2(53.0, 91.0));
        alpha *= smoothstep(0.0, edge_fade_width * n * 0.75 + 0.035, length(uv));
    }
    if (corner_mask.z > 0.5) { // bottom-left (UV (0,1))
        float dx = uv.x;
        float dy = 1.0 - uv.y;
        float n = fbm(noise_pos + vec2(107.0, 211.0));
        alpha *= smoothstep(0.0, edge_fade_width * n * 0.75 + 0.035, sqrt(dx*dx + dy*dy));
    }
    if (corner_mask.w > 0.5) { // bottom-right (UV (1,1))
        float dx = 1.0 - uv.x;
        float dy = 1.0 - uv.y;
        float n = fbm(noise_pos + vec2(67.0, 179.0));
        alpha *= smoothstep(0.0, edge_fade_width * n * 0.75 + 0.035, sqrt(dx*dx + dy*dy));
    }
    return alpha;
}

// Distance (in UV units, 0..1) to the nearest EXPOSED tile edge. Returns 1.0
// for a fully-surrounded interior tile (no foam there). Used to band foam along
// the organic shoreline.
float nearest_edge_distance(vec2 uv) {
    float d = 1.0;
    if (edge_mask.x > 0.5) d = min(d, 1.0 - uv.x); // right
    if (edge_mask.y > 0.5) d = min(d, uv.x);       // left
    if (edge_mask.z > 0.5) d = min(d, 1.0 - uv.y); // bottom
    if (edge_mask.w > 0.5) d = min(d, uv.y);       // top
    return d;
}

// --- Animated caustics (ridged noise web) -----------------------------------
// World-continuous bright thin web of light, scrolling in two directions so it
// shimmers and refocuses. Returns ~[0,1.7]. Bright lines sit where the fbm
// field crosses its mid value (ridges), tightened with pow().
float caustics(vec2 p, float time) {
    vec2 a = p + vec2(time * 0.16, time * 0.11);
    vec2 b = p * 1.35 - vec2(time * 0.13, time * 0.19);
    float r1 = 1.0 - abs(fbm(a) * 2.0 - 1.0);
    float r2 = 1.0 - abs(fbm(b) * 2.0 - 1.0);
    return pow(r1, 4.0) + pow(r2, 4.0) * 0.7;
}

// --- Surface normal + lighting ----------------------------------------------
// Canvas-space normal from 4 height samples (left,right,down,up). Larger
// `strength` = flatter water (gentler slopes).
vec3 normal_from_heights(float hL, float hR, float hD, float hU, float strength) {
    return normalize(vec3(hL - hR, hD - hU, strength));
}

// Blinn-Phong for a straight-down view (+Z). `light_dir` points surface->light.
// Returns vec2(diffuse, specular).
vec2 water_lighting(vec3 n, vec3 light_dir, float shininess) {
    float diff = clamp(dot(n, light_dir), 0.0, 1.0);
    vec3 h = normalize(light_dir + vec3(0.0, 0.0, 1.0));
    float spec = pow(clamp(dot(n, h), 0.0, 1.0), shininess);
    return vec2(diff, spec);
}

// Sharp animated sun sparkle on crests that tilt toward the light. Two
// high-frequency twinkle fields multiplied for crisp, sparse-but-present points.
float sun_glitter(vec3 n, vec3 light_dir, vec2 world_uv, float time) {
    float align = clamp(dot(n, light_dir), 0.0, 1.0);
    float s = value_noise(world_uv * 16.0 + vec2(time * 1.7, -time * 1.3));
    s *= value_noise(world_uv * 26.0 - vec2(time * 0.9, time * 1.5));
    float spark = smoothstep(0.62, 0.92, s);
    return spark * smoothstep(0.35, 0.9, align);
}

// --- Reactive ripples (driven by FluidManager) ------------------------------
// World-space (tile-grid units). vec4(center.x, center.y, age_seconds, strength).
uniform vec4 u_ripples[6];
uniform int u_ripple_count = 0;
uniform float u_ripple_speed = 2.2;      // ring expansion, grid units / sec
uniform float u_ripple_wavelength = 7.0; // wavelet spatial frequency
uniform float u_ripple_life = 1.4;       // seconds

float ripple_height(vec2 wp) {
    float h = 0.0;
    for (int i = 0; i < 6; i++) {
        if (i >= u_ripple_count) break;
        vec4 r = u_ripples[i];
        float age = r.z;
        if (age < 0.0 || age > u_ripple_life) continue;
        float d = distance(wp, r.xy);
        float ring = d - age * u_ripple_speed;
        float env = exp(-abs(ring) * 3.0) * (1.0 - age / u_ripple_life) * r.w;
        h += sin(ring * u_ripple_wavelength) * env;
    }
    return h;
}

// Foam crest at each ripple's expanding leading edge.
float ripple_foam(vec2 wp) {
    float f = 0.0;
    for (int i = 0; i < 6; i++) {
        if (i >= u_ripple_count) break;
        vec4 r = u_ripples[i];
        float age = r.z;
        if (age < 0.0 || age > u_ripple_life) continue;
        float ring = distance(wp, r.xy) - age * u_ripple_speed;
        f = max(f, smoothstep(0.10, 0.0, abs(ring)) * (1.0 - age / u_ripple_life) * r.w);
    }
    return f;
}

// --- Directional fill -------------------------------------------------------
float compute_fill_alpha(vec2 uv, vec2 world_uv) {
    if (fill_ratio >= 0.999) return 1.0;
    vec2 noise_pos = world_uv * edge_noise_scale;
    float in_len = length(inflow_direction);
    if (in_len < 0.05) {
        float n = fbm(noise_pos * 0.7);
        return smoothstep(1.0 - fill_ratio - 0.1, 1.0 - fill_ratio + 0.1, n);
    }
    vec2 in_dir = inflow_direction / in_len;
    float p = dot(uv - 0.5, in_dir);
    float half_range = 0.5 * (abs(in_dir.x) + abs(in_dir.y));
    float front_p = mix(-half_range, half_range, fill_ratio);
    // Wobble the front with low-frequency noise for an organic edge.
    float n = fbm(noise_pos * 0.8 + vec2(13.0, 29.0));
    front_p += (n - 0.5) * 0.08;
    return 1.0 - smoothstep(front_p - 0.04, front_p + 0.04, p);
}
