#[compute]
#version 450

// Solve 2/3 (per iteration): each particle's position correction, into scratch. A body
// member's push from other bodies is also added up in vel (velocity_update). What a soft member
// gets from other soft bodies is kept for this iteration in body_push, over the size of its region
// (solve_apply, ADR 0008).
// Liquids: density constraint. Everyone: powder contacts. Clamped to half a spacing
// per iteration for stability. New behaviour classes add their term here.

// common.glslinc stamp: Params 128 B, v22. Bump in every .glsl when common.glslinc changes (SPEC 2.7).
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
	vec2 body_out;
	vec2 body_share;
	float region_n;
	d += contact_delta(t, body_out, body_share, region_n);
	float len = length(d);
	float max_len = 0.5 * params.spacing;
	float scale = len > max_len ? max_len / len : 1.0;
	d *= scale;
	if (s_body(t) != 0u) {
		vel[sorted_ids[t]] += scale * body_out;  // summed over the iterations (velocity_update)
	}
	// What a soft member gets from other soft bodies, in the share each member of its region gets
	// of it (solve_apply).
	body_push[t] = scale * body_share / region_n;
	scratch[t] = d;
}
