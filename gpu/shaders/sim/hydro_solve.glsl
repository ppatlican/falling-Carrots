#[compute]
#version 450

// Hydro 3/3: the HYDRO_SWEEPS projected red-black SOR sweeps of the density projection
// grid (see hydro.glslinc), all in one workgroup with p in shared memory. Warm-started
// from the last step's p (hydro_p), written back at the end.
//
// The grid is small (920 cells), so a dispatch per half sweep cost more in launch and
// barrier overhead than in work: 64 dispatches made the hydro pass 420-670 us per frame at
// any particle count (2 substeps, GPU probe, 2026-10-12). Here the sweeps are separated
// by workgroup barriers, with 128 threads (the Vulkan minimum for a workgroup, so any
// device runs it), each owning HYDRO_SLOTS cells. phi doesn't change during the sweeps, so
// each cell's update is a fixed linear form in its four neighbours' p (hydro_row), worked
// out once into the thread's registers; a half sweep is then four shared loads per cell.
// Re-deriving the update from phi in every sweep, as the dispatches did, made one
// workgroup 1.5-2.5x slower than the dispatches (latency-bound on one compute unit). Same
// result as the per-sweep dispatches, up to float rounding, in the same red-black order.
// Measured at 50k, uncapped fps: the pass 360-430 -> 160-180 us per frame, of which the
// sweeps are ~115 (splat and density alone: 43). Giving each thread cells of one parity
// per half sweep (no idle threads), and issuing all shared loads before the stores, made
// no difference: what is left is the 64 barriers on one compute unit.

#define LOCAL_SIZE_X 128
// common.glslinc stamp: Params 124 B, v16. Bump in every .glsl when common.glslinc changes (SPEC 2.7).
#include "common.glslinc"
#include "hydro.glslinc"

shared vec2 s_phi[HYDRO_MAX_CELLS];
shared float s_p[HYDRO_MAX_CELLS];

// Cells per thread.
const int HYDRO_SLOTS = HYDRO_MAX_CELLS / LOCAL_SIZE_X;

// How a cell's new p follows from t = dot(w, p of the +x, -x, +y, -y neighbours) + b.
const int HYDRO_ROW_BED = 0;     // sand bed: max(t, 0)
const int HYDRO_ROW_AIR = 1;     // ghost pressure: t
const int HYDRO_ROW_LIQUID = 2;  // max(mix(max(p, 0), t, HYDRO_SOR), 0)
const int HYDRO_ROW_KEEP = 3;    // walled in: max(p, 0)

struct HydroRow {
	vec4 w;
	float b;
	int mode;
};

// The projected SOR update of coarse cell ci as a HydroRow. Per cell, with a the cell
// size: sum over in-grid neighbours of (p_n - p) = -a^2 HYDRO_K err / dt^2. Side walls and
// the ceiling drop out; the floor holds the water's weight (dp/dn = rho g). Air neighbours
// have p = 0. A cell reads only neighbours of the other parity, so a half sweep can update
// its cells in place.
HydroRow hydro_row(ivec2 ci, ivec2 size) {
	uint c = hydro_index(ci);
	float a = hydro_cell_size();
	// Hydrostatic head across one cell: at rest p rises by this per cell of depth.
	float head = params.gravity * a;
	vec2 phi_c = s_phi[c];
	float phi = phi_c.x;
	bool solid = hydro_solid(phi_c);
	bool air = !solid && phi < HYDRO_AIR;
	vec4 w = vec4(0.0);
	float n = 0.0;
	float wall_sum = 0.0;
	for (int k = 0; k < 4; k++) {
		ivec2 off = k == 0 ? ivec2(1, 0) : (k == 1 ? ivec2(-1, 0) : (k == 2 ? ivec2(0, 1) : ivec2(0, -1)));
		ivec2 nc = ci + off;
		if (nc.y >= size.y) {
			// The floor holds the water's weight, as a sand bed does (solid_n below). As a
			// zero-gradient wall it held none: the floor row carried the whole column by
			// staying ~0.6% compressed, which at ~1.7 head per 1% of fill error read 0.2-0.7
			// head under hydrostatic and noisy cell to cell, and pure water circulated along
			// the floor at up to 4-5 px/s while water on a sand floor came to rest
			// (water_feel_probe bowl nosand, 2026-10-11).
			if (!solid && !air) {
				wall_sum += head;
			}
			continue;
		}
		if (nc.x < 0 || nc.y < 0 || nc.x >= size.x) {
			continue;
		}
		vec2 phi_nv = s_phi[hydro_index(nc)];
		float phi_n = phi_nv.x;
		bool solid_n = hydro_solid(phi_nv);
		bool air_n = !solid_n && phi_n < HYDRO_AIR;
		if (solid) {
			// The bed carries the pressure of the water on it into its pores, continued
			// hydrostatically from each neighbour that isn't air: p = p_n - head * off.y.
			if (!air_n) {
				w[k] = 1.0;
				wall_sum -= head * float(off.y);
				n += 1.0;
			}
		} else if (solid_n) {
			// A wall holding the water's weight: dp/dn = rho g . n, so the term (p_n - p)
			// is head * off.y. Treating sand as air (p = 0 at the bed, as before) or as a
			// zero-gradient wall gave the water at the bed no support from the grid: the
			// contact push carried its weight, along the slope's normal only, and the layer
			// on a slope slid down and drove a loop through the pool (water_feel_probe bowl).
			if (!air) {
				wall_sum += head * float(off.y);
			}
		} else if (air) {
			// Ghost pressure: average over liquid neighbours of their p extrapolated
			// through 0 at the surface.
			if (!air_n) {
				w[k] = 1.0 - 1.0 / hydro_theta(phi_n, phi);
				n += 1.0;
			}
		} else if (air_n) {
			// p = 0 at the surface, theta of the way: the term (0 - p) / theta.
			n += 1.0 / hydro_theta(phi, phi_n);
		} else {
			w[k] = 1.0;
			n += 1.0;
		}
	}
	if (solid || air) {
		// With no neighbour to continue from, p = 0.
		return n > 0.0 ? HydroRow(w / n, wall_sum / n, solid ? HYDRO_ROW_BED : HYDRO_ROW_AIR)
				: HydroRow(vec4(0.0), 0.0, HYDRO_ROW_AIR);
	}
	if (n == 0.0) {
		// Walled in by sand on every side: nothing to solve against.
		return HydroRow(vec4(0.0), 0.0, HYDRO_ROW_KEEP);
	}
	// Compression is always corrected. A cell with room left is pulled full only under a
	// full cell (the one above at least HYDRO_FULL): an air bubble trapped in the water
	// closes from the top, while cells at the free surface, which are rightly
	// part-filled, aren't pulled together. Requiring all four neighbours full left 30k
	// water full of bubbles next to each other. Powder fills room too (HYDRO_POWDER_VOL):
	// counting only the liquid made a wet sand bed look like a bubble, pulled water into
	// it forever, and water over sand churned at 9 px/s. Skipping cells with any powder
	// instead left air pockets riding on every clump of sand sinking through water
	// (water_feel_probe sink, owner screenshot 2026-10-10). Powder counts at its packing
	// under water here (HYDRO_POWDER_FULL), so a sand surface isn't a bubble. The floor row
	// is never pulled: its cells are half outside the world, and water keeps a gap from the
	// floor, so they read 0.1-0.4% short of full (0.996-1.000), and the pull, stiff as it is,
	// held their p 0.2-0.5 head under hydrostatic and noisy. A floor lined with sand, whose
	// bottom cells are bed and never pulled, calmed pure water from 0.74-0.78 px/s to 0.26
	// (water_feel_probe bowl nosand vs floor=12 cols=0, 2026-10-11).
	vec2 above = ci.y > 0 ? s_phi[hydro_index(ci - ivec2(0, 1))] : vec2(0.0);
	bool covered = above.x + above.y * HYDRO_POWDER_VOL >= HYDRO_FULL && ci.y < size.y - 1;
	float err = max(phi - 1.0, 0.0);
	if (covered) {
		err += min(phi + phi_c.y * HYDRO_POWDER_FULL - 1.0, 0.0);
	}
	float rhs = -a * a * hydro_k() * err / (params.dt * params.dt);
	return HydroRow(w / n, (wall_sum - rhs) / n, HYDRO_ROW_LIQUID);
}

