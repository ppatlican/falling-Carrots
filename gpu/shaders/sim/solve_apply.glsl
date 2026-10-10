#[compute]
#version 450

// Solve 3/3 (per iteration): apply the correction and keep particles in the world.
// Powders pressed into the floor get floor friction (sideways move cut by friction).
// Powders pressed into a side wall get Coulomb friction along the wall: the vertical
// move it cancels is at most friction x how far the grain was pressed into the wall.
// A fixed cut (like the floor's) held lightly touching grains up in thin columns on
// the walls (Milestone 2 GPU measurement).

// common.glslinc stamp: Params 108 B, v8. Bump in every .glsl when common.glslinc changes (SPEC 2.7).
#include "common.glslinc"

void main() {
	uint t;
	if (!sorted_particle(t)) {
		return;
	}
	vec2 p = s_pred[t] + scratch[t];
	vec2 c = clamp_to_world(p, sorted_ids[t]);
	if (s_class(t) == CLASS_POWDER) {
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
