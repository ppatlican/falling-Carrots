#[compute]
#version 450

// Solve 2/3 (per iteration): each particle's position correction, into scratch.
// Liquids: density constraint. Everyone: powder contacts. Clamped to half a spacing
// per iteration for stability. New behaviour classes add their term here.

// common.glslinc stamp: Params 108 B, v10. Bump in every .glsl when common.glslinc changes (SPEC 2.7).
#include "common.glslinc"
#include "liquid.glslinc"
#include "powder.glslinc"

void main() {
	uint t;
	if (!sorted_particle(t)) {
		return;
	}
	vec2 d = vec2(0.0);
	if (s_class(t) == CLASS_LIQUID) {
		d = liquid_delta(t);
	}
	d += contact_delta(t);
	float len = length(d);
	float max_len = 0.5 * params.spacing;
	if (len > max_len) {
		d *= max_len / len;
	}
	scratch[t] = d;
}
