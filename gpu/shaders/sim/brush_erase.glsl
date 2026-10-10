#[compute]
#version 450

// Brush, erase: every live particle (any material) inside the brush circle is
// removed and its slot pushed back onto the free stack.

// common.glslinc stamp: Params 108 B, v10. Bump in every .glsl when common.glslinc changes (SPEC 2.7).
#include "common.glslinc"

void main() {
	uint i = gl_GlobalInvocationID.x;
	if (i >= params.cap || !is_alive(i)) {
		return;
	}
	if (distance(pos[i], params.brush_pos) > params.brush_radius) {
		return;
	}
	mat_flags[i] = 0u;
	uint top = atomicAdd(counters[0], 1u);
	free_stack[top] = i;
}
