#[compute]
#version 450

// Brush, after add or erase (one thread): commit the spawn to the free count and
// refresh the live count that later passes and the capacity meter read.

// common.glslinc stamp: Params 108 B, v2. Bump in every .glsl when common.glslinc changes (SPEC 2.7).
#include "common.glslinc"

void main() {
	if (gl_GlobalInvocationID.x != 0u) {
		return;
	}
	uint free_count = counters[0];
	if (params.brush_op == BRUSH_CIRCLE || params.brush_op == BRUSH_BLOCK) {
		free_count -= min(params.brush_count, free_count);
	}
	counters[0] = free_count;
	counters[1] = params.cap - free_count;
}
