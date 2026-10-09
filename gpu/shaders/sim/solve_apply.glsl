#[compute]
#version 450

// Solve 3/3 (per iteration): apply the correction and keep particles in the world.
// Powders pressed into the floor get floor friction (sideways move cut by friction).

#include "common.glslinc"

void main() {
	uint t;
	if (!sorted_particle(t)) {
		return;
	}
	vec2 p = s_pred[t] + scratch[t];
	vec2 c = clamp_to_world(p, sorted_ids[t]);
	if (s_class(t) == CLASS_POWDER && p.y > c.y) {
		c.x = mix(c.x, s_pos[t].x, materials[s_material(t)].phys.y);
	}
	s_pred[t] = c;
}
