shader_type canvas_item;
render_mode blend_add;

// Field-accumulation blob for CellFluidFX's offscreen SubViewport (ported from
// the editor's shaders/fluid_field.gdshader). Godot's canvas blend_add is
// glBlendFuncSeparate(SRC_ALPHA, ONE, SRC_ALPHA, ONE): every channel lands
// multiplied by the OUTPUT ALPHA once more, so a shader that outputs (c*k, k)
// accumulates k^2 in A -- blobs shrink to dots and never fuse. Outputting
// s = sqrt(kernel * depth) instead makes the target accumulate exactly
// RGB += colour*kernel*depth and A += kernel*depth: a smooth union depth field
// with premultiplied colour, which the water shader un-premultiplies. Vertex
// COLOR carries the fluid colour in RGB and the depth (0..1) in A.

void fragment() {
	float d = length(UV - vec2(0.5)) * 2.0;
	float k = clamp(1.0 - d, 0.0, 1.0);
	k *= k;                                  // soft quadratic kernel
	float s = sqrt(k * COLOR.a);
	COLOR = vec4(COLOR.rgb * s, s);
}
