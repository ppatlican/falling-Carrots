#[compute]
#version 450

// Bodies, after an erase (ADR 0004): applies the split ParticleSim planned from a readback of
// the members of the bodies the eraser cut (ParticleSim.plan_split). Runs first in the brush
// pass, never in a frame that spawns a body, since both read body_spawn. One thread per member
// that was live at the readback.
// Input in body_spawn: [0].x the number of entries, [0].y 1 when the eraser ran again since the
// readback (the outlines then stay stale until the next check). Entry e is [1 + 2e] (slot, old
// id, new id, member index) and [2 + 2e] (the way out of its piece's rest shape xy, piece size,
// flags), the integers as float bits.
// A member moves to its piece's id and gets its piece's outline only while its slot still
// carries the old id: a slot erased since the readback, maybe reused, is left alone. Its member
// list entry is written anyway, and the body pass skips it there.
// SPLIT_FIRST marks a piece's first entry, whose thread writes the piece's record. A new piece
// takes the old body's frame, rest centroid, reference pressure and wet flag, so it moves on as
// it was. The kept piece, at the front of the old member range, gets its new member count and,
// unless the eraser ran again, loses BODY_STALE.
// Mirror: cpu_ref/particle_step.gd split_body.

// common.glslinc stamp: Params 128 B, v24. Bump in every .glsl when common.glslinc changes (SPEC 2.7).
#include "common.glslinc"

// Entry flags. Mirror: ParticleSim.SPLIT_FIRST.
const uint SPLIT_FIRST = 1u;

void main() {
	uint e = gl_GlobalInvocationID.x;
	if (e >= floatBitsToUint(body_spawn[0].x)) {
		return;
	}
	uvec4 a = floatBitsToUint(body_spawn[1u + 2u * e]);
	vec4 b = body_spawn[2u + 2u * e];
	uint slot = a.x;
	uint old_id = a.y;
	uint new_id = a.z;
	body_members[a.w] = slot;
	if (is_alive(slot) && body_of(slot) == old_id) {
		rest_offset[slot].zw = b.xy;
		mat_flags[slot] = (mat_flags[slot] & ~(0xFFFFu << BODY_SHIFT)) | (new_id << BODY_SHIFT);
	}
	if ((floatBitsToUint(b.w) & SPLIT_FIRST) == 0u) {
		return;
	}
	uint count = floatBitsToUint(b.z);
	bool keep_stale = floatBitsToUint(body_spawn[0].y) != 0u;
	if (new_id == old_id) {
		bodies[old_id].info.y = count;
		if (!keep_stale) {
			atomicAnd(bodies[old_id].info.w, ~BODY_STALE);
		}
	} else {
		// Only the wet flag is taken from the old record's flags, which the kept piece's thread
		// may be clearing BODY_STALE from at the same time.
		uint wet = bodies[old_id].info.w & BODY_WET;
		bodies[new_id].info = uvec4(a.w, count, count, wet | (keep_stale ? BODY_STALE : 0u));
		bodies[new_id].frame = bodies[old_id].frame;
		bodies[new_id].rest_c = bodies[old_id].rest_c;
		bodies[new_id].p_ref = bodies[old_id].p_ref;
		bodies[new_id].p_min = BODY_P_UNSET;
	}
}
