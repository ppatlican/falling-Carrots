## Liquids of different density (ADR 0010): mass-weighted PBF and density projection grid in
## the CPU reference. A light liquid poured under water rises over it, a heavy one poured on
## water sinks under it, and the grid's pressure in a pool of one liquid scales with its density.
extends "res://tests/test_case.gd"

## Test groups for run_tests.gd (-- @name); which to run for a change: docs/agents/testing.md.
const FILE_GROUPS := ["liquids", "hydro"]
const GROUPS := {"test_liquid_pool_pressure_scales_with_its_density": ["quick"]}

const MaterialTable = preload("res://cpu_ref/material_table.gd")
const ParticleStep = preload("res://cpu_ref/particle_step.gd")
const SimParams = preload("res://core/sim_params.gd")

const WORLD := Vector2(32, 40)
const FRAMES := 420
const MIXED_FRAMES := 480


## Oil (0.8) on the floor under as much water: it rises through it and ends as the top layer.
## With one global density (before ADR 0010) the two stayed as poured.
func test_oil_under_water_rises_to_the_top() -> void:
	var table = _table()
	var gap := _layer_gap(table, table.id_of("oil"), table.id_of("water"))
	# y grows downward: oil on top means a smaller mean y.
	expect(gap > 3.0, "oil above water: water mean y minus oil mean y %.1f px" % gap)


## Water made heavy (the slider's top end, 2) poured onto oil sinks under it.
func test_heavy_liquid_on_oil_sinks_under_it() -> void:
	var table = _table()
	var water: int = table.id_of("water")
	table.set_value(water, "density", 2.0)
	var gap := _layer_gap(table, table.id_of("oil"), water)
	expect(gap > 4.0, "heavy water under oil: water mean y minus oil mean y %.1f px" % gap)


## Oil and water mixed as finely as the lattice allows (a checkerboard, 14 x 20, 40 px deep)
## separate, oil on top. The block tests start as two layers; the owner's report (2026-10-15,
## "oil does not float above water; they just mix") asked whether a mixed start layers too.
## The world is 72 px tall so the floor sits at a grid cell's centre, as in the game's 360 px:
## at 80 px the grid's push fades to 0 over the bottom 8 px and holds oil on the floor.
func test_mixed_oil_and_water_separate() -> void:
	var table = _table()
	var oil: int = table.id_of("oil")
	var water: int = table.id_of("water")
	var world := Vector2(32, 72)
	var sim = ParticleStep.new(world, table)
	var state := {"pos": PackedVector2Array(), "vel": PackedVector2Array(), "material": PackedInt32Array()}
	var rows := 20
	for y in rows:
		for x in 14:
			state.pos.append(Vector2(3.0 + x * SimParams.SPACING, world.y - 1.0 - y * SimParams.SPACING))
			state.vel.append(Vector2.ZERO)
			state.material.append(oil if (x + y) % 2 == 0 else water)
	for f in MIXED_FRAMES:
		sim.step(state, SimParams.DT, 4)
	var sum := {oil: 0.0, water: 0.0}
	var n := {oil: 0, water: 0}
	for i in state.pos.size():
		sum[state.material[i]] += state.pos[i].y
		n[state.material[i]] += 1
	var water_y: float = sum[water] / n[water]
	var above := 0
	for i in state.pos.size():
		if state.material[i] == oil and state.pos[i].y < water_y:
			above += 1
	# Fully layered: 10 rows of each, 20 px apart; mixed: 0 and half the oil above.
	var gap: float = water_y - sum[oil] / n[oil]
	expect(gap > 14.0, "mixed start: water mean y minus oil mean y %.1f px (20 when layered)" % gap)
	expect(float(above) / n[oil] > 0.85, "mixed start: %.2f of the oil above the water's mean y" % (float(above) / n[oil]))


## The grid's p in a pool of one liquid is its density times water's (the mass-weighted solve:
## the push over the particle's mass is then the same), on hand-made cells.
func test_liquid_pool_pressure_scales_with_its_density() -> void:
	var table = _table()
	var sim = ParticleStep.new(Vector2(64, 128), table)
	var cols := 4
	var phi := PackedVector4Array()
	phi.resize(cols * 8)
	for c in phi.size():
		phi[c] = Vector4(1.0, 0.0, 0.0, 0.0) if c >= cols else Vector4.ZERO
	var p_water := _solve(sim, phi, PackedFloat32Array())
	for rho in [0.5, 2.0]:
		var cell_rho := PackedFloat32Array()
		cell_rho.resize(phi.size())
		cell_rho.fill(rho)
		var p := _solve(sim, phi, cell_rho)
		for y in [3, 7]:
			var c: int = y * cols + 1
			expect(absf(p[c] - rho * p_water[c]) < 0.02 * rho * p_water[c],
					"density %.1f, row %d: p %.0f, water's %.0f" % [rho, y, p[c], p_water[c]])


## Heavy mean y minus light mean y after FRAMES: a block of each, 14 x 5, in a 32 x 40 box, the
## light one on the floor and the heavy one poured on it (-11 px as placed, +11 fully swapped).
func _layer_gap(table, light: int, heavy: int) -> float:
	var sim = ParticleStep.new(WORLD, table)
	var state := {"pos": PackedVector2Array(), "vel": PackedVector2Array(), "material": PackedInt32Array()}
	_block(state, heavy, Vector2(3, 18), 14, 5)
	_block(state, light, Vector2(3, 29), 14, 5)
	for f in FRAMES:
		sim.step(state, SimParams.DT, 4)
	var sum := {light: 0.0, heavy: 0.0}
	var n := {light: 0, heavy: 0}
	for i in state.pos.size():
		var p: Vector2 = state.pos[i]
		expect(p.is_finite() and p.x > 0.0 and p.x < WORLD.x and p.y > 0.0 and p.y < WORLD.y,
				"particle %d in bounds: %s" % [i, p])
		sum[state.material[i]] += p.y
		n[state.material[i]] += 1
	return sum[heavy] / n[heavy] - sum[light] / n[light]


func _table():
	var table = MaterialTable.new()
	table.load_file()
	return table


func _block(state: Dictionary, material: int, origin: Vector2, cols: int, rows: int) -> void:
	for y in rows:
		for x in cols:
			state.pos.append(origin + Vector2(x, y) * SimParams.SPACING)
			state.vel.append(Vector2.ZERO)
			state.material.append(material)


## p after 100 frames of sweeps, from 0.
func _solve(sim, phi: PackedVector4Array, rho: PackedFloat32Array) -> PackedFloat32Array:
	var p := PackedFloat32Array()
	p.resize(phi.size())
	for f in 100:
		sim._hydro_solve(phi, p, SimParams.DT, rho)
	return p
