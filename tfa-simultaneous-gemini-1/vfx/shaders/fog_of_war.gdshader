// fog_of_war.gdshader
shader_type canvas_item;

uniform sampler2D visibility_texture : filter_linear;
uniform vec2 grid_size = vec2(100.0, 100.0);
uniform vec2 tile_size = vec2(128.0, 128.0);
uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, filter_linear_mipmap;

void fragment() {
    // Calculate which grid tile this pixel belongs to
    vec2 screen_pos = FRAGCOORD.xy;
    vec2 grid_coord = screen_pos / tile_size;
    vec2 uv = grid_coord / grid_size;
    
    // Sample the visibility texture
    float visibility = texture(visibility_texture, uv).r;
    
    // Get the color from what's actually rendered beneath this fog layer
    vec4 screen_color = texture(SCREEN_TEXTURE, SCREEN_UV);
    
    if (visibility < 0.05) {
        // Completely dark - show black
        COLOR = vec4(0.0, 0.0, 0.0, 1.0);
    } else if (visibility < 1.0) {
        // Partially visible - darken the scene
        COLOR = vec4(screen_color.rgb * visibility, 1.0);
    } else {
        // Fully visible - show normally
        COLOR = screen_color;
    }
}