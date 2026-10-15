#[compute]
#version 450

// Bodies (once per solver iteration, after solve_apply): shape matching of cluster solids
// (Mueller et al. 2005, rotation only; docs/adr/0002-cluster-solid-layout.md items 7, 8, 15).
// One workgroup per body id, 1..body_max_id; a record with no members returns at once.
//   1. Each thread sums over its share of the body's member range: live count, p (relative
//      to the last centroid, to keep the sums small), rest offset q, and the two terms of
//      A_pq the 2D rotation comes from (p.q and q x p). A member counts only while its slot
//      is alive and carries this body's id.
//   2. The sums are reduced in shared memory. From them: centroid c, rest centroid c0 of
//      the live members, and the rotation atan2(A10 - A01, A00 + A11) as (cos, sin), kept
//      from the last pass when live < 2 or |A_pq| is near 0.
//   Thread 0 also moves the reference pressure and wet flag solve_pressure found this substep
//   into place for the next (ADR 0003 item 4).
//   Every live member's push from other bodies so far (vel, solve_delta) becomes the body's mean.
//   3. Every live member of a rigid body moves toward its goal c + R(q - c0) by
//      k = 1 - (1 - stiffness)^(dt * 60 / iterations), so stiffness is the share of the shape
//      error removed per 1/60 s whatever the substep and iteration counts.
// A body's members are read and written only by its own workgroup, so no atomics are needed.
// 128 threads (the Vulkan minimum, as hydro_solve), not 64: one workgroup walks a whole body,
// so its time grows with the body's size, and the loads per member depend on each other.
// Bodies pass per frame (2 substeps x 4 iterations, RTX 3080 Ti, uncapped), 64 / 128 / 256
// threads: 256 boxes of 48 particles 37 / 44 / 43 us; one 5000-particle body 773 / 436 / 286;
// one of 10000, 1582 / 797 / 467 (tools/body_probe.gd many, big, huge).
// Mirror: cpu_ref/particle_step.gd _match_shapes.

#define LOCAL_SIZE_X 128
// common.glslinc stamp: Params 128 B, v21. Bump in every .glsl when common.glslinc changes (SPEC 2.7).
#include "common.glslinc"

// Keeps the last rotation when |A_pq| is below this, per live member, in px^2.
// Mirror: ParticleStep.BODY_ROT_EPS.
const float BODY_ROT_EPS = 1e-4;

// How far (px) the density projection grid's free surface (p = 0) sits above the surface of the
// top water particles. A body's reference pressure is at least gravity x this, so a floating body
// (p_min 0) floats level with the water it shows rather than ~2 px high (ADR 0003 item 4). A max,
// not a switch at p_min 0: switched, a 16 x 10 cork whose top went awash lost the drop (p_ref
// 1000 -> ~0), popped up, got it back and sank again, heaving +-4 px for 15 s (body_probe
// waterbox). Mirror: SimParams.BODY_SURFACE_DROP.
const float BODY_SURFACE_DROP = 2.5;

shared float sh_n[LOCAL_SIZE_X];
shared vec2 sh_p[LOCAL_SIZE_X];  // sum of p - last centroid
shared vec2 sh_q[LOCAL_SIZE_X];  // sum of rest offsets
shared vec2 sh_a[LOCAL_SIZE_X];  // sum of (p.q, q x p), p relative to the last centroid
shared vec2 sh_o[LOCAL_SIZE_X];  // sum of the members' pushes from other bodies so far (vel)

// Sorted index of a live slot this frame (as hash_scatter places it).
uint sorted_of(uint slot) {
	return cell_start[particle_cell[slot]] + particle_rank[slot];
}

bool live_member(uint slot, uint id) {
	return is_alive(slot) && body_of(slot) == id;
}

