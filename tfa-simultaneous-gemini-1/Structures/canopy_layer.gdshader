shader_type canvas_item;
render_mode blend_premul_alpha;

// CanopyLayer (P3-B): the canopy atlas's crowns, premultiplied, faded round
// up to 8 points (party members under a crown, the cursor) so what stands
// under them shows. COLOR comes in as the atlas texel times the crown's
// vertex colour (its tree's hit flash and damage tint), still premultiplied.

uniform int fade_count = 0;
uniform vec4 fade_pts[8];      // xy = world px, z = inner radius, w = outer radius
uniform float fade_min = 0.25; // what is left of a crown at a fade point

varying vec2 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

void fragment() {
	float a = 1.0;
	for (int i = 0; i < 8; i++) {
		if (i >= fade_count) {
			break;
		}
		vec4 f = fade_pts[i];
		a = min(a, mix(fade_min, 1.0, smoothstep(f.z, f.w, distance(world_pos, f.xy))));
	}
	COLOR *= a;
}
