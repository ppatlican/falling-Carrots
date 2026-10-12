## CPU reference: cluster solids by shape matching (ADR 0002). Rigid and jelly boxes on
## the floor, stacked, half erased, spawned into the floor and dropped on a corner.
## Runs at the config.json defaults (2 substeps, 4 iterations). Thresholds come from what
## the owner could see: 0.1 px is a tenth of a pixel, and a body moving under 0.5 px/s
## shifts by less than a pixel in 2 s.
extends "res://tests/test_case.gd"

const MaterialTable = preload("res://cpu_ref/material_table.gd")
const ParticleStep = preload("res://cpu_ref/particle_step.gd")
const SimParams = preload("res://core/sim_params.gd")

const WORLD := Vector2(80, 60)
const SUBSTEPS := 2
const ITERATIONS := 4
## Lowest y a body particle's centre reaches: the fixed 0.5-spacing wall inset.
const FLOOR := WORLD.y - 0.5 * SimParams.SPACING
## Fastest a body counts as at rest (px/s): under a pixel in 2 s.
const REST_SPEED := 0.5

var _carrot: int
var _jelly: int


func test_rigid_box_on_floor_keeps_shape() -> void:
	var sim = _sim()
	var state := {"pos": PackedVector2Array(), "vel": PackedVector2Array(), "material": PackedInt32Array()}
	var id: int = ParticleStep.make_body(state, _box(Vector2(40, FLOOR - 2.0), 8, 6), _carrot)
	for f in 240:
		_frame(sim, state)
	var err: float = _fit(state, id).err
	_report("rigid box on floor: shape error %.5f px after 240 frames" % err)
	expect(err < 0.1, "rigid box keeps its shape within 0.1 px: %.4f px" % err)


func test_rigid_box_on_floor_does_not_rock() -> void:
	var sim = _sim()
	var state := {"pos": PackedVector2Array(), "vel": PackedVector2Array(), "material": PackedInt32Array()}
	var id: int = ParticleStep.make_body(state, _box(Vector2(40, FLOOR - 2.0), 8, 6), _carrot)
	var max_turn := 0.0
	var max_speed := 0.0
	for f in 240:
		_frame(sim, state)
		if f >= 120:
			max_turn = maxf(max_turn, absf(_fit(state, id).theta))
			max_speed = maxf(max_speed, _body_vel(state, id).length())
	_report("rigid box on floor, last 120 frames: max |rotation| %.5f rad, max centroid speed %.3f px/s" % [max_turn, max_speed])
	# 0.01 rad moves the corners of an 8x6 box (8.6 px from its centre) by under 0.1 px.
	expect(max_turn < 0.01, "box stays upright, |rotation| < 0.01 rad: %.4f" % max_turn)
	expect(max_speed < REST_SPEED, "box at rest, centroid speed < %.1f px/s: %.3f" % [REST_SPEED, max_speed])


func test_squashed_jelly_springs_back() -> void:
	var sim = _sim()
	var state := {"pos": PackedVector2Array(), "vel": PackedVector2Array(), "material": PackedInt32Array()}
	var id: int = ParticleStep.make_body(state, _box(Vector2(40, FLOOR), 10, 8), _jelly)
	# The control: the same jelly left unsquashed. A soft body sags under its own weight
	# (about 1 px here), so "sprung back" means resting where the control rests.
	var control := state.duplicate(true)
	# Squash to half height on the floor, 1.4x as wide.
	var pos: PackedVector2Array = state.pos
	for i in pos.size():
		pos[i] = Vector2(40.0 + (pos[i].x - 40.0) * 1.4, FLOOR - (FLOOR - pos[i].y) * 0.5)
	state.pos = pos
	var start: float = _fit(state, id).err
	var back := -1
	for f in 120:
		_frame(sim, state)
		_frame(sim, control)
		if back < 0 and _fit(state, id).err < 0.1 * start:
			back = f + 1
	var off := 0.0
	for i in state.pos.size():
		off = maxf(off, state.pos[i].distance_to(control.pos[i]))
	_report("squashed jelly (stiffness 0.3): shape error %.3f px, under 10%% after %d frames; at 2 s %.3f px from an unsquashed jelly at rest (its sag %.3f px)" % [start, back, off, _fit(control, id).err])
	# Stiffness 0.3 alone removes all but 0.7^n of the error in n frames.
	expect(back > 0, "jelly springs back to under 10%% of its start error (%.2f px) within 2 s" % start)
	expect(off < 0.1 * start, "after 2 s every particle is within 10%% of the start error of an unsquashed jelly at rest: %.3f px" % off)


