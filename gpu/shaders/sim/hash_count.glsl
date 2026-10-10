#[compute]
#version 450

// Hash 2/6: count live particles per cell. The atomic's return value is the
// particle's rank inside its cell, which the scatter pass uses as its offset.

// common.glslinc stamp: Params 108 B, v7. Bump in every .glsl when common.glslinc changes (SPEC 2.7).
#include "common.glslinc"

void main() {
	uint i = gl_GlobalInvocationID.x;
	if (i >= params.cap || !is_alive(i)) {
		return;
	}
	uint cell = cell_index(cell_coord(pred[i]));
	particle_cell[i] = cell;
	particle_rank[i] = atomicAdd(cell_count[cell], 1u);
}
