shader_type canvas_item;
render_mode blend_add;

// Soft radial particle blob -- the shader half of TFA's fire look. TFA renders its
// fire as GPUParticles with a 16x16 radial white->transparent GradientTexture2D on
// ADD blend (vfx/fire.tscn); this reproduces that falloff for quads FireFX draws
// with UVs 0..1 and vertex COLOR = the particle's ramp color. Quadratic falloff
// reads slightly softer than the linear gradient, which suits the larger blobs.

void fragment() {
	float d = length(UV - vec2(0.5)) * 2.0;
	float a = clamp(1.0 - d, 0.0, 1.0);
	a *= a;
	COLOR = vec4(COLOR.rgb * a, COLOR.a * a);
}
