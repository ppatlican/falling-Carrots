#[compute]
#version 450

// Velocity 3/3: write the solved position and new velocity back to the particle's slot
// for the next frame.

// common.glslinc stamp: Params 108 B, v9. Bump in every .glsl when common.glslinc changes (SPEC 2.7).
#include "common.glslinc"

void main() {
	uint t;
	if (!sorted_particle(t)) {
		return;
	}
	uint i = sorted_ids[t];
	vel[i] = scratch[t];
	pos[i] = s_pred[t];
}