void main() {
	ivec2 size = hydro_size();
	uint n = uint(size.x * size.y);
	uint tid = gl_LocalInvocationID.x;
	for (uint c = tid; c < n; c += LOCAL_SIZE_X) {
		s_phi[c] = hydro_phi[c];
		s_p[c] = hydro_p[c];
	}
	memoryBarrierShared();
	barrier();
	// This thread's cells tid + k * LOCAL_SIZE_X: their rows, parity (2 past the grid) and
	// neighbour indices (clamped into the grid; a neighbour outside it has weight 0).
	HydroRow row[HYDRO_SLOTS];
	uvec4 nb[HYDRO_SLOTS];
	uint par[HYDRO_SLOTS];
	ivec2 hi = size - ivec2(1);
	for (int k = 0; k < HYDRO_SLOTS; k++) {
		uint c = tid + uint(k) * LOCAL_SIZE_X;
		ivec2 ci = ivec2(int(c) % size.x, int(c) / size.x);
		par[k] = 2u;
		row[k] = HydroRow(vec4(0.0), 0.0, HYDRO_ROW_KEEP);
		nb[k] = uvec4(0u);
		if (c < n) {
			par[k] = uint(ci.x + ci.y) % 2u;
			row[k] = hydro_row(ci, size);
			nb[k] = uvec4(hydro_index(clamp(ci + ivec2(1, 0), ivec2(0), hi)),
					hydro_index(clamp(ci - ivec2(1, 0), ivec2(0), hi)),
					hydro_index(clamp(ci + ivec2(0, 1), ivec2(0), hi)),
					hydro_index(clamp(ci - ivec2(0, 1), ivec2(0), hi)));
		}
	}
	for (int s = 0; s < 2 * HYDRO_SWEEPS; s++) {
		uint parity = uint(s) & 1u;
		for (int k = 0; k < HYDRO_SLOTS; k++) {
			if (par[k] != parity) {
				continue;
			}
			uint c = tid + uint(k) * LOCAL_SIZE_X;
			vec4 pn = vec4(s_p[nb[k].x], s_p[nb[k].y], s_p[nb[k].z], s_p[nb[k].w]);
			float t = dot(row[k].w, pn) + row[k].b;
			int mode = row[k].mode;
			if (mode == HYDRO_ROW_BED) {
				s_p[c] = max(t, 0.0);
			} else if (mode == HYDRO_ROW_AIR) {
				s_p[c] = t;
			} else if (mode == HYDRO_ROW_LIQUID) {
				// Warm start: a cell that was air last frame holds a negative ghost.
				s_p[c] = max(mix(max(s_p[c], 0.0), t, HYDRO_SOR), 0.0);
			} else {
				s_p[c] = max(s_p[c], 0.0);
			}
		}
		memoryBarrierShared();
		barrier();
	}
	for (uint c = tid; c < n; c += LOCAL_SIZE_X) {
		hydro_p[c] = s_p[c];
	}
}
