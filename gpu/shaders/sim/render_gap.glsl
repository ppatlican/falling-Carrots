#[compute]
#version 450

// Render 3/4 (after the liquids, before the powders): fills the empty pixels between a
// liquid particle and the grain right under it with the liquid's colour. Drawing only: it
// hides the air, it doesn't remove it. The water's bottom layer over a settled sand bed
// lies 2-3 px above the grains, held up by the density projection grid's pressure, which
// a 16 px cell can't resolve, and the gap drew as a dark strip along the bed top (owner,
// 2026-10-11). Fixing it in the sim either drove a loop over sand mounds or changed how
// much water the bed holds (see docs/STATUS.md, dark strip). Only background pixels are
// painted and always in the liquid's plain colour, so the draw order among threads can't
// make it flicker, and grains drawn next still cover their own pixels.

// common.glslinc stamp: Params 128 B, v24. Bump in every .glsl when common.glslinc changes (SPEC 2.7).
#include "common.glslinc"
#include "hydro.glslinc"

// Largest gap (px) between the liquid's point and the grain's point that is filled, and
// how far to the side (px) the grain's centre may be.
const int GAP_MAX = 4;
const float GAP_SIDE = 2.0;
// Inside the bed liquid is drawn as wet sand (render_points), so nothing to fill there;
// with no sand near (powder fill under NEAR_FILL, as in open water) there is nothing under
// it, and skipping the neighbour search there saves most of the pass's cost.
const float BED_INSIDE_FILL = 0.9;
const float NEAR_FILL = 0.02;

// A pixel nothing has been drawn on yet (render_clear's background is ~0.07).
bool background(ivec2 q) {
	vec3 c = imageLoad(out_image, q).rgb;
	return max(c.r, max(c.g, c.b)) < 0.2;
}

void main() {
	uint t;
	if (!sorted_particle(t) || s_class(t) != CLASS_LIQUID) {
		return;
	}
	vec2 pt = s_pred[t];
	float fill = hydro_powder_fill(pt);
	if (fill >= BED_INSIDE_FILL || fill < NEAR_FILL) {
		return;
	}
	// The nearest grain under the particle.
	float best = 1e30;
	vec2 below = pt;
	FOR_EACH_NEIGHBOUR(t) {
		uint j = k;
		if (j == t || s_class(j) != CLASS_POWDER) continue;
		vec2 d = s_pred[j] - pt;
		if (d.y <= 0.0 || abs(d.x) > GAP_SIDE) continue;
		if (d.y < best) {
			best = d.y;
			below = s_pred[j];
		}
	} END_NEIGHBOURS
	if (best > 1e29) {
		return;
	}
	ivec2 p = ivec2(floor(pt - 0.5));
	int top = int(floor(below.y - 0.5));  // the grain's first row
	int from = p.y + 2;
	if (top - from > GAP_MAX || top <= from) {
		return;
	}
	vec4 color = vec4(materials[s_material(t)].color.rgb, 1.0);
	ivec2 size = ivec2(params.world_size);
	for (int y = from; y < top; y++) {
		for (int dx = 0; dx < 2; dx++) {
			ivec2 q = ivec2(p.x + dx, y);
			if (q.x >= 0 && q.y >= 0 && q.x < size.x && q.y < size.y && background(q)) {
				imageStore(out_image, q, color);
			}
		}
	}
}
