#[compute]
#version 450

// Hash 1/6: zero the per-cell counts (n_cells + 1 entries; the extra one makes
// the prefix sum's last entry the total).

// common.glslinc stamp: Params 108 B, v2. Bump in every .glsl when common.glslinc changes (SPEC 2.7).
#include "common.glslinc"

void main() {
	uint c = gl_GlobalInvocationID.x;
	if (c <= params.n_cells) {
		cell_count[c] = 0u;
	}
}
