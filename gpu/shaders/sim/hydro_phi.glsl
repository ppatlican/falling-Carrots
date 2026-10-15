#[compute]
#version 450

// Hydro 2/4: liquid, powder and body density over rest of each coarse cell (hydro_density in
// hydro.glslinc) and its liquid mass (hydro_mass) from the splatted sums, which it zeroes for
// the next frame.
// One thread per coarse cell.

// common.glslinc stamp: Params 124 B, v20. Bump in every .glsl when common.glslinc changes (SPEC 2.7).
#include "common.glslinc"
#include "hydro.glslinc"

void main() {
	ivec2 size = hydro_size();
	uint c = gl_GlobalInvocationID.x;
	if (c >= uint(size.x * size.y)) {
		return;
	}
	float mass;
	vec4 phi = hydro_density(ivec2(int(c) % size.x, int(c) / size.x), mass);
	float rho = hydro_rho_of(mass, phi.x);
	if (rho != 1.0) {
		// A body at its weight in the liquid that is there (hydro_level), not in water (ADR 0010).
		phi.w = min(phi.w / rho, phi.z);
	}
	hydro_phi[c] = phi;
	hydro_mass[c] = mass;
	for (uint k = 0u; k < HYDRO_CHANNELS; k++) {
		hydro_acc[HYDRO_CHANNELS * c + k] = 0;
	}
}
