## CPU reference: plasticity (ADR 0012). A soft body whose material has plasticity keeps the
## shape it is pressed or dropped into (dough), where a jelly springs back, and a resting one
## doesn't creep. Jelly with its stiffness and plasticity set here, as the parameter panel does,
## so the numbers don't follow a shipped row, and on regions (ADR 0005) as ADR 0012's dough was (dough is mochi since ADR 0017): the
## shipped jelly is on pair joints (ADR 0016), not yet checked with plasticity. 2 substeps, 4 iterations (config.json).
extends "res://tests/test_case.gd"

const FILE_GROUPS := ["plastic"]
const GROUPS := {
	"test_plasticity_0_leaves_the_rest_shape_alone": ["quick"],
	"test_dough_keeps_a_dent": ["soft"],
	"test_dropped_dough_flattens_and_keeps_it": ["soft"],
}

const MaterialTable = preload("res://cpu_ref/material_table.gd")
const ParticleStep = preload("res://cpu_ref/particle_step.gd")
const ParticleSim = preload("res://gpu/particle_sim.gd")
const SimParams = preload("res://core/sim_params.gd")

const SUBSTEPS := 2
const ITERATIONS := 4
## A dough for these tests: soft enough to dent under a carrot, fully plastic.
const DOUGH := {"stiffness": 0.5, "plasticity": 1.0}

var _jelly: int
var _carrot: int
var _sand: int


## Plasticity 0 (every shipped material): a squashed jelly's rest offsets stay exactly as made.
func test_plasticity_0_leaves_the_rest_shape_alone() -> void:
	var world := Vector2(60, 40)
	var sim = _sim(world, {"stiffness": 0.5, "plasticity": 0.0})
	var state := _empty()
	var fl := _floor_y(world)
	var id: int = ParticleStep.make_body(state, _box(Vector2(30, fl), 12, 8), _jelly)
	ParticleStep.make_body(state, _box(Vector2(30, fl - 8 * SimParams.SPACING - 0.5), 12, 8), _carrot)
	var rest: PackedVector2Array = state.rest.duplicate()
	var edge: PackedVector2Array = state.edge.duplicate()
	for f in 30:
		_frame(sim, state)
	var moved := 0
	for m in _live(state, id):
		if state.rest[m] != rest[m] or state.edge[m] != edge[m]:
			moved += 1
	_report("jelly at plasticity 0 under a carrot, 30 frames: %d of %d rest offsets or outlines changed" % [moved, _live(state, id).size()])
	expect_eq(moved, 0, "rest offsets and outlines changed")


## A 12 x 8 carrot set on a 12 x 8 dough presses it flat; 4 s after the carrot is erased the dough
## is still lower than a jelly of the same stiffness that had the same carrot on it.
func test_dough_keeps_a_dent() -> void:
	var r_jelly := _dent({"stiffness": DOUGH.stiffness, "plasticity": 0.0})
	var r_dough := _dent(DOUGH)
	_report("12x8 under a 12x8 carrot, erased after 1.5 s, 4 s later: jelly %.2f px tall (rest shape %.2f), dough %.2f (rest shape %.2f); the rest shape was %.2f"
			% [r_jelly.height, r_jelly.rest_h, r_dough.height, r_dough.rest_h, 7 * SimParams.SPACING])
	expect(r_dough.rest_h < 0.9 * 7 * SimParams.SPACING, "the dough's rest shape keeps the dent, over 10%% lower: %.2f px" % r_dough.rest_h)
	expect(r_dough.height < r_jelly.height - 1.0, "the dough stays over 1 px lower than the jelly: %.2f against %.2f" % [r_dough.height, r_jelly.height])
	expect(r_dough.speed < 1.0, "the dough comes to rest, every member under 1 px/s: %.2f" % r_dough.speed)
	_expect_lattice(r_dough.state, r_dough.id, r_dough.links)
	_expect_outline(r_dough.state, r_dough.id)


