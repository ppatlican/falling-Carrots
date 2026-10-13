## CPU reference: cluster solids by shape matching (ADR 0002). Rigid and jelly boxes on
## the floor, stacked, half erased, spawned into the floor and dropped on a corner; in water
## (sinking, floating, water kept out) and dropped onto sand (grains kept out), ADR 0003.
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
var _cork: int
var _water: int
var _sand: int


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


# --- Bodies in water and on sand (ADR 0003) ---------------------------------------------

## The way out of an 8x6 box's rest shape: boundary members are half a spacing inside the
## outline, along their outward normal; an inner member points at the nearest edge.
func test_rest_outline_of_a_box() -> void:
	var sp := SimParams.SPACING
	var rest := _box(Vector2.ZERO, 8, 6)
	var mean := Vector2.ZERO
	for q in rest:
		mean += q
	mean /= rest.size()
	for k in rest.size():
		rest[k] -= mean
	var e: PackedVector2Array = ParticleStep.rest_outline(rest)
	expect_eq(e.size(), rest.size(), "one outline vector per member")
	# Member (col, row) of the 8x6 lattice is e[row * 8 + col], row 0 at the top.
	_expect_vec(e[0 * 8 + 3], Vector2(0, -0.5 * sp), "top edge member points up half a spacing")
	_expect_vec(e[2 * 8 + 0], Vector2(-0.5 * sp, 0), "left edge member points left")
	_expect_vec(e[5 * 8 + 4], Vector2(0, 0.5 * sp), "bottom edge member points down")
	var corner: Vector2 = e[0 * 8 + 7]
	expect(corner.x > 0.0 and corner.y < 0.0 and absf(corner.x + corner.y) < 1e-4,
			"top-right corner points out diagonally: %s" % corner)
	_expect_vec(e[1 * 8 + 3], Vector2(0, -1.5 * sp), "member one row in points up to the top outline")
	_expect_vec(e[2 * 8 + 1], Vector2(-1.5 * sp, 0), "member one column in points left")


func test_sinking_box_keeps_water_out() -> void:
	var world := Vector2(48, 60)
	var sim = _sim(world)
	var state := _pool(world, 24, 18)
	var surface := world.y - 18 * SimParams.SPACING
	# A carrot (denser than water) dropped from 8 px above the water.
	var id: int = ParticleStep.make_body(state, _box(Vector2(24, surface - 8.0), 8, 6), _carrot)
	var most_inside := 0
	for f in 300:
		_frame(sim, state)
		if f % 10 == 9:
			most_inside = maxi(most_inside, _inside(state, id, _water).size())
	var fit := _fit(state, id)
	var above := _floor_y(world) - _lowest(state, id)
	_report("carrot box into water, 300 frames: lowest particle %.2f px above the floor, %d water inside at the end (most %d), rotation %.4f rad, speed %.3f px/s, shape error %.4f px"
			% [above, _inside(state, id, _water).size(), most_inside, fit.theta, _body_vel(state, id).length(), fit.err])
	# On the floor, or on one layer of water particles: nothing squeezes a one-particle film out
	# from under a body (ADR 0003 known limits).
	expect(above < 2.0 * SimParams.SPACING, "the carrot sinks to the floor (or one water layer above it): %.2f px above it" % above)
	expect(most_inside == 0, "no water inside the box at any sample: up to %d" % most_inside)
	expect(fit.err < 0.1, "the box keeps its shape within 0.1 px: %.4f" % fit.err)


## A cork floats about half under, level with the top water particles (BODY_SURFACE_DROP: the
## grid's free surface sits ~2.5 px above them, ADR 0003 item 4). An 8x6 box at density 0.5 is
## only just stable upright (a box floats upright when width / height > sqrt(6 rho (1 - rho)),
## 1.22 here, it is 1.33), so it rocks slowly; "upright" means not capsized.
func test_light_box_floats_at_its_density() -> void:
	var world := Vector2(48, 60)
	var sim = _sim(world)
	var state := _pool(world, 24, 18)
	var surface := world.y - 18 * SimParams.SPACING
	# A cork (density 0.5) set down on the water.
	var id: int = ParticleStep.make_body(state, _box(Vector2(24, surface - 1.0), 8, 6), _cork)
	var late := _settle_in_water(sim, state, id, 360)
	_report("cork box on water, 360 frames, last 60: mean draft %.2f of its height (density 0.5), mean speed %.2f px/s, max |rotation| %.3f rad, %d water inside"
			% [late.draft, late.speed, late.turn, _inside(state, id, _water).size()])
	expect(late.draft > 0.25 and late.draft < 0.7, "the cork floats about half under: draft %.2f of its height" % late.draft)
	expect(late.speed < 3.0, "the cork is nearly still, mean speed < 3 px/s: %.2f" % late.speed)
	expect(late.turn < 0.35, "the cork floats upright, |rotation| < 0.35 rad: %.3f" % late.turn)
	expect_eq(_inside(state, id, _water).size(), 0, "no water inside the cork")


