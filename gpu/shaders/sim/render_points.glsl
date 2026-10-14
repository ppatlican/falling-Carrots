#[compute]
#version 450

// Render 2/4: draw each live liquid particle as a 2x2 point in its material colour
// (powders follow in render_powder.glsl, on top). Liquid in the pores of a powder bed is
// drawn as the nearest grain darkened, so a bed under water reads as wet sand where no
// grain covers the pore. Drawn plainly, pore water scattered blue specks over about a
// third of a settled bed (owner). The bed is found from the density projection grid's
// powder fill (hydro_powder_fill), not from counting neighbours: liquid leaves powder out
// of its density, so pore water sits at full density among the grains and touches about
// as much water as sand. Counted by neighbours (more powder than liquid within 1.2
// spacings), much of it drew blue, and a bed of 20k sand under a pool looked full of
// trapped water (owner screenshot, 2026-10-11).

// common.glslinc stamp: Params 124 B, v18. Bump in every .glsl when common.glslinc changes (SPEC 2.7).
#include "common.glslinc"
#include "render.glslinc"
#include "hydro.glslinc"

// Brightness of pore liquid drawn as wet powder.
const float WET_SHADE = 0.72;
// Powder fill (hydro_powder_fill) from which liquid touching a grain is pore liquid, and
// from which any liquid is: about the bed's top edge, and a cell's width inside it.
const float BED_EDGE_FILL = 0.5;
const float BED_INSIDE_FILL = 0.9;

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
	float best = 1e30;
	uint grain = t;
	FOR_EACH_NEIGHBOUR(t) {
		uint j = k;
		if (j == t) continue;
		vec2 d = s_pred[j] - pt;
		float r2 = dot(d, d);
		if (s_class(j) == CLASS_POWDER && r2 < best) {
			best = r2;
			grain = j;
		}
		if (r2 >= reach2) continue;
		if (s_class(j) == CLASS_POWDER) {
			powder++;
		} else if (s_class(j) == CLASS_LIQUID) {
			liquid++;
		}
	} END_NEIGHBOURS
	// Pore liquid: inside the bed, at its edge touching a grain, or (where the grid is too
	// coarse to see a thin layer) touching more powder than liquid.
	float fill = hydro_powder_fill(pt);
	bool pore = fill >= BED_INSIDE_FILL || (powder > 0 && (fill >= BED_EDGE_FILL || powder > liquid));
	if (pore && grain != t) {
		color = WET_SHADE * grain_color(s_material(grain), sorted_ids[t]);
	}
	draw_point(pt, color);
}