## A 16 x 10 dough dropped 40 px lands flatter and stays so, at rest.
func test_dropped_dough_flattens_and_keeps_it() -> void:
	var world := Vector2(60, 70)
	var sim = _sim(world, DOUGH)
	var state := _empty()
	var fl := _floor_y(world)
	var id: int = ParticleStep.make_body(state, _box(Vector2(30, fl - 40.0), 16, 10), _jelly)
	var links := _links(state, id)
	for f in 360:
		_frame(sim, state)
	var rest_h := _rest_height(state, id)
	var speed := _max_member_speed(state, id)
	_report("16x10 dough dropped 40 px, 6 s: rest shape %.2f px tall (was %.2f), %.2f px tall now, fastest member %.2f px/s"
			% [rest_h, 9 * SimParams.SPACING, _height(state, id), speed])
	expect(rest_h < 0.9 * 9 * SimParams.SPACING, "it lands over 10%% flatter and keeps it: rest shape %.2f px tall" % rest_h)
	expect(speed < 1.0, "it comes to rest, every member under 1 px/s: %.2f" % speed)
	_expect_lattice(state, id, links)
	_expect_outline(state, id)


## A 30 x 20 dough set on the floor settles once and then keeps its rest shape: from 3 s to 5 s no
## rest offset moves (about their mean) more than a hundredth of a pixel.
func test_resting_dough_does_not_creep() -> void:
	var world := Vector2(80, 60)
	var sim = _sim(world, DOUGH)
	var state := _empty()
	var id: int = ParticleStep.make_body(state, _box(Vector2(40, _floor_y(world)), 30, 20), _jelly)
	for f in 180:
		_frame(sim, state)
	var before: PackedVector2Array = state.rest.duplicate()
	var h3 := _rest_height(state, id)
	for f in 120:
		_frame(sim, state)
	var most := _most_moved(state, id, before)
	_report("30x20 dough on the floor: rest shape %.2f px tall at 3 s (was %.2f), %.2f at 5 s; most a rest offset moved from 3 s to 5 s %.4f px"
			% [h3, 19 * SimParams.SPACING, _rest_height(state, id), most])
	expect(most < 0.01, "no creep at rest: rest offsets still within 0.01 px from 3 s to 5 s: %.4f" % most)


## ADR 0009's weak spot (a soft body digging into sand) at the slider's softest corner: a 12 x 4
## dough at stiffness 0.2 and plasticity 1 set on a sand bed rests on it.
func test_soft_dough_rests_on_sand() -> void:
	var world := Vector2(64, 80)
	var sim = _sim(world, {"stiffness": 0.2, "plasticity": 1.0})
	var state := _lattice(world, 28, 10, _sand)
	for f in 60:
		_frame(sim, state)
	var top := _top_of(state, _sand)
	var id: int = ParticleStep.make_body(state, _box(Vector2(32, top - SimParams.SPACING - 0.5), 12, 4), _jelly)
	var speed := 0.0
	for f in 420:
		_frame(sim, state)
		if f >= 360:
			speed = maxf(speed, _max_member_speed(state, id))
	var sunk := _lowest(state, id) - top
	_report("12x4 dough (stiffness 0.2, plasticity 1) on a sand bed, 420 frames: fastest member over the last 60 frames %.2f px/s, lowest member %.2f px below the bed's top, rest shape %.2f px tall (was %.2f)"
			% [speed, sunk, _rest_height(state, id), 3 * SimParams.SPACING])
	expect(speed < 1.0, "it rests, every member under 1 px/s: %.2f" % speed)
	expect(sunk < 3.0 * SimParams.SPACING, "it doesn't dig into the bed, lowest member under 3 spacings below its top: %.2f px" % sunk)


