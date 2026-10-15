#[compute]
#version 450

// Regions 2/2 (once per solver iteration, after body_region_fit): every member of a soft body
// moves toward the mean, over the regions that hold it, of each region's goal for it, t + R q
// (region_frame, q its rest offset), by k = 1 - (1 - stiffness)^(dt * 60 / iterations), as
// body_match moves a rigid body's members (docs/adr/0005-soft-bodies-bend.md item 1). The regions
// that hold member i are those of the members in its own region (the relation is symmetric),
// found as body_region_fit finds them. Each region is rigid, but neighbouring regions turn by
// different amounts, so the body bends where it is loaded and springs back to its rest shape.
// A thread writes only its own s_pred and reads no other particle's position, so no thread sees
// another's move. Mirror: cpu_ref/particle_step.gd _match_regions (the goal).

// common.glslinc stamp: Params 124 B, v20. Bump in every .glsl when common.glslinc changes (SPEC 2.7).
#include "common.glslinc"

void main() {
	uint t;
	if (!sorted_particle(t)) {
		return;
	}
	uint body = s_body(t);
	uint m = s_material(t);
	if (body == 0u || !soft_material(m)) {
		return;
	}
	vec2 q_t = rest_offset[sorted_ids[t]].xy;
	float reach = region_reach(m);
	float n = 0.0;
	vec2 goal = vec2(0.0);
	FOR_EACH_NEIGHBOUR(t) {
		uint j = k;
		if (s_body(j) != body) continue;
		uint slot_j = sorted_ids[j];
		vec2 q = rest_offset[slot_j].xy - q_t;
		if (dot(q, q) > reach * reach) continue;
		vec4 f = region_frame[slot_j];
		goal += f.xy + vec2(f.z * q_t.x - f.w * q_t.y, f.w * q_t.x + f.z * q_t.y);
		n += 1.0;
	} END_NEIGHBOURS
	float k = 1.0 - pow(1.0 - materials[m].extra.y, params.dt * 60.0 / float(params.iterations));
	s_pred[t] += k * (goal / n - s_pred[t]);
}
