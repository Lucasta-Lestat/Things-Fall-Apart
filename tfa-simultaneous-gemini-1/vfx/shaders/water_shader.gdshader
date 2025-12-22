//water_shader.gdshader
shader_type canvas_item;

// Color parameters
uniform vec4 shallow_color : source_color = vec4(0.4, 0.7, 1.0, 0.3);
uniform vec4 deep_color : source_color = vec4(0.1, 0.3, 0.8, 0.9);

// Wave parameters
uniform float wave_speed : hint_range(0.1, 5.0) = 1.0;
uniform float wave_frequency : hint_range(0.5, 10.0) = 2.0;
uniform float wave_amplitude : hint_range(0.0, 0.2) = 0.05;

// Dappling light parameters
uniform float dapple_scale : hint_range(5.0, 50.0) = 20.0;
uniform float dapple_speed : hint_range(0.1, 2.0) = 0.5;
uniform float dapple_intensity : hint_range(0.0, 1.0) = 0.3;

// Depth (set from script)
uniform float water_depth : hint_range(0.0, 100.0) = 10.0;
uniform float max_depth : hint_range(10.0, 200.0) = 50.0;

// Ripple effect (set from script)
uniform vec2 ripple_center = vec2(0.5, 0.5);
uniform float ripple_time = 0.0;
uniform float ripple_active = 0.0;

// Random function for noise
float random(vec2 uv) {
    return fract(sin(dot(uv, vec2(12.9898, 78.233))) * 43758.5453);
}

// Noise function for dappling
float noise(vec2 uv) {
    vec2 i = floor(uv);
    vec2 f = fract(uv);
    
    float a = random(i);
    float b = random(i + vec2(1.0, 0.0));
    float c = random(i + vec2(0.0, 1.0));
    float d = random(i + vec2(1.0, 1.0));
    
    vec2 u = f * f * (3.0 - 2.0 * f);
    
    return mix(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
}

// Sum of sines wave function
float wave_function(vec2 uv, float time) {
    float wave1 = sin(uv.x * wave_frequency + time * wave_speed) * wave_amplitude;
    float wave2 = sin(uv.y * wave_frequency * 1.3 - time * wave_speed * 0.8) * wave_amplitude * 0.7;
    float wave3 = sin((uv.x + uv.y) * wave_frequency * 0.7 + time * wave_speed * 1.2) * wave_amplitude * 0.5;
    
    return wave1 + wave2 + wave3;
}

// Ripple function (concentric circles)
float ripple_function(vec2 uv, vec2 center, float time) {
    if (ripple_active < 0.5) return 0.0;
    
    float dist = distance(uv, center);
    float ripple = sin(dist * 20.0 - time * 8.0) * exp(-dist * 3.0);
    
    // Fade out over time
    float fade = 1.0 - clamp(time / 2.0, 0.0, 1.0);
    
    return ripple * fade;
}

void fragment() {
    vec2 uv = UV;
    
    // Calculate depth ratio (0 to 1)
    float depth_ratio = clamp(water_depth / max_depth, 0.0, 1.0);
    
    // Apply wave distortion to UV
    float wave_offset = wave_function(uv, TIME);
    vec2 distorted_uv = uv + vec2(wave_offset, wave_offset * 0.5);
    
    // Base water color based on depth
    vec4 water_color = mix(shallow_color, deep_color, depth_ratio);
    
    // Dappling light effect (sun rays through water)
    float dapple_time = TIME * dapple_speed;
    vec2 dapple_uv = distorted_uv * dapple_scale + vec2(dapple_time * 0.1, dapple_time * 0.05);
    float dapple = noise(dapple_uv);
    dapple = pow(dapple, 3.0); // Make it more concentrated
    
    // Add another layer of dappling for more variation
    vec2 dapple_uv2 = distorted_uv * dapple_scale * 0.6 - vec2(dapple_time * 0.08, dapple_time * 0.12);
    float dapple2 = noise(dapple_uv2);
    dapple2 = pow(dapple2, 3.0);
    
    float combined_dapple = max(dapple, dapple2 * 0.7);
    
    // Apply dappling to color (white specks)
    water_color.rgb += combined_dapple * dapple_intensity * vec3(1.0, 1.0, 0.9);
    
    // Add ripple effect (concentric white circles)
    float ripple = ripple_function(uv, ripple_center, ripple_time);
    water_color.rgb += ripple * 0.5 * vec3(1.0);
    
    // Sample the base texture
    vec4 texture_color = texture(TEXTURE, distorted_uv);
    
    // Combine texture with water color
    COLOR = texture_color * water_color;
    
    // Ensure alpha is properly applied based on depth
    COLOR.a = water_color.a * texture_color.a;
}
