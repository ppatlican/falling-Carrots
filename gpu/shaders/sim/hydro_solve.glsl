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
// common.glslinc stamp: Params 128 B, v25. Bump in every .glsl when common.glslinc changes (SPEC 2.7).
#include "common.glslinc"
#include "hydro.glslinc"

// Per cell: x its level (hydro_level), y its bed fill (hydro_solid_fill). The cell's own
// compression and room, and the cell above's fullness, are read from hydro_phi when its row
// is set up (once per frame), so shared memory stays 16 B per cell with s_rho (16 KB is the
// Vulkan minimum for a workgroup).
shared vec2 s_phi[HYDRO_MAX_CELLS];
shared float s_p[HYDRO_MAX_CELLS];
// Per cell: its liquid density (hydro_rho, ADR 0010), for the faces' weights.
shared float s_rho[HYDRO_MAX_CELLS];
// One bit per cell: under a floater's bottom (hydro_floater_scan), set before the rows are
// worked out. Testing it in hydro_row instead, inlined into each of a thread's rows, took the
// hydro pass from ~150 to ~220-235 us per frame, with or without bodies (2026-10-15).
shared uint s_roof[HYDRO_MAX_CELLS / 32];
// One bit per cell each: body volume at least HYDRO_BODY_CELL, and at least HYDRO_BODY_ROOF.
shared uint s_in_body[HYDRO_MAX_CELLS / 32];
shared uint s_roof_body[HYDRO_MAX_CELLS / 32];

// Cells per thread.
const int HYDRO_SLOTS = (HYDRO_MAX_CELLS + LOCAL_SIZE_X - 1) / LOCAL_SIZE_X;

// How a cell's new p follows from t = dot(w, p of the +x, -x, +y, -y neighbours) + b.
const int HYDRO_ROW_BED = 0;     // sand bed: max(t, 0)
const int HYDRO_ROW_AIR = 1;     // ghost pressure: t
const int HYDRO_ROW_LIQUID = 2;  // max(mix(max(p, 0), t, HYDRO_SOR), 0)
const int HYDRO_ROW_KEEP = 3;    // walled in: max(p, 0)

// Body volume from which a cell is a body's: it isn't pulled full, and as bed it is a wall to
// the water beside it, not porous sand (see hydro_row). Mirror: SimParams.HYDRO_BODY_CELL.
const float HYDRO_BODY_CELL = 0.05;
// Body volume in the cell above from which a cell is under a body's bottom, and the most room
// such a cell is pulled for (see hydro_row). Mirror: SimParams.HYDRO_BODY_ROOF, HYDRO_ROOF_PULL.
const float HYDRO_BODY_ROOF = 0.25;
const float HYDRO_ROOF_PULL = 0.003;

// A cell short of HYDRO_AIR but holding at least this much liquid and HYDRO_MIXED_SOLID of
// bed fill (sand or body) is under water, not air, when the cell above isn't air (hydro_air).
// Mirror: SimParams.HYDRO_MIXED_WET, HYDRO_MIXED_SOLID.
const float HYDRO_MIXED_WET = 0.02;
const float HYDRO_MIXED_SOLID = 0.1;

struct HydroRow {
	vec4 w;
	float b;
	int mode;
};

// True when coarse cell ci is air (p = 0 past the surface): neither bed nor HYDRO_AIR full of
// liquid. A cell that sand or a body partly fills and that holds some water, under a cell that
// isn't air, is under water: its room is the water's gap from the grains and the body, not
// air. Read as air, such a cell beside a cork wedged on the floor under sand (water 0.2, sand
// 0.24, body 0.24) put p = 0 on the floor under ~170 px of water for a frame, and the cork's
// faces read 0 and it heaved (body_probe sandcorks). Mirror: ParticleStep.hydro_air.
bool hydro_air(ivec2 ci) {
	vec2 v = s_phi[hydro_index(ci)];
	if (v.y >= HYDRO_SOLID || v.x >= HYDRO_AIR) {
		return false;
	}
	if (ci.y > 0 && v.x >= HYDRO_MIXED_WET && v.y >= HYDRO_MIXED_SOLID) {
		vec2 u = s_phi[hydro_index(ci - ivec2(0, 1))];
		return u.y < HYDRO_SOLID && u.x < HYDRO_AIR;
	}
	return true;
}

