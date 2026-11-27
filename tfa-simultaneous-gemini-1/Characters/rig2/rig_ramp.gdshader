shader_type canvas_item;
// Draws a hand in another material: the texture's luminance is read against the
// source's four tone stops (outline, shadow, mid, light) and replaced by the four
// colours of a ramp. Used for the shared greyscale fist (ramp = the race's skin, or
// a glove) and for a race's own open hand under a glove (stops = the race's skin).
// The offline mirror is core.ramp_colour in tools/rigkit/core.py; keep them in step.
uniform vec4 src_stops = vec4(0.2, 0.4, 0.55, 0.7);
uniform vec3 ramp0 = vec3(0.1);
uniform vec3 ramp1 = vec3(0.35);
uniform vec3 ramp2 = vec3(0.5);
uniform vec3 ramp3 = vec3(0.7);
// UV.x left of which nothing is drawn (a gloved fist ends at the wrist); < 0 = off
uniform float cut = -1.0;

// In Godot 4 the fragment COLOR arrives already multiplied by the texture, so the
// node's modulate / vertex colour is carried separately (else the ramp is darkened
// by the greyscale art and alpha is squared).
varying vec4 tint;

void vertex() {
	tint = COLOR;
}

void fragment() {
	vec4 t = texture(TEXTURE, UV);
	float l = dot(t.rgb, vec3(0.299, 0.587, 0.114));
	vec3 c = ramp0;
	if (l >= src_stops.x) {
		c = mix(ramp0, ramp1, clamp((l - src_stops.x) / max(src_stops.y - src_stops.x, 0.0001), 0.0, 1.0));
	}
	if (l >= src_stops.y) {
		c = mix(ramp1, ramp2, clamp((l - src_stops.y) / max(src_stops.z - src_stops.y, 0.0001), 0.0, 1.0));
	}
	if (l >= src_stops.z) {
		c = mix(ramp2, ramp3, clamp((l - src_stops.z) / max(src_stops.w - src_stops.z, 0.0001), 0.0, 1.0));
	}
	float a = t.a;
	if (UV.x < cut) {
		a = 0.0;
	}
	COLOR = vec4(c, a) * tint;
}
