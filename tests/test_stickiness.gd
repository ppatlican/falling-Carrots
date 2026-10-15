## Stickiness (ADR 0011): cohesion and adhesion in the CPU reference. Sticky sand holds to the
## ceiling and as a column, an overloaded sticky block breaks, a sticky clump or block in mid-air
## falls as a dry one, a sticky liquid clings to a wall, a sticky body hangs from the ceiling, and a
## pair is pulled together as its contact pushes it apart. With no stickiness nothing changes.
extends "res://tests/test_case.gd"

## Test groups for run_tests.gd (-- @name); which to run for a change: docs/agents/testing.md.
const FILE_GROUPS := ["stick"]
const GROUPS := {
	"test_shipped_table_has_no_stickiness": ["quick"],
	"test_a_pair_pulls_as_its_contact_pushes": ["quick"],
	"test_sticky_sand_holds_to_the_ceiling": ["quick"],
}

const MaterialTable = preload("res://cpu_ref/material_table.gd")
const ParticleStep = preload("res://cpu_ref/particle_step.gd")
const SimParams = preload("res://core/sim_params.gd")

const WORLD := Vector2(32, 40)
const SUBSTEPS := 2


func _table():
	var table = MaterialTable.new()
	var problems: PackedStringArray = table.load_file()
	expect(problems.is_empty(), "materials.json problems: %s" % "; ".join(problems))
	return table


func _state() -> Dictionary:
	return {"pos": PackedVector2Array(), "vel": PackedVector2Array(), "material": PackedInt32Array()}


## cols x rows particles of material m on the rest lattice, top-left particle at corner.
func _block(state: Dictionary, corner: Vector2, cols: int, rows: int, m: int) -> void:
	for y in rows:
		for x in cols:
			state.pos.append(corner + Vector2(x, y) * SimParams.SPACING)
			state.vel.append(Vector2.ZERO)
			state.material.append(m)


## Steps as the game does (config.json: 2 substeps of 4 iterations). At one substep the lagged
## pull is half as stiff against the contacts, and a damp column that stands at 2 slumps.
func _run(sim, state: Dictionary, frames: int) -> void:
	for f in frames * SUBSTEPS:
		sim.step(state, SimParams.DT / SUBSTEPS, 4)


func _mean_y(state: Dictionary) -> float:
	var sum := 0.0
	for p in state.pos:
		sum += p.y
	return sum / state.pos.size()


## The shipped materials have none, so the step computes none of it (the game is unchanged).
func test_shipped_table_has_no_stickiness() -> void:
	var sim = ParticleStep.new(WORLD, _table())
	expect(not sim.has_stickiness(), "shipped materials have no cohesion or adhesion")


## A grain and a water particle side by side a little apart: each is pulled toward the other, by
## its share of their contact (the water yields to the grain, POWDER_LIQUID_SHARE).
func test_a_pair_pulls_as_its_contact_pushes() -> void:
	var table = _table()
	var sand: int = table.id_of("sand")
	var water: int = table.id_of("water")
	table.set_value(water, "adhesion", 0.5)
	var sim = ParticleStep.new(WORLD, table)
	var pred := PackedVector2Array([Vector2(14, 20), Vector2(15.5, 20)])  # 0.3 px past touching
	var mat := PackedInt32Array([sand, water])
	var body := PackedInt32Array([0, 0])
	var a0: Vector2 = sim._stick_pull(0, pred, mat, body, [], PackedInt32Array([1]))
	var a1: Vector2 = sim._stick_pull(1, pred, mat, body, [], PackedInt32Array([0]))
	expect(a0.x > 0.0 and a1.x < 0.0, "pulled toward each other: %s, %s" % [a0, a1])
	var share := SimParams.POWDER_LIQUID_SHARE
	expect(absf(a0.length() / a1.length() - share / (1.0 - share)) < 1e-3,
			"split as their contact: %.3f, %.3f" % [a0.length(), a1.length()])
	table.set_value(water, "adhesion", 0.0)
	sim = ParticleStep.new(WORLD, table)
	expect_eq(sim._stick_pull(0, pred, mat, body, [], PackedInt32Array([1])), Vector2.ZERO, "no pull without stickiness")


## Two rows of sand against the ceiling, with adhesion and cohesion at 1, stay up; without, they
## fall to the floor.
func test_sticky_sand_holds_to_the_ceiling() -> void:
	var table = _table()
	var sand: int = table.id_of("sand")
	var drop := {}
	for sticky in [true, false]:
		table.set_value(sand, "adhesion", 1.0 if sticky else 0.0)
		table.set_value(sand, "cohesion", 1.0 if sticky else 0.0)
		var sim = ParticleStep.new(WORLD, table)
		var state := _state()
		_block(state, Vector2(8, 1.0), 8, 2, sand)
		var y0 := _mean_y(state)
		_run(sim, state, 60)
		drop[sticky] = _mean_y(state) - y0
	expect(drop[true] < 2.0, "sticky sand on the ceiling dropped %.1f px" % drop[true])
	expect(drop[false] > 25.0, "dry sand fell %.1f px" % drop[false])


## A tall sticky block hanging from the ceiling is more than the pulls can hold (each is capped):
## it tears, and most of it falls to the floor.
func test_an_overloaded_sticky_block_breaks() -> void:
	var table = _table()
	var sand: int = table.id_of("sand")
	table.set_value(sand, "adhesion", 1.0)
	table.set_value(sand, "cohesion", 1.0)
	var sim = ParticleStep.new(WORLD, table)
	var state := _state()
	_block(state, Vector2(8, 1.0), 8, 16, sand)
	_run(sim, state, 90)
	var low := 0
	for p in state.pos:
		if p.y > WORLD.y * 0.5:
			low += 1
	expect(low > state.pos.size() / 2, "%d of %d grains fell to the lower half" % [low, state.pos.size()])


