#[compute]
#version 450

// Bodies, once per substep after the hash and before solve_pressure: each body member's swept
// contact with other bodies (ADR 0003 item 14; SunaEngine's swept contacts, docs/papers.md).
// A member that started this substep outside another body's outline and is predicted to end
// inside it has gone in this substep. The other body's member nearest it at the start (s_pos)
// gives the face it came through: that member's way out of the rest shape, turned by its
// body's rotation, is the face's normal N and its distance |e| (push_out). The member's depth
// past that face at the predicted positions, less any it started with, over how far the two
// came together along N this substep, is the share of the substep after they first touched
// (time of impact). It goes into vel.x, and body_project rewinds every member of the body by the
// largest share among its members (the earliest touch) along its own path. Both bodies rewind
// the same share, so together they undo the overlap: a body that went into a resting one takes
// all of it, two that met at equal speeds half each.
// Along the face's normal instead, a carrot landing near a plank's corner, where the outline's
// normal is diagonal, was moved back sideways and slid off at 74 px/s (main.tscn); and shared by
// contact mass (stack_weight), the carrot took 65% of the overlap, the plank's share went into
// the floor and the carrot went in between the plank's rows (CPU reference, body_probe plank).
// Why the start: at 1.6 spacings a substep (main.tscn's Drop buttons, ~390 px/s) the bottom row
// of a falling carrot ends 2.5 spacings into the one below, and through a 2-row plank, where
// the nearest member at the end is the plank's bottom row, whose outline faces down: the
// push-out held the carrot's bottom row between the plank's rows for good (body_probe plank).
// Why the whole body: the contacts and push-out move the members that went in, and shape
// matching hands each of them a tenth of that (a 16 x 10 carrot hits with one row), so a 5 px
// dip took ~12 frames to leave, tilting the carrot 0.2 rad (body_probe boxhigh).
// Only members of bodies take part; vel is zero from hash_scatter for everything else.
// Mirror: cpu_ref/particle_step.gd _sweep_delta.

// common.glslinc stamp: Params 124 B, v18. Bump in every .glsl when common.glslinc changes (SPEC 2.7).
#include "common.glslinc"
#include "powder.glslinc"

// In spacings: the deepest a member may already be inside the other body's outline at the start
// and still count as coming from outside (members resting in contact sit at -0.5 on a flat face
// and at 0 over a corner, whose outline runs diagonally), and the least it must go further in
// this substep (60 px/s at 2 substeps). Slower approaches are left to the contacts and the
// push-out, which held stacks before: with no least depth, the members over a corner of the box
// below, on its outline, went in by ~0.01 px now and then, and each move back pushed sideways,
// so a 5-box stack leaned 1 px a box and never came to rest (test_bodies). Mirror:
// SimParams.SWEEP_DEPTH.
const float SWEEP_DEPTH = 0.25;

void main() {
	uint t;
	if (!sorted_particle(t)) {
		return;
	}
	uint t_body = s_body(t);
	if (t_body == 0u) {
		return;
	}
	vec2 x0 = s_pos[t];
	vec2 x1 = s_pred[t];
	uint near0 = 0xFFFFFFFFu;  // other-body member nearest at the start
	float near0_d2 = 1e30;
	uint near1 = 0xFFFFFFFFu;  // other-body member nearest at the end, within a spacing
	float near1_d = params.spacing;
	FOR_EACH_NEIGHBOUR(t) {
		uint j = k;
		uint j_body = s_body(j);
		if (j_body == 0u || j_body == t_body) continue;
		float d_end = length(x1 - s_pred[j]);
		if (d_end >= params.h) continue;  // the CPU reference's neighbour lists
		vec2 a = x0 - s_pos[j];
		if (dot(a, a) < near0_d2) {
			near0 = j;
			near0_d2 = dot(a, a);
		}
		if (d_end < near1_d) {
			near1 = j;
			near1_d = d_end;
		}
	} END_NEIGHBOURS
	if (near1 == 0xFFFFFFFFu) {  // then near0 is set too
		return;
	}
	// Ends inside the other body's outline: a member passing beside a corner doesn't count.
	vec2 out_end = push_out(x1, near1, s_body(near1));
	if (dot(out_end, out_end) == 0.0) {
		return;
	}
	uint j_body = s_body(near0);
	if ((bodies[j_body].info.w & BODY_STALE) != 0u) {
		return;
	}
	vec2 e_rest = rest_offset[sorted_ids[near0]].zw;
	vec2 r = member_rot(near0, j_body);  // a soft body's face bends with it (ADR 0005)
	vec2 e = vec2(r.x * e_rest.x - r.y * e_rest.y, r.y * e_rest.x + r.x * e_rest.y);
	float len = length(e);
	if (len < 1e-6) {
		return;
	}
	vec2 normal = e / len;
	float d0 = len - dot(normal, x0 - s_pos[near0]);
	float d1 = len - dot(normal, x1 - s_pred[near0]);
	float gone_in = d1 - max(d0, 0.0);
	if (d0 > SWEEP_DEPTH * params.spacing || gone_in < SWEEP_DEPTH * params.spacing) {
		return;
	}
	// How far they came together along N: d1 - d0, at least gone_in (>= SWEEP_DEPTH spacings).
	vel[sorted_ids[t]] = vec2(min(gone_in / (d1 - d0), 1.0), 0.0);
}
