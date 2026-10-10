#[compute]
#version 450

// Hydro 2/4: liquid and powder density over rest of each coarse cell (hydro_density in
// hydro.glslinc) from the splatted sums, which it zeroes for the next frame.
// One thread per coarse cell.

// common.glslinc stamp: Params 108 B, v10. Bump in every .glsl when common.glslinc changes (SPEC 2.7).
#include "common.glslinc"
#include "hydro.glslinc"

void main() {
	ivec2 size = hydro_size();
	uint c = gl_GlobalInvocationID.x;
	if (c >= uint(size.x * size.y)) {
		return;
	}
	hydro_phi[c] = hydro_density(ivec2(int(c) % size.x, int(c) / size.x));
	hydro_acc[2u * c] = 0;
	hydro_acc[2u * c + 1u] = 0;
}
