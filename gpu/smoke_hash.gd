## CPU mirror of hash_u32 in gpu/shaders/smoke/smoke_fill.glsl.
## GDScript ints are signed 64-bit, so 32-bit multiplies are split into 16-bit
## halves to stay exact (no reliance on overflow wrapping).
extends RefCounted

const MASK32 := 0xFFFFFFFF


## Exact (a * b) mod 2^32 for 32-bit unsigned a and b.
static func mul32(a: int, b: int) -> int:
	var lo := a * (b & 0xFFFF)
	var hi := (a * (b >> 16)) & 0xFFFF
	return (lo + (hi << 16)) & MASK32


static func hash_u32(x: int) -> int:
	x &= MASK32
	x ^= x >> 16
	x = mul32(x, 0x7feb352d)
	x ^= x >> 15
	x = mul32(x, 0x846ca68b)
	x ^= x >> 16
	return x