func test_light_box_rises_from_the_bottom() -> void:
	var world := Vector2(48, 60)
	var sim = _sim(world)
	# The pool leaves an 8-column gap on the floor for a cork, with the water around it.
	var state := _pool(world, 24, 18, 8)
	var id: int = ParticleStep.make_body(state, _box(Vector2(24, _floor_y(world)), 8, 6), _cork)
	var late := _settle_in_water(sim, state, id, 420)
	_report("cork box let go on the floor of a pool, 420 frames, last 60: mean draft %.2f of its height, mean speed %.2f px/s, max tilt %.3f rad, %d water inside"
			% [late.draft, late.speed, late.turn, _inside(state, id, _water).size()])
	expect(late.draft > 0.25 and late.draft < 0.7, "the cork rises and floats about half under: draft %.2f" % late.draft)
	# It comes up fast and rocks in this narrow pool's slosh for seconds (still +-0.4 rad at
	# 7 s); the check is that it floats on a face, not on its side (1.57 rad).
	expect(late.turn < 0.6, "the cork floats face up or down, tilt < 0.6 rad: %.3f" % late.turn)


## ADR 0003 known limit: water's pressure pushes act on a body's wet particles only, relative to
## its top (p_ref), so a jelly's bottom and lower sides are pushed at up to ~9 g and it was
## squeezed out of shape, with water inside (GPU: 4.4 px off, 20-26 inside). The pushes on a soft
## body are projected onto its rigid motion, so the water moves and turns it without deforming it.
func test_sunk_jelly_keeps_its_shape() -> void:
	var world := Vector2(64, 60)
	# The control: the same jelly on the dry floor sags under its own weight.
	var dry_sim = _sim(world)
	var dry := {"pos": PackedVector2Array(), "vel": PackedVector2Array(), "material": PackedInt32Array()}
	var dry_id: int = ParticleStep.make_body(dry, _box(Vector2(32, _floor_y(world)), 16, 10), _jelly)
	for f in 240:
		_frame(dry_sim, dry)
	var sag: float = _fit(dry, dry_id).err
	# The 16x10 jelly main.tscn drops (density 1.1), let go on the floor of a pool, 10 rows of
	# water around it and 10 over it.
	var sim = _sim(world)
	var state := _pool(world, 32, 20, 16, 10)
	var id: int = ParticleStep.make_body(state, _box(Vector2(32, _floor_y(world)), 16, 10), _jelly)
	var most_inside := 0
	var worst := 0.0
	for f in 240:
		_frame(sim, state)
		if f % 10 == 9:
			most_inside = maxi(most_inside, _inside(state, id, _water).size())
			if f >= 120:
				worst = maxf(worst, _fit(state, id).err)
	var above := _floor_y(world) - _lowest(state, id)
	_report("jelly 16x10 on the floor of a pool, 240 frames: shape error up to %.3f px over the last 2 s (%.3f px dry on the floor), %d water inside at the end (most %d), lowest particle %.2f px above the floor, speed %.3f px/s"
			% [worst, sag, _inside(state, id, _water).size(), most_inside, above, _body_vel(state, id).length()])
	expect(above < 2.0 * SimParams.SPACING, "the jelly stays on the floor (or one water layer above it): %.2f px above it" % above)
	expect(worst < 2.0 * sag, "the sunk jelly keeps its shape within twice its dry sag (%.3f px): %.3f" % [sag, worst])
	expect(most_inside == 0, "no water inside the jelly at any sample: up to %d" % most_inside)


