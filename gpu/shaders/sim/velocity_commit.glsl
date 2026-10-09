#[compute]
#version 450

// Velocity 3/3: write the solved position and new velocity back to the particle's
// slot for the next frame.

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
