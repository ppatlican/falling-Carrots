#[compute]
#version 450

// Hash 3/6, prefix sum part 1: each workgroup scans SCAN_BLOCK (256) cell counts,
// 4 per thread, writes the exclusive prefix to cell_start, and its total to block_sums.

#include "common.glslinc"

shared uint partial[64];

void main() {
	uint n = params.n_cells + 1u;
	uint lid = gl_LocalInvocationID.x;
	uint base = gl_WorkGroupID.x * SCAN_BLOCK + lid * 4u;

	// Sequential exclusive scan of this thread's 4 elements.
	uint local_prefix[4];
	uint total = 0u;
	for (uint k = 0u; k < 4u; k++) {
		local_prefix[k] = total;
		if (base + k < n) {
			total += cell_count[base + k];
		}
	}

	// Inclusive scan of the 64 thread totals (Hillis-Steele).
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
	uint thread_start = partial[lid] - total;

	for (uint k = 0u; k < 4u; k++) {
		if (base + k < n) {
			cell_start[base + k] = thread_start + local_prefix[k];
		}
	}
	if (lid == 63u) {
		block_sums[gl_WorkGroupID.x] = partial[63];
	}
}
