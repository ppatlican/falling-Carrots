#[compute]
#version 450

// Predict (spec 2.6 step 2): apply gravity and guess where each particle goes.
// The move is clamped to max_step so fast particles can't skip past neighbours.

// common.glslinc stamp: Params 108 B, v10. Bump in every .glsl when common.glslinc changes (SPEC 2.7).
#include "common.glslinc"

void main() {
	uint i = gl_GlobalInvocationID.x;
	if (i >= params.cap || !is_alive(i)) {
		return;
	}
	vec2 v = vel[i] + vec2(0.0, params.gravity * params.dt);
	vec2 move = v * params.dt;
	float len = length(move);
	if (len > params.max_step) {
		move *= params.max_step / len;
	}
	vel[i] = v;
	pred[i] = clamp_to_world(pos[i] + move, i);
}
