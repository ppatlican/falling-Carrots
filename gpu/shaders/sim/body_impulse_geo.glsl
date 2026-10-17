#[compute]
#version 450

// Contact impulses 1/4 (ADR 0015, impulse.glslinc), once per substep: each rigid body's centroid
// at the start of the substep (s_pos), 1/mass and 1/moment, whether it rests (every member slower
// than an impact; fixed_in_pair), and its contact count cleared. One
// workgroup per body id, as body_project. Mass is members x density; the moment is density x
// sum (|r|^2 + spacing^2 / 6) about the centroid, the second term each member's own square.
// A soft body gets 0, 0 and takes no part. Mirror: cpu_ref/particle_step.gd _contact_impulses.

#define LOCAL_SIZE_X 128
// common.glslinc stamp: Params 128 B, v25. Bump in every .glsl when common.glslinc changes (SPEC 2.7).
#include "common.glslinc"
#include "impulse.glslinc"

shared float sh_n[LOCAL_SIZE_X];
shared vec2 sh_p[LOCAL_SIZE_X];   // sum of p - last centroid
shared float sh_q[LOCAL_SIZE_X];  // sum of |p - last centroid|^2
shared uint sh_m[LOCAL_SIZE_X];   // a live member's material (they share one)
shared float sh_v[LOCAL_SIZE_X];  // the fastest member's speed

uint sorted_of(uint slot) {
	return cell_start[particle_cell[slot]] + particle_rank[slot];
}

void main() {
	uint id = gl_WorkGroupID.x + 1u;
	uint lid = gl_LocalInvocationID.x;
	if (id > params.body_max_id || bodies[id].info.y == 0u) {
		return;
	}
	uint first = bodies[id].info.x;
	uint end = first + bodies[id].info.y;
	vec2 c_last = bodies[id].frame.xy;
	float n = 0.0;
	vec2 sp = vec2(0.0);
	float sq = 0.0;
	uint m_id = 0xFFFFFFFFu;  // the body's material
	float v_max = 0.0;
	for (uint m = first + lid; m < end; m += LOCAL_SIZE_X) {
		uint slot = body_members[m];
		if (!is_alive(slot) || body_of(slot) != id) continue;
		uint t = sorted_of(slot);
		vec2 p = s_pos[t] - c_last;
		v_max = max(v_max, length(s_vel[t]));
		n += 1.0;
		sp += p;
		sq += dot(p, p);
		m_id = min(m_id, mat_flags[slot] & MAT_MASK);
	}
	sh_n[lid] = n;
	sh_p[lid] = sp;
	sh_q[lid] = sq;
	sh_m[lid] = m_id;
	sh_v[lid] = v_max;
	memoryBarrierShared();
	barrier();
	for (uint s = LOCAL_SIZE_X / 2u; s > 0u; s >>= 1u) {
		if (lid < s) {
			sh_n[lid] += sh_n[lid + s];
			sh_p[lid] += sh_p[lid + s];
			sh_q[lid] += sh_q[lid + s];
			sh_m[lid] = min(sh_m[lid], sh_m[lid + s]);
			sh_v[lid] = max(sh_v[lid], sh_v[lid + s]);
		}
		memoryBarrierShared();
		barrier();
	}
	if (lid != 0u) {
		return;
	}
	float live = sh_n[0];
	body_dyn[id].cnt = 0u;
	body_dyn[id].rest = sh_v[0] < impulse_speed() ? 1u : 0u;
	body_dyn[id].imp = vec4(0.0);
	body_dyn[id].geo = vec4(c_last, 0.0, 0.0);
	if (live == 0.0) {
		return;
	}
	float rho = materials[sh_m[0]].phys.x;
	if (!rigid_material(sh_m[0]) || rho <= 0.0) {
		return;
	}
	vec2 p_mean = sh_p[0] / live;
	// Sum about the centroid: sum |p - P/n|^2 = sum |p|^2 - n |P/n|^2.
	float moment = rho * (max(sh_q[0] - live * dot(p_mean, p_mean), 0.0) + live * params.spacing * params.spacing / 6.0);
	body_dyn[id].geo = vec4(c_last + p_mean, 1.0 / (rho * live), 1.0 / moment);
}
