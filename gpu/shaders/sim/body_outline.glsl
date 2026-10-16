#[compute]
#version 450

// Plasticity 2/3 (docs/adr/0012-plasticity.md item 4): each plastic member is sorted on its
// body's rest shape as moved by body_plastic (rest offset plus body_push), as rest_outline sorts:
// with fewer than 8 rest neighbours within 1.5 spacings (in its hash window) it is a boundary
// member, and its outline point is half a spacing out along the sum of the directions from its
// neighbours (from the body's rest centroid if they cancel). Writes the point to scratch (sorted
// index), PLASTIC_INNER for an inner member, for body_rest.
// Mirror: cpu_ref/particle_step.gd _plastic_outline (the points).

// common.glslinc stamp: Params 128 B, v22. Bump in every .glsl when common.glslinc changes (SPEC 2.7).
#include "common.glslinc"
#include "plastic.glslinc"

void main() {
	uint t;
	if (!sorted_particle(t) || !plastic_member(t)) {
		return;
	}
	uint body = s_body(t);
	float sp = params.spacing;
	vec2 q = rest_offset[sorted_ids[t]].xy + body_push[t];
	uint count = 0u;
	vec2 normal = vec2(0.0);
	FOR_EACH_NEIGHBOUR(t) {
		uint j = k;
		if (j == t || s_body(j) != body) continue;
		vec2 u = q - (rest_offset[sorted_ids[j]].xy + body_push[j]);
		float d2 = dot(u, u);
		if (d2 < 2.25 * sp * sp) {
			count++;
			normal += d2 > 0.0 ? u * inversesqrt(d2) : vec2(0.0);
		}
	} END_NEIGHBOURS
	if (count >= 8u) {
		scratch[t] = vec2(PLASTIC_INNER);
		return;
	}
	if (length(normal) < 1e-4) {
		normal = q - bodies[body].rest_c;
	}
	normal = length(normal) > 1e-6 ? normalize(normal) : vec2(0.0, -1.0);
	scratch[t] = q + 0.5 * sp * normal;
}
