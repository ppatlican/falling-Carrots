## Mochi (ADR 0017): dough is a cohesive lump with no rest shape, after Phyzios' Mochi. The pair rule
## pushes where a pair is dense and pulls (at half, by cohesion) where it is sparse, and stops at the
## reach; a lump set on the floor slumps into a mound and rests without creeping; a lump dropped onto
## another merges with it; with no cohesion it spreads flat; it holds a carrot set on it. The shipped
## dough row is mochi and isn't sticky (its cohesion is the pull). 2 substeps, 4 iterations (config.json).
extends "res://tests/test_case.gd"

const FILE_GROUPS := ["mochi"]
const GROUPS := {
	"test_shipped_dough_is_mochi": ["quick", "setup"],
	"test_pair_rule": ["quick"],
	"test_a_lump_slumps_and_rests": ["quick"],
	"test_wet_pair_rule": ["quick"],
}

const MaterialTable = preload("res://cpu_ref/material_table.gd")
const ParticleStep = preload("res://cpu_ref/particle_step.gd")
const SimParams = preload("res://core/sim_params.gd")

const SUBSTEPS := 2
const ITERATIONS := 4
const WORLD := Vector2(80, 40)


func _table():
	var table = MaterialTable.new()
	var problems: PackedStringArray = table.load_file()
	expect(problems.is_empty(), "materials.json problems: %s" % "; ".join(problems))
	return table


func _state() -> Dictionary:
	return {"pos": PackedVector2Array(), "vel": PackedVector2Array(), "material": PackedInt32Array()}


## cols x rows particles of material m on the rest lattice, bottom-centre at `bottom`.
func _block(state: Dictionary, bottom: Vector2, cols: int, rows: int, m: int) -> void:
	for y in rows:
		for x in cols:
			state.pos.append(bottom + Vector2((x - 0.5 * (cols - 1)) * SimParams.SPACING, -y * SimParams.SPACING))
			state.vel.append(Vector2.ZERO)
			state.material.append(m)


func _floor_y(world: Vector2) -> float:
	return world.y - 0.5 * SimParams.SPACING


func _run(sim, state: Dictionary, frames: int) -> void:
	for f in frames * SUBSTEPS:
		sim.step(state, SimParams.DT / SUBSTEPS, ITERATIONS)


## Width, height, centre, fastest speed, how many move over 1 px/s and pieces (joined by pairs within the reach) of the particles
## of material m.
func _measure(state: Dictionary, m: int) -> Dictionary:
	var lo := Vector2(INF, INF)
	var hi := -lo
	var c := Vector2.ZERO
	var fastest := 0.0
	var moving := 0
	var pts := PackedVector2Array()
	for i in state.pos.size():
		if state.material[i] != m:
			continue
		pts.append(state.pos[i])
		lo = lo.min(state.pos[i])
		hi = hi.max(state.pos[i])
		c += state.pos[i]
		fastest = maxf(fastest, state.vel[i].length())
		if state.vel[i].length() > 1.0:
			moving += 1
	var parent := range(pts.size())
	var reach := SimParams.MOCHI_REACH * SimParams.SPACING
	for i in pts.size():
		for j in range(i + 1, pts.size()):
			if pts[i].distance_to(pts[j]) < reach:
				var a: int = i
				while parent[a] != a:
					a = parent[a]
				var b: int = j
				while parent[b] != b:
					b = parent[b]
				parent[maxi(a, b)] = mini(a, b)
	var pieces := 0
	for i in pts.size():
		if parent[i] == i:
			pieces += 1
	return {"size": hi - lo, "centre": c / pts.size(), "fastest": fastest, "moving": moving, "pieces": pieces, "bottom": hi.y}


