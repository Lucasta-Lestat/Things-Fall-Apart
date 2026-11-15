shader_type canvas_item;
render_mode blend_premul_alpha;

// CanopyLayer (P3-B): the canopy atlas's crowns, premultiplied, faded round
// up to 128 shapes (CanopyLayer.MAX_FADES): party members under a crown, the
// cursor, and what must stay readable under the crowns (routes, aim lines,
// reticles, fire: CanopyLayer.REVEAL_GROUP), each a capsule a..b (a == b: a
// disc). COLOR comes in as the atlas texel times the crown's vertex colour
// (its tree's hit flash and damage tint), still premultiplied.

uniform int fade_count = 0;
uniform vec4 fade_seg[128];    // xy = a, zw = b (world px)
uniform vec2 fade_rad[128];    // x = full fade within, y = no fade past (px)
uniform float fade_min = 0.25; // what is left of a crown under a fade shape

varying vec2 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

void fragment() {
	float a = 1.0;
	for (int i = 0; i < 128; i++) {
		if (i >= fade_count) {
			break;
		}
		vec4 s = fade_seg[i];
		vec2 pa = world_pos - s.xy;
		vec2 ba = s.zw - s.xy;
		float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-4), 0.0, 1.0);
		vec2 r = fade_rad[i];
		a = min(a, mix(fade_min, 1.0, smoothstep(r.x, r.y, length(pa - ba * h))));
	}
	COLOR *= a;
}
