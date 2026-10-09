#[compute]
#version 450

// Brush, add: thread t fills one free slot, popped from the top of the free stack.
// Only min(brush_count, free count) threads do work, so the pool can't overfill.
// brush_finalize.glsl then lowers the free count. Mirror: cpu_ref/particle_pool.gd.

// common.glslinc stamp: Params 108 B, v5. Bump in every .glsl when common.glslinc changes (SPEC 2.7).
#include "common.glslinc"

void main() {
	uint t = gl_GlobalInvocationID.x;
	uint free_count = counters[0];
	if (t >= min(params.brush_count, free_count)) {
		return;
	}
	uint slot = free_stack[free_count - 1u - t];

	vec2 p;
	if (params.brush_op == BRUSH_BLOCK) {
		// Square lattice at rest spacing, block_cols per row, growing downward.
		p = params.brush_pos + vec2(float(t % params.block_cols), float(t / params.block_cols)) * params.spacing;
	} else {
		// Random point in the brush circle (sqrt for uniform area density).
		uint seed = t * 2u + params.frame * 9781u;
		float angle = hash_unit(seed) * 2.0 * PI;
		float r = sqrt(hash_unit(seed + 1u)) * params.brush_radius;
		p = params.brush_pos + vec2(cos(angle), sin(angle)) * r;
	}
	p = clamp_to_world(p, slot);

	pos[slot] = p;
	pred[slot] = p;
	vel[slot] = vec2(0.0);
	mat_flags[slot] = (params.brush_material & MAT_MASK) | ALIVE;
}
