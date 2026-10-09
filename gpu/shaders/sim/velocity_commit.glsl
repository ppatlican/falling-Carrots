#[compute]
#version 450

// Velocity 3/3: write the solved position, new velocity and carried-over liquid
// pressure (times WARM_START) back to the particle's slot for the next frame.

// common.glslinc stamp: Params 108 B, v4. Bump in every .glsl when common.glslinc changes (SPEC 2.7).
#include "common.glslinc"

void main() {
	uint t;
	if (!sorted_particle(t)) {
		return;
	}
	uint i = sorted_ids[t];
	vel[i] = scratch[t];
	pos[i] = s_pred[t];
	lambda_acc[i] = WARM_START * s_lambda[t];
}
