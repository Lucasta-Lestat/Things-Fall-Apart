shader_type canvas_item;
render_mode blend_disabled;

// P3-A: the CALM frame of a contract-3 map's painted open water, rendered ONCE
// per map by CellFluidFX (a SubViewport at 1/CALM_DIV of the open-water mask's
// size; its texture binds to water_surface.gdshader's water_calm). The ground
// PNG froze one frame of ripples and sun glints; this is that frame with the
// glints filtered out, which the water shader then lays live ones over.
// TEXTURE is the ground (a Sprite2D scaled onto the viewport), so UV and
// TEXTURE_PIXEL_SIZE are the ground's; water_mask is the open-water mask (R =
// the open-water share c; docs in water_surface.gdshader).
// Per texel: of the ground at UV and two rings of 8 taps (OW_R1, OW_R2 ground
// px) that lie in open water (c >= 0.99 there), the (OW_RANK + 1)-th darkest.
// A rank, not the darkest: a lip shadow or a dark rim inside the water's edge
// reaches only a few taps, so it neither spreads into the open water nor
// prints the rings as lines parallel to the shore (the darkest tap did, on
// tg_hillside_ossuary's channel), while glints, a minority of the taps, still
// fall out. Out: rgb = that tap, a = 1; no tap in open water: (0, 0, 0, 0).
// blend_disabled: raw data over the clear colour. A once-per-map pass: the
// selection (17 taps, O(17^2) compares) costs about 0.8 ms a frame per
// 0.45 Mpx of open water when done per pixel per frame (RTX 4080 Laptop, D3D12).

uniform sampler2D water_mask : filter_linear, repeat_disable;
const float OW_R1 = 6.0;     // tap rings, in ground (export) px
const float OW_R2 = 12.0;
const int OW_RANK = 5;       // the calm tap: the 6th darkest open-water tap (0 = the darkest)
const vec2 OW_RING1[8] = vec2[8](vec2(1.0, 0.0), vec2(0.70710678, 0.70710678), vec2(0.0, 1.0),
	vec2(-0.70710678, 0.70710678), vec2(-1.0, 0.0), vec2(-0.70710678, -0.70710678), vec2(0.0, -1.0),
	vec2(0.70710678, -0.70710678));
const vec2 OW_RING2[8] = vec2[8](vec2(0.92387953, 0.38268343), vec2(0.38268343, 0.92387953),
	vec2(-0.38268343, 0.92387953), vec2(-0.92387953, 0.38268343), vec2(-0.92387953, -0.38268343),
	vec2(-0.38268343, -0.92387953), vec2(0.38268343, -0.92387953), vec2(0.92387953, -0.38268343));

void fragment() {
	// 9.0 = not open water: ranks after every real luma
	float tl[17];
	vec3 tc[17];
	vec3 c0 = texture(TEXTURE, UV).rgb;
	bool v0 = texture(water_mask, UV).r >= 0.99;
	tl[0] = v0 ? dot(c0, vec3(0.299, 0.587, 0.114)) : 9.0;
	tc[0] = c0;
	int nv = v0 ? 1 : 0;
	for (int i = 0; i < 8; i++) {
		vec2 t1 = UV + OW_RING1[i] * (OW_R1 * TEXTURE_PIXEL_SIZE);
		vec3 s1 = texture(TEXTURE, t1).rgb;
		bool v1 = texture(water_mask, t1).r >= 0.99;
		tl[1 + i] = v1 ? dot(s1, vec3(0.299, 0.587, 0.114)) : 9.0;
		tc[1 + i] = s1;
		nv += v1 ? 1 : 0;
		vec2 t2 = UV + OW_RING2[i] * (OW_R2 * TEXTURE_PIXEL_SIZE);
		vec3 s2 = texture(TEXTURE, t2).rgb;
		bool v2 = texture(water_mask, t2).r >= 0.99;
		tl[9 + i] = v2 ? dot(s2, vec3(0.299, 0.587, 0.114)) : 9.0;
		tc[9 + i] = s2;
		nv += v2 ? 1 : 0;
	}
	vec4 outc = vec4(0.0);
	if (nv > 0) {
		int kk = min(OW_RANK, nv - 1);
		for (int i = 0; i < 17; i++) {
			int rk = 0;
			for (int j = 0; j < 17; j++) {
				if (tl[j] < tl[i] || (tl[j] == tl[i] && j < i))
					rk++;
			}
			if (rk == kk)
				outc = vec4(tc[i], 1.0);
		}
	}
	COLOR = outc;
}