void main() {
	uint id = gl_WorkGroupID.x + 1u;
	uint lid = gl_LocalInvocationID.x;
	// Both checks are the same for the whole workgroup, so returning before the barriers is safe.
	if (id > params.body_max_id || bodies[id].info.y == 0u) {
		return;
	}
	uint first = bodies[id].info.x;
	uint end = first + bodies[id].info.y;
	vec4 frame = bodies[id].frame;
	vec2 c_last = frame.xy;

	float n = 0.0;
	vec2 sp = vec2(0.0);
	vec2 sq = vec2(0.0);
	vec2 sa = vec2(0.0);
	vec2 so = vec2(0.0);
	for (uint m = first + lid; m < end; m += LOCAL_SIZE_X) {
		uint slot = body_members[m];
		if (!live_member(slot, id)) continue;
		vec2 p = s_pred[sorted_of(slot)] - c_last;
		vec2 q = rest_offset[slot].xy;
		n += 1.0;
		sp += p;
		sq += q;
		sa += vec2(dot(p, q), q.x * p.y - q.y * p.x);
		so += vel[slot];
	}
	sh_n[lid] = n;
	sh_o[lid] = so;
	sh_p[lid] = sp;
	sh_q[lid] = sq;
	sh_a[lid] = sa;
	memoryBarrierShared();
	barrier();
	for (uint s = LOCAL_SIZE_X / 2u; s > 0u; s >>= 1u) {
		if (lid < s) {
			sh_n[lid] += sh_n[lid + s];
			sh_p[lid] += sh_p[lid + s];
			sh_q[lid] += sh_q[lid + s];
			sh_a[lid] += sh_a[lid + s];
			sh_o[lid] += sh_o[lid + s];
		}
		memoryBarrierShared();
		barrier();
	}

	float live = sh_n[0];
	if (live == 0.0) {
		if (lid == 0u) {
			bodies[id].info.z = 0u;
		}
		return;
	}
	vec2 p_sum = sh_p[0];
	vec2 q_sum = sh_q[0];
	vec2 c = c_last + p_sum / live;
	vec2 c0 = q_sum / live;
	vec2 o_mean = sh_o[0] / live;
	// Sums about the centroids: sum (p - P/n).(q - Q/n) = sum p.q - P.Q/n, and likewise for x.
	vec2 a = sh_a[0] - vec2(dot(p_sum, q_sum), q_sum.x * p_sum.y - q_sum.y * p_sum.x) / live;
	vec2 rot = frame.zw;
	if (live >= 2.0 && length(a) > BODY_ROT_EPS * live) {
		rot = normalize(a);
	}
	if (lid == 0u) {
		bodies[id].info.z = uint(live);
		bodies[id].frame = vec4(c, rot);
		bodies[id].rest_c = c0;
		// The reference pressure and the wet flag solve_pressure found this substep carry to
		// the next (ADR 0003 item 4). Only the first pass of a substep finds p_min set.
		uint p_min = bodies[id].p_min;
		if (p_min != BODY_P_UNSET) {
			bodies[id].p_ref = max(uintBitsToFloat(p_min), params.gravity * BODY_SURFACE_DROP);
			bodies[id].p_min = BODY_P_UNSET;
			uint flags = bodies[id].info.w;
			bodies[id].info.w = (flags & BODY_STALE) | ((flags & BODY_WET_NOW) != 0u ? BODY_WET : 0u);
		}
	}

	for (uint m = first + lid; m < end; m += LOCAL_SIZE_X) {
		uint slot = body_members[m];
		if (!live_member(slot, id)) continue;
		float stiffness = materials[mat_flags[slot] & MAT_MASK].extra.y;
		// A soft body gets its record and pushes here but no goals: its regions move its members
		// (body_region_fit, body_region_goal; ADR 0005 item 7).
		if (stiffness >= 1.0) {
			float k = 1.0 - pow(1.0 - stiffness, params.dt * 60.0 / float(params.iterations));
			vec2 q = rest_offset[slot].xy - c0;
			vec2 goal = c + vec2(rot.x * q.x - rot.y * q.y, rot.y * q.x + rot.x * q.y);
			uint t = sorted_of(slot);
			s_pred[t] += k * (goal - s_pred[t]);
		}
		// Shape matching spreads a push on a few members over the whole body, so each
		// member keeps the body's mean (the mean of the last mean plus new pushes adds up
		// the iterations; velocity_update takes it out).
		vel[slot] = o_mean;
	}
}
