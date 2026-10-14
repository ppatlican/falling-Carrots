#[compute]
#version 450

// Hydro 1/4: each liquid, powder and body particle adds its tent weight to the density sums
// of the coarse cells around it (hydro_splat in hydro.glslinc); a body particle to its
// volume and its weight in water.

// common.glslinc stamp: Params 124 B, v19. Bump in every .glsl when common.glslinc changes (SPEC 2.7).
#include "common.glslinc"
#include "hydro.glslinc"

void main() {
	uint t;
	if (!sorted_particle(t)) {
		return;
	}
	uint cls = s_class(t);
	if (s_body(t) != 0u) {
		// Body volume, and its weight in water (ADR 0003).
		hydro_splat(s_pred[t], 2u, 1.0);
		hydro_splat(s_pred[t], 3u, min(materials[s_material(t)].phys.x, 1.0));
	} else if (cls == CLASS_LIQUID || cls == CLASS_POWDER) {
		hydro_splat(s_pred[t], cls == CLASS_LIQUID ? 0u : 1u, 1.0);
	}
}