## ADR 0002 known limit: an 8x6 box dropped 72 px onto sand ended with 7 grains inside.
func test_box_dropped_on_sand_keeps_grains_out() -> void:
	var world := Vector2(80, 140)
	var sim = _sim(world)
	var state := _bed(world, 40, 10)
	for f in 60:
		_frame(sim, state)
	# Dropped from 100 px above the bed's top (lands at ~280 px/s, as body_probe sand).
	var top := _top_of(state, _sand)
	var id: int = ParticleStep.make_body(state, _box(Vector2(40, top - 100.0), 8, 6), _carrot)
	var most := 0
	for f in 180:
		_frame(sim, state)
		most = maxi(most, _inside(state, id, _sand).size())
	var fit := _fit(state, id)
	var inside := _inside(state, id, _sand).size()
	_report("8x6 carrot dropped 100 px onto a sand bed, 180 frames: %d grains inside at the end (most %d in a frame), rotation %.3f rad, shape error %.4f px, speed %.3f px/s"
			% [inside, most, fit.theta, fit.err, _body_vel(state, id).length()])
	expect_eq(inside, 0, "no grain inside the box after landing")
	expect(fit.err < 0.1, "the box keeps its shape: %.4f" % fit.err)


## Body-body push-out (ADR 0003 item 11): without it the dropped box ended inside the other,
## the ordinary contacts balanced among the interleaved lattices (body_probe boxdrop).
func test_box_dropped_on_box_stays_out() -> void:
	var world := Vector2(80, 220)
	var sim = _sim(world)
	var state := {"pos": PackedVector2Array(), "vel": PackedVector2Array(), "material": PackedInt32Array()}
	var floor_y := _floor_y(world)
	var below: int = ParticleStep.make_body(state, _box(Vector2(40, floor_y), 16, 10), _carrot)
	# Dropped 150 px onto it: lands at ~350 px/s, over a spacing per substep.
	var above: int = ParticleStep.make_body(state, _box(Vector2(40, floor_y - 20.0 - 150.0), 16, 10), _carrot)
	var most := 0
	var max_speed := 0.0
	for f in 300:
		_frame(sim, state)
		most = maxi(most, _members_inside(state, below, above) + _members_inside(state, above, below))
		if f >= 240:
			max_speed = maxf(max_speed, _body_vel(state, above).length())
	var inside := _members_inside(state, below, above) + _members_inside(state, above, below)
	var gap := _closest_cross_pair(state)
	var err := maxf(_fit(state, below).err, _fit(state, above).err)
	_report("16x10 carrot dropped 150 px onto another, 300 frames: %d members inside the other at the end (most %d in a frame), closest cross-body pair %.3f px, max shape error %.4f px, speed (last 60 frames) %.3f px/s"
			% [inside, most, gap, err, max_speed])
	expect_eq(inside, 0, "no member inside the other box at the end")
	expect(gap >= 0.8 * SimParams.SPACING, "the box rests on the other, closest cross-body pair >= 0.8 spacing: %.3f px" % gap)
	expect(err < 0.1, "both keep their shape: %.4f" % err)
	expect(max_speed < REST_SPEED, "at rest, speed < %.1f px/s: %.3f" % [REST_SPEED, max_speed])


