#[compute]
#version 450

// Regions 1/2 (once per solver iteration, after the body pass): soft bodies bend
// (docs/adr/0005-soft-bodies-bend.md items 1 and 3; FastLSM, Rivers & James 2007). One thread per
// sorted particle; anything not in a soft body (a cluster material below stiffness 1) returns.
// A member's region is itself and the members of its body whose rest offsets lie within the
// material's region radius of its own (region_reach, at most H), found in the 3 x 3 hash cells
// around it: the same pairs from both sides, so "r's region holds i" exactly when "i's region
// holds r". The region is fitted as body_match fits a whole body (closed-form 2D rotation
// atan2(A10 - A01, A00 + A11), the last rotation kept when the region has under 2 members or |A_pq|
// is near 0), except that each member j counts with weight 1 / n_j, n_j the size of its own region
// (body_push.z from solve_delta; FastLSM, ADR 0014): centroids and A_pq are weighted sums. Then
// body_region_goal's mean over a member's n_i regions keeps the body's momentum exactly, since
// sum over i of (1 / n_i) sum over its regions r of (goal_r(i) - p_i) = sum over r of the weighted
// sum over its members of (goal_r(i) - p_i) = 0 about each weighted centroid. With equal weights
// edge members (smaller regions) counted for more, and a lopsided jelly at stiffness 0.2 slid
// sideways for good (GPU body_probe creep: 0.15 px/s, 1.8 px/s with no friction; weighted 0.03
// and 0.06). Written per slot as t = c - R c0 and R (region_frame), so
// body_region_goal can turn any member's rest offset q into this region's goal t + R q.
// p and q are summed relative to the member's own, to keep the sums small.
// Mirror: cpu_ref/particle_step.gd _match_regions (the fit) and _find_regions.

// common.glslinc stamp: Params 128 B, v25. Bump in every .glsl when common.glslinc changes (SPEC 2.7).
#include "common.glslinc"

// Keeps the last rotation when |A_pq| is below this, per unit of the members' weights, in px^2.
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
	float ws = 0.0;  // the members' weights
	vec2 sp = vec2(0.0);
	vec2 sq = vec2(0.0);
	vec2 sa = vec2(0.0);
	FOR_EACH_NEIGHBOUR(t) {
		uint j = k;
		if (s_body(j) != body) continue;
		vec2 q = rest_offset[sorted_ids[j]].xy - q_t;
		if (dot(q, q) > reach * reach) continue;
		vec2 p = s_pred[j] - p_t;
		float w = 1.0 / max(body_push[j].z, 1.0);
		n += 1.0;
		ws += w;
		sp += w * p;
		sq += w * q;
		sa += w * vec2(dot(p, q), q.x * p.y - q.y * p.x);
	} END_NEIGHBOURS
	// Weighted sums about the weighted centroids: sum w (p - P/W).(q - Q/W) = sum w p.q - P.Q/W,
	// and likewise for x.
	vec2 a = sa - vec2(dot(sp, sq), sq.x * sp.y - sq.y * sp.x) / ws;
	vec2 rot = region_frame[slot].zw;
	if (dot(rot, rot) < 0.25) {
		rot = vec2(1.0, 0.0);
	}
	if (n >= 2.0 && length(a) > BODY_ROT_EPS * ws) {
		rot = normalize(a);
	}
	vec2 c = p_t + sp / ws;
	vec2 c0 = q_t + sq / ws;
	region_frame[slot] = vec4(c - vec2(rot.x * c0.x - rot.y * c0.y, rot.y * c0.x + rot.x * c0.y), rot);
}
