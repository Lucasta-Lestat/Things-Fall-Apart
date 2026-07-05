// boid_sprite.gdshader - per-instance scurry animation for sprite-mode swarms.
//
// Drives a subtle squash/stretch + fore-aft shuffle from each agent's gait
// phase (packed into INSTANCE_CUSTOM.x by BoidField). Only vertex() is defined
// so the built-in canvas fragment still applies the per-instance color tint.
shader_type canvas_item;

void vertex() {
	float phase = INSTANCE_CUSTOM.x;
	// Body bob: squash along the short (y) axis, slight stretch along travel (x).
	float s = sin(phase);
	VERTEX.y *= 1.0 + 0.10 * s;
	VERTEX.x *= 1.0 - 0.05 * s;
	// Tiny fore-aft shuffle so the gait reads even when nearly stationary.
	VERTEX.x += 0.5 * sin(phase * 0.5);
}