## A fast, off-centre drop (body_probe boxhigh): at ~390 px/s the box moves 1.6 spacings a
## substep and dips ~2.5 spacings in. Its push back out came back as speed: it bounced up at
## ~78 px/s, tilted and slid off. The push may stop a body but not send it away (velocity
## update, stop_not_launch).
func test_fast_box_drop_stacks_off_centre() -> void:
	var world := Vector2(160, 420)
	var sim = _sim(world)
	var state := {"pos": PackedVector2Array(), "vel": PackedVector2Array(), "material": PackedInt32Array()}
	var floor_y := _floor_y(world)
	var below: int = ParticleStep.make_body(state, _box(Vector2(80, floor_y), 16, 10), _carrot)
	var above: int = ParticleStep.make_body(state, _box(Vector2(84, floor_y - 20.0 - 330.0), 16, 10), _carrot)
	var touched := false
	var rebound := 0.0
	var max_speed := 0.0
	for f in 400:
		_frame(sim, state)
		var v := _body_vel(state, above)
		touched = touched or _closest_cross_pair(state) < SimParams.SPACING
		if touched:
			rebound = maxf(rebound, -v.y)
		if f >= 340:
			max_speed = maxf(max_speed, v.length())
	var inside := _members_inside(state, below, above) + _members_inside(state, above, below)
	var on_top: bool = _fit(state, above).c.y < _fit(state, below).c.y - 10.0 * SimParams.SPACING + 1.0
	var gap := _closest_cross_pair(state)
	_report("16x10 carrot dropped 330 px, 4 px off centre, onto another, 400 frames: on top %s, fastest rebound %.1f px/s, %d members inside the other, closest cross-body pair %.3f px, speed (last 60 frames) %.3f px/s"
			% [on_top, rebound, inside, gap, max_speed])
	expect(on_top, "the box stays on the other")
	expect(rebound < 20.0, "no bounce, rebound < 20 px/s: %.1f" % rebound)
	expect_eq(inside, 0, "no member inside the other box at the end")
	expect(gap >= 0.8 * SimParams.SPACING, "closest cross-body pair >= 0.8 spacing: %.3f px" % gap)
	expect(max_speed < REST_SPEED, "at rest, speed < %.1f px/s: %.3f" % [REST_SPEED, max_speed])


func test_erasing_part_of_a_body_marks_its_outline_stale() -> void:
	_sim()
	var state := {"pos": PackedVector2Array(), "vel": PackedVector2Array(), "material": PackedInt32Array()}
	var a: int = ParticleStep.make_body(state, _box(Vector2(20, 50), 8, 6), _carrot)
	var b: int = ParticleStep.make_body(state, _box(Vector2(60, 50), 8, 6), _carrot)
	expect(not state.bodies[a].stale and not state.bodies[b].stale, "new bodies have a fresh outline")
	ParticleStep.erase_particles(state, PackedInt32Array([0, 1, 2]))
	expect(state.bodies[a].stale, "the body that lost members is marked stale")
	expect(not state.bodies[b].stale, "the other body keeps its outline")


# --- Helpers -----------------------------------------------------------------------

## A ParticleStep over the shipped table plus test-only rigid ("carrot", stiffness 1) and
## jelly (stiffness 0.3) rows: materials.json gets no cluster rows until the GPU has bodies.
func _sim(world := WORLD):
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
	rows.append(_with(sand, {"id": 4, "name": "cork", "class": "cluster", "color": "#c8a46e",
			"density": 0.5, "stiffness": 1.0, "tags": []}))
	var table = MaterialTable.new()
	var problems: PackedStringArray = table.load_rows(rows)
	expect(problems.is_empty(), "test material rows: %s" % "; ".join(problems))
	_carrot = table.id_of("carrot")
	_jelly = table.id_of("jelly")
	_cork = table.id_of("cork")
	_water = table.id_of("water")
	_sand = table.id_of("sand")
	return ParticleStep.new(world, table)


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


## Runs `frames` frames; over the last 60, the body's mean draft, mean speed and largest
## tilt off level (|rotation| from the nearest half turn).
func _settle_in_water(sim, state: Dictionary, id: int, frames: int) -> Dictionary:
	var draft := 0.0
	var speed := 0.0
	var turn := 0.0
	for f in frames:
		_frame(sim, state)
		if f >= frames - 60:
			draft += _draft(state, id) / 60.0
			speed += _body_vel(state, id).length() / 60.0
			# Tilt off level: a box turned half over floats as well face down.
			var theta: float = _fit(state, id).theta
			turn = maxf(turn, absf(theta - roundf(theta / PI) * PI))
	return {"draft": draft, "speed": speed, "turn": turn}


## Water at rest spacing from the floor up, cols x rows, centred. With `gap` > 0 the middle
## `gap` columns of the bottom `gap_rows` rows stay empty (room for a box on the floor).
func _pool(world: Vector2, cols: int, rows: int, gap := 0, gap_rows := 6) -> Dictionary:
	return _lattice(world, cols, rows, _water, gap, gap_rows)


## A sand bed from the floor up.
func _bed(world: Vector2, cols: int, rows: int) -> Dictionary:
	return _lattice(world, cols, rows, _sand, 0)


