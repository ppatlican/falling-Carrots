#[compute]
#version 450

// Hash 4/6, prefix sum part 2 (one workgroup): turn the block totals into an
// exclusive prefix in place. Handles up to 256 blocks (65536 cells); checked at startup.

// common.glslinc stamp: Params 108 B, v3. Bump in every .glsl when common.glslinc changes (SPEC 2.7).
#include "common.glslinc"

shared uint partial[64];

void main() {
	uint n_blocks = (params.n_cells + 1u + SCAN_BLOCK - 1u) / SCAN_BLOCK;
	uint lid = gl_LocalInvocationID.x;
	uint base = lid * 4u;

	uint vals[4];
	uint total = 0u;
	for (uint k = 0u; k < 4u; k++) {
		vals[k] = base + k < n_blocks ? block_sums[base + k] : 0u;
		total += vals[k];
	}

	partial[lid] = total;
	memoryBarrierShared();
	barrier();
	for (uint offset = 1u; offset < 64u; offset *= 2u) {
		uint add = lid >= offset ? partial[lid - offset] : 0u;
		memoryBarrierShared();
		barrier();
		partial[lid] += add;
		memoryBarrierShared();
		barrier();
	}

	uint running = partial[lid] - total;
	for (uint k = 0u; k < 4u; k++) {
		if (base + k < n_blocks) {
			block_sums[base + k] = running;
		}
		running += vals[k];
	}
}