## Dough is a mochi row (not a body), its sliders are the mochi class's, and its cohesion (the pull)
## doesn't turn stickiness on.
func test_shipped_dough_is_mochi() -> void:
	var table = _table()
	var dough: int = table.id_of("dough")
	expect_eq(table.materials[dough]["class"], "mochi", "dough's class")
	expect_eq(table.class_of(dough), ParticleStep.MOCHI, "the class number the CPU reference reads")
	expect(float(table.materials[dough].cohesion) > 0.0, "dough holds together by its cohesion")
	expect(not ParticleStep.new(WORLD, table).has_stickiness(), "a mochi row's cohesion isn't stickiness")
	expect_eq(MaterialTable.PANEL_FIELDS["mochi"], ["density", "friction", "viscosity", "drag", "cohesion", "adhesion"], "mochi sliders")
	expect_eq(ParticleStep.mochi_rest(), 1.0, "rest density: the four lattice neighbours at w = 0.25")


## The pair rule: no push on the rest lattice; a pull where both ends are sparse, at MOCHI_PULL of the
## push the same deficit would make, and none at cohesion 0; a push where they are dense; nothing from
## the reach on; within MOCHI_MAX_PAIR.
func test_pair_rule() -> void:
	var sp := SimParams.SPACING
	var reach := SimParams.MOCHI_REACH * sp
	var rest := ParticleStep.mochi_rest()
	var target := ParticleStep.mochi_target()
	expect(absf(ParticleStep.mochi_push_size(rest, rest, sp, target, 1.0)) < 1e-6, "a pair on the rest lattice is at rest")
	var pull := ParticleStep.mochi_push_size(0.5, 0.5, 0.9 * reach, target, 1.0)
	expect(pull < 0.0, "a sparse pair pulls: %.4f px" % pull)
	var w := ParticleStep.mochi_w(0.9 * reach)
	var unhalved := ((0.5 + 0.5 - 2.0 * target) * SimParams.MOCHI_KE + w * SimParams.MOCHI_KS) * reach
	expect(absf(pull - SimParams.MOCHI_PULL * unhalved) < 1e-5, "the pull is MOCHI_PULL of it: %.4f against %.4f" % [pull, unhalved])
	expect_eq(ParticleStep.mochi_push_size(0.5, 0.5, 0.9 * reach, target, 0.0), 0.0, "no pull at cohesion 0")
	expect(ParticleStep.mochi_push_size(2.0, 2.0, 0.7 * sp, target, 1.0) > 0.0, "a dense pair pushes")
	expect_eq(ParticleStep.mochi_push_size(0.1, 0.1, reach, target, 1.0), 0.0, "nothing at the reach (a strand breaks there)")
	expect(absf(ParticleStep.mochi_push_size(9.0, 9.0, 0.0, target, 1.0)) <= SimParams.MOCHI_MAX_PAIR * sp + 1e-6, "clamped")


## Against a liquid (ADR 0018): the pair rule with the mochi end's own plus wet density, a push only. A
## dough particle at a flat water face (three dough and one water neighbour at the rest spacing) is
## pushed by nothing; one closed in (dense) pushes; a sparse pair doesn't pull; within
## MOCHI_WET_MAX_PAIR. A water particle mostly closed in by dough counts as enclosed, one lying on it
## doesn't.
func test_wet_pair_rule() -> void:
	var sp := SimParams.SPACING
	var target := ParticleStep.mochi_target()
	expect(absf(ParticleStep.mochi_wet_push_size(0.75, 0.25, sp, target)) < 1e-6, "water on a flat dough face is at rest")
	expect(ParticleStep.mochi_wet_push_size(0.75, 0.75, 0.8 * sp, target) > 0.0, "water pressed into a dough is pushed out")
	expect_eq(ParticleStep.mochi_wet_push_size(0.5, 0.0, 1.2 * sp, target), 0.0, "no pull: water doesn't stick")
	expect(ParticleStep.mochi_wet_push_size(9.0, 9.0, 0.0, target) <= SimParams.MOCHI_WET_MAX_PAIR * sp + 1e-6, "clamped")
	var table = _table()
	var sim = ParticleStep.new(WORLD, table)
	sim._encl = PackedVector2Array([Vector2(1.0, 0.05), Vector2(0.3, 1.0), Vector2.ZERO])
	expect_eq(sim.mochi_enclosed(0), 1.0, "closed in")
	expect_eq(sim.mochi_enclosed(1), 0.0, "lying on a dough")
	expect_eq(sim.mochi_enclosed(2), 0.0, "no dough near")


