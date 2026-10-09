#[compute]
#version 450

// Velocity 1/3 (spec 2.6 step 5): velocity from the solved move, times (1 - drag).
// Powders: the solver's push-out may stop a grain but not launch it faster than
// max_separation in the push direction (keeps settled sand from hopping).
// Powders also sleep (Macklin et al. 2014, "particle sleeping"): a grain the solver
// stopped (its move differs from the predicted one) that moved less than
// SLEEP_DISTANCE this step stays where it started, with zero velocity. Without it a
// settled 50k pile never came to rest: the few Jacobi iterations leave ~2.5 px/s of
// back-and-forth in every grain ("pudding", Milestone 2 GPU measurement). It is decided
// again each step, so a grain wakes as soon as it is hit or loses its support.

// common.glslinc stamp: Params 108 B, v3. Bump in every .glsl when common.glslinc changes (SPEC 2.7).
#include "common.glslinc"

// Largest move per step (px) that still counts as resting. Below the free-fall move of
// one step from rest (gravity * dt^2 = 0.11 px). Mirror: SimParams.SLEEP_DISTANCE.
const float SLEEP_DISTANCE = 0.1;

void main() {
	uint t;
	if (!sorted_particle(t)) {
		return;
	}
	float drag = materials[s_material(t)].phys.w;
	vec2 v = (s_pred[t] - s_pos[t]) / params.dt;
	if (s_class(t) == CLASS_POWDER) {
		vec2 v_pre = s_vel[t];  // velocity predict moved with (after gravity, before the solver)
		float max_v = params.max_step / params.dt;
		if (length(v_pre) > max_v) {
			v_pre *= max_v / length(v_pre);
		}
		bool stopped = length(v - v_pre) > 0.5 * params.gravity * params.dt;
		if (stopped && length(s_pred[t] - s_pos[t]) < SLEEP_DISTANCE) {
			s_pred[t] = s_pos[t];
			v = vec2(0.0);
		}
		vec2 dv = v - v_pre;
		float dv_len = length(dv);
		if (dv_len > 1e-6) {
			vec2 n = dv / dv_len;
			float excess = dot(v, n) - max(params.max_separation, dot(v_pre, n));
			if (excess > 0.0) {
				v -= excess * n;
			}
		}
	}
	s_vel[t] = v * (1.0 - drag);
}
