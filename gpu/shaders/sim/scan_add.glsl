#[compute]
#version 450

// Hash 5/6, prefix sum part 3: add each block's offset. cell_start[c] is now the
// first sorted index of cell c, and cell_start[n_cells] is the live count.

// common.glslinc stamp: Params 108 B, v2. Bump in every .glsl when common.glslinc changes (SPEC 2.7).
#include "common.glslinc"

void main() {
	uint c = gl_GlobalInvocationID.x;
	if (c <= params.n_cells) {
		cell_start[c] += block_sums[c / SCAN_BLOCK];
	}
}