## Water caught in a dough under water rises out of it (ADR 0018): a 14 x 6 dough on the floor with one
## of its particles in the third row swapped for water, under a 4-row pool; after 2 s the water particle
## is over the dough's top and the dough is one piece on the floor.
func test_water_in_a_dough_rises_out() -> void:
	var table = _table()
	var dough: int = table.id_of("dough")
	var water: int = table.id_of("water")
	var world := Vector2(40, 30)
	var sim = ParticleStep.new(world, table)
	var state := _state()
	var fl := _floor_y(world)
	_block(state, Vector2(world.x * 0.5, fl), 14, 6, dough)
	var caught := 2 * 14 + 7
	state.material[caught] = water
	for y in 4:
		for x in 19:
			state.pos.append(Vector2(1.0 + x * SimParams.SPACING, fl - (6 + y) * SimParams.SPACING))
			state.vel.append(Vector2.ZERO)
			state.material.append(water)
	var start: float = state.pos[caught].y
	_run(sim, state, 120)
	var top := INF
	for i in state.pos.size():
		if state.material[i] == dough:
			top = minf(top, state.pos[i].y)
	var d := _measure(state, dough)
	_report("water caught in a 14x6 dough under a pool: from y %.1f to %.1f in 2 s, the dough's top at %.1f, %d piece(s)"
			% [start, state.pos[caught].y, top, d.pieces])
	expect(state.pos[caught].y < top, "out over the dough's top: %.1f against %.1f" % [state.pos[caught].y, top])
	expect_eq(d.pieces, 1, "the dough stays one piece")


## A 16 x 10 dough block set on the floor has no rest shape to keep: it slumps lower and wider, stays
## one piece, comes to rest and doesn't creep sideways (the pair moves are equal and opposite). At
## rest a few particles still shake in place by ~0.05 px a frame, reading 1-4 px/s, so rest is
## judged by how far they move.
func test_a_lump_slumps_and_rests() -> void:
	var table = _table()
	var dough: int = table.id_of("dough")
	var sim = ParticleStep.new(WORLD, table)
	var state := _state()
	_block(state, Vector2(WORLD.x * 0.5, _floor_y(WORLD)), 16, 10, dough)
	var made := Vector2(15, 9) * SimParams.SPACING
	_run(sim, state, 150)
	var at := _measure(state, dough)
	var at_pos: PackedVector2Array = state.pos.duplicate()
	_run(sim, state, 30)
	var end := _measure(state, dough)
	var moved := 0.0
	for i in at_pos.size():
		moved = maxf(moved, at_pos[i].distance_to(state.pos[i]))
	_report("16x10 dough (%.0f x %.0f px) on the floor: 2.5 s %.1f x %.1f px, 3 s %.1f x %.1f, %d piece(s); in the last 0.5 s the most a particle moved %.3f px (%d read over 1 px/s, fastest %.2f), the centre %.4f px"
			% [made.x, made.y, at.size.x, at.size.y, end.size.x, end.size.y, end.pieces, moved, end.moving, end.fastest, absf(end.centre.x - at.centre.x)])
	expect(end.size.y < 0.95 * made.y and end.size.x > 1.1 * made.x, "slumped: %.1f x %.1f px" % [end.size.x, end.size.y])
	expect(end.size.y > 0.4 * made.y, "not a puddle: %.1f px tall" % end.size.y)
	expect_eq(end.pieces, 1, "one piece")
	expect(moved < 0.5, "at rest: a particle moved %.3f px in 0.5 s" % moved)
	expect(absf(end.centre.x - at.centre.x) < 0.02, "no creep: %.4f px in 0.5 s" % absf(end.centre.x - at.centre.x))


