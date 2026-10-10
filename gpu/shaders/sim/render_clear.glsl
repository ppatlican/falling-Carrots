#[compute]
#version 450

// Render 1/2: clear the art-resolution image (one thread per pixel). With the
// hash-grid view on, each cell is shaded by how many particles it holds.

// common.glslinc stamp: Params 108 B, v8. Bump in every .glsl when common.glslinc changes (SPEC 2.7).
#include "common.glslinc"

void main() {
	uint w = uint(params.world_size.x);
	uint idx = gl_GlobalInvocationID.x;
	if (idx >= w * uint(params.world_size.y)) {
		return;
	}
	ivec2 pixel = ivec2(int(idx % w), int(idx / w));
	vec3 color = vec3(0.07, 0.07, 0.09);
	if ((params.view_flags & VIEW_HASH) != 0u) {
		ivec2 c = cell_coord(vec2(pixel) + 0.5);
		float fill = min(float(cell_count[cell_index(c)]) / 8.0, 1.0);
		color = mix(color, vec3(0.1, 0.6, 0.2), fill * 0.8);
		if (pixel.x % int(params.h) == 0 || pixel.y % int(params.h) == 0) {
			color += vec3(0.03);  // faint cell borders
		}
	}
	imageStore(out_image, pixel, vec4(color, 1.0));
}