func test_three_rigid_boxes_stack_and_settle() -> void:
	var sim = _sim()
	var state := {"pos": PackedVector2Array(), "vel": PackedVector2Array(), "material": PackedInt32Array()}
	# 8x5 boxes, 1 px apart (beyond contact distance), each shifted 2 px right of the one below.
	var ids := []
	for k in 3:
		var bottom := FLOOR - 1.0 - k * (5.0 * SimParams.SPACING + 1.0)
		ids.append(ParticleStep.make_body(state, _box(Vector2(36.0 + 2.0 * k, bottom), 8, 5), _carrot))
	var run_min := INF
	var max_speed := 0.0
	for f in 300:
		_frame(sim, state)
		run_min = minf(run_min, _closest_cross_pair(state))
		if f >= 240:
			for id in ids:
				max_speed = maxf(max_speed, _body_vel(state, id).length())
	var gap := _closest_cross_pair(state)
	var max_turn := 0.0
	for id in ids:
		max_turn = maxf(max_turn, absf(_fit(state, id).theta))
	_report("3-box stack: closest cross-body pair %.3f px at rest (%.3f px over the run), max |rotation| %.5f rad, max speed (last 60 frames) %.3f px/s" % [gap, run_min, max_turn, max_speed])
	expect(gap >= 0.8 * SimParams.SPACING, "no box sinks into another, closest cross-body pair >= 0.8 spacing: %.3f px" % gap)
	# 0.02 rad moves an 8x5 box's corners (8.1 px out) by under 0.2 px.
	expect(max_turn < 0.02, "boxes stay upright, |rotation| < 0.02 rad: %.4f" % max_turn)
	expect(max_speed < REST_SPEED, "stack at rest, speed < %.1f px/s: %.3f" % [REST_SPEED, max_speed])


## Why bodies get STACK_K (ADR 0002): with plain mass weighting the bottom pair of this
## stack closed to 1.45 px.
func test_five_aligned_boxes_hold_without_sinking() -> void:
	var sim = _sim()
	var state := {"pos": PackedVector2Array(), "vel": PackedVector2Array(), "material": PackedInt32Array()}
	var ids := []
	for k in 5:
		var bottom := FLOOR - 1.0 - k * (5.0 * SimParams.SPACING + 1.0)
		ids.append(ParticleStep.make_body(state, _box(Vector2(36.0, bottom), 8, 5), _carrot))
	var max_speed := 0.0
	for f in 300:
		_frame(sim, state)
		if f >= 240:
			for id in ids:
				max_speed = maxf(max_speed, _body_vel(state, id).length())
	var gap := _closest_cross_pair(state)
	_report("5-box aligned stack: closest cross-body pair %.3f px, max speed (last 60 frames) %.3f px/s" % [gap, max_speed])
	expect(gap >= 0.8 * SimParams.SPACING, "no box sinks into another, closest cross-body pair >= 0.8 spacing: %.3f px" % gap)
	expect(max_speed < REST_SPEED, "stack at rest, speed < %.1f px/s: %.3f" % [REST_SPEED, max_speed])