## The GPU's split readback (ADR 0012 item 5): rest offsets decoded from a rest_offset readback
## for the slots of a member range.
func test_split_reads_the_rest_offsets_back() -> void:
	var data := PackedByteArray()
	data.resize(4 * 16)
	data.encode_float(2 * 16, 1.5)
	data.encode_float(2 * 16 + 4, -2.25)
	data.encode_float(2 * 16 + 8, 9.0)  # the outline (zw) isn't the rest offset
	data.encode_float(3 * 16, 4.0)
	var got: PackedVector2Array = ParticleSim.rest_from_readback(PackedInt32Array([2, 3, 99]), data)
	expect_eq(got, PackedVector2Array([Vector2(1.5, -2.25), Vector2(4.0, 0.0), Vector2.ZERO]),
			"rest offsets of slots 2, 3 and one past the readback")


# --- Helpers -----------------------------------------------------------------------

## A 12 x 8 body of jelly with these parameters under a 12 x 8 carrot for 90 frames; the carrot
## is erased and it runs 240 more.
func _dent(jelly: Dictionary) -> Dictionary:
	var world := Vector2(60, 40)
	var sim = _sim(world, jelly)
	var state := _empty()
	var fl := _floor_y(world)
	var id: int = ParticleStep.make_body(state, _box(Vector2(30, fl), 12, 8), _jelly)
	var carrot: int = ParticleStep.make_body(state, _box(Vector2(30, fl - 8 * SimParams.SPACING - 0.5), 12, 8), _carrot)
	var links := _links(state, id)
	for f in 90:
		_frame(sim, state)
	# The carrot's particles come after the dough's, so erasing them leaves the dough's indices.
	ParticleStep.erase_particles(state, _live(state, carrot))
	for f in 240:
		_frame(sim, state)
	return {"height": _height(state, id), "rest_h": _rest_height(state, id), "speed": _max_member_speed(state, id),
			"state": state, "id": id, "links": links}


func _sim(world: Vector2, jelly: Dictionary):
	var table = MaterialTable.new()
	var problems: PackedStringArray = table.load_file()
	expect(problems.is_empty(), "materials.json: %s" % "; ".join(problems))
	_jelly = table.id_of("jelly")
	_carrot = table.id_of("carrot")
	_sand = table.id_of("sand")
	table.set_soft_model(_jelly, "regions")
	for column in jelly:
		table.set_value(_jelly, column, jelly[column])
	return ParticleStep.new(world, table)


func _frame(sim, state: Dictionary) -> void:
	for s in SUBSTEPS:
		sim.step(state, SimParams.DT / SUBSTEPS, ITERATIONS)


func _empty() -> Dictionary:
	return {"pos": PackedVector2Array(), "vel": PackedVector2Array(), "material": PackedInt32Array()}


func _box(bottom: Vector2, cols: int, rows: int) -> PackedVector2Array:
	var sp := SimParams.SPACING
	var size := Vector2(cols - 1, rows - 1) * sp
	var centre := bottom - Vector2(0.0, 0.5 * size.y)
	var out := PackedVector2Array()
	for y in rows:
		for x in cols:
			out.append(centre + Vector2(x, y) * sp - 0.5 * size)
	return out


func _lattice(world: Vector2, cols: int, rows: int, material: int) -> Dictionary:
	var sp := SimParams.SPACING
	var state := _empty()
	var x0 := 0.5 * (world.x - (cols - 1) * sp)
	for r in rows:
		for c in cols:
			state.pos.append(Vector2(x0 + c * sp, _floor_y(world) - r * sp))
			state.vel.append(Vector2.ZERO)
			state.material.append(material)
	return state


func _floor_y(world: Vector2) -> float:
	return world.y - 0.5 * SimParams.SPACING


func _live(state: Dictionary, id: int) -> PackedInt32Array:
	var b: Dictionary = state.bodies[id]
	var out := PackedInt32Array()
	for m in state.members.slice(b.first, b.first + b.count):
		if state.body[m] == id:
			out.append(m)
	return out


