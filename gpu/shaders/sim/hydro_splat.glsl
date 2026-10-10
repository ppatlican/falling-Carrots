#[compute]
#version 450

// Hydro 1/4: each liquid and powder particle adds its tent weight to the density sums
// of the coarse cells around it (hydro_splat in hydro.glslinc).

// common.glslinc stamp: Params 108 B, v9. Bump in every .glsl when common.glslinc changes (SPEC 2.7).
#include "common.glslinc"
#include "hydro.glslinc"

void main() {
	uint t;
	if (!sorted_particle(t)) {
		return;
	}
	uint cls = s_class(t);
	if (cls == CLASS_LIQUID || cls == CLASS_POWDER) {
		hydro_splat(s_pred[t], cls == CLASS_LIQUID ? 0u : 1u);
	}
}
