#[compute]
#version 450

// Velocity 2/3: XSPH viscosity for liquids, written to scratch so every particle
// reads its neighbours' unmodified velocities.

// common.glslinc stamp: Params 108 B, v7. Bump in every .glsl when common.glslinc changes (SPEC 2.7).
#include "common.glslinc"
#include "liquid.glslinc"

void main() {
	uint t;
	if (!sorted_particle(t)) {
		return;
	}
	vec2 v = s_vel[t];
	if (s_class(t) == CLASS_LIQUID) {
		v += liquid_xsph(t);
	}
	scratch[t] = v;
}
