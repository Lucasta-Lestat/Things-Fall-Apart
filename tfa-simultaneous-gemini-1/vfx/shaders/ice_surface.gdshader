shader_type canvas_item;

uniform vec4 ice_color : source_color = vec4(0.7, 0.85, 0.95, 0.7);
uniform vec4 frost_color : source_color = vec4(0.9, 0.95, 1.0, 0.5);
uniform float crack_density : hint_range(0.0, 1.0) = 0.3;
uniform float shimmer_speed : hint_range(0.1, 3.0) = 0.8;
uniform float frost_amount : hint_range(0.0, 1.0) = 0.4;
// Breadth of the frost patches, in tile units (replaces the old per-tile edge
// vignette). Smaller = broader patches.
uniform float frost_patch_scale : hint_range(0.2, 8.0) = 1.7;

// This tile's GRID coordinate, set per instance by SurfaceManager._spawn_surface_vfx.
// Ice is drawn as one Sprite2D PER FROZEN TILE (_place_ice -> _spawn_surface_vfx ->
// vfx/ice_surface.tscn), so UV runs 0..1 inside every tile and anything derived
// from UV alone repeats identically in each one. Adding the tile coordinate makes
// the sample position world-continuous, so a frozen body reads as a single sheet.
// Same convention as water_flow / oil_sheen (`tile_position + uv`, see fluid.gd).
uniform vec2 tile_position = vec2(0.0);

float hash(vec2 p) {
	// Fold the lattice to a bounded range: world-space coords push p into the
	// hundreds and sin() loses precision on large arguments. The fold is by an
	// integer, so the noise/voronoi field stays seamless -- it just repeats every
	// 512 pattern units (32768 px), far larger than any map.
	vec2 fp = mod(p, 512.0);
	return fract(sin(dot(fp, vec2(127.1, 311.7))) * 43758.5453123);
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

float voronoi_cracks(vec2 uv) {
	vec2 i = floor(uv);
	vec2 f = fract(uv);
	float min_dist = 1.0;
	float second_dist = 1.0;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 neighbor = vec2(float(x), float(y));
			vec2 point = vec2(hash(i + neighbor), hash(i + neighbor + vec2(37.0, 17.0)));
			float d = length(neighbor + point - f);
			if (d < min_dist) {
				second_dist = min_dist;
				min_dist = d;
			} else if (d < second_dist) {
				second_dist = d;
			}
		}
	}
	// Edge detection: thin cracks where two cells meet
	return smoothstep(0.0, 0.08, second_dist - min_dist);
}

void fragment() {
	// World-continuous coordinate in TILE units. This replaces a bare `UV`, which
	// restarted at 0 in every tile and made the entire pattern (grain, cracks,
	// frost halo, shimmer blob) repeat identically per tile. Feature sizes are
	// unchanged: UV spanned 0..1 across a tile and so does one unit here.
	vec2 uv = tile_position + UV;

	// Base ice color with subtle noise variation
	float n = noise(uv * 8.0);
	vec3 base = mix(ice_color.rgb, ice_color.rgb * 1.15, n * 0.3);

	// Cracks pattern -- now spans tile borders, so a frozen pond reads as one sheet
	float cracks = voronoi_cracks(uv * 6.0);
	float crack_lines = 1.0 - smoothstep(0.0, crack_density, 1.0 - cracks);
	base = mix(base, base * 0.6, crack_lines * 0.5);

	// Frost crystals: broad organic world-space patches. The old version keyed off
	// distance to the QUAD edge (min(uv.x, 1.0 - uv.x), ...), which painted an
	// identical soft rectangular halo around every single tile -- the grid artefact.
	float frost_noise = noise(uv * 12.0 + TIME * 0.02);
	float frost_patch = smoothstep(0.35, 0.75, noise(uv * frost_patch_scale));
	float frost = frost_patch * frost_noise * frost_amount;
	base = mix(base, frost_color.rgb, frost);

	// Shimmer / specular highlight
	float shimmer = noise(uv * 4.0 + vec2(TIME * shimmer_speed, TIME * shimmer_speed * 0.7));
	shimmer = smoothstep(0.6, 0.9, shimmer) * 0.25;
	base += vec3(shimmer);

	COLOR = vec4(base, ice_color.a);
}
