#[compute]
#version 450

// Velocity 1/3 (spec 2.6 step 5): velocity from the solved move, times (1 - drag).
// Powders: the solver's push-out may stop a grain but not launch it faster than
// max_separation in the push direction (keeps settled sand from hopping).

#include "common.glslinc"

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
