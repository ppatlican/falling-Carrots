#[compute]
#version 450

// Solve, once per frame before the iterations: liquids are pushed down the gradient of
// the pressure carried over from the last frame (liquid_pressure_delta), into scratch,
// clamped like solve_delta. solve_apply then applies it.

// common.glslinc stamp: Params 108 B, v4. Bump in every .glsl when common.glslinc changes (SPEC 2.7).
#include "common.glslinc"
#include "liquid.glslinc"

void main() {
	uint t;
	if (!sorted_particle(t)) {
		return;
	}
	vec2 d = vec2(0.0);
	if (s_class(t) == CLASS_LIQUID) {
		d = liquid_pressure_delta(t);
	}
	float len = length(d);
	float max_len = 0.5 * params.spacing;
	if (len > max_len) {
		d *= max_len / len;
	}
	scratch[t] = d;
}
