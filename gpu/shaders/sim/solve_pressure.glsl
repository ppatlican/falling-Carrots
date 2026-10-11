#[compute]
#version 450

// Solve, once per frame before the iterations: liquids are pushed down the gradient of
// the density projection grid's pressure (hydro_delta in hydro.glslinc), into scratch,
// clamped like solve_delta. solve_apply then applies it. A particle hanging over air next
// to sand loses part of the upward push (hydro_hang_share), so water lying as a lid over a
// dip in the bed, or as a face off a slope, falls in.

// common.glslinc stamp: Params 108 B, v14. Bump in every .glsl when common.glslinc changes (SPEC 2.7).
#include "common.glslinc"
#include "hydro.glslinc"

void main() {
	uint t;
	if (!sorted_particle(t)) {
		return;
	}
	vec2 d = vec2(0.0);
	if (s_class(t) == CLASS_LIQUID) {
		d = hydro_delta(s_pred[t]);
		if (d.y < 0.0) {
			d.y *= 1.0 - hydro_hang_share(t);
		}
	}
	float len = length(d);
	float max_len = 0.5 * params.spacing;
	if (len > max_len) {
		d *= max_len / len;
	}
	scratch[t] = d;
}
