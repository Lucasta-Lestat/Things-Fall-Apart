shader_type canvas_item;

uniform vec4 target_color : source_color = vec4(1.0);
uniform vec4 base_color : source_color = vec4(0.8, 0.6, 0.4, 1.0); // Base skin color

void fragment() {
    vec4 tex = texture(TEXTURE, UV);
    
    // If pixel matches base skin color (with some tolerance)
    float tolerance = 0.1;
    if (distance(tex.rgb, base_color.rgb) < tolerance && tex.a > 0.0) {
        // Replace with target color, preserving original alpha and brightness
        float brightness = (tex.r + tex.g + tex.b) / 3.0;
        COLOR = vec4(target_color.rgb * brightness, tex.a);
    } else {
        COLOR = tex;
    }
}