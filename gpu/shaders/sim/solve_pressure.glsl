#[compute]
#version 450

// Solve, once per frame before the iterations: liquids are pushed down the gradient of
// the density projection grid's pressure (hydro_delta in hydro.glslinc), into scratch,
// clamped like solve_delta, and scaled by hydro_support (none for loose drops above the
// surface). solve_apply then applies it. The density loop runs only near the surface.

// common.glslinc stamp: Params 108 B, v9. Bump in every .glsl when common.glslinc changes (SPEC 2.7).
#include "common.glslinc"
#include "hydro.glslinc"
#include "liquid.glslinc"

void main() {
	uint t;
	if (!sorted_particle(t)) {
		return;
	}
	vec2 d = vec2(0.0);
	if (s_class(t) == CLASS_LIQUID) {
		d = hydro_delta(s_pred[t]);
		if (!hydro_submerged(s_pred[t])) {
			d *= hydro_support(liquid_density(t));
		}
	}
	float len = length(d);
	float max_len = 0.5 * params.spacing;
	if (len > max_len) {
		d *= max_len / len;
	}
	scratch[t] = d;
}
