#[compute]
#version 450

// Contact impulses 2/4 (ADR 0015, impulse.glslinc), once per impulse pass, per particle: how many
// impact pairs each member of a rigid body is in, kept per member (body_contact, so body_impulse
// walks only members that have some) and summed into its body's contact count.
// Mirror: cpu_ref/particle_step.gd _contact_impulses.

// common.glslinc stamp: Params 128 B, v25. Bump in every .glsl when common.glslinc changes (SPEC 2.7).
#include "common.glslinc"
#include "impulse.glslinc"

void main() {
	uint t;
	if (!sorted_particle(t)) {
		return;
	}
	uint t_body = s_body(t);
	body_contact[t] = 0u;
	if (t_body == 0u || body_dyn[t_body].geo.z == 0.0) {  // not in a rigid body
		return;
	}
	uint count = 0u;
	FOR_EACH_NEIGHBOUR(t) {
		uint j = k;
		vec2 n;
		float excess;
		if (impact_pair(t, j, n, excess)) {
			count++;
		}
	} END_NEIGHBOURS
	body_contact[t] = count;
	if (count > 0u) {
		atomicAdd(body_dyn[t_body].cnt, count);
	}
}
