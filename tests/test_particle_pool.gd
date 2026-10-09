## Free-list rules the GPU brush shaders follow (cpu_ref/particle_pool.gd mirrors them):
## spawning stops exactly at the cap, and erasing returns slots for reuse.
extends "res://tests/test_case.gd"

const ParticlePool = preload("res://cpu_ref/particle_pool.gd")


func test_spawn_stops_at_cap() -> void:
	var pool = ParticlePool.new(100)
	expect_eq(pool.spawn(60).size(), 60, "first spawn")
	expect_eq(pool.spawn(60).size(), 40, "second spawn is clamped to the free slots")
	expect_eq(pool.live_count(), 100, "pool full")
	expect_eq(pool.spawn(10).size(), 0, "full pool adds nothing")
	expect_eq(pool.live_count(), 100, "nothing deleted")


func test_erase_returns_slots() -> void:
	var pool = ParticlePool.new(10)
	var slots: PackedInt32Array = pool.spawn(10)
	pool.erase(PackedInt32Array([slots[2], slots[7], slots[7]]))  # double erase is harmless
	expect_eq(pool.live_count(), 8, "two erased")
	var reused: PackedInt32Array = pool.spawn(5)
	expect_eq(reused.size(), 2, "only the freed slots are reused")
	var got := Array(reused)
	got.sort()
	var freed := [slots[2], slots[7]]
	freed.sort()
	expect_eq(got, freed, "the freed slots are the ones reused")
	expect_eq(pool.live_count(), 10, "full again")