func test_half_erased_box_keeps_shape_without_drifting() -> void:
	var sim = _sim()
	var state := {"pos": PackedVector2Array(), "vel": PackedVector2Array(), "material": PackedInt32Array()}
	var id: int = ParticleStep.make_body(state, _box(Vector2(40, FLOOR - 6.0), 10, 6), _carrot)
	for f in 120:
		_frame(sim, state)
	# Erase the left five columns.
	var gone := PackedInt32Array()
	var cx: float = _fit(state, id).c.x
	for i in state.pos.size():
		if state.pos[i].x < cx:
			gone.append(i)
	ParticleStep.erase_particles(state, gone)
	expect_eq(state.members.size(), 30, "members remapped after erase")
	var start: Vector2 = _fit(state, id).c
	var max_drift := 0.0
	for f in 120:
		_frame(sim, state)
		max_drift = maxf(max_drift, absf(_fit(state, id).c.x - start.x))
	var fit := _fit(state, id)
	_report("half-erased box, 120 frames: shape error %.5f px, sideways drift %.4f px, rotation %.5f rad" % [fit.err, max_drift, fit.theta])
	expect(fit.err < 0.1, "what is left keeps its shape within 0.1 px: %.4f" % fit.err)
	expect(max_drift < 0.5, "what is left doesn't slide sideways, drift < 0.5 px: %.3f" % max_drift)
	expect(absf(fit.theta) < 0.01, "what is left stays upright, |rotation| < 0.01 rad: %.4f" % fit.theta)


func test_box_spawned_into_floor_does_not_launch() -> void:
	var sim = _sim()
	var state := {"pos": PackedVector2Array(), "vel": PackedVector2Array(), "material": PackedInt32Array()}
	# Bottom row 4 px (two spacings) past the floor's wall inset.
	var id: int = ParticleStep.make_body(state, _box(Vector2(40, FLOOR + 4.0), 8, 6), _carrot)
	var peak_up := 0.0
	for f in 120:
		_frame(sim, state)
		peak_up = maxf(peak_up, -_body_vel(state, id).y)
	var speed := _body_vel(state, id).length()
	_report("box spawned 4 px into the floor: peak upward centroid speed %.2f px/s, final speed %.3f px/s" % [peak_up, speed])
	# Leaving the floor by more than a spacing (2 px) is a launch: v^2 / 2g < 2 px.
	var bound := sqrt(2.0 * SimParams.GRAVITY * SimParams.SPACING)
	expect(peak_up < bound, "no launch, peak upward speed < %.0f px/s (a hop under one spacing): %.2f" % [bound, peak_up])
	expect(speed < REST_SPEED, "box at rest after 2 s, speed < %.1f px/s: %.3f" % [REST_SPEED, speed])


func test_box_dropped_on_corner_tips_and_settles() -> void:
	var sim = _sim()
	var state := {"pos": PackedVector2Array(), "vel": PackedVector2Array(), "material": PackedInt32Array()}
	var tilt := deg_to_rad(30.0)
	var pts := _box(Vector2(40, 40), 12, 5, tilt)
	var lowest := -INF
	for p in pts:
		lowest = maxf(lowest, p.y)
	for i in pts.size():
		pts[i].y += FLOOR - 4.0 - lowest  # lowest corner 4 px above the floor
	var id: int = ParticleStep.make_body(state, pts, _carrot)
	var turned := 0.0
	var late := []
	for f in 300:
		_frame(sim, state)
		var now: float = tilt + _fit(state, id).theta
		turned = maxf(turned, absf(now - tilt))
		if f >= 240:
			late.append(now)
	var angle: float = late[-1]
	var off_flat := absf(angle - roundf(angle / (PI / 2.0)) * PI / 2.0)
	var wobble: float = late.max() - late.min()
	var speed := _body_vel(state, id).length()
	_report("12x5 box dropped on a corner at 30 deg: turned up to %.1f deg, ends %.2f deg from a face down, turns %.4f rad over the last 60 frames, speed %.3f px/s" % [rad_to_deg(turned), rad_to_deg(off_flat), wobble, speed])
	expect(turned > deg_to_rad(15.0), "the box tips, turning more than 15 deg: %.1f" % rad_to_deg(turned))
	# 0.05 rad (3 deg) lifts the far end of a 24 px face by about 1 px.
	expect(off_flat < 0.05, "the box ends on a face, within 0.05 rad: %.4f" % off_flat)
	expect(wobble < 0.01, "the box has stopped turning, under 0.01 rad in the last 60 frames: %.4f" % wobble)
	expect(speed < REST_SPEED, "the box at rest, speed < %.1f px/s: %.3f" % [REST_SPEED, speed])


