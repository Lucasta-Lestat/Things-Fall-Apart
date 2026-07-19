shader_type canvas_item;

// The editor's organic water look, ported to composite onto the STRUCTURED-map
// ground sprite (whose TEXTURE is the finished ground PNG). Samples CellFluidFX's
// blob field (fluid_mask = premultiplied fluid colour + depth in A) and flow
// field (flow_mask = dir 0.5-centred in RG, speed in B), and paints water right
// over the ground: soft blob shorelines, a stylised wave surface with spec, a
// foam collar, live flow advection (bounded crossfade), and white-water rush.
// Where dry it outputs the ground unchanged. Structures (z -3) draw over it.
// Verbatim helper chain from ground_paint.gdshader (hash12/vnoise/fbm/warpfield/
// waterSurf) so waves match the editor exactly.

uniform sampler2D fluid_mask : filter_linear, repeat_disable;
uniform sampler2D flow_mask : filter_linear, repeat_disable;
uniform float fluid_on = 0.0;
uniform vec3 foam_col : source_color = vec3(0.86, 0.92, 0.93);
uniform vec2 sun_dir = vec2(-0.6, -0.8);    // editor default: light from upper-LEFT
uniform float ravine_sun_z = 0.42;          // editor default (grazing)
// world units per EXPORT pixel (1/export_scale). The ground sprite is at export
// scale, but the editor tuned every wave/foam/rush frequency in WORLD units, so
// Wn must be converted back or the surface detail is export_scale x too fine.
uniform float wave_scale = 1.0;

const mat2 M2 = mat2(vec2(0.8, -0.6), vec2(0.6, 0.8));

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	float a = hash12(i);
	float b = hash12(i + vec2(1.0, 0.0));
	float c = hash12(i + vec2(0.0, 1.0));
	float d = hash12(i + vec2(1.0, 1.0));
	return (mix(mix(a, b, u.x), mix(c, d, u.x), u.y)) * 2.0 - 1.0;
}

float fbm(vec2 p) {
	float s = 0.0;
	float a = 0.5;
	float n = 0.0;
	for (int i = 0; i < 5; i++) {
		s += a * vnoise(p);
		n += a;
		p = M2 * p * 2.07 + vec2(37.13, 17.71);
		a *= 0.5;
	}
	return s / n;
}

float warpfield(vec2 p, float warp, out vec2 flow) {
	vec2 q = vec2(fbm(p), fbm(p + vec2(5.2, 1.3)));
	flow = q;
	return fbm(p + warp * q);
}

float waterSurf(vec2 W, vec2 dir, float t, out vec2 grad) {
	vec2 adv = dir * (t * 2.4);
	vec2 f;
	float a = warpfield(W * 0.10 + adv, 1.0, f);
	float b = warpfield(W * 0.23 - adv * 0.6 + 17.0, 1.0, f);
	float e = 1.5; vec2 _q;
	float hx = warpfield((W + vec2(e, 0.0)) * 0.10 + adv, 1.0, _q) - warpfield((W - vec2(e, 0.0)) * 0.10 + adv, 1.0, _q);
	float hy = warpfield((W + vec2(0.0, e)) * 0.10 + adv, 1.0, _q) - warpfield((W - vec2(0.0, e)) * 0.10 + adv, 1.0, _q);
	grad = vec2(hx, hy);
	return a * 0.6 + b * 0.4;
}

