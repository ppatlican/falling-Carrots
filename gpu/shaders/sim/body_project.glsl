#[compute]
#version 450

// Bodies, once per substep between solve_pressure and its solve_apply: a soft body's pressure
// pushes (in scratch) replaced by their rigid part (ADR 0003 item 12). One workgroup per body
// id, as body_match.
//   1. Each thread sums over its share of the body's live members: count, p (relative to the
//      last centroid, to keep the sums small), |p|^2, the push d and p x d.
//   2. The sums are reduced in shared memory. From them, about the members' centroid c: the
//      mean push and the turn theta = sum r x d / sum |r|^2 (r = p - c), linearised.
//   3. Every live member of a soft body (stiffness < 1) gets the mean push plus theta x r,
//      clamped like solve_pressure. A rigid body's pushes are left alone: matching at
//      stiffness 1 takes out the rest.
// The water moves and turns a jelly without squeezing it: relative to p_ref (its top) the
// pushes on its bottom and lower sides reach ~9 g, and a 16 x 10 jelly crumpled 4.4 px out of
// shape with water inside (body_probe waterjelly). Members share a material, so their masses
// are equal. Mirror: cpu_ref/particle_step.gd _project_body_pushes.

#define LOCAL_SIZE_X 128
// common.glslinc stamp: Params 124 B, v17. Bump in every .glsl when common.glslinc changes (SPEC 2.7).
#include "common.glslinc"

// No turn when sum |r|^2 is below this, per live member, in px^2. Mirror: ParticleStep.BODY_ROT_EPS.
const float BODY_ROT_EPS = 1e-4;

shared float sh_n[LOCAL_SIZE_X];
shared vec2 sh_p[LOCAL_SIZE_X];   // sum of p - last centroid
shared vec2 sh_d[LOCAL_SIZE_X];   // sum of pushes
shared vec2 sh_m[LOCAL_SIZE_X];   // sum of (|p|^2, p x d)

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
	vec2 c_last = bodies[id].frame.xy;

	float n = 0.0;
	vec2 sp = vec2(0.0);
	vec2 sd = vec2(0.0);
	vec2 sm = vec2(0.0);
	for (uint m = first + lid; m < end; m += LOCAL_SIZE_X) {
		uint slot = body_members[m];
		if (!live_member(slot, id)) continue;
		uint t = sorted_of(slot);
		vec2 p = s_pred[t] - c_last;
		vec2 d = scratch[t];
		n += 1.0;
		sp += p;
		sd += d;
		sm += vec2(dot(p, p), p.x * d.y - p.y * d.x);
	}
	sh_n[lid] = n;
	sh_p[lid] = sp;
	sh_d[lid] = sd;
	sh_m[lid] = sm;
	memoryBarrierShared();
	barrier();
	for (uint s = LOCAL_SIZE_X / 2u; s > 0u; s >>= 1u) {
		if (lid < s) {
			sh_n[lid] += sh_n[lid + s];
			sh_p[lid] += sh_p[lid + s];
			sh_d[lid] += sh_d[lid + s];
			sh_m[lid] += sh_m[lid + s];
		}
		memoryBarrierShared();
		barrier();
	}

	float live = sh_n[0];
	if (live == 0.0) {
		return;
	}
	vec2 p_mean = sh_p[0] / live;
	vec2 push = sh_d[0] / live;
	// Sums about the centroid: sum |p - P/n|^2 = sum |p|^2 - n |P/n|^2, sum (p - P/n) x d = sum p x d - P/n x D.
	float inertia = sh_m[0].x - live * dot(p_mean, p_mean);
	float torque = sh_m[0].y - (p_mean.x * sh_d[0].y - p_mean.y * sh_d[0].x);
	float turn = inertia > BODY_ROT_EPS * live ? torque / inertia : 0.0;
	float max_len = 0.5 * params.spacing;

	for (uint m = first + lid; m < end; m += LOCAL_SIZE_X) {
		uint slot = body_members[m];
		if (!live_member(slot, id) || materials[mat_flags[slot] & MAT_MASK].extra.y >= 1.0) continue;
		uint t = sorted_of(slot);
		vec2 r = s_pred[t] - c_last - p_mean;
		vec2 d = push + turn * vec2(-r.y, r.x);
		float len = length(d);
		if (len > max_len) {
			d *= max_len / len;
		}
		scratch[t] = d;
	}
}
