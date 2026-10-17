#[compute]
#version 450

// Plasticity 3/3 (docs/adr/0012-plasticity.md item 4): a plastic member whose hash window holds a
// member that moved this substep (body_push from body_plastic) takes its moved rest offset and its
// way out of the moved rest shape: a boundary member to its own outline point (scratch, from
// body_outline), an inner member to the nearest boundary member's point in its window, and with
// none there (two or more rows in) it keeps its way out, moved with it. Writes only its own
// rest_offset, and reads only its own, so no member sees another's half-written.
// Mirror: cpu_ref/particle_step.gd _plastic_outline (the new outline and rest).

// common.glslinc stamp: Params 128 B, v26. Bump in every .glsl when common.glslinc changes (SPEC 2.7).
#include "common.glslinc"
#include "plastic.glslinc"

void main() {
	uint t;
	if (!sorted_particle(t) || !plastic_member(t)) {
		return;
	}
	uint body = s_body(t);
	uint slot = sorted_ids[t];
	vec4 r = rest_offset[slot];
	vec2 q = r.xy + body_push[t].xy;
	bool moved = false;
	vec2 best = vec2(PLASTIC_INNER);
	// Only points within PLASTIC_REACH spacings on the rest shape: the window holds the members
	// near it where they are now, which in a crumpled body can be far apart on the rest shape.
	float best_d2 = PLASTIC_REACH * PLASTIC_REACH * params.spacing * params.spacing;
	FOR_EACH_NEIGHBOUR(t) {
		uint j = k;
		if (s_body(j) != body) continue;
		moved = moved || body_push[j].xy != vec2(0.0);
		vec2 o = scratch[j];
		if (o.x < 0.5 * PLASTIC_INNER) {
			float d2 = dot(o - q, o - q);
			if (d2 < best_d2) {
				best_d2 = d2;
				best = o;
			}
		}
	} END_NEIGHBOURS
	if (!moved) {
		return;
	}
	vec2 own = scratch[t];
	vec2 e = r.zw;
	if (own.x < 0.5 * PLASTIC_INNER) {
		e = own - q;
	} else if (best.x < 0.5 * PLASTIC_INNER) {
		e = best - q;
	}
	rest_offset[slot] = vec4(q, e);
}
