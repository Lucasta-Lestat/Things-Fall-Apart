// ice_magic.gdshader - Ice/Rime Magic Effect
shader_type canvas_item;

uniform float time : hint_range(0.0, 10.0) = 0.0;
uniform float crystal_density : hint_range(0.1, 2.0) = 0.8;
uniform vec4 ice_color : source_color = vec4(0.7, 0.9, 1.0, 1.0);
uniform vec2 resolution = vec2(100.0, 100.0);
uniform float time_seed : hint_range(0.0, 1000.0) = 0.0;

float random(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7)) + time_seed) * 43758.5453);
}

float voronoi(vec2 uv) {
    vec2 i = floor(uv);
    vec2 f = fract(uv);
    float min_dist = 1.0;

    for (int x = -1; x <= 1; x++) {
        for (int y = -1; y <= 1; y++) {
            vec2 neighbor = vec2(float(x), float(y));
            vec2 point = random(i + neighbor) * vec2(1.0) + neighbor;
            point = 0.5 + 0.5 * sin(time * 0.5 + 6.28 * point);
            float dist = length(point - f);
            min_dist = min(min_dist, dist);
        }
    }
    return min_dist;
}

void fragment() {
    vec2 uv = UV * crystal_density;

    // Create ice crystal pattern
    float crystals = voronoi(uv * 6.0);
    crystals = 1.0 - crystals;
    crystals = smoothstep(0.3, 0.8, crystals);

    // Add frost patterns
    float frost = random(floor(uv * 10.0)) * 0.5;
    frost *= smoothstep(0.4, 0.6, random(floor(uv * 5.0)));

    // Ice color with shimmer
    vec3 base_ice = ice_color.rgb;
    float shimmer = sin(time * 3.0 + length(uv) * 10.0) * 0.2 + 0.8;
    base_ice *= shimmer;

    // Combine effects
    float total_ice = crystals + frost;
    vec3 final_color = base_ice + total_ice * vec3(0.9, 0.95, 1.0);

    // Add sparkle effect
    float sparkle = step(0.98, random(uv * 20.0 + time * 2.0));
    final_color += sparkle * vec3(1.0);

    COLOR = vec4(final_color, total_ice * ice_color.a);
}
