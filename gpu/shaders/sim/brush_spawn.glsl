#[compute]
#version 450

// Brush, add: thread t fills one free slot, popped from the top of the free stack.
// Block: thread t is the t-th particle of the block, min(brush_count, free count) threads.
// Circle: thread t is one spot of a lattice at rest spacing over the brush's bounding
// square, shifted randomly each frame. A spot outside the circle, or with a live particle
// closer than SPAWN_CLEARANCE (from the last step's hash), is skipped; the others claim a
// slot with an atomic counter (counters[2]) until brush_count are placed. Random points
// used to land on top of each other and on existing particles. Water sprayed a 300 px
// dome that drifted down (water feel probe, pour). Sand, whose push-outs can't add speed
// (MAX_SEPARATION), was packed tighter each frame the brush was held: the blob expanded up
// to the ceiling and hung there, 2655 of 5640 grains still in the air 1 s after a 1 s pour
// would have landed them (water feel probe, sandair r=10 n=94 spawn=60 move=0).
// brush_finalize.glsl then lowers the free count. Mirror: cpu_ref/particle_pool.gd.

// common.glslinc stamp: Params 108 B, v10. Bump in every .glsl when common.glslinc changes (SPEC 2.7).
#include "common.glslinc"

// Closest a new circle-brush particle may be to a live one, in rest spacings.
const float SPAWN_CLEARANCE = 0.9;

// True when a live particle sits within SPAWN_CLEARANCE spacings of p (last step's hash).
bool spot_taken(vec2 p) {
	ivec2 c = cell_coord(p);
	float r2 = SPAWN_CLEARANCE * SPAWN_CLEARANCE * params.spacing * params.spacing;
	for (int dy = -1; dy <= 1; dy++) {
		for (int dx = -1; dx <= 1; dx++) {
			ivec2 cc = c + ivec2(dx, dy);
			if (cc.x < 0 || cc.y < 0 || cc.x >= int(params.grid_w) || cc.y >= int(params.grid_h)) continue;
			uint cell = cell_index(cc);
			for (uint k = cell_start[cell]; k < cell_start[cell + 1u]; k++) {
				vec2 d = s_pred[k] - p;
				if (dot(d, d) < r2 && is_alive(sorted_ids[k])) {
					return true;
				}
			}
		}
	}
	return false;
}

void main() {
	uint t = gl_GlobalInvocationID.x;
	uint free_count = counters[0];
	uint wanted = min(params.brush_count, free_count);
	vec2 p;
	uint k;
	if (params.brush_op == BRUSH_BLOCK) {
		if (t >= wanted) {
			return;
		}
		// Square lattice at rest spacing, block_cols per row, growing downward.
		p = params.brush_pos + vec2(float(t % params.block_cols), float(t / params.block_cols)) * params.spacing;
		k = t;
	} else {
		uint side = brush_lattice_side(params.brush_radius, params.spacing);
		if (t >= side * side) {
			return;
		}
		uint seed = params.frame * 9781u;
		vec2 shift = vec2(hash_unit(seed), hash_unit(seed + 1u)) * params.spacing;
		vec2 offset = (vec2(float(t % side), float(t / side)) - 0.5 * float(side)) * params.spacing + shift;
		if (dot(offset, offset) > params.brush_radius * params.brush_radius) {
			return;
		}
		p = params.brush_pos + offset;
		if (spot_taken(p)) {
			return;
		}
		k = atomicAdd(counters[2], 1u);
		if (k >= wanted) {
			return;
		}
	}
	uint slot = free_stack[free_count - 1u - k];
	p = clamp_to_world(p, slot);

	pos[slot] = p;
	pred[slot] = p;
	vel[slot] = vec2(0.0);
	mat_flags[slot] = (params.brush_material & MAT_MASK) | ALIVE;
}
