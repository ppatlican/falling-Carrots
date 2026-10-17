#[compute]
#version 450

// Contact impulses 4/4 (ADR 0015, impulse.glslinc), once per impulse pass, per particle: a member
// of a body that took an impulse gets v += dV + dw x r (r from the start centroid) and is predicted
// again from it as predict does (move capped at max_step, clamped to the world). Shape matching
// keeps the body rigid. Every member of a rigid body also clears its body's contact count for the
// next pass's body_impulse_count (they all write 0).
// Mirror: cpu_ref/particle_step.gd _contact_impulses.

// common.glslinc stamp: Params 128 B, v26. Bump in every .glsl when common.glslinc changes (SPEC 2.7).
#include "common.glslinc"
#include "impulse.glslinc"

void main() {
	uint t;
	if (!sorted_particle(t)) {
		return;
	}
	uint b = s_body(t);
	if (b == 0u) {
		return;
	}
	vec4 geo = body_dyn[b].geo;
	if (geo.z == 0.0) {
		return;
	}
	body_dyn[b].cnt = 0u;
	vec3 imp = body_dyn[b].imp.xyz;
	if (imp == vec3(0.0)) {
		return;
	}
	vec2 r = s_pos[t] - geo.xy;
	vec2 v = s_vel[t] + imp.xy + imp.z * vec2(-r.y, r.x);
	s_vel[t] = v;
	vec2 move = v * params.dt;
	float len = length(move);
	if (len > params.max_step) {
		move *= params.max_step / len;
	}
	s_pred[t] = clamp_to_world(s_pos[t] + move, sorted_ids[t], true);
}
