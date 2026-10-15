#[compute]
#version 450

// Regions 1/2 (once per solver iteration, after the body pass): soft bodies bend
// (docs/adr/0005-soft-bodies-bend.md items 1 and 3; FastLSM, Rivers & James 2007). One thread per
// sorted particle; anything not in a soft body (a cluster material below stiffness 1) returns.
// A member's region is itself and the members of its body whose rest offsets lie within the
// material's region radius of its own (region_reach, at most H), found in the 3 x 3 hash cells
// around it: the same pairs from both sides, so "r's region holds i" exactly when "i's region
// holds r". The region is fitted as body_match fits a whole body (unweighted sums, closed-form
// 2D rotation atan2(A10 - A01, A00 + A11), the last rotation kept when the region has under 2
// members or |A_pq| is near 0), and written per slot as t = c - R c0 and R (region_frame), so
// body_region_goal can turn any member's rest offset q into this region's goal t + R q.
// p and q are summed relative to the member's own, to keep the sums small.
// Mirror: cpu_ref/particle_step.gd _match_regions (the fit) and _find_regions.

// common.glslinc stamp: Params 124 B, v20. Bump in every .glsl when common.glslinc changes (SPEC 2.7).
#include "common.glslinc"

// Keeps the last rotation when |A_pq| is below this, per region member, in px^2.
// Mirror: ParticleStep.BODY_ROT_EPS.
const float BODY_ROT_EPS = 1e-4;

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
	uint slot = sorted_ids[t];
	vec2 p_t = s_pred[t];
	vec2 q_t = rest_offset[slot].xy;
	float reach = region_reach(m);
	float n = 0.0;
	vec2 sp = vec2(0.0);
	vec2 sq = vec2(0.0);
	vec2 sa = vec2(0.0);
	FOR_EACH_NEIGHBOUR(t) {
		uint j = k;
		if (s_body(j) != body) continue;
		vec2 q = rest_offset[sorted_ids[j]].xy - q_t;
		if (dot(q, q) > reach * reach) continue;
		vec2 p = s_pred[j] - p_t;
		n += 1.0;
		sp += p;
		sq += q;
		sa += vec2(dot(p, q), q.x * p.y - q.y * p.x);
	} END_NEIGHBOURS
	// Sums about the centroids: sum (p - P/n).(q - Q/n) = sum p.q - P.Q/n, and likewise for x.
	vec2 a = sa - vec2(dot(sp, sq), sq.x * sp.y - sq.y * sp.x) / n;
	vec2 rot = region_frame[slot].zw;
	if (dot(rot, rot) < 0.25) {
		rot = vec2(1.0, 0.0);
	}
	if (n >= 2.0 && length(a) > BODY_ROT_EPS * n) {
		rot = normalize(a);
	}
	vec2 c = p_t + sp / n;
	vec2 c0 = q_t + sq / n;
	region_frame[slot] = vec4(c - vec2(rot.x * c0.x - rot.y * c0.y, rot.y * c0.x + rot.x * c0.y), rot);
}