func _lattice(world: Vector2, cols: int, rows: int, material: int, gap: int, gap_rows := 6) -> Dictionary:
	var sp := SimParams.SPACING
	var state := {"pos": PackedVector2Array(), "vel": PackedVector2Array(), "material": PackedInt32Array()}
	var x0 := 0.5 * (world.x - (cols - 1) * sp)
	var mid := 0.5 * (cols - 1)
	for r in rows:
		for c in cols:
			if gap > 0 and r < gap_rows and absf(c - mid) < 0.5 * gap:
				continue
			state.pos.append(Vector2(x0 + c * sp, _floor_y(world) - r * sp))
			state.vel.append(Vector2.ZERO)
			state.material.append(material)
	return state


## Lowest y a body particle's centre reaches in this world (the 0.5-spacing wall inset).
func _floor_y(world: Vector2) -> float:
	return world.y - 0.5 * SimParams.SPACING


## Highest particle centre of a material (smallest y).
func _top_of(state: Dictionary, material: int) -> float:
	var top := INF
	for i in state.pos.size():
		if state.material[i] == material:
			top = minf(top, state.pos[i].y)
	return top


func _lowest(state: Dictionary, id: int) -> float:
	var y := -INF
	for m in _live(state, id):
		y = maxf(y, state.pos[m].y)
	return y


## Particles of `material` whose centre is inside the body's outline (the bounding box of its
## rest lattice, out to half a spacing past the boundary members, less a quarter spacing of
## slack), placed by the body's best fit.
func _inside(state: Dictionary, id: int, material: int) -> PackedInt32Array:
	var fit := _fit(state, id)
	var live := _live(state, id)
	var c0 := Vector2.ZERO
	for m in live:
		c0 += state.rest[m]
	c0 /= live.size()
	var lo := Vector2(INF, INF)
	var hi := -lo
	for m in live:
		lo = lo.min(state.rest[m] - c0)
		hi = hi.max(state.rest[m] - c0)
	var pad := Vector2.ONE * 0.25 * SimParams.SPACING
	lo -= pad
	hi += pad
	var out := PackedInt32Array()
	for i in state.pos.size():
		if state.material[i] != material:
			continue
		var q: Vector2 = (state.pos[i] - fit.c).rotated(-fit.theta)
		if q.x > lo.x and q.x < hi.x and q.y > lo.y and q.y < hi.y:
			out.append(i)
	return out


## Members of body `other` inside body `id`'s rest lattice (more than half a spacing inside
## its outline), taken into its rest frame.
func _members_inside(state: Dictionary, id: int, other: int) -> int:
	var fit := _fit(state, id)
	var live := _live(state, id)
	var c0 := Vector2.ZERO
	for m in live:
		c0 += state.rest[m]
	c0 /= live.size()
	var lo := Vector2(INF, INF)
	var hi := -lo
	for m in live:
		lo = lo.min(state.rest[m] - c0)
		hi = hi.max(state.rest[m] - c0)
	var n := 0
	for m in _live(state, other):
		var q: Vector2 = (state.pos[m] - fit.c).rotated(-fit.theta)
		if q.x > lo.x and q.x < hi.x and q.y > lo.y and q.y < hi.y:
			n += 1
	return n


## Share of a floating body's height under the water: from its outline's bottom up to the
## water's surface (half a spacing over the top water particle, in columns clear of it).
func _draft(state: Dictionary, id: int) -> float:
	var sp := SimParams.SPACING
	var top := INF
	var bottom := -INF
	var left := INF
	var right := -INF
	for m in _live(state, id):
		var p: Vector2 = state.pos[m]
		top = minf(top, p.y)
		bottom = maxf(bottom, p.y)
		left = minf(left, p.x)
		right = maxf(right, p.x)
	var surface := INF
	for i in state.pos.size():
		var p: Vector2 = state.pos[i]
		if state.material[i] == _water and (p.x < left - 3.0 * sp or p.x > right + 3.0 * sp):
			surface = minf(surface, p.y)
	surface -= 0.5 * sp
	return (bottom + 0.5 * sp - surface) / (bottom - top + sp)


func _expect_vec(got: Vector2, want: Vector2, what: String) -> void:
	expect(got.distance_to(want) < 1e-3, "%s: %s, expected %s" % [what, got, want])


func _report(line: String) -> void:
	print("    " + line)
