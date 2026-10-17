#[compute]
#version 450

// Solve, once per frame before the iterations: liquids are pushed down the gradient of
// the density projection grid's pressure (hydro_delta in hydro.glslinc) over their mass, into scratch,
// clamped like solve_delta. solve_apply then applies it.
// Body particles are pushed by the pressure on their wet surface (body_pressure_delta, ADR 0003); mochi
// where the grid holds liquid as a liquid is (ADR 0018).

// common.glslinc stamp: Params 128 B, v26. Bump in every .glsl when common.glslinc changes (SPEC 2.7).
#include "common.glslinc"
#include "hydro.glslinc"
#include "mochi.glslinc"

// A body particle's wet face toward a liquid neighbour d away: the unit vector to it, weighted
// 1 out to 1.5 spacings and fading to 0 at h, over 1 + sqrt(2), what a flat face of liquid on
// the rest lattice gives (one neighbour straight on, two diagonal). Summed, it reads 1 for a
// flat wet face and sqrt(2) along the diagonal at a corner wet on two sides, wherever the
// water sits within 1.5 spacings. Summed spiky kernel gradients over their value for that
// lattice read 0.55-0.64 instead: water by a body sits ~2-2.5 px off and not on a lattice, and
// the spiky gradient falls steeply over that range, so an 80 x 40 cork floated at 0.71 of its
// height instead of ~0.5 (body_probe waterbig). Mirror: ParticleStep.body_wet_face.
vec2 body_wet_face(vec2 d) {
	float r = length(d);
	if (r < MIN_DIST || r >= params.h) {
		return vec2(0.0);
	}
	float w = clamp((params.h - r) / (params.h - 1.5 * params.spacing), 0.0, 1.0);
	return d / r * w / (1.0 + sqrt(2.0));
}

// Liquid in the density projection grid at x, over rest (bilinear over the cells' liquid
// channel, as hydro_powder_fill reads the powder one).
float body_liquid_fill(vec2 x) {
	ivec2 size = hydro_size();
	vec2 gc = x / hydro_cell_size() - 0.5;
	ivec2 c0 = ivec2(floor(gc));
	vec2 f = gc - vec2(c0);
	float v[4];
	for (int k = 0; k < 4; k++) {
		ivec2 c = clamp(c0 + ivec2(k & 1, k >> 1), ivec2(0), size - ivec2(1));
		v[k] = hydro_phi[hydro_index(c)].x;
	}
	return mix(mix(v[0], v[1], f.x), mix(v[2], v[3], f.x), f.y);
}

// Liquid fill (body_liquid_fill) at a wet body's outline point from which that face is under
// water, between grains or in a void, even with no water particle on it. A dry bed reads 0;
// the saturated bed under a pool 0.02-0.26 of a cell, since the grains take up most of the
// pores. Mirror: SimParams.BODY_PORE_WET.
const float BODY_PORE_WET = 0.02;

