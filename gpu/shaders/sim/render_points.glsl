#[compute]
#version 450

// Render 2/3: draw each live liquid particle as a 2x2 point in its material colour
// (powders follow in render_powder.glsl, on top). Liquid in the pores of a powder bed
// (more powder than liquid touching it) is drawn as the nearest grain darkened, so a bed
// under water reads as wet sand where no grain covers the pore. Drawn plainly, pore
// water scattered blue specks over about a third of a settled bed (owner).

// common.glslinc stamp: Params 108 B, v10. Bump in every .glsl when common.glslinc changes (SPEC 2.7).
#include "common.glslinc"
#include "render.glslinc"

// Brightness of pore liquid drawn as wet powder.
const float WET_SHADE = 0.72;

void main() {
	uint t;
	if (!sorted_particle(t) || s_class(t) != CLASS_LIQUID) {
		return;
	}
	vec3 color = materials[s_material(t)].color.rgb;
	vec2 pt = s_pred[t];
	float reach2 = 1.44 * params.spacing * params.spacing;
	int powder = 0;
	int liquid = 0;
	float best = reach2;
	uint grain = t;
	FOR_EACH_NEIGHBOUR(t) {
		uint j = k;
		vec2 d = s_pred[j] - pt;
		float r2 = dot(d, d);
		if (j == t || r2 >= reach2) continue;
		if (s_class(j) == CLASS_POWDER) {
			powder++;
			if (r2 < best) {
				best = r2;
				grain = j;
			}
		} else if (s_class(j) == CLASS_LIQUID) {
			liquid++;
		}
	} END_NEIGHBOURS
	if (powder > liquid) {
		color = WET_SHADE * grain_color(s_material(grain), sorted_ids[t]);
	}
	draw_point(pt, color);
}
