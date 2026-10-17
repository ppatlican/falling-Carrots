#[compute]
#version 450

// Plasticity 1/3 (docs/adr/0012-plasticity.md items 2-3; Mueller et al. 2005, section 4.5, on the
// rest offsets): each member of a soft body whose material has plasticity measures its offset
// from its body's best fit in the rest frame, e = R^T (p - c) - (q - c0), with (c, R) and c0 the
// body record's frame and rest centroid as body_match left them. Past PLASTIC_YIELD spacings its
// rest offset is to move toward where it is by the plasticity's share of the excess per 1/60 s,
// k = 1 - (1 - plasticity)^(dt 60), at most plastic_step(), cut short where it would take a rest
// neighbour out of the lattice's band (plastic_room). The move goes into body_push (sorted
// index), which body_outline and body_rest read; nothing moves here.
// Mirror: cpu_ref/particle_step.gd _plastic_flow, _plastic_room.

// common.glslinc stamp: Params 128 B, v25. Bump in every .glsl when common.glslinc changes (SPEC 2.7).
#include "common.glslinc"
#include "plastic.glslinc"

// Largest share (0 to 1) of a move d of member t's rest offset q that keeps every rest neighbour
// (rest offsets less than PLASTIC_LINK spacings apart, in its hash window) in the band
// [PLASTIC_GAP, PLASTIC_LINK], whatever the neighbour's own move this substep (at most a step),
// checked against its rest offset before the moves: more than a step inside the band, the move
// stops a step short of either end; within a step of the near end it may not approach the
// neighbour at all (u.d >= 0), and within a step of the far end it must approach by at least |d|^2
// (u.d <= -|d|^2), so the pair's distance can't shrink, or grow, whatever both do. Checked only
// against the neighbour's old rest offset, two neighbours sliding the same way closed on each
// other a little every substep (a dough's floor row crept to 0.62 spacing).
float plastic_room(uint t, vec2 q, vec2 d, float max_move) {
	float a = dot(d, d);
	if (a < 1e-12) {
		return 0.0;
	}
	uint body = s_body(t);
	float sp = params.spacing;
	float near_end = PLASTIC_GAP * sp + max_move;
	float far_end = PLASTIC_LINK * sp - max_move;
	float share = 1.0;
	FOR_EACH_NEIGHBOUR(t) {
		uint j = k;
		if (j == t || s_body(j) != body) continue;
		vec2 u = q - rest_offset[sorted_ids[j]].xy;
		float dist = length(u);
		if (dist >= PLASTIC_LINK * sp) continue;
		float b = dot(u, d);
		if (dist <= near_end) {
			if (b < 0.0) {
				return 0.0;
			}
		} else {
			// |u + s d|^2 = a s^2 + 2 b s + |u|^2: the share where it first comes to near.
			float disc = b * b - a * (dist * dist - near_end * near_end);
			if (disc > 0.0) {
				float s = (-b - sqrt(disc)) / a;
				if (s >= 0.0) {
					share = min(share, s);
				}
			}
		}
		if (dist >= far_end) {
			if (b >= 0.0) {
				return 0.0;
			}
			share = min(share, -b / a);
		} else {
			share = min(share, (-b + sqrt(max(b * b - a * (dist * dist - far_end * far_end), 0.0))) / a);
		}
	} END_NEIGHBOURS
	return max(share, 0.0);
}

void main() {
	uint t;
	if (!sorted_particle(t) || !plastic_member(t)) {
		return;
	}
	uint body = s_body(t);
	uint m = s_material(t);
	vec4 f = bodies[body].frame;
	vec2 q = rest_offset[sorted_ids[t]].xy;
	vec2 p = s_pred[t] - f.xy;
	vec2 e = vec2(f.z * p.x + f.w * p.y, -f.w * p.x + f.z * p.y) - (q - bodies[body].rest_c);
	float len = length(e);
	float yield_px = PLASTIC_YIELD * params.spacing;
	vec2 d = vec2(0.0);
	if (len > yield_px) {
		float k = 1.0 - pow(1.0 - materials[m].more.w, params.dt * 60.0);
		d = e * (k * (len - yield_px) / len);
		float max_move = plastic_step();
		float dl = length(d);
		if (dl > max_move) {
			d *= max_move / dl;
		}
		d *= plastic_room(t, q, d, max_move);
	}
	body_push[t] = vec4(d, 0.0, 0.0);
}