// Position change of body particle t from the liquid's pressure on its wet surface (ADR 0003
// item 4): p at the body's outline on the liquid side, over the body's reference pressure,
// pressing on its wet face g (body_wet_face summed over its liquid neighbours), over the
// body's mass per particle (density x spacing^2, water being 1). Summed over a body this is
// the pressure over its wet surface: a submerged body is pushed up by the weight of the water
// it displaces, a dry one by nothing, a floating one only below its waterline. Pressure under
// p_ref pushes nothing. Within 1.5 spacings of the floor or a side wall, a particle of a body
// that was wet last substep also counts the floor or wall as a face of liquid (water seeps
// between them), so a light body on the floor of a pool rises, and one against a wall isn't
// pushed into it by the water on its other side: the wall's friction (solve_apply) then held
// it, and two corks on the floor by the walls of a sand-and-water tank stayed there (body_probe
// sandcorks).
// It also gives the body its reference pressure for the next substep (atomicMin of the float's
// bits into p_min, which body_match moves to p_ref): the lowest p over its wet particles and
// over its bare boundary members (its way out, rest_offset.zw, half a spacing long; nothing but
// its own body within 1.5 spacings, away from the walls), each of which reads the grid's p at
// its outline point. Closed in by liquid, grains, other bodies, the floor and walls, a body is
// pushed only by the pressure difference across it: at the floor of a 30k pool the absolute
// push would be ~2 px per substep, past the cap. With a face out of the water, that face reads
// 0 (the grid's p is 0 past the free surface) and it floats on the absolute pressure: referred
// to its lowest wet pressure instead, a cork bobbing up until only its bottom row was wet lost
// its lift at the top of each bob, and the bob grew (CPU reference). A bare member reads the
// grid, not 0: poured water is full of small voids, and a 16 x 10 cork on the floor of a 270 px
// pool had one beside some member nearly every substep; p_ref went to 0, the pushes on every
// face hit the cap and cancelled, and it stayed on the floor (body_probe pourfloor, pourdrop).
// Under water the whole face is wet, whatever touches it: a boundary member of a body that was
// wet last substep, not touching another body, takes its outline face as wet where the grid
// holds liquid at its outline point (BODY_PORE_WET) and a pressure over 0, if that face is
// larger than the one its liquid neighbours give. The face is its way out of the rest shape,
// turned by the body's rotation, over half a spacing: 1 on a flat face and sqrt(2) along a
// corner's diagonal, as body_wet_face reads them. Counting only liquid neighbours, ten corks
// dropped onto 10k sand and covered by 20k water had grains, not water, under their bottoms,
// no lift, and six to eight stayed on the bed (body_probe sandcorks); counting the grains
// touching them as well, the push was 0.45-0.6 of their buoyancy, since grains and the water
// between them leave gaps, and a cork lifted off the grains lost its bottom's push. Such a face
// also keeps the body wet. A dry bed, which the grid gives a hydrostatic pressure but no pore
// water, pushes nothing; a face reading 0 (the grid's air) is left dry, or it took p_ref to 0.
// Mirror: ParticleStep._body_pressure_delta.
vec2 body_pressure_delta(uint t, uint body) {
	float sp = params.spacing;
	vec2 x = s_pred[t];
	vec2 g = vec2(0.0);
	bool touching = false;
	bool on_body = false;
	FOR_EACH_NEIGHBOUR(t) {
		uint j = k;
		if (j == t || s_body(j) == body) continue;
		vec2 rv = x - s_pred[j];
		if (dot(rv, rv) < 2.25 * sp * sp) {
			touching = true;
			on_body = on_body || s_body(j) != 0u;
		}
		if (s_class(j) == CLASS_LIQUID) {
			g += body_wet_face(-rv);
		}
	} END_NEIGHBOURS
	bool was_wet = (bodies[body].info.w & BODY_WET) != 0u;
	vec2 e_rest = rest_offset[sorted_ids[t]].zw;
	vec2 r = bodies[body].frame.zw;
	vec2 e = vec2(r.x * e_rest.x - r.y * e_rest.y, r.y * e_rest.x + r.x * e_rest.y);
	bool boundary = length(e_rest) < 0.75 * sp;
	bool wet = length(g) > 1e-6;
	float pw = wet ? body_p_sample(x + 0.5 * sp * normalize(g)) : 0.0;
	vec2 face = e / (0.5 * sp);
	if (was_wet && boundary && !on_body && length(g) < length(face) && body_liquid_fill(x + e) >= BODY_PORE_WET) {
		float pf = body_p_sample(x + 0.5 * sp * normalize(face));
		if (pf > 0.0) {
			g = face;
			pw = pf;
			wet = true;
		}
	}
	if (wet) {
		atomicOr(bodies[body].info.w, BODY_WET_NOW);
	}
	uint ref = wet ? floatBitsToUint(pw) : BODY_P_INF;
	bool at_wall = x.x < 1.5 * sp || x.y < 1.5 * sp || x.x > params.world_size.x - 1.5 * sp
			|| x.y > params.world_size.y - 1.5 * sp;
	if (!touching && !at_wall && boundary) {
		// A bare boundary member: the grid's p at its outline point, 0 out of the water.
		ref = min(ref, floatBitsToUint(body_p_sample(x + e)));
	}
	atomicMin(bodies[body].p_min, ref);
	if (was_wet) {
		if (x.y >= params.world_size.y - 1.5 * sp) {
			g.y = max(g.y, 1.0);
			pw = max(pw, body_p_sample(vec2(x.x, params.world_size.y)));
		}
		if (x.x <= 1.5 * sp) {
			g.x = min(g.x, -1.0);
			pw = max(pw, body_p_sample(vec2(0.0, x.y)));
		}
		if (x.x >= params.world_size.x - 1.5 * sp) {
			g.x = max(g.x, 1.0);
			pw = max(pw, body_p_sample(vec2(params.world_size.x, x.y)));
		}
	}
	if (length(g) <= 1e-6) {
		return vec2(0.0);
	}
	float density = materials[s_material(t)].phys.x;
	return -max(pw - bodies[body].p_ref, 0.0) * g * params.dt * params.dt / (density * sp);
}

void main() {
	uint t;
	if (!sorted_particle(t)) {
		return;
	}
	vec2 d = vec2(0.0);
	uint body = s_body(t);
	body_push[t] = vec4(0.0);  // nothing from other bodies yet this substep (solve_apply, ADR 0008)
	if (body != 0u) {
		d = body_pressure_delta(t, body);
	} else if (s_class(t) == CLASS_LIQUID) {
		// Over the particle's mass (ADR 0010): a liquid lighter than the one around it rises.
		float rho = materials[s_material(t)].phys.x;
		d = hydro_delta(s_pred[t]);
		if (rho != 1.0) {
			d /= rho;
		}
	} else if (s_class(t) == CLASS_MOCHI) {
		// Mochi in liquid (ADR 0018): as a liquid, over its mass, where the grid holds liquid at it
		// (MOCHI_WET_FILL), so a dough floats, hangs or sinks by its density. Ungated, a dry dough bed's
		// grid pressure (continued hydrostatically, though no water is in it) would hold it up.
		float gate = smoothstep(0.0, MOCHI_WET_FILL, body_liquid_fill(s_pred[t]));
		if (gate > 0.0) {
			d = hydro_delta(s_pred[t]) * (gate / materials[s_material(t)].phys.x);
		}
	}
	// A body's pushes are capped after body_project has taken their rigid part, not here.
	float len = length(d);
	float max_len = 0.5 * params.spacing;
	if (body == 0u && len > max_len) {
		d *= max_len / len;
	}
	scratch[t] = d;
}
