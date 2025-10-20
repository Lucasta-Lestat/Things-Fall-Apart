shader_type canvas_item;

uniform float time : hint_range(0.0, 10.0) = 0.0;
uniform vec4 cloud_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float transparency : hint_range(0.0, 1.0) = 0.6;
uniform vec2 resolution = vec2(100.0, 100.0);
uniform float time_seed : hint_range(0.0, 1000.0) = 0.0;

// Noise functions for cloud generation
float random(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7)) + time_seed) * 43758.5453);
}

float noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);

    return mix(
        mix(random(i + vec2(0.0, 0.0)), random(i + vec2(1.0, 0.0)), u.x),
        mix(random(i + vec2(0.0, 1.0)), random(i + vec2(1.0, 1.0)), u.x),
        u.y
    );
}

float fbm(vec2 p) {
    float value = 0.0;
    float amplitude = 0.5;
    for (int i = 0; i < 6; i++) {
        value += amplitude * noise(p);
        p *= 2.0;
        amplitude *= 0.5;
    }
    return value;
}

void fragment() {
    vec2 uv = UV;

    // Create multiple layers of clouds with different speeds
    vec2 cloud_uv1 = uv * 2.0 + vec2(time * 0.02, time * 0.01);
    vec2 cloud_uv2 = uv * 3.0 + vec2(time * -0.015, time * 0.025);
    vec2 cloud_uv3 = uv * 4.0 + vec2(time * 0.03, time * -0.02);

    // Generate cloud layers
    float cloud1 = fbm(cloud_uv1);
    float cloud2 = fbm(cloud_uv2) * 0.7;
    float cloud3 = fbm(cloud_uv3) * 0.5;

    // Combine cloud layers
    float cloud_density = (cloud1 + cloud2 + cloud3) / 2.2;

    // Create more natural cloud edges
    float edge_falloff = 1.0 - length(uv - 0.5) * 1.5;
    edge_falloff = clamp(edge_falloff, 0.0, 1.0);

    cloud_density *= edge_falloff;

    // Add some swirling motion
    vec2 swirl_uv = uv + vec2(
        sin(time * 0.5 + uv.y * 6.0) * 0.1,
        cos(time * 0.3 + uv.x * 4.0) * 0.1
    );
    float swirl = fbm(swirl_uv * 3.0) * 0.3;
    cloud_density += swirl;

    // Threshold for cloud appearance
    cloud_density = smoothstep(0.3, 0.8, cloud_density);

    // Apply color and transparency
    vec3 final_color = cloud_color.rgb;

    // Add slight color variation
    float color_variation = noise(uv * 5.0 + time * 0.1) * 0.2;
    final_color += color_variation * 0.1;

    float alpha = cloud_density * cloud_color.a * transparency;

    // Add subtle pulsing for poison/magical clouds
    if (cloud_color.g > 0.7 && cloud_color.r < 0.5) { // Green-ish clouds
        alpha *= 0.8 + 0.2 * sin(time * 2.0 + length(uv - 0.5) * 10.0);
    }

    COLOR = vec4(final_color, alpha);
}