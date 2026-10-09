## The GPU smoke readback is checked against smoke_hash.gd, so the mirror itself
## must be right. Expected values were computed independently in Python.
extends "res://tests/test_case.gd"

const SmokeHash = preload("res://gpu/smoke_hash.gd")

const EXPECTED := {
	0: 0,
	1: 1753845952,
	2: 3507691905,
	63: 3550727198,
	64: 3705938106,
	49999: 3934219429,
	0xFFFFFFFF: 1734902346,
}


func test_hash_matches_reference() -> void:
	for x in EXPECTED:
		expect_eq(SmokeHash.hash_u32(x), EXPECTED[x], "hash_u32(%d)" % x)


func test_mul32_wraps() -> void:
	expect_eq(SmokeHash.mul32(0xFFFFFFFF, 0xFFFFFFFF), 1, "mul32(max, max)")
