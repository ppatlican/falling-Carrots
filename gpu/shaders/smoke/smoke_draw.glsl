#[compute]
#version 450

// Smoke test, pass 2: read the buffer from pass 1 and draw one pixel per element
// into a storage texture. The texture is shown on screen through Texture2DRD.

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer Values {
	uint data[];
} values;

layout(set = 0, binding = 1, rgba8) restrict writeonly uniform image2D out_image;

// Same layout as smoke_fill.glsl. 16 bytes.
layout(push_constant, std430) uniform Params {
	uint count;
	uint width;
	float time;
	uint pad;
} params;

void main() {
	uint i = gl_GlobalInvocationID.x;
	if (i >= params.count) {
		return;
	}
	ivec2 pixel = ivec2(int(i % params.width), int(i / params.width));

	// Static per-pixel grain from the hash, plus a moving diagonal wave, so a
	// frozen image (GPU work not running) is easy to spot.
	float grain = float(values.data[i] & 255u) / 255.0;
	float wave = 0.5 + 0.5 * sin(params.time * 3.0 + float(pixel.x) * 0.05 + float(pixel.y) * 0.08);
	vec3 carrot = vec3(1.0, 0.55, 0.1);
	vec3 color = mix(carrot * 0.25, carrot, wave) * (0.75 + 0.25 * grain);

	imageStore(out_image, pixel, vec4(color, 1.0));
}
