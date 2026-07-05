#[compute]
#version 450

// ---------------------------------------------------------------------------
// boids.glsl - GPU flocking simulation for the BoidField system.
//
// One invocation per agent. Classic Reynolds steering (separation / alignment
// / cohesion) plus target seek-or-flee, smooth wander, soft home pull and hard
// bounds. Neighbour search is brute-force O(n^2) which is plenty for the swarm
// sizes this game uses (tens to a couple thousand); swap in a spatial grid here
// if you ever need 10k+.
//
// Agent state is packed as two vec4 per agent in a single storage buffer:
//   a0 = (pos.x, pos.y, vel.x, vel.y)
//   a1 = (gait_phase, scale_var, color_idx, seed)
// Only pos/vel/phase are written back each step; scale_var/color_idx/seed are
// authored once on spawn and left untouched.
// ---------------------------------------------------------------------------

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer Agents {
	vec4 data[];
} agents;

// All-float push constant (24 floats = 96 bytes). agent_count is carried as a
// float and re-cast to int so the GDScript side can build the whole block with
// a single PackedFloat32Array.
layout(push_constant, std430) uniform Params {
	float agent_count;
	float delta;
	float time;
	float max_speed;

	float min_speed;
	float max_force;
	float perception;
	float sep_radius;

	float sep_w;
	float ali_w;
	float coh_w;
	float wander_w;

	float target_x;
	float target_y;
	float target_w;
	float flee;          // 0 = seek target, 1 = flee from target

	float bounds_min_x;
	float bounds_min_y;
	float bounds_max_x;
	float bounds_max_y;

	float bounds_w;
	float home_w;
	float damping;
	float swirl;         // tangential orbit force around the field centre
} P;

const float TAU = 6.28318530718;

float hash11(float p) {
	p = fract(p * 0.1031);
	p *= p + 33.33;
	p *= p + p;
	return fract(p);
}

vec2 limit(vec2 v, float m) {
	float l = length(v);
	if (l > m && l > 1e-6) {
		return v / l * m;
	}
	return v;
}

// Reynolds steering: accelerate toward `desired` direction at full speed,
// minus current velocity, clamped to the max steering force.
vec2 steer(vec2 desired, vec2 vel) {
	float l = length(desired);
	if (l < 1e-5) {
		return vec2(0.0);
	}
	desired = desired / l * P.max_speed;
	return limit(desired - vel, P.max_force);
}

void main() {
	uint gi = gl_GlobalInvocationID.x;
	int n = int(P.agent_count);
	if (int(gi) >= n) {
		return;
	}

	vec4 a0 = agents.data[gi * 2u];
	vec4 a1 = agents.data[gi * 2u + 1u];
	vec2 pos = a0.xy;
	vec2 vel = a0.zw;
	float phase = a1.x;
	float seed = a1.w;

	// --- Neighbour accumulation (single pass) --------------------------------
	vec2 sep = vec2(0.0);
	vec2 ali = vec2(0.0);
	vec2 coh = vec2(0.0);
	int ali_n = 0;
	int coh_n = 0;
	int sep_n = 0;

	float perc2 = P.perception * P.perception;
	float sepr2 = P.sep_radius * P.sep_radius;

	for (int j = 0; j < n; j++) {
		if (j == int(gi)) {
			continue;
		}
		vec4 o = agents.data[j * 2u];
		vec2 d = o.xy - pos;
		float dist2 = dot(d, d);
		if (dist2 > perc2 || dist2 < 1e-6) {
			continue;
		}
		coh += o.xy; coh_n++;
		ali += o.zw; ali_n++;
		if (dist2 < sepr2) {
			// Push away, weighted by inverse distance so close crowding hurts more.
			sep -= d / dist2;
			sep_n++;
		}
	}

	vec2 acc = vec2(0.0);

	if (sep_n > 0) {
		acc += steer(sep, vel) * P.sep_w;
	}
	if (ali_n > 0) {
		acc += steer(ali / float(ali_n), vel) * P.ali_w;
	}
	if (coh_n > 0) {
		vec2 center = coh / float(coh_n);
		acc += steer(center - pos, vel) * P.coh_w;
	}

	// --- Wander: steer toward the current heading nudged by a slow random jitter.
	if (P.wander_w > 0.0) {
		float base = atan(vel.y, vel.x);
		// Re-roll the jitter ~8x/sec so motion looks organic, not per-frame noise.
		float r = hash11(seed * 3.1 + floor(P.time * 8.0) + seed);
		float jitter = (r - 0.5) * 1.4;
		vec2 wdir = vec2(cos(base + jitter), sin(base + jitter));
		acc += steer(wdir, vel) * P.wander_w;
	}

	// --- Target seek / flee --------------------------------------------------
	if (P.target_w > 0.0) {
		vec2 to_t = vec2(P.target_x, P.target_y) - pos;
		if (P.flee > 0.5) {
			to_t = -to_t;
		}
		acc += steer(to_t, vel) * P.target_w;
	}

	// --- Home: gentle pull toward the centre of the field's bounds -----------
	vec2 bmin = vec2(P.bounds_min_x, P.bounds_min_y);
	vec2 bmax = vec2(P.bounds_max_x, P.bounds_max_y);
	if (P.home_w > 0.0) {
		vec2 center = (bmin + bmax) * 0.5;
		acc += steer(center - pos, vel) * P.home_w;
	}

	// --- Bounds: turn back before crossing the edge (acts only near/over it). -
	if (P.bounds_w > 0.0) {
		float margin = 24.0;
		vec2 desired = vel;
		if (pos.x < bmin.x + margin) desired.x = P.max_speed;
		else if (pos.x > bmax.x - margin) desired.x = -P.max_speed;
		if (pos.y < bmin.y + margin) desired.y = P.max_speed;
		else if (pos.y > bmax.y - margin) desired.y = -P.max_speed;
		acc += limit(desired - vel, P.max_force) * P.bounds_w;
	}

	// --- Swirl: tangential orbit around the centre for a vortex / magical look.
	if (abs(P.swirl) > 0.001) {
		vec2 radial = pos - (bmin + bmax) * 0.5;
		if (dot(radial, radial) > 1.0) {
			vec2 tangent = normalize(vec2(-radial.y, radial.x)) * sign(P.swirl);
			acc += steer(tangent, vel) * abs(P.swirl);
		}
	}

	// --- Integrate -----------------------------------------------------------
	vel += acc * P.delta;
	vel *= P.damping;

	float spd = length(vel);
	if (spd > P.max_speed) {
		vel = vel / spd * P.max_speed;
	} else if (spd < P.min_speed) {
		if (spd > 1e-4) {
			vel = vel / spd * P.min_speed;
		} else {
			// Dead-stopped: kick off in a seeded random direction.
			float a = hash11(seed) * TAU;
			vel = vec2(cos(a), sin(a)) * P.min_speed;
		}
	}

	pos += vel * P.delta;
	// Hard clamp just outside the bounds so nothing can ever escape on screen.
	pos = clamp(pos, bmin - 48.0, bmax + 48.0);

	// Gait phase advances faster the faster the agent moves.
	float move = clamp(spd / max(P.max_speed, 1.0), 0.0, 1.0);
	phase = mod(phase + P.delta * (4.0 + move * 18.0), TAU);

	agents.data[gi * 2u] = vec4(pos, vel);
	a1.x = phase;
	agents.data[gi * 2u + 1u] = a1;
}
