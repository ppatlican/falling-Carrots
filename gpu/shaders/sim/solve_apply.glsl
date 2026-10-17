#[compute]
#version 450

// Solve 3/3 (per iteration): apply the correction and keep particles in the world.
// Powders, mochi (ADR 0017) and body particles (ADR 0002) pressed into the floor get floor friction
// (sideways move cut by friction). Pressed into a side wall they get Coulomb friction
// along the wall: the vertical move it cancels is at most friction x how far the grain
// was pressed into the wall.
// A fixed cut (like the floor's) held lightly touching grains up in thin columns on
// the walls (Milestone 2 GPU measurement).
// A member of a soft body hands what it gets from other soft bodies (their contacts, the push-out
// and friction) out in equal parts to the members of its region (body_push holds that share,
// solve_delta), and is moved by the shares it gets from the members of its own region instead
// (ADR 0008 item 1), so a contact between two soft bodies moves a patch of the surface together
// and the body's total push is kept. Pushed on its own, a member carrying a contact moved out of
// line with its neighbours by far more than its region pulls it back in an iteration, and one soft
// body draped over another. The region is found as body_region_goal finds it.
// Mirror: ParticleStep._share_pushes_over_regions.

// common.glslinc stamp: Params 128 B, v26. Bump in every .glsl when common.glslinc changes (SPEC 2.7).
#include "common.glslinc"

void main() {
	uint t;
	if (!sorted_particle(t)) {
		return;
	}
	vec2 p = s_pred[t] + scratch[t];
	uint body = s_body(t);
	bool in_body = body != 0u;
	uint m = s_material(t);
	if (in_body && soft_material(m)) {
		vec2 q_t = rest_offset[sorted_ids[t]].xy;
		float reach = region_reach(m);
		float n = 0.0;
		vec2 got = vec2(0.0);
		FOR_EACH_NEIGHBOUR(t) {
			uint j = k;
			if (s_body(j) != body) continue;
			vec2 q = rest_offset[sorted_ids[j]].xy - q_t;
			if (dot(q, q) > reach * reach) continue;
			got += body_push[j].xy;
			n += 1.0;
		} END_NEIGHBOURS
		p += got - n * body_push[t].xy;  // n * its share is its own push
	}
	vec2 c = clamp_to_world(p, sorted_ids[t], in_body);
	if (s_class(t) == CLASS_POWDER || s_class(t) == CLASS_MOCHI || in_body) {
		float mu = materials[s_material(t)].phys.y;
		if (p.y > c.y) {
			c.x = mix(c.x, s_pos[t].x, mu);
		}
		float pen_x = abs(p.x - c.x);
		if (pen_x > 0.0) {
			float slide = c.y - s_pos[t].y;
			c.y -= sign(slide) * min(abs(slide), mu * pen_x);
		}
	}
	s_pred[t] = c;
}
