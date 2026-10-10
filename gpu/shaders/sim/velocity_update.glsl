#[compute]
#version 450

// Velocity 1/3 (spec 2.6 step 5): velocity from the solved move, times exp(-drag * dt)
// (material drag is per second, so it doesn't depend on the substep count).
// Powders: the solver's push-out may stop a grain but not launch it faster than
// max_separation in the push direction (keeps settled sand from hopping).
// Powders also sleep (Macklin et al. 2014, "particle sleeping"): a grain the solver
// held up (took away at least half of gravity's speed this step) that moved slower than
// SLEEP_SPEED this step stays where it started, with zero velocity. Without it a
// settled 50k pile never came to rest: the few Jacobi iterations leave ~2.5 px/s of
// back-and-forth in every grain ("pudding", Milestone 2 GPU measurement). It is decided
// again each step, so a grain wakes as soon as it is hit or loses its support.
// Liquids: the solver's correction may stop water but add at most LIQUID_KICK x
// gravity x dt of speed in its own direction per step. With few Jacobi iterations the
// density correction overshoots, and the overshoot became upward speed: deep water
// churned at ~37 px/s (30k) and ~60 px/s (50k), with jets of 150-350 px/s up the side
// walls. A cap of 0 would stop the water levelling, since the slow sideways push from a
// higher surface starts from rest. Depth pressure comes from the grid (hydro.glslinc).

// common.glslinc stamp: Params 108 B, v8. Bump in every .glsl when common.glslinc changes (SPEC 2.7).
#include "common.glslinc"

// Fastest speed (px/s) that still counts as resting: 0.1 px per 1/60 s step, below the
// free-fall speed after one 1/60 s step (6.7 px/s). Mirror: SimParams.SLEEP_SPEED.
const float SLEEP_SPEED = 6.0;

// Liquids: the separating speed the solver's correction may add in one step, in units
// of gravity * dt. Mirror: SimParams.LIQUID_KICK.
const float LIQUID_KICK = 2.0;

void main() {
	uint t;
	if (!sorted_particle(t)) {
		return;
	}
	float drag = materials[s_material(t)].phys.w;
	vec2 v = (s_pred[t] - s_pos[t]) / params.dt;
	vec2 v_pre = s_vel[t];  // velocity predict moved with (after gravity, before the solver)
	float max_v = params.max_step / params.dt;
	if (length(v_pre) > max_v) {
		v_pre *= max_v / length(v_pre);
	}
	// Separating speed the solver's correction may leave along its own direction n:
	// max(sep, speed along n before the solver) + kick.
	float sep = 0.0;
	float kick = 0.0;
	if (s_class(t) == CLASS_POWDER) {
		// Held up: the solver took away at least half a step of gravity's fall (y points
		// down). Counting a change of speed in any direction let grains with nothing
		// under them sleep: a falling grain moves g dt^2 (0.03 px at 2 substeps) in its
		// first step, under the sleep distance, so small groups whose contacts pushed
		// sideways froze in mid-air, held still every step from then on (owner: a
		// brushed pile erased with the eraser left clumps in the air;
		// water_feel_probe erase: 7-11 grains).
		bool stopped = v_pre.y - v.y > 0.5 * params.gravity * params.dt;
		if (stopped && length(s_pred[t] - s_pos[t]) < SLEEP_SPEED * params.dt) {
			s_pred[t] = s_pos[t];
			v = vec2(0.0);
		}
		sep = params.max_separation;
	} else {
		kick = LIQUID_KICK * params.gravity * params.dt;
	}
	vec2 dv = v - v_pre;
	float dv_len = length(dv);
	if (dv_len > 1e-6) {
		vec2 n = dv / dv_len;
		float excess = dot(v, n) - (max(sep, dot(v_pre, n)) + kick);
		if (excess > 0.0) {
			v -= excess * n;
		}
	}
	s_vel[t] = v * exp(-drag * params.dt);
}
