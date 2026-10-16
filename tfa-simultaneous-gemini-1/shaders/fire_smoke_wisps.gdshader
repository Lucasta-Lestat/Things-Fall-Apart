shader_type canvas_item;

// GPU port of CellFireFX._draw_smoke: the two hard-edged wisps that curl off
// each burning cell (the drifting body of smoke is a real FogOverlay plume,
// see CellFire._emit_smoke). One MultiMesh instance per disc, animated here
// off the fire sim's clock. Same INSTANCE_CUSTOM packing as fire_cells:
//   x: cell radius   y: kind*2 + seed   z: burn duration t0   w: lit time
// kind: puff*2 + sub, puff 0-1, sub 0 = body disc, 1 = lighter highlight disc.

uniform float sim_t = 0.0;
uniform vec2 wind = vec2(0.0);

const vec2 UP = vec2(0.0, -1.0);

void vertex() {
	float cr = INSTANCE_CUSTOM.x;
	float packed = INSTANCE_CUSTOM.y;
	float t0 = INSTANCE_CUSTOM.z;
	float lit = INSTANCE_CUSTOM.w;
	int kind = int(floor(packed * 0.5));
	float sd = packed - float(kind) * 2.0;
	int puff = kind / 2;
	int sub = kind - puff * 2;
	float fi = float(puff);
	float t = t0 - (sim_t - lit);
	float k = clamp((t0 - t) / 1.2, 0.25, 1.0) * clamp(t / 2.2, 0.22, 1.0);
	float u = fract(sim_t * 0.22 + sd * 3.0 + fi * 0.5);
	vec2 drift = UP * (cr * 1.6 + cr * 2.8 * u) + wind * cr * 1.6 * u
		+ vec2(sin(sim_t * 0.9 + sd * 20.0 + fi * 3.0) * cr * 0.3, 0.0);
	float rad = cr * (0.30 + 0.55 * u) * k;
	vec2 c;
	float r;
	vec4 col;
	if (sub == 0) {
		c = drift;
		r = rad;
		col = vec4(0.13, 0.12, 0.11, 0.17 * (1.0 - u));
	} else {
		c = drift + vec2(-rad * 0.3, -rad * 0.25);
		r = rad * 0.6;
		col = vec4(0.22, 0.21, 0.20, 0.12 * (1.0 - u));
	}
	if (t <= 0.0) {
		r = 0.0;
		col = vec4(0.0);
	}
	VERTEX = c + VERTEX * r;
	COLOR = col * COLOR;
}

void fragment() {
	// draw_circle was a hard-edged filled disc
	if (length(UV - vec2(0.5)) * 2.0 > 1.0) {
		discard;
	}
}
