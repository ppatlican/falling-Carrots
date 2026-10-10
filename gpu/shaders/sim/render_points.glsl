#[compute]
#version 450

// Render 2/2: draw each live particle as a 2x2 point in its material colour.
// Powders get a little per-grain brightness variation (fixed per slot). Overlapping
// points simply overwrite each other (no blending), which is fine for plain points.

// common.glslinc stamp: Params 108 B, v9. Bump in every .glsl when common.glslinc changes (SPEC 2.7).
#include "common.glslinc"

void main() {
	uint t;
	if (!sorted_particle(t)) {
		return;
	}
	vec4 color = materials[s_material(t)].color;
	if (s_class(t) == CLASS_POWDER) {
		color.rgb *= 0.85 + 0.3 * hash_unit(sorted_ids[t]);
	}
	ivec2 p = ivec2(floor(s_pred[t] - 0.5));
	ivec2 size = ivec2(params.world_size);
	for (int y = 0; y < 2; y++) {
		for (int x = 0; x < 2; x++) {
			ivec2 q = p + ivec2(x, y);
			if (q.x >= 0 && q.y >= 0 && q.x < size.x && q.y < size.y) {
				imageStore(out_image, q, vec4(color.rgb, 1.0));
			}
		}
	}
}
