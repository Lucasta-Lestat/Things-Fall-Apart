shader_type canvas_item;

// Door Kickers-style "never seen" filter (UnexploredFogLayer). Where the
// explored mask reads 0 the scene beneath is repainted as a desaturated
// blue-grey; where it reads 255 the fog is fully transparent. The mask is one
// L8 pixel per GridManager tile — bilinear sampling plus the smoothstep below
// turn the tile grid into a soft boundary, and the fade-in bytes (1..254)
// animate through the same ramp.
//
// The filter reads the backbuffer (hint_screen_texture) and remaps the scene's
// LUMINANCE into a blue-grey ramp, so furniture and walls stay readable as
// shapes — a flat translucent wash loses the dark-floor/bright-wall contrast
// that makes the Door Kickers look.

uniform sampler2D explored_mask : filter_linear, repeat_disable;
uniform sampler2D screen_tex : hint_screen_texture, filter_nearest;
uniform vec4 fog_color : source_color = vec4(0.36, 0.44, 0.58, 1.0);
// Luminance remap: darkest scene pixel keeps luma_floor of the tint, brightest
// reaches luma_floor + luma_gain. Keep the sum near 1.0 or fog reads as glow.
uniform float luma_floor : hint_range(0.0, 1.0) = 0.22;
uniform float luma_gain : hint_range(0.0, 2.0) = 0.72;
// Explored-value window the boundary blends across.
uniform float edge_lo : hint_range(0.0, 1.0) = 0.25;
uniform float edge_hi : hint_range(0.0, 1.0) = 0.75;

void fragment() {
	float explored = texture(explored_mask, UV).r;
	float hide = 1.0 - smoothstep(edge_lo, edge_hi, explored);
	vec3 scene = texture(screen_tex, SCREEN_UV).rgb;
	float luma = dot(scene, vec3(0.299, 0.587, 0.114));
	vec3 tinted = fog_color.rgb * (luma_floor + luma_gain * luma);
	COLOR = vec4(tinted, hide * fog_color.a);
}