# --- Helpers -----------------------------------------------------------------------

## A ParticleStep over the shipped table plus test-only rigid ("carrot", stiffness 1) and
## jelly (stiffness 0.3) rows: materials.json gets no cluster rows until the GPU has bodies.
func _sim():
	var shipped = MaterialTable.new()
	shipped.load_file()
	var rows := []
	for id in shipped.materials:
		rows.append(shipped.materials[id].duplicate(true))
	var sand: Dictionary = shipped.materials[shipped.id_of("sand")]
	rows.append(_with(sand, {"id": 2, "name": "carrot", "class": "cluster", "color": "#e8792b",
			"density": 1.2, "stiffness": 1.0, "tags": []}))
	rows.append(_with(sand, {"id": 3, "name": "jelly", "class": "cluster", "color": "#d94f8a",
			"density": 1.1, "stiffness": 0.3, "tags": []}))
	var table = MaterialTable.new()
	var problems: PackedStringArray = table.load_rows(rows)
	expect(problems.is_empty(), "test material rows: %s" % "; ".join(problems))
	_carrot = table.id_of("carrot")
	_jelly = table.id_of("jelly")
	return ParticleStep.new(WORLD, table)


func _with(row: Dictionary, changes: Dictionary) -> Dictionary:
	var r := row.duplicate(true)
	r.merge(changes, true)
	return r


## One frame at the config.json defaults.
func _frame(sim, state: Dictionary) -> void:
	for s in SUBSTEPS:
		sim.step(state, SimParams.DT / SUBSTEPS, ITERATIONS)


## A cols x rows lattice at rest spacing whose bottom-centre is at `bottom`, turned by
## `angle` about its centre.
func _box(bottom: Vector2, cols: int, rows: int, angle: float = 0.0) -> PackedVector2Array:
	var sp := SimParams.SPACING
	var size := Vector2(cols - 1, rows - 1) * sp
	var centre := bottom - Vector2(0.0, 0.5 * size.y)
	var out := PackedVector2Array()
	for y in rows:
		for x in cols:
			out.append(centre + (Vector2(x, y) * sp - 0.5 * size).rotated(angle))
	return out


## Live members of a body, as the solver counts them.
func _live(state: Dictionary, id: int) -> PackedInt32Array:
	var b: Dictionary = state.bodies[id]
	var out := PackedInt32Array()
	for m in state.members.slice(b.first, b.first + b.count):
		if state.body[m] == id:
			out.append(m)
	return out


## Best fit of a body's rest shape to its particles, worked out here from positions and
## rest offsets: centroid c, rotation theta and the largest distance to the fitted shape.
func _fit(state: Dictionary, id: int) -> Dictionary:
	var live := _live(state, id)
	var c := Vector2.ZERO
	var c0 := Vector2.ZERO
	for m in live:
		c += state.pos[m]
		c0 += state.rest[m]
	c /= live.size()
	c0 /= live.size()
	var dot := 0.0
	var cross := 0.0
	for m in live:
		var p: Vector2 = state.pos[m] - c
		var q: Vector2 = state.rest[m] - c0
		dot += p.dot(q)
		cross += q.cross(p)
	var theta := atan2(cross, dot)
	var err := 0.0
	for m in live:
		var goal: Vector2 = c + (state.rest[m] - c0).rotated(theta)
		err = maxf(err, goal.distance_to(state.pos[m]))
	return {"c": c, "theta": theta, "err": err}


func _body_vel(state: Dictionary, id: int) -> Vector2:
	var live := _live(state, id)
	var v := Vector2.ZERO
	for m in live:
		v += state.vel[m]
	return v / live.size()


func _closest_cross_pair(state: Dictionary) -> float:
	var best := INF
	var n: int = state.pos.size()
	for i in n:
		for j in range(i + 1, n):
			if state.body[i] != state.body[j]:
				best = minf(best, state.pos[i].distance_to(state.pos[j]))
	return best


func _report(line: String) -> void:
	print("    " + line)