## A sticky clump let go in mid-air falls to the floor as a whole. While the pull still acted on
## touching grains and was split by mass, their contacts pushed them apart mostly upward (STACK_K)
## and the clump rose to the ceiling (_stick_pull, ADR 0011).
func test_a_sticky_clump_in_mid_air_falls() -> void:
	var table = _table()
	var sand: int = table.id_of("sand")
	table.set_value(sand, "cohesion", 1.0)
	var sim = ParticleStep.new(WORLD, table)
	var state := _state()
	_block(state, Vector2(10, 8), 6, 6, sand)
	_run(sim, state, 60)
	var highest := WORLD.y
	for p in state.pos:
		highest = minf(highest, p.y)
	# On the floor the 6 rows reach up to ~10 px above it.
	expect(highest > WORLD.y - 16.0, "the clump's top grain at y %.1f (floor %.0f)" % [highest, WORLD.y])


## A big sticky block on the rest lattice let go in mid-air falls as fast as a dry one. Pulled
## while touching, its pairs were pressed together and their contacts pushed them apart mostly
## upward (STACK_K): it fell 12 px in 30 frames against 46 (stick_shape).
func test_a_sticky_block_falls_freely() -> void:
	var table = _table()
	var sand: int = table.id_of("sand")
	var drop := {}
	for c in [1.0, 0.0]:
		table.set_value(sand, "cohesion", c)
		var sim = ParticleStep.new(Vector2(80, 120), table)
		var state := _state()
		_block(state, Vector2(10, 4), 30, 20, sand)
		var y0 := _mean_y(state)
		_run(sim, state, 30)
		drop[c] = _mean_y(state) - y0
	expect(drop[1.0] > 0.95 * drop[0.0], "sticky block fell %.1f px, dry %.1f" % [drop[1.0], drop[0.0]])


## A column of damp sand (cohesion 1) stands, where a dry one slumps into a pile. Hex-packed, as
## sand settles; on the square lattice even dry sand stands.
func test_damp_sand_holds_a_column() -> void:
	var table = _table()
	var sand: int = table.id_of("sand")
	var world := Vector2(64, 40)
	var width := {}
	for c in [1.0, 0.0]:
		table.set_value(sand, "cohesion", c)
		var sim = ParticleStep.new(world, table)
		var state := _state()
		for y in 14:
			for x in 6:
				state.pos.append(Vector2(26 + x * SimParams.SPACING + (1.0 if y % 2 == 1 else 0.0), world.y - 1.0 - y * 1.75))
				state.vel.append(Vector2.ZERO)
				state.material.append(sand)
		_run(sim, state, 100)
		var lo := world.x
		var hi := 0.0
		for p in state.pos:
			if p.y > world.y - 4.0:  # the bottom row
				lo = minf(lo, p.x)
				hi = maxf(hi, p.x)
		width[c] = hi - lo
	expect(width[1.0] < 16.0, "damp column's base %.1f px wide (started 11)" % width[1.0])
	expect(width[0.0] > 30.0, "dry sand slumps: base %.1f px" % width[0.0])


## Water with adhesion 1 against the left wall clings and creeps down it; without, it falls. Only
## the column touching the wall is judged: the outer one sticks to nothing (water's cohesion is 0).
func test_sticky_liquid_clings_to_a_wall() -> void:
	var table = _table()
	var water: int = table.id_of("water")
	var drop := {}
	for adh in [1.0, 0.0]:
		table.set_value(water, "adhesion", adh)
		var sim = ParticleStep.new(WORLD, table)
		var state := _state()
		_block(state, Vector2(1.0, 4.0), 2, 4, water)
		var y0 := _wall_column_y(state)
		_run(sim, state, 20)
		drop[adh] = _wall_column_y(state) - y0
	expect(drop[1.0] < 0.4 * drop[0.0], "sticky water on the wall slid %.1f px, plain water fell %.1f" % [drop[1.0], drop[0.0]])


## Mean y of the particles that started against the left wall (_block's even indices for 2 columns).
func _wall_column_y(state: Dictionary) -> float:
	var sum := 0.0
	for i in range(0, state.pos.size(), 2):
		sum += state.pos[i].y
	return sum / (state.pos.size() / 2)


## A carrot with adhesion 1 under the ceiling hangs there; with none it falls. (On a side wall a
## body slides: each member's wall friction only holds its own weight, ADR 0011 Known limits.)
func test_sticky_body_hangs_from_the_ceiling() -> void:
	var table = _table()
	var carrot: int = table.id_of("carrot")
	var drop := {}
	for adh in [1.0, 0.0]:
		table.set_value(carrot, "adhesion", adh)
		var sim = ParticleStep.new(WORLD, table)
		var state := _state()
		var box := PackedVector2Array()
		for y in 3:
			for x in 4:
				box.append(Vector2(12.0 + x * SimParams.SPACING, 1.0 + y * SimParams.SPACING))
		var id: int = ParticleStep.make_body(state, box, carrot)
		expect(id > 0, "body made")
		var y0 := _mean_y(state)
		_run(sim, state, 30)
		drop[adh] = _mean_y(state) - y0
	expect(drop[1.0] < 1.0, "sticky carrot under the ceiling dropped %.1f px" % drop[1.0])
	expect(drop[0.0] > 15.0, "plain carrot fell %.1f px" % drop[0.0])
