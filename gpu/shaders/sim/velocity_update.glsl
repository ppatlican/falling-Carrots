#[compute]
#version 450

// Velocity 1/3 (spec 2.6 step 5): velocity from the solved move, times (1 - drag).

#include "common.glslinc"

void main() {
	uint t;
	if (!sorted_particle(t)) {
		return;
	}
	float drag = materials[s_material(t)].phys.w;
	s_vel[t] = (s_pred[t] - s_pos[t]) / params.dt * (1.0 - drag);
}
