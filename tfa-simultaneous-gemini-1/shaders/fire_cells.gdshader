shader_type canvas_item;
render_mode blend_add;

// GPU port of CellFireFX's per-cell flame recipe. CellFireFX used to rebuild
// every cell's twelve soft blobs on the CPU each frame with draw_polygon (a
// separate canvas command per blob: ~10k GDScript-built polygons per frame for
// a big fire, 6-11 fps). Now each blob is one MultiMesh instance that never
// changes while its cell burns; this vertex shader replays the SAME animation
// math off the fire sim's clock (`sim_t`, so flames freeze with the sim on
// tactical pause), and the fragment is the fire_blob falloff unchanged.
//
// Per instance: transform = cell centroid; INSTANCE_CUSTOM =
//   x: cell radius   y: kind*2 + seed (seed in [0,1])   z: burn duration t0
//   w: sim time the cell was lit
// kind: 0 glow halo, 1 core sheet, 2-3 ember bed, 4-9 rising tongues,
// 10-11 climbing embers. The instance color stays white so the canvas
// modulate still applies (COLOR is multiplied, not replaced).

uniform float sim_t = 0.0;

const vec2 UP = vec2(0.0, -1.0);
const float TAU_F = 6.28318530718;

// CellFireFX._sfr: seeded pseudo-random in [0,1)
float sfr(float sd, float i) {
	return fract(sin(sd * 91.7 + i * 47.3) * 437.585);
}

// fire.tres color ramp: white-yellow -> orange -> deep red wisp -> gone
vec4 ramp_color(float u, float k) {
	vec4 c;
	if (u < 0.35) {
		c = mix(vec4(1.0, 0.95, 0.6, 0.85), vec4(1.0, 0.55, 0.1, 0.85), u / 0.35);
	} else if (u < 0.75) {
		c = mix(vec4(1.0, 0.55, 0.1, 0.85), vec4(0.6, 0.05, 0.0, 0.7), (u - 0.35) / 0.4);
	} else {
		c = mix(vec4(0.6, 0.05, 0.0, 0.7), vec4(0.05, 0.02, 0.0, 0.0), (u - 0.75) / 0.25);
	}
	c.a *= k;
	return c;
}

void vertex() {
	float cr = INSTANCE_CUSTOM.x;
	float packed = INSTANCE_CUSTOM.y;
	float t0 = INSTANCE_CUSTOM.z;
	float lit = INSTANCE_CUSTOM.w;
	int kind = int(floor(packed * 0.5));
	float sd = packed - float(kind) * 2.0;
	float elapsed = sim_t - lit;
	float t = t0 - elapsed;
	// size ramp over the burn: quick flare-up, sustain, dwindle (CellFireFX._ramp)
	float k = clamp((t0 - t) / 1.2, 0.25, 1.0) * clamp(t / 2.2, 0.22, 1.0);
	float flick = 1.0 + sin(sim_t * 18.0 + sd * 9.0) * 0.08 + sin(sim_t * 7.3 + 1.7 + sd * 5.0) * 0.05;
	vec2 off = vec2(0.0);
	float s = 0.0;
	float sy = 0.0;
	vec4 col = vec4(0.0);
	if (kind == 0) {
		// glow halo
		s = cr * 2.8 * k;
		sy = s;
		col = vec4(1.0, 0.6, 0.2, 0.30 * k * flick);
	} else if (kind == 1) {
		// core sheet bridging neighbouring cells' tongues
		s = cr * 1.9 * k;
		sy = s;
		col = vec4(1.0, 0.62, 0.15, 0.35 * k * flick);
	} else if (kind < 4) {
		// ember under-glow: seeded off-centre, wandering, fading in over ~2s
		float fg = float(kind - 2);
		float bed_k = k * clamp(elapsed / 2.0, 0.0, 1.0);
		vec2 goff = vec2(sfr(sd, fg + 71.0) - 0.5, sfr(sd, fg + 83.0) - 0.5) * cr * 0.9;
		goff += vec2(sin(sim_t * 0.7 + sd * 12.0 + fg * 3.1), cos(sim_t * 0.9 + sd * 7.0 + fg * 2.3)) * cr * 0.15;
		off = goff;
		s = cr * 1.6;
		sy = s;
		col = vec4(1.0, 0.38, 0.05, 0.40 * bed_k * flick);
	} else if (kind < 10) {
		// rising tongue: respawns somewhere new in the cell every cycle
		float fj = float(kind - 4);
		float dur = 0.7 + 0.45 * sfr(sd, fj + 13.0);
		float raw = sim_t / dur + sfr(sd, fj);
		float u = fract(raw);
		float cyc = floor(raw);
		float ease = 1.0 - pow(1.0 - u, 1.7);
		float rise = cr * (1.3 + 0.8 * sfr(sd, fj + 3.0 + cyc)) * k;
		float aoff = TAU_F * sfr(sd, fj * 3.7 + cyc * 11.0);
		float rad = sqrt(sfr(sd, fj * 5.1 + cyc * 17.0)) * cr * 0.85;
		vec2 base = vec2(cos(aoff), sin(aoff)) * rad;
		float wig = sin(sim_t * (2.5 + 2.0 * sfr(sd, fj + 41.0)) + fj * 1.7) * cr * 0.2 * u;
		off = base + vec2(wig, cr * 0.25 - rise * ease);
		float s0 = cr * (1.4 + 0.6 * sfr(sd, fj + 7.0 + cyc)) * k;
		s = s0 * mix(1.0, 0.55, min(u / 0.85, 1.0));
		float stretch = 1.6 + 0.4 * sfr(sd, fj + 23.0);
		sy = s * stretch;
		col = ramp_color(u, k);
	} else {
		// rare spark that outclimbs the flame body
		float fe = float(kind - 10);
		float ue = fract(sim_t * (0.55 + 0.2 * fe) + sd * 7.0 + fe * 0.37);
		off = vec2(sin(sd * 40.0 + fe * 9.0 + sim_t * 2.0) * cr * 0.4, 0.0) + UP * (cr * 0.5 + cr * 2.6 * ue);
		s = 2.0 * (1.0 - ue) * k + 0.8;
		sy = s;
		col = vec4(1.0, 0.62, 0.15, (1.0 - ue) * 0.5 * k);
	}
	if (t <= 0.0) {
		// burnt out between sim erase and the FX resync: draw nothing
		s = 0.0;
		sy = 0.0;
		col = vec4(0.0);
	}
	// unit quad (+-1) -> blob half-extents; the instance transform adds the centroid
	VERTEX = off + VERTEX * vec2(s, sy);
	COLOR = col * COLOR;
}

void fragment() {
	// fire_blob.gdshader falloff: soft radial, quadratic
	float d = length(UV - vec2(0.5)) * 2.0;
	float a = clamp(1.0 - d, 0.0, 1.0);
	a *= a;
	COLOR = vec4(COLOR.rgb * a, COLOR.a * a);
}
