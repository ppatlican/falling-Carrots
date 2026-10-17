#[compute]
#version 450

// Brush, erase: every live particle (any material) inside the brush circle is
// removed and its slot pushed back onto the free stack. A body it takes members from is
// marked BODY_STALE.

// common.glslinc stamp: Params 128 B, v25. Bump in every .glsl when common.glslinc changes (SPEC 2.7).
#include "common.glslinc"

void main() {
	uint i = gl_GlobalInvocationID.x;
	if (i >= params.cap || !is_alive(i)) {
		return;
	}
	if (distance(pos[i], params.brush_pos) > params.brush_radius) {
		return;
	}
	// A body losing members gets a stale outline: the push-out skips it (ADR 0003 item 10).
	uint body = body_of(i);
	if (body != 0u) {
		atomicOr(bodies[body].info.w, BODY_STALE);
	}
	mat_flags[i] = 0u;
	uint top = atomicAdd(counters[0], 1u);
	free_stack[top] = i;
}