// Sets s_roof for the cells under the bottom of a body that floats: HYDRO_BODY_ROOF of body in
// the cell above, less in its own, not the floor row, and the body reaches the air: going up from
// the cell above, past the cells holding body (HYDRO_BODY_CELL), the first cell is air (open-cell
// air: hydro_air's mixed-cell rule is for cells pinned under water), or the top of the grid. A
// floating body's gap is open to the air at its ends, so its water rises into it; under water, a
// body's void is water closing in. One thread per column scans it top-down, carrying whether the
// run of body cells it is in ends in air above, so the walk goes up to a body's top however tall:
// stopped after 3 cells (bodies up to ~48 px), it missed the air over a 40 px cork, which with the
// tent smear holds body in 4 cells, and that cork floated over 13-14 px of air (body_probe
// waterbig, 2026-10-15). Walked per cell from hydro_phi in the fill loop instead, 6 cells up or
// to the top, it took the hydro pass for pure water from ~150 to 225-250 us per frame.
// Mirror: ParticleStep.hydro_under_floater.
void hydro_floater_scan(ivec2 size) {
	int x = int(gl_LocalInvocationID.x);
	if (x >= size.x) {
		return;
	}
	bool open = true;  // the run of body cells over the current cell ends in air
	for (int y = 0; y < size.y; y++) {
		uint c = hydro_index(ivec2(x, y));
		uint ca = c - uint(size.x);
		if (y >= 1 && y < size.y - 1 && open && (s_roof_body[c >> 5u] & (1u << (c & 31u))) == 0u
				&& (s_roof_body[ca >> 5u] & (1u << (ca & 31u))) != 0u) {
			atomicOr(s_roof[c >> 5u], 1u << (c & 31u));
		}
		if ((s_in_body[c >> 5u] & (1u << (c & 31u))) == 0u) {
			open = s_phi[c].x < HYDRO_AIR && s_phi[c].y < HYDRO_SOLID;
		}
	}
}

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
	bool solid = phi_c.y >= HYDRO_SOLID;
	bool air = hydro_air(ci);
	float rho_c = s_rho[c];
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
		uint ni = hydro_index(nc);
		vec2 phi_nv = s_phi[ni];
		float phi_n = phi_nv.x;
		bool solid_n = phi_nv.y >= HYDRO_SOLID;
		bool air_n = hydro_air(nc);
		// Liquid density across this face: a face weighs 1 / rho, the head in the pores is rho's
		// (ADR 0010).
		float rho_f = hydro_face_rho(rho_c, s_rho[ni], phi, phi_n);
		float w_f = rho_f == 1.0 ? 1.0 : 1.0 / rho_f;
		if (solid) {
			// The bed carries the pressure of the liquid on it into its pores, continued
			// hydrostatically from each neighbour that isn't air: p = p_n - rho head * off.y.
			if (!air_n) {
				w[k] = 1.0;
				wall_sum -= rho_f * head * float(off.y);
				n += 1.0;
			}
		} else if (solid_n) {
			// A wall holding the water's weight: dp/dn = rho g . n, so the term (p_n - p)
			// is head * off.y. Treating sand as air (p = 0 at the bed, as before) or as a
			// zero-gradient wall gave the water at the bed no support from the grid: the
			// contact push carried its weight, along the slope's normal only, and the layer
			// on a slope slid down and drove a loop through the pool (water_feel_probe bowl).
			// Sand bed is porous: its p is the water's continued into the pores (above), so a
			// liquid cell beside it takes that p as its neighbour's, which at rest is the same
			// head. A pocket of water closed in by bed then still reads the pool's pressure
			// through the sand; as a wall it had no p of its own to keep (any p solved it), and
			// a cork wedged in a corner under sand (body_probe sandcorks) took its pocket's p
			// to 0 or to 5.8 million in a frame. Bed that is mostly body stays a wall: a body
			// lets no water through.
			if (!air) {
				if (hydro_phi[ni].z < HYDRO_BODY_CELL) {
					w[k] = w_f;
					n += w_f;
				} else {
					wall_sum += head * float(off.y);
				}
			}
		} else if (air) {
			// Ghost pressure: average over liquid neighbours of their p extrapolated
			// through 0 at the surface.
			if (!air_n) {
				w[k] = 1.0 - 1.0 / hydro_theta(phi_n, phi);
				n += 1.0;
			}
		} else if (air_n) {
			// p = 0 at the surface, theta of the way: the term (0 - p) / theta, over this cell's
			// liquid density.
			n += 1.0 / (rho_c * hydro_theta(phi, phi_n));
		} else {
			w[k] = w_f;
			n += w_f;
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
	// Body volume counts as full room and as compression (ADR 0003): a body isn't a bubble to
	// fill, and water squeezed under or into a body is pushed out.
	// A cell a body partly fills (HYDRO_BODY_CELL) is never pulled: water keeps a contact
	// gap from the body, so it reads short of full with no air in it. Pulled, a cork held
	// down in a corner of a deep pool by sand (body_probe sandcorks) had its cells flip every
	// few frames between short of full (p pulled to 0 under ~170 px of water: its faces read
	// 0 and it fell) and squeezed (p 2-3x hydrostatic once water rushed in: it shot up), and
	// the whole pool's p swung with them: the sea jumped (owner report, 2026-10-13).
	vec4 own = hydro_phi[c];
	vec4 above = ci.y > 0 ? hydro_phi[hydro_index(ci - ivec2(0, 1))] : vec4(0.0);
	bool covered = above.x + above.y * HYDRO_POWDER_VOL + above.z >= HYDRO_FULL && ci.y < size.y - 1
			&& own.z < HYDRO_BODY_CELL;
	float err = max(own.x + own.z - 1.0, 0.0);
	float room = min(own.x + own.y * HYDRO_POWDER_FULL + own.z - 1.0, 0.0);
	if (covered) {
		err += room;
	} else if ((s_roof[c >> 5u] & (1u << (c & 31u))) != 0u) {
		// Under the bottom of a body that floats (hydro_floater_scan), a cell with room is
		// pulled, for at most HYDRO_ROOF_PULL of it. The body's bottom cell is only part full,
		// as its bottom row cuts through it, so it never covered the cell under it: that cell was
		// water under a wall, at hydrostatic p, and its water, weightless, stayed where it lay,
		// a cell of air under a long floating cork (~18 px, body_probe corkstrip; owner
		// screenshot 2026-10-15). Not under a body still under water: the void a rising body
		// leaves under it is such a cell too, and pulled, even capped, its p went to 0, the
		// body's bottom read it, and a long cork rising off the floor hung ~25 px up (corkstrip).
		err += max(room, -HYDRO_ROOF_PULL);
	}
	float rhs = -a * a * hydro_k() * err / (params.dt * params.dt);
	return HydroRow(w / n, (wall_sum - rhs) / n, HYDRO_ROW_LIQUID);
}

void main() {
	ivec2 size = hydro_size();
	uint n = uint(size.x * size.y);
	uint tid = gl_LocalInvocationID.x;
	if (tid < uint(HYDRO_MAX_CELLS / 32)) {
		s_roof[tid] = 0u;
		s_in_body[tid] = 0u;
		s_roof_body[tid] = 0u;
	}
	memoryBarrierShared();
	barrier();
	for (uint c = tid; c < n; c += LOCAL_SIZE_X) {
		vec4 phi = hydro_phi[c];
		s_phi[c] = vec2(hydro_level(phi), hydro_solid_fill(phi));
		s_p[c] = hydro_p[c];
		s_rho[c] = hydro_rho[c];
		if (phi.z >= HYDRO_BODY_CELL) {
			atomicOr(s_in_body[c >> 5u], 1u << (c & 31u));
		}
		if (phi.z >= HYDRO_BODY_ROOF) {
			atomicOr(s_roof_body[c >> 5u], 1u << (c & 31u));
		}
	}
	memoryBarrierShared();
	barrier();
	hydro_floater_scan(size);
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