func _height(state: Dictionary, id: int) -> float:
	var lo := INF
	var hi := -INF
	for m in _live(state, id):
		lo = minf(lo, state.pos[m].y)
		hi = maxf(hi, state.pos[m].y)
	return hi - lo


func _lowest(state: Dictionary, id: int) -> float:
	var y := -INF
	for m in _live(state, id):
		y = maxf(y, state.pos[m].y)
	return y


func _top_of(state: Dictionary, material: int) -> float:
	var top := INF
	for i in state.pos.size():
		if state.material[i] == material:
			top = minf(top, state.pos[i].y)
	return top


func _rest_height(state: Dictionary, id: int) -> float:
	var lo := INF
	var hi := -INF
	for m in _live(state, id):
		lo = minf(lo, state.rest[m].y)
		hi = maxf(hi, state.rest[m].y)
	return hi - lo


func _max_member_speed(state: Dictionary, id: int) -> float:
	var v := 0.0
	for m in _live(state, id):
		v = maxf(v, state.vel[m].length())
	return v


## Largest move of a member's rest offset since `before`, both about their mean.
func _most_moved(state: Dictionary, id: int, before: PackedVector2Array) -> float:
	var live := _live(state, id)
	var m0 := Vector2.ZERO
	var m1 := Vector2.ZERO
	for m in live:
		m0 += before[m]
		m1 += state.rest[m]
	m0 /= live.size()
	m1 /= live.size()
	var most := 0.0
	for m in live:
		most = maxf(most, (state.rest[m] - m1).distance_to(before[m] - m0))
	return most


## The body's rest lattice links (pairs of members less than 1.5 spacings apart), as particle
## index pairs.
func _links(state: Dictionary, id: int) -> Array:
	var live := _live(state, id)
	var out := []
	for a in live.size():
		for b in range(a + 1, live.size()):
			if state.rest[live[a]].distance_to(state.rest[live[b]]) < 1.5 * SimParams.SPACING:
				out.append([live[a], live[b]])
	return out


## Every link of the lattice as made is still between PLASTIC_GAP and PLASTIC_LINK spacings long.
func _expect_lattice(state: Dictionary, id: int, links: Array) -> void:
	var sp := SimParams.SPACING
	var short := INF
	var long := 0.0
	for l in links:
		var d: float = state.rest[l[0]].distance_to(state.rest[l[1]])
		short = minf(short, d)
		long = maxf(long, d)
	_report("rest lattice links: %d, from %.3f to %.3f px" % [links.size(), short, long])
	expect(short >= SimParams.PLASTIC_GAP * sp - 1e-3, "no link shorter than %.1f spacing: %.3f px" % [SimParams.PLASTIC_GAP, short])
	expect(long < SimParams.PLASTIC_LINK * sp, "no link stretched out of the lattice: %.3f px" % long)


## The push-out's way out of the rest shape follows it (ADR 0012 item 4): every boundary member's
## (fewer than 8 rest neighbours within 1.5 spacings, as rest_outline counts) is half a spacing out
## along the sum of the directions from its neighbours on the rest shape now.
func _expect_outline(state: Dictionary, id: int) -> void:
	var sp := SimParams.SPACING
	var live := _live(state, id)
	var worst := 0.0
	var boundary := 0
	for i in live:
		var n := 0
		var normal := Vector2.ZERO
		for j in live:
			if j != i and state.rest[i].distance_squared_to(state.rest[j]) < 2.25 * sp * sp:
				n += 1
				normal += (state.rest[i] - state.rest[j]).normalized()
		if n >= 8 or normal.length() < 1e-4:
			continue
		boundary += 1
		worst = maxf(worst, state.edge[i].distance_to(0.5 * sp * normal.normalized()))
	_report("outline: %d boundary members, furthest from half a spacing out on the rest shape now %.4f px" % [boundary, worst])
	expect(worst < 0.01, "each boundary member's way out follows the rest shape: off by %.4f px" % worst)


func _report(line: String) -> void:
	print("    " + line)
