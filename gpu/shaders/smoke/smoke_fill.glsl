#[compute]
#version 450

// Smoke test, pass 1: write a deterministic hash of each element's index.
// gpu/smoke_hash.gd mirrors hash_u32 on the CPU, which is how the async
// readback check verifies the GPU result bit for bit.

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict writeonly buffer Values {
	uint data[];
} values;

// Shared by both smoke shaders. 16 bytes.
layout(push_constant, std430) uniform Params {
	uint count;  // number of valid elements
	uint width;  // output texture width (draw pass only)
	float time;  // seconds (draw pass only)
	uint pad;
} params;

// "lowbias32" integer hash (Chris Wellons). Keep in sync with smoke_hash.gd.
uint hash_u32(uint x) {
	x ^= x >> 16;
	x *= 0x7feb352du;
	x ^= x >> 15;
	x *= 0x846ca68bu;
	x ^= x >> 16;
	return x;
}

void main() {
	uint i = gl_GlobalInvocationID.x;
	if (i >= params.count) {
		return; // last workgroup may run past the end
	}
	values.data[i] = hash_u32(i);
}
