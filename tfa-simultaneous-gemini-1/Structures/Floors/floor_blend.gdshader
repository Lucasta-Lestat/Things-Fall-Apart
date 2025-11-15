shader_type canvas_item;

uniform sampler2D noise_texture;
uniform float blend_amount : hint_range(0.0, 1.0) = 0.2;
uniform float noise_scale : hint_range(0.5, 4.0) = 2.0;

void fragment() {
    vec4 tex = texture(TEXTURE, UV);

    // Sample noise texture if provided, otherwise generate simple noise
    float noise;
        // Simple procedural noise as fallback
    noise = fract(sin(dot(UV * noise_scale, vec2(12.9898, 78.233))) * 43758.5453);

    // Calculate edge factor (stronger at tile edges)
    vec2 edge = abs(UV - vec2(0.5)) * 2.0;
    float edge_factor = max(edge.x, edge.y);

    // Apply subtle variation
    float variation = mix(.96, 1.04, noise);
    vec3 varied_color = tex.rgb * variation;

    // Blend more at edges
    COLOR.rgb = mix(tex.rgb, varied_color, edge_factor * blend_amount);
    COLOR.a = tex.a;
}