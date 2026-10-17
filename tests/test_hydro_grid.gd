## CPU reference density projection grid (ParticleStep._hydro_solve) on hand-made cells: no
## particles, so these run in well under a second. The world is 4 x 8 cells of 16 px; the
## top row is air and the rest a pool, with sand bed and body cells placed by each test.
extends "res://tests/test_case.gd"

## Test groups for run_tests.gd (-- @name); which to run for a change: docs/agents/testing.md.
const FILE_GROUPS := ["hydro", "liquids", "quick"]

const MaterialTable = preload("res://cpu_ref/material_table.gd")
const ParticleStep = preload("res://cpu_ref/particle_step.gd")
const SimParams = preload("res://core/sim_params.gd")

const WORLD := Vector2(64, 128)
const COLS := 4
const ROWS := 8


## A pocket of water closed in by sand bed and the wall on the floor of a pool reads the
## pool's pressure at its depth: the bed's p is the water's continued into its pores. As a
## sealed wall the bed left the pocket's p free (any p solved it), so it kept what it had:
## a cork wedged in a corner under sand had its faces read 0 there, or 5.8 million once the
## pocket was squeezed (body_probe sandcorks, 2026-10-13).
func test_water_pocket_in_a_sand_bed_reads_the_pool_pressure() -> void:
	var phi := _pool()
	for c in [Vector2i(0, 5), Vector2i(1, 5), Vector2i(1, 6), Vector2i(1, 7)]:
		phi[c.y * COLS + c.x] = Vector4(0.2, 1.1, 0.0, 0.0)  # sand bed with pore water
	var p := _solve(phi)
	var head := SimParams.GRAVITY * ParticleStep.hydro_cell_size()
	for y in [6, 7]:
		var pocket: float = p[y * COLS]
		var open: float = p[y * COLS + 3]
		expect(absf(pocket - open) < 0.25 * head, "row %d: pocket p %.0f, open water beside the bed %.0f (head %.0f)" % [y, pocket, open, head])


## A floor cell that a body and sand partly fill, with a little water, under a body cell, is
## under water, not air: its p is the pool's. Read as air, it put p = 0 on the floor beside a
## cork wedged under sand, and the cork's faces read 0 and it heaved (body_probe sandcorks).
func test_cell_partly_filled_by_a_body_and_sand_under_water_is_not_air() -> void:
	var phi := _pool()
	phi[6 * COLS] = Vector4(0.2, 0.0, 0.7, 0.35)  # the body, bed
	phi[7 * COLS] = Vector4(0.2, 0.3, 0.2, 0.1)  # beside it: fill 0.41, level 0.27
	var p := _solve(phi)
	var head := SimParams.GRAVITY * ParticleStep.hydro_cell_size()
	expect(absf(p[7 * COLS] - p[7 * COLS + 2]) < 0.5 * head,
			"floor cell under the body: p %.0f, open water %.0f (head %.0f)" % [p[7 * COLS], p[7 * COLS + 2], head])


## The cell under a floating body's bottom is under a floater however many cells the body holds:
## a 40 px cork holds body in 4 (the tent smear adds one), and a walk stopped after 3 missed the
## air over it, so its water was never pulled up and it floated over 15-18 px of air (body_probe
## waterbig, ADR 0003 item 18). The same body with water over it isn't a floater.
func test_cell_under_a_tall_floater_is_under_a_floater() -> void:
	var phi := _pool()
	for y in [0, 1]:
		phi[y * COLS + 1] = Vector4.ZERO
	for c in [Vector2i(1, 2), Vector2i(1, 3), Vector2i(1, 4), Vector2i(1, 5)]:
		phi[c.y * COLS + c.x] = Vector4(0.0, 0.0, [0.1, 0.9, 1.0, 0.55][c.y - 2], 0.0)
	phi[6 * COLS + 1] = Vector4(0.3, 0.0, 0.0, 0.0)
	var size := Vector2i(COLS, ROWS)
	expect(ParticleStep.hydro_under_floater(phi, Vector2i(1, 6), size), "cell under a body 4 cells tall, air over it")
	phi[1 * COLS + 1] = Vector4(1.0, 0.0, 0.0, 0.0)
	expect(not ParticleStep.hydro_under_floater(phi, Vector2i(1, 6), size), "the same body with water over it")


## A cell under full water with room left beside a dough is pulled full, as in open water: the
## air a dough left sinking through a pool, unpulled, stayed under the liquid for good (up to
## ~20 px at a wall, ADR 0020). Beside a body it isn't (water keeps a contact gap from a body).
func test_room_beside_mochi_is_pulled_beside_a_body_not() -> void:
	var phi := _pool()
	phi[6 * COLS + 1] = Vector4(0.5, 0.0, 0.2, 0.2)  # room 0.3
	var mochi := PackedFloat32Array()
	mochi.resize(phi.size())
	mochi[6 * COLS + 1] = 0.2
	var head := SimParams.GRAVITY * ParticleStep.hydro_cell_size()
	var open_row := 6 * COLS + 3
	var p_mochi := _solve(phi, mochi)
	var p_body := _solve(phi)
	expect(p_mochi[6 * COLS + 1] < p_mochi[open_row] - 0.25 * head,
			"beside mochi: p %.0f, open water %.0f (head %.0f)" % [p_mochi[6 * COLS + 1], p_mochi[open_row], head])
	expect(absf(p_body[6 * COLS + 1] - p_body[open_row]) < 0.25 * head,
			"beside a body: p %.0f, open water %.0f (head %.0f)" % [p_body[6 * COLS + 1], p_body[open_row], head])


## Where a mochi particle takes the grid's push (ADR 0021): a dough lump in open water reads mostly
## liquid round it (the 3 x 3 cells) and takes it all; dough round a pocket of water caught deep in a
## dough bed reads mostly mochi and takes none.
func test_mochi_lifted_in_open_water_not_round_a_pocket() -> void:
	var table = MaterialTable.new()
	table.load_file()
	var sim = ParticleStep.new(WORLD, table)
	var cell := Vector2i(1, 4)
	var phi := _pool()
	var mochi := PackedFloat32Array()
	mochi.resize(phi.size())
	phi[4 * COLS + 1] = Vector4(0.4, 0.0, 0.6, 0.0)  # a lump in the pool
	mochi[4 * COLS + 1] = 0.6
	var lump: float = sim._hydro_liquid_share(cell, phi, mochi)
	for y in range(1, ROWS):
		for x in COLS:
			phi[y * COLS + x] = Vector4(0.0, 0.0, 1.0, 0.0)  # a dough bed under one row of water
			mochi[y * COLS + x] = 1.0
	phi[4 * COLS + 1] = Vector4(0.3, 0.0, 0.7, 0.0)  # a pocket of water in it
	mochi[4 * COLS + 1] = 0.7
	var pocket: float = sim._hydro_liquid_share(cell, phi, mochi)
	print("    liquid share round a lump in water %.2f (gate %.2f), round a pocket in a dough bed %.2f (gate %.2f)"
			% [lump, ParticleStep.mochi_share_gate(lump), pocket, ParticleStep.mochi_share_gate(pocket)])
	expect(ParticleStep.mochi_share_gate(lump) == 1.0, "a lump in open water takes the whole push")
	expect(ParticleStep.mochi_share_gate(pocket) == 0.0, "dough round a pocket in a bed takes none")


## Air in the top row, water at rest density below.
func _pool() -> PackedVector4Array:
	var phi := PackedVector4Array()
	phi.resize(COLS * ROWS)
	for c in phi.size():
		phi[c] = Vector4(1.0, 0.0, 0.0, 0.0) if c >= COLS else Vector4.ZERO
	return phi


## p after 100 frames of sweeps, from 0. mochi: each cell's mochi volume (ADR 0020), none by default.
func _solve(phi: PackedVector4Array, mochi := PackedFloat32Array()) -> PackedFloat32Array:
	var table = MaterialTable.new()
	table.load_file()
	var sim = ParticleStep.new(WORLD, table)
	var p := PackedFloat32Array()
	p.resize(phi.size())
	for f in 100:
		sim._hydro_solve(phi, p, SimParams.DT, PackedFloat32Array(), mochi)
	return p
