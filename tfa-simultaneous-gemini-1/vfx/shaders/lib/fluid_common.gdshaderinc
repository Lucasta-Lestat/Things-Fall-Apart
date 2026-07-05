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
uniform float edge_noise_scale : hint_range(1.0, 10.0) = 3.0; // shoreline noise frequency

// Neighbour occupancy for the continuous shoreline. Presence of the 8 neighbours
// of this tile (1 = same fluid present, 0 = absent):
//   cov_sides = (right, left, bottom, top)
//   cov_diag  = (top-right, top-left, bottom-left, bottom-right)
// Default = isolated, so an un-refreshed / still-spreading tile appears as a
// round droplet (not a solid square) until its real coverage is set.
uniform vec4 cov_sides = vec4(0.0);
uniform vec4 cov_diag = vec4(0.0);
uniform float edge_irregularity : hint_range(0.0, 0.4) = 0.10; // shoreline waviness (bounded noise on the waterline)
uniform float edge_softness : hint_range(0.02, 0.3) = 0.07;    // waterline blur
// Higher = water recedes further inward from the tile edge (wider erosion band);
// lower = a thinner band hugging the boundary. Kept modest so the edge softening
// stays at the very edge and doesn't bleed toward the next tile layer.
uniform float edge_threshold : hint_range(0.4, 0.95) = 0.56;

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

// --- Organic shoreline (continuous across tiles) ----------------------------
// Coverage reconstructed from the 8-neighbour occupancy. Each tile corner = the
// average of the 4 cells meeting there (self always present); shared corner
// values match across tile seams, so the field is C0-continuous and ONE
// threshold yields a single waterline around the WHOLE body — no per-tile square
// cores. A connectivity-gated ROUND blob keeps lone / thin / still-spreading
// tiles visible WITHOUT a square per-tile footprint (the old chebyshev centre
// cap is what made the shore look sawtoothed, worst while the body spread).
float tile_coverage(vec2 uv) {
    float R = cov_sides.x, L = cov_sides.y, B = cov_sides.z, T = cov_sides.w;
    float TR = cov_diag.x, TL = cov_diag.y, BL = cov_diag.z, BR = cov_diag.w;
    float c_tl = (1.0 + L + T + TL) * 0.25;
    float c_tr = (1.0 + R + T + TR) * 0.25;
    float c_bl = (1.0 + L + B + BL) * 0.25;
    float c_br = (1.0 + R + B + BR) * 0.25;
    float cov = mix(mix(c_tl, c_tr, uv.x), mix(c_bl, c_br, uv.x), uv.y);

    // corner_max ~ how strongly this tile belongs to a body: 1.0 = interior/edge
    // of a body, 0.25 = fully isolated. Only weakly-connected tiles get the blob,
    // so a real shoreline stays purely coverage-driven (smooth, no bumps).
    float corner_max = max(max(c_tl, c_tr), max(c_bl, c_br));
    float lone = 1.0 - smoothstep(0.55, 0.85, corner_max);
    float r = length(uv - vec2(0.5)) * 2.0;                // 0 centre .. ~1.41 corners
    float blob = (1.0 - smoothstep(0.15, 1.0, r)) * 0.85;  // round centre fill
    return max(cov, blob * lone);
}

// Alpha from the coverage field with a world-space noisy waterline. The noise is
// bounded (edge_irregularity) so the contour stays connected — it can wobble the
// shoreline but can't carve detached islands.
float compute_edge_alpha(vec2 uv, vec2 world_uv) {
    float cov = tile_coverage(uv);
    float n = fbm(world_uv * edge_noise_scale) - 0.5;
    float threshold = edge_threshold + n * edge_irregularity;
    return smoothstep(threshold - edge_softness, threshold + edge_softness, cov);
}

// Interior "depth from shore" proxy (0 at the waterline, growing inward), from
// the same coverage field so foam/depth banding hugs the organic shoreline.
float nearest_edge_distance(vec2 uv) {
    return clamp(tile_coverage(uv) - edge_threshold, 0.0, 0.5);
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
