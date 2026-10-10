#[compute]
#version 450

// Hydro 3/4: one SOR sweep over the even cells ((x + y) % 2 == 0), see hydro.glslinc.

// common.glslinc stamp: Params 108 B, v7. Bump in every .glsl when common.glslinc changes (SPEC 2.7).
#include "common.glslinc"
#include "hydro.glslinc"

void main() {
	hydro_sweep(0u);
}
