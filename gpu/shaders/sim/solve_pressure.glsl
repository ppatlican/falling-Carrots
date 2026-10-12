#[compute]
#version 450

// Solve, once per frame before the iterations: liquids are pushed down the gradient of
// the density projection grid's pressure (hydro_delta in hydro.glslinc), into scratch,
// clamped like solve_delta. solve_apply then applies it.
// Body particles are pushed by the pressure on their wet surface (body_pressure_delta, ADR 0003).

// common.glslinc stamp: Params 124 B, v17. Bump in every .glsl when common.glslinc changes (SPEC 2.7).
#include "common.glslinc"
#include "hydro.glslinc"

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

// Position change of body particle t from the liquid's pressure on its wet surface (ADR 0003
// item 4): p at the body's outline on the liquid side, over the body's reference pressure,
// pressing on its wet face g (body_wet_face summed over its liquid neighbours), over the
// body's mass per particle (density x spacing^2, water being 1). Summed over a body this is
// the pressure over its wet surface: a submerged body is pushed up by the weight of the water
// it displaces, a dry one by nothing, a floating one only below its waterline. Pressure under
// p_ref pushes nothing. Within 1.5 spacings of the floor, a particle of a body that was wet last
// substep also counts the floor below it as a face of liquid (water seeps under it), so a light
// body on the floor of a pool rises.
// It also gives the body its reference pressure for the next substep (atomicMin of the float's
// bits into p_min, which body_match moves to p_ref): the lowest p over its wet particles, or 0
// if a boundary member (its way out, rest_offset.zw, half a spacing long) touches air (nothing
// but its own body within 1.5 spacings, away from the walls). Closed in by liquid, grains,
// other bodies, the floor and walls, a body is pushed only by the pressure difference across
// it: at the floor of a 30k pool the absolute push would be ~2 px per substep, past the cap.
// With a face in air it floats, and the pressure is absolute: referred to its lowest wet
// pressure instead, a cork bobbing up until only its bottom row was wet lost its lift at the
// top of each bob, and the bob grew (CPU reference). Mirror: ParticleStep._body_pressure_delta.
vec2 body_pressure_delta(uint t, uint body) {
	float sp = params.spacing;
	vec2 x = s_pred[t];
	vec2 g = vec2(0.0);
	bool touching = false;
	FOR_EACH_NEIGHBOUR(t) {
		uint j = k;
		if (j == t || s_body(j) == body) continue;
		vec2 rv = x - s_pred[j];
		if (dot(rv, rv) < 2.25 * sp * sp) {
			touching = true;
		}
		if (s_class(j) == CLASS_LIQUID) {
			g += body_wet_face(-rv);
		}
	} END_NEIGHBOURS
	bool wet = length(g) > 1e-6;
	float pw = 0.0;
	uint ref = BODY_P_INF;
	if (wet) {
		pw = body_p_sample(x + 0.5 * sp * normalize(g));
		ref = floatBitsToUint(pw);
		atomicOr(bodies[body].info.w, BODY_WET_NOW);
	}
	bool at_wall = x.x < 1.5 * sp || x.y < 1.5 * sp || x.x > params.world_size.x - 1.5 * sp
			|| x.y > params.world_size.y - 1.5 * sp;
	if (!touching && !at_wall && length(rest_offset[sorted_ids[t]].zw) < 0.75 * sp) {
		ref = 0u;  // a boundary member in air
	}
	atomicMin(bodies[body].p_min, ref);
	if (x.y >= params.world_size.y - 1.5 * sp && (bodies[body].info.w & BODY_WET) != 0u) {
		g.y = max(g.y, 1.0);
		pw = max(pw, body_p_sample(vec2(x.x, params.world_size.y)));
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
	if (body != 0u) {
		d = body_pressure_delta(t, body);
	} else if (s_class(t) == CLASS_LIQUID) {
		d = hydro_delta(s_pred[t]);
	}
	float len = length(d);
	float max_len = 0.5 * params.spacing;
	if (len > max_len) {
		d *= max_len / len;
	}
	scratch[t] = d;
}
