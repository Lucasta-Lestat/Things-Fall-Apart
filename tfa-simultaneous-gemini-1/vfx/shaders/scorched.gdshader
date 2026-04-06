shader_type canvas_item;

// Scorch overlay: dark ashy look with noise variation
// Applied to floor sprites after fire burns out

uniform float scorch_amount : hint_range(0.0, 1.0) = 0.85;
uniform vec4 ash_color : source_color = vec4(0.08, 0.06, 0.05, 1.0);
uniform vec4 ember_color : source_color = vec4(0.15, 0.05, 0.02, 1.0);
uniform float noise_scale = 4.0;

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
    v += value_noise(p * 2.0 + 13.0) * 0.25;
    v += value_noise(p * 4.0 + 29.0) * 0.125;
    v += value_noise(p * 8.0 + 47.0) * 0.0625;
    return v / 0.9375;
}

void fragment() {
    vec4 original = texture(TEXTURE, UV);

    // Noise-based variation across the tile
    vec2 noise_uv = UV * noise_scale;
    float n = fbm(noise_uv);
    float n2 = fbm(noise_uv * 1.5 + 7.0);

    // Mix between ash (dark grey) and ember (dark red-brown) based on noise
    vec3 scorch = mix(ash_color.rgb, ember_color.rgb, n2 * 0.6);

    // Vary the scorch intensity with noise — some spots darker, some lighter
    float local_scorch = scorch_amount * mix(0.7, 1.0, n);

    // Darken and desaturate the original texture
    vec3 desaturated = vec3(dot(original.rgb, vec3(0.299, 0.587, 0.114)));
    vec3 darkened = desaturated * 0.25;

    // Blend: original -> darkened+desaturated -> ash overlay
    vec3 result = mix(original.rgb, mix(darkened, scorch, 0.7), local_scorch);

    COLOR = vec4(result, original.a);
}
