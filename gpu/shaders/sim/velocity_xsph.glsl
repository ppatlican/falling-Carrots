#[compute]
#version 450

// Velocity 2/3: XSPH viscosity for liquids, and the liquid's drag on powders and bodies
// (powder_liquid_drag, body_liquid_drag), written to scratch so every particle reads its neighbours'
// unmodified velocities.

// common.glslinc stamp: Params 124 B, v17. Bump in every .glsl when common.glslinc changes (SPEC 2.7).
#include "common.glslinc"
#include "liquid.glslinc"
#include "powder.glslinc"

void main() {
	uint t;
	if (!sorted_particle(t)) {
		return;
	}
	vec2 v = s_vel[t];
	if (s_body(t) != 0u) {
		v += body_liquid_drag(t);
	} else if (s_class(t) == CLASS_LIQUID) {
		v += liquid_xsph(t);
	} else if (s_class(t) == CLASS_POWDER) {
		v += powder_liquid_drag(t);
	}
	scratch[t] = v;
}
