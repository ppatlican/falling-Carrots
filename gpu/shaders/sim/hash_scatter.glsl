#[compute]
#version 450

// Hash 6/6: give each live particle its sorted index t (cells in order) and copy
// its state into the sorted s_* arrays, so the solver reads neighbours from
// contiguous memory. sorted_ids maps t back to the slot.

// common.glslinc stamp: Params 108 B, v9. Bump in every .glsl when common.glslinc changes (SPEC 2.7).
#include "common.glslinc"

void main() {
	uint i = gl_GlobalInvocationID.x;
	if (i >= params.cap || !is_alive(i)) {
		return;
	}
	uint t = cell_start[particle_cell[i]] + particle_rank[i];
	sorted_ids[t] = i;
	s_pred[t] = pred[i];
	s_pos[t] = pos[i];
	s_vel[t] = vel[i];
	s_mat[t] = mat_flags[i];
}
