#[compute]
#version 450

// Velocity 2/3: XSPH viscosity for liquids, the liquid's drag on powders and bodies
// (powder_liquid_drag, body_liquid_drag) and on mochi, as on a body, with its viscosity
// (mochi_viscosity, ADR 0017), and stickiness while any material has it (stick.glslinc,
// ADR 0011), written to scratch so every particle reads its neighbours' unmodified velocities.

// common.glslinc stamp: Params 128 B, v26. Bump in every .glsl when common.glslinc changes (SPEC 2.7).
#include "common.glslinc"
#include "liquid.glslinc"
#include "mochi.glslinc"
#include "powder.glslinc"
#include "stick.glslinc"

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
	} else if (s_class(t) == CLASS_MOCHI) {
		v += body_liquid_drag(t) + mochi_viscosity(t);
	}
	if (params.sticky != 0u) {
		v += stick_velocity(t);
	}
	scratch[t] = v;
}
