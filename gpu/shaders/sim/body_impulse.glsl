#[compute]
#version 450

// Contact impulses 3/4 (ADR 0015, impulse.glslinc), once per impulse pass: one workgroup per body
// id. Each thread walks its share of the body's members that are in impact pairs (body_contact) and
// sums, over their pairs, the impulse P = J n + J_t t and its moment r x P (r from the start
// centroid). J = excess / (D_a + D_b), D = (c^2 / I + 1 / M) cnt, c = r x n, with the other body's
// centroid, 1/M, 1/I and cnt from body_dyn; J_t stops the slide along t at the contact, at most
// friction x J. The body's dV = sum P / M and dw = sum r x P / I go into body_dyn.imp for
// body_impulse_apply. Velocities are read only (s_vel), so every pair is seen the same from both ends.
// Mirror: cpu_ref/particle_step.gd _contact_impulses.

#define LOCAL_SIZE_X 128
// common.glslinc stamp: Params 128 B, v24. Bump in every .glsl when common.glslinc changes (SPEC 2.7).
#include "common.glslinc"
#include "impulse.glslinc"

shared vec2 sh_p[LOCAL_SIZE_X];   // sum of impulses
shared float sh_l[LOCAL_SIZE_X];  // sum of their moments

uint sorted_of(uint slot) {
	return cell_start[particle_cell[slot]] + particle_rank[slot];
}

// Inverse effective mass of body b at r along dir, times its contact count.
float inv_mass(vec4 geo, uint cnt, vec2 r, vec2 dir) {
	float c = cross2(r, dir);
	return (c * c * geo.w + geo.z) * float(cnt);
}

void main() {
	uint id = gl_WorkGroupID.x + 1u;
	uint lid = gl_LocalInvocationID.x;
	if (id > params.body_max_id || bodies[id].info.y == 0u) {
		return;
	}
	uint cnt = body_dyn[id].cnt;
	if (cnt == 0u) {
		if (lid == 0u) {
			body_dyn[id].imp = vec4(0.0);
		}
		return;
	}
	vec4 geo = body_dyn[id].geo;
	uint rest = body_dyn[id].rest;
	uint first = bodies[id].info.x;
	uint end = first + bodies[id].info.y;
	vec2 sp = vec2(0.0);
	float sl = 0.0;
	for (uint m = first + lid; m < end; m += LOCAL_SIZE_X) {
		uint slot = body_members[m];
		if (!is_alive(slot) || body_of(slot) != id) continue;
		uint t = sorted_of(slot);
		if (body_contact[t] == 0u) continue;
		vec2 r = s_pos[t] - geo.xy;
		float mu_t = materials[s_material(t)].phys.y;
		FOR_EACH_NEIGHBOUR(t) {
			uint j = k;
			vec2 n;
			float excess;
			if (!impact_pair(t, j, n, excess)) continue;
			uint jb = s_body(j);
			vec4 geo_j = body_dyn[jb].geo;
			uint cnt_j = max(body_dyn[jb].cnt, 1u);
			vec2 r_j = s_pos[j] - geo_j.xy;
			// Either body fixed in this pair (fixed_in_pair: this one is pushed along n, the other along -n).
			bool held = fixed_in_pair(rest, n);
			bool held_j = fixed_in_pair(body_dyn[jb].rest, -n);
			if (held && held_j) continue;
			float w = held ? 0.0 : 1.0;
			float w_j = held_j ? 0.0 : 1.0;
			float jn = excess / (w * inv_mass(geo, cnt, r, n) + w_j * inv_mass(geo_j, cnt_j, r_j, n));
			vec2 tg = vec2(-n.y, n.x);
			float vt = dot(s_vel[t] - s_vel[j], tg);
			float mu = min(mu_t, materials[s_material(j)].phys.y);
			float jt = -vt / (w * inv_mass(geo, cnt, r, tg) + w_j * inv_mass(geo_j, cnt_j, r_j, tg));
			jt = clamp(jt, -mu * jn, mu * jn);
			if (held) continue;  // what it rests on takes it
			vec2 p = jn * n + jt * tg;
			sp += p;
			sl += cross2(r, p);
		} END_NEIGHBOURS
	}
	sh_p[lid] = sp;
	sh_l[lid] = sl;
	memoryBarrierShared();
	barrier();
	for (uint s = LOCAL_SIZE_X / 2u; s > 0u; s >>= 1u) {
		if (lid < s) {
			sh_p[lid] += sh_p[lid + s];
			sh_l[lid] += sh_l[lid + s];
		}
		memoryBarrierShared();
		barrier();
	}
	if (lid == 0u) {
		body_dyn[id].imp = vec4(sh_p[0] * geo.z, sh_l[0] * geo.w, 0.0);
	}
}
