## CPU reference particle step: a block of sand dropped onto water in a small box.
## After settling, sand is under the water, everything is in bounds and nearly
## still, and particles haven't collapsed onto each other.
extends "res://tests/test_case.gd"

const MaterialTable = preload("res://cpu_ref/material_table.gd")
const ParticleStep = preload("res://cpu_ref/particle_step.gd")
const SimParams = preload("res://core/sim_params.gd")

const WORLD := Vector2(40, 40)
const FRAMES := 240


func test_sand_sinks_through_water_and_settles() -> void:
	var table = MaterialTable.new()
	table.load_file()
	var sand: int = table.id_of("sand")
	var water: int = table.id_of("water")
	var sim = ParticleStep.new(WORLD, table)
	var state := {"pos": PackedVector2Array(), "vel": PackedVector2Array(), "material": PackedInt32Array()}
	_block(state, water, Vector2(4, 20), 16, 10)  # water on the floor
	_block(state, sand, Vector2(10, 2), 10, 6)    # sand above it
	var count: int = state.pos.size()

	for f in FRAMES:
		sim.step(state, SimParams.DT, 4)

	expect_eq(state.pos.size(), count, "particle count unchanged")
	var mean_y := {sand: 0.0, water: 0.0}
	var n := {sand: 0, water: 0}
	var crowded := 0
	for i in count:
		var p: Vector2 = state.pos[i]
		expect(p.x > 0.0 and p.x < WORLD.x and p.y > 0.0 and p.y < WORLD.y and p.is_finite(),
				"particle %d in bounds: %s" % [i, p])
		expect(state.vel[i].length() < 30.0, "particle %d settled: speed %.1f" % [i, state.vel[i].length()])
		mean_y[state.material[i]] += p.y
		n[state.material[i]] += 1
		for j in range(i + 1, count):
			if p.distance_to(state.pos[j]) < 0.4 * SimParams.SPACING:
				crowded += 1
	# y grows downward: sand below water means a larger mean y.
	expect(mean_y[sand] / n[sand] > mean_y[water] / n[water] + 3.0,
			"sand under water: sand y %.1f, water y %.1f" % [mean_y[sand] / n[sand], mean_y[water] / n[water]])
	expect(crowded < count / 10, "%d of %d particles collapsed onto a neighbour" % [crowded, count])


func _block(state: Dictionary, material: int, origin: Vector2, cols: int, rows: int) -> void:
	for y in rows:
		for x in cols:
			state.pos.append(origin + Vector2(x, y) * SimParams.SPACING)
			state.vel.append(Vector2.ZERO)
			state.material.append(material)
