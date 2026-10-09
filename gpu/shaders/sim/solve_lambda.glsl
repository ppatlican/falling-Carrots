#[compute]
#version 450

// Solve 1/3 (per iteration): PBF lambda for liquids. Other classes get 0.

// common.glslinc stamp: Params 108 B, v3. Bump in every .glsl when common.glslinc changes (SPEC 2.7).
#include "common.glslinc"
#include "liquid.glslinc"

void main() {
	uint t;
	if (!sorted_particle(t)) {
		return;
	}
	lambda[t] = s_class(t) == CLASS_LIQUID ? liquid_lambda(t) : 0.0;
}
