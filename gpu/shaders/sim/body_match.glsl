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
//   3. Every live member moves toward its goal c + R(q - c0) by
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
// common.glslinc stamp: Params 124 B, v16. Bump in every .glsl when common.glslinc changes (SPEC 2.7).
#include "common.glslinc"

// Keeps the last rotation when |A_pq| is below this, per live member, in px^2.
// Mirror: ParticleStep.BODY_ROT_EPS.
const float BODY_ROT_EPS = 1e-4;

shared float sh_n[LOCAL_SIZE_X];
shared vec2 sh_p[LOCAL_SIZE_X];  // sum of p - last centroid
shared vec2 sh_q[LOCAL_SIZE_X];  // sum of rest offsets
shared vec2 sh_a[LOCAL_SIZE_X];  // sum of (p.q, q x p), p relative to the last centroid

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
	for (uint m = first + lid; m < end; m += LOCAL_SIZE_X) {
		uint slot = body_members[m];
		if (!live_member(slot, id)) continue;
		vec2 p = s_pred[sorted_of(slot)] - c_last;
		vec2 q = rest_offset[slot];
		n += 1.0;
		sp += p;
		sq += q;
		sa += vec2(dot(p, q), q.x * p.y - q.y * p.x);
	}
	sh_n[lid] = n;
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
	// Sums about the centroids: sum (p - P/n).(q - Q/n) = sum p.q - P.Q/n, and likewise for x.
	vec2 a = sh_a[0] - vec2(dot(p_sum, q_sum), q_sum.x * p_sum.y - q_sum.y * p_sum.x) / live;
	vec2 rot = frame.zw;
	if (live >= 2.0 && length(a) > BODY_ROT_EPS * live) {
		rot = normalize(a);
	}
	if (lid == 0u) {
		bodies[id].info.z = uint(live);
		bodies[id].frame = vec4(c, rot);
		bodies[id].rest = vec4(c0, 0.0, 0.0);
	}

	for (uint m = first + lid; m < end; m += LOCAL_SIZE_X) {
		uint slot = body_members[m];
		if (!live_member(slot, id)) continue;
		float stiffness = materials[mat_flags[slot] & MAT_MASK].extra.y;
		float k = 1.0 - pow(1.0 - stiffness, params.dt * 60.0 / float(params.iterations));
		vec2 q = rest_offset[slot] - c0;
		vec2 goal = c + vec2(rot.x * q.x - rot.y * q.y, rot.y * q.x + rot.x * q.y);
		uint t = sorted_of(slot);
		s_pred[t] += k * (goal - s_pred[t]);
	}
}
