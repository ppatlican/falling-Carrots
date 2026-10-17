#[compute]
#version 450

// Solve 1/3 (per iteration): PBF lambda for liquids; for mochi, its density (mochi.glslinc, ADR 0017).
// Other classes get 0.

// common.glslinc stamp: Params 128 B, v26. Bump in every .glsl when common.glslinc changes (SPEC 2.7).
#include "common.glslinc"
#include "liquid.glslinc"
#include "mochi.glslinc"

void main() {
	uint t;
	if (!sorted_particle(t)) {
		return;
	}
	uint c = s_class(t);
	lambda[t] = c == CLASS_LIQUID ? liquid_lambda(t) : (c == CLASS_MOCHI ? mochi_density(t) : 0.0);
}