void fragment() {
	vec4 base = texture(TEXTURE, UV);
	vec3 col = base.rgb;
	// world units (export px / export_scale): the wave math was tuned at world scale
	vec2 Wn = (UV / TEXTURE_PIXEL_SIZE) * wave_scale;
	if (fluid_on > 0.5) {
		// 9-tap blur: the blob union has a cell-periodic ripple that would print
		// as dimples on the body
		vec2 fr = 4.5 / vec2(textureSize(fluid_mask, 0));
		vec4 fl = texture(fluid_mask, UV) * 2.0;
		fl += texture(fluid_mask, UV + vec2(fr.x, 0.0)) + texture(fluid_mask, UV - vec2(fr.x, 0.0));
		fl += texture(fluid_mask, UV + vec2(0.0, fr.y)) + texture(fluid_mask, UV - vec2(0.0, fr.y));
		fl += texture(fluid_mask, UV + fr) + texture(fluid_mask, UV - fr);
		fl += texture(fluid_mask, UV + vec2(fr.x, -fr.y)) + texture(fluid_mask, UV + vec2(-fr.x, fr.y));
		fl /= 10.0;
		float fd = fl.a;
		if (fd > 0.05) {
			float shore = 0.26 + (fbm(Wn * 0.11 + 41.0) - 0.5) * 0.10;
			float wm = smoothstep(shore, shore + 0.09, fd);
			float rim = smoothstep(shore - 0.10, shore, fd) * (1.0 - wm);
			col *= mix(1.0, 0.84, rim);
			if (wm > 0.003) {
				vec3 fcol = fl.rgb / max(fd, 1e-4);
				float depth01 = smoothstep(shore, 1.25, fd);
				vec3 wet = col * mix(vec3(1.0), fcol * 2.2, 0.45) * 0.88;
				vec3 body = mix(fcol * 1.0, fcol * 0.38, depth01);
				vec3 water = mix(wet, body, smoothstep(0.0, 0.65, depth01));
				vec4 fw = texture(flow_mask, UV);
				vec2 flowV = vec2(0.0);
				float fspd = 0.0;
				if (fw.a > 0.01) {
					float wgt = smoothstep(0.02, 0.15, fw.a);
					fspd = clamp(fw.b / fw.a, 0.0, 1.0) * wgt;
					flowV = ((fw.rg / fw.a) * 2.0 - 1.0) * (fspd * 12.0);
				}
				const float HP = 3.0;
				float saw0 = fract(TIME / (2.0 * HP));
				float saw1 = fract(TIME / (2.0 * HP) + 0.5);
				float xfade = abs(saw0 * 2.0 - 1.0);
				vec2 offA = flowV * (saw0 * 2.0 * HP - HP);
				vec2 offB = flowV * (saw1 * 2.0 * HP - HP);
				vec2 gradA;
				vec2 gradB;
				float hA = waterSurf(Wn - offA, vec2(0.22, -0.14), TIME, gradA);
				float hB = waterSurf(Wn - offB + vec2(37.0, 19.0), vec2(0.22, -0.14), TIME, gradB);
				float h = mix(hA, hB, xfade);
				vec2 gradH = mix(gradA, gradB, xfade);
				water *= 1.0 + (0.07 + 0.09 * fspd) * (smoothstep(0.55, 0.95, h * 0.5 + 0.5) - 0.25);
				vec3 Lw = normalize(vec3(normalize(sun_dir), ravine_sun_z));
				vec3 Nw = normalize(vec3(-gradH * 1.8, 1.0));
				vec3 Hw = normalize(Lw + vec3(0.0, 0.0, 1.0));
				float spec = pow(max(dot(Nw, Hw), 0.0), 48.0) * wm * smoothstep(0.1, 0.5, depth01);
				water += vec3(1.0, 0.97, 0.88) * spec * 0.3;
				float fedge = 1.0 - smoothstep(0.0, 0.06, abs(fd - shore));
				float froth = smoothstep(0.35, 0.8, fbm(Wn * 0.5 + vec2(0.0, TIME * 0.4)) * 0.5 + 0.5);
				float foam_k = smoothstep(0.08, 0.30, dot(fcol, vec3(0.299, 0.587, 0.114)));
				water = mix(water, foam_col, clamp(fedge * froth, 0.0, 1.0) * 0.4 * foam_k);
				float rush = smoothstep(0.12, 0.45, fspd);
				if (rush > 0.01) {
					float sA = fbm((Wn - offA) * 0.35) * 0.5 + 0.5;
					float sB = fbm((Wn - offB + vec2(11.0, 53.0)) * 0.35) * 0.5 + 0.5;
					float streak = smoothstep(0.55, 0.9, mix(sA, sB, xfade));
					water = mix(water, foam_col, rush * streak * 0.3 * foam_k);
				}
				col = mix(col, water, wm * 0.92);
			}
		}
	}
	COLOR = vec4(col, base.a);
}