## A 10 x 4 dough dropped onto another resting on the floor merges with it into one piece.
func test_a_lump_dropped_on_another_merges() -> void:
	var table = _table()
	var dough: int = table.id_of("dough")
	var sim = ParticleStep.new(WORLD, table)
	var state := _state()
	_block(state, Vector2(WORLD.x * 0.5, _floor_y(WORLD)), 10, 4, dough)
	_block(state, Vector2(WORLD.x * 0.5, _floor_y(WORLD) - 4 * SimParams.SPACING - 8.0), 10, 4, dough)
	var before := _measure(state, dough)
	_run(sim, state, 90)
	var end := _measure(state, dough)
	_report("10x4 dough dropped 8 px onto another: %d pieces before, %d after 1.5 s, fastest %.3f px/s" % [before.pieces, end.pieces, end.fastest])
	expect_eq(before.pieces, 2, "two pieces to start with")
	expect_eq(end.pieces, 1, "merged into one")
	expect(end.fastest < 1.0, "at rest: %.3f px/s" % end.fastest)


## Cohesion is what holds a lump up: at 0 (the slider's end) the same block spreads into a layer a
## few particles thick, without launching anything.
func test_without_cohesion_a_lump_spreads() -> void:
	var table = _table()
	var dough: int = table.id_of("dough")
	var height := {}
	var fastest := {}
	for cohesion in [1.0, 0.0]:
		table.set_value(dough, "cohesion", cohesion)
		var sim = ParticleStep.new(WORLD, table)
		var state := _state()
		_block(state, Vector2(WORLD.x * 0.5, _floor_y(WORLD)), 12, 8, dough)
		_run(sim, state, 120)
		var m := _measure(state, dough)
		height[cohesion] = m.size.y
		fastest[cohesion] = m.fastest
	_report("12x8 dough after 2 s: %.1f px tall at cohesion 1, %.1f at 0 (fastest %.2f, %.2f px/s)"
			% [height[1.0], height[0.0], fastest[1.0], fastest[0.0]])
	expect(height[0.0] < 0.75 * height[1.0], "spreads flatter without cohesion")
	expect(fastest[0.0] < 20.0, "nothing launched at cohesion 0: %.2f px/s" % fastest[0.0])


## An 8 x 4 carrot set on a 16 x 6 dough is held up: it squashes the dough under it, stays above the
## floor and doesn't get into it.
func test_a_lump_holds_a_carrot() -> void:
	var table = _table()
	var dough: int = table.id_of("dough")
	var carrot: int = table.id_of("carrot")
	var sim = ParticleStep.new(WORLD, table)
	var state := _state()
	var fl := _floor_y(WORLD)
	_block(state, Vector2(WORLD.x * 0.5, fl), 16, 6, dough)
	var box := PackedVector2Array()
	for y in 4:
		for x in 8:
			box.append(Vector2(WORLD.x * 0.5 + (x - 3.5) * SimParams.SPACING, fl - 6 * SimParams.SPACING - 0.5 - y * SimParams.SPACING))
	var id: int = ParticleStep.make_body(state, box, carrot)
	var before := _measure(state, dough)
	_run(sim, state, 120)
	var d := _measure(state, dough)
	var bottom := -INF
	for i in state.pos.size():
		if state.body[i] == id:
			bottom = maxf(bottom, state.pos[i].y)
	_report("8x4 carrot set on a 16x6 dough, 2 s: dough %.1f px tall (made %.1f), carrot's bottom %.1f px over the floor, fastest dough %.3f px/s"
			% [d.size.y, before.size.y, fl - bottom, d.fastest])
	expect(fl - bottom > 2.0 * SimParams.SPACING, "held over the floor: %.1f px" % (fl - bottom))
	expect(d.size.y < before.size.y, "the dough squashes under it")
	expect(d.fastest < 1.0, "at rest: %.3f px/s" % d.fastest)


func _report(line: String) -> void:
	print("    " + line)
