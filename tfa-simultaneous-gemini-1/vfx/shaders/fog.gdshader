shader_type canvas_item;

uniform vec4 fog_color : source_color = vec4(0.8, 0.8, 0.8, 0.5);
uniform float density : hint_range(0.0, 1.0) = 0.5;
uniform vec2 speed = vec2(0.02, 0.01);
uniform float scale = 4.0;
// Silhouette. `falloff_radius` is measured against the rect's INSCRIBED circle:
// 1.0 is the middle of an edge, so any radius <= 1.0 is guaranteed to have faded
// out before the rect can clip it. (The old default of 0.8 was measured against
// length(UV - 0.5), where an edge midpoint is only 0.5 -- the fade never even
// started there, so every fog rendered as a hard rectangle.)
uniform float falloff_radius : hint_range(0.0, 1.0) = 1.0;
uniform float falloff_softness : hint_range(0.01, 1.0) = 0.5;
// How much low-frequency noise chews into the boundary. 0 = clean oval.
uniform float edge_wobble : hint_range(0.0, 1.0) = 0.35;
// Per-cloud offset so two puffs spawned side by side aren't the same shape.
uniform vec2 noise_seed = vec2(0.0);
uniform float color_shift : hint_range(0.0, 0.3) = 0.08;
uniform float warp_strength : hint_range(0.0, 2.0) = 0.8;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash(i);
	float b = hash(i + vec2(1.0, 0.0));
	float c = hash(i + vec2(0.0, 1.0));
	float d = hash(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p) {
	float value = 0.0;
	float amplitude = 0.5;
	for (int i = 0; i < 5; i++) {
		value += amplitude * noise(p);
		p *= 2.0;
		amplitude *= 0.5;
	}
	return value;
}

void fragment() {
	vec2 uv = UV * scale + noise_seed;
	vec2 movement = TIME * speed;

	// Domain warping: layer 1 (q) distorts the base, layer 2 (r) distorts further
	vec2 q = vec2(
		fbm(uv + movement),
		fbm(uv + vec2(5.2, 1.3) + movement * 0.6)
	);

	vec2 r = vec2(
		fbm(uv + warp_strength * q + vec2(1.7, 9.2) - movement * 0.4),
		fbm(uv + warp_strength * q + vec2(8.3, 2.8) + movement * 0.3)
	);

	float n = fbm(uv + warp_strength * r);

	// --- Silhouette ---------------------------------------------------------
	// dist == 1.0 on the rect's inscribed circle, 1.41 in the corners.
	vec2 d = (UV - vec2(0.5)) * 2.0;
	float dist = length(d);

	// Low-frequency noise bites into the boundary, turning the oval into lobes
	// and bays. It only ever carves INWARD, so the fade is always finished by
	// `falloff_radius` and the rect edge stays invisible no matter the seed.
	float bite = clamp(fbm(d * 1.7 + noise_seed + vec2(11.3, 4.1) + movement * 0.25), 0.0, 1.0);
	float radius = falloff_radius * (1.0 - edge_wobble * bite);
	float body = 1.0 - smoothstep(max(radius - falloff_softness, 0.0), radius, dist);

	// --- Density ------------------------------------------------------------
	// The rim raises the noise THRESHOLD rather than dimming the result, so the
	// cloud erodes into wisps and holes on the way out -- the same trick that
	// gives the fluid surface its ragged coastline. A flat alpha ramp instead
	// reads as a translucent shape with a visible geometric outline.
	// At body == 1 this is exactly the old smoothstep(1.0 - density, 1.0, n);
	// at body == 0 the threshold is above anything fbm can produce, so alpha is
	// a true zero well before the rect border.
	float low = mix(1.25, 1.0 - density, body);
	float fog = smoothstep(low, low + max(density, 0.05), n);
	fog *= 0.4 + 0.6 * body;

	// Color variation: derive two tints from fog_color
	// Slightly warmer (brighter) and cooler (darker) versions
	float luma = dot(fog_color.rgb, vec3(0.299, 0.587, 0.114));
	vec3 warm = fog_color.rgb + vec3(color_shift, color_shift * 0.5, -color_shift);
	vec3 cool = fog_color.rgb + vec3(-color_shift, -color_shift * 0.3, color_shift);

	// Blend between the two based on the warp pattern
	float color_mix = smoothstep(0.3, 0.7, r.x);
	vec3 final_color = mix(warm, cool, color_mix);

	COLOR = vec4(final_color, fog * fog_color.a);
}