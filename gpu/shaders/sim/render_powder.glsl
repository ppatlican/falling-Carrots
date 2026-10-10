#[compute]
#version 450

// Render 3/3: draw each live powder grain as a 2x2 point, after the liquids, so sand
// always covers the water in its pores. Drawn in one dispatch, the winner of each
// overlapping pixel followed the cell sort, which changes every frame: a settled bed
// under water flickered between sand and water on ~20% of its pixels.

// common.glslinc stamp: Params 108 B, v10. Bump in every .glsl when common.glslinc changes (SPEC 2.7).
#include "common.glslinc"
#include "render.glslinc"

void main() {
	uint t;
	if (!sorted_particle(t)) {
		return;
	}
	if (s_class(t) == CLASS_POWDER) {
		draw_point(s_pred[t], grain_color(s_material(t), sorted_ids[t]));
	}
}
