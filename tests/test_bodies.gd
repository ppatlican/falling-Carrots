## CPU reference: cluster solids by shape matching (ADR 0002). Rigid and jelly boxes on
## the floor, stacked, half erased, erased in two (each piece its own body, ADR 0004), spawned
## into the floor and dropped on a corner; in water (sinking, floating, water kept out) and
## dropped onto sand (grains kept out), ADR 0003.
## Runs at the config.json defaults (2 substeps, 4 iterations). Thresholds come from what
## the owner could see: 0.1 px is a tenth of a pixel, and a body moving under 0.5 px/s
## shifts by less than a pixel in 2 s.
## Cost is particles x frames, x world area with water (the density grid covers the whole world
## every substep that has liquid): alone, the body-in-water tests take 20-80 s each, the dry ones
## 1-30 s (testing.md). A new test takes
## the smallest world, particles and frames that still go red on the broken code (testing.md).
extends "res://tests/test_case.gd"

## Test groups for run_tests.gd (-- @name); which to run for a change: docs/agents/testing.md.
const GROUPS := {
	"test_rigid_box_on_floor_keeps_shape": ["rigid", "quick"],
	"test_rigid_box_on_floor_does_not_rock": ["rigid"],
	"test_squashed_jelly_springs_back": ["soft", "quick"],
	"test_jelly_plank_bends_over_a_gap": ["soft"],
	"test_dropped_jelly_wobbles_and_settles": ["soft"],
	"test_jelly_squashes_under_a_carrot_and_springs_back": ["soft"],
	"test_jelly_strip_folds_without_passing_through_itself": ["soft"],
	"test_soft_body_rests_on_a_soft_body": ["soft"],
	"test_three_rigid_boxes_stack_and_settle": ["rigid"],
	"test_five_aligned_boxes_hold_without_sinking": ["rigid"],
	"test_half_erased_box_keeps_shape_without_drifting": ["rigid", "erase"],
	"test_box_spawned_into_floor_does_not_launch": ["rigid", "quick"],
	"test_box_dropped_on_corner_tips_and_settles": ["rigid"],
	"test_rest_outline_of_a_box": ["rigid", "erase", "quick"],
	"test_sinking_box_keeps_water_out": ["bodies-water"],
	"test_light_box_floats_at_its_density": ["bodies-water"],
	"test_light_box_rises_from_the_bottom": ["bodies-water"],
	"test_submerged_body_keeps_its_reference_pressure": ["bodies-water", "hydro"],
	"test_cork_pressed_into_wet_sand_rises": ["bodies-water", "sand", "hydro"],
	"test_sunk_jelly_keeps_its_shape": ["bodies-water", "soft"],
	"test_box_dropped_on_sand_keeps_grains_out": ["sand", "rigid", "quick"],
	"test_soft_jelly_rests_on_sand": ["sand", "soft"],
	"test_box_dropped_on_box_stays_out": ["rigid", "quick"],
	"test_fast_box_drop_stacks_off_centre": ["rigid"],
	"test_fast_box_drop_on_plank_stays_on_top": ["rigid"],
	"test_boxes_colliding_sideways_stay_apart": ["rigid"],
	"test_fast_box_drop_on_a_stack_of_three": ["rigid"],
	"test_erasing_part_of_a_body_works_its_outline_out_again": ["erase", "quick"],
	"test_erasing_a_body_in_two_makes_two_bodies": ["erase", "quick"],
	"test_pieces_keep_the_motion_they_had": ["erase"],
	"test_body_pieces_on_the_rest_lattice": ["erase", "quick"],
	"test_split_plan_for_the_gpu": ["erase", "quick"],
}

const MaterialTable = preload("res://cpu_ref/material_table.gd")
const ParticleStep = preload("res://cpu_ref/particle_step.gd")
const SimParams = preload("res://core/sim_params.gd")
const ParticleSim = preload("res://gpu/particle_sim.gd")

const WORLD := Vector2(80, 60)
const SUBSTEPS := 2
const ITERATIONS := 4
## Lowest y a body particle's centre reaches: the fixed 0.5-spacing wall inset.
const FLOOR := WORLD.y - 0.5 * SimParams.SPACING
## Fastest a body counts as at rest (px/s): under a pixel in 2 s.
const REST_SPEED := 0.5
## A carrot's speed 20 px before it lands from a 330 px drop (main.tscn's Drop buttons): the
## material's drag (0.6/s) holds the fall to 387 px/s at the impact, as on the GPU (~390).
const DROP_SPEED := 378.0

var _carrot: int
var _jelly: int
var _cork: int
var _water: int
var _sand: int
## Jelly's region radius in spacings (ADR 0005).
var _region: float


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
	_report("squashed jelly: shape error %.3f px, under 10%% after %d frames; at 2 s %.3f px from an unsquashed jelly at rest (its sag %.3f px)" % [start, back, off, _fit(control, id).err])
	expect(back > 0, "jelly springs back to under 10%% of its start error (%.2f px) within 2 s" % start)
	expect(off < 0.1 * start, "after 2 s every particle is within 10%% of the start error of an unsquashed jelly at rest: %.3f px" % off)


## ADR 0005: a soft body is matched over small regions, so it bends. A 24x6 jelly plank laid
## over a 20 px gap between two carrot pillars sags into it and rests there (one cluster sagged
## about 1 px). Thinner or longer planks fall through the gap (ADR 0005 Known limits).
func test_jelly_plank_bends_over_a_gap() -> void:
	var world := Vector2(80, 40)
	var sim = _sim(world)
	var state := {"pos": PackedVector2Array(), "vel": PackedVector2Array(), "material": PackedInt32Array()}
	var fl := _floor_y(world)
	# Pillars 6 wide, 10 tall, their inner faces 20 px apart.
	ParticleStep.make_body(state, _box(Vector2(40 - 15, fl), 6, 10), _carrot)
	ParticleStep.make_body(state, _box(Vector2(40 + 15, fl), 6, 10), _carrot)
	var top := fl - 10 * SimParams.SPACING
	var id: int = ParticleStep.make_body(state, _box(Vector2(40, top), 24, 6), _jelly)
	var live := _live(state, id)
	var mid0 := _rest_column_y(state, live, 0.0)
	for f in 120:
		_frame(sim, state)
	var sag := _rest_column_y(state, live, 0.0) - _rest_column_y(state, live, 15.0)
	var down := _rest_column_y(state, live, 0.0) - mid0
	var speed := _max_member_speed(state, id)
	_report("jelly 24x6 over a 20 px gap, 120 frames: middle %.2f px below the columns over the pillars (moved down %.2f px), fastest member %.2f px/s, closest non-region pair %.2f px"
			% [sag, down, speed, _self_gap(state, id)])
	expect(sag > 2.0, "the plank bends: its middle sags over 2 px below its ends: %.2f" % sag)
	expect(down < 10.0, "the plank stays on the pillars: middle moved down %.2f px" % down)
	expect(speed < 5.0 * REST_SPEED, "the plank rests, every member under %.1f px/s: %.2f" % [5.0 * REST_SPEED, speed])


## ADR 0005: a 16x10 jelly dropped 40 px wobbles (its shape error peaks at the impact and
## swings), then settles within 2 s and rests.
func test_dropped_jelly_wobbles_and_settles() -> void:
	var world := Vector2(60, 70)
	var sim = _sim(world)
	var state := {"pos": PackedVector2Array(), "vel": PackedVector2Array(), "material": PackedInt32Array()}
	var fl := _floor_y(world)
	var id: int = ParticleStep.make_body(state, _box(Vector2(30, fl - 40.0), 16, 10), _jelly)
	var errs := PackedFloat32Array()
	var landed := -1
	for f in 210:
		_frame(sim, state)
		errs.append(_fit(state, id).err)
		if landed < 0 and fl - _lowest(state, id) < 0.5:
			landed = f
	var rest_err: float = errs[errs.size() - 1]
	var peak := 0.0
	var swings := 0
	var settled := landed
	for f in range(landed, errs.size()):
		peak = maxf(peak, errs[f])
		if f > landed and signf(errs[f] - rest_err) != signf(errs[f - 1] - rest_err):
			swings += 1
		if absf(errs[f] - rest_err) > 0.5:
			settled = f
	var speed := _max_member_speed(state, id)
	_report("jelly 16x10 dropped 40 px: landed frame %d, shape error peak %.2f px, %d swings, within 0.5 px of its rest error (%.2f px) from %.2f s after landing; fastest member at 3.5 s %.2f px/s"
			% [landed, peak, swings, rest_err, (settled - landed) / 60.0, speed])
	expect(peak > 1.0, "the jelly deforms on impact: peak shape error over 1 px: %.2f" % peak)
	expect(swings >= 2, "the jelly wobbles: at least 2 swings: %d" % swings)
	expect(settled - landed < 120, "it settles within 2 s of landing: %.2f s" % ((settled - landed) / 60.0))
	expect(speed < 2.0 * REST_SPEED, "it rests, every member under %.1f px/s: %.2f" % [2.0 * REST_SPEED, speed])


## ADR 0005: a 12x8 carrot set on a 12x8 jelly flattens it; once the carrot is erased the jelly
## gets back within 0.5 px of the height of an unloaded jelly beside it.
func test_jelly_squashes_under_a_carrot_and_springs_back() -> void:
	var world := Vector2(100, 40)
	var sim = _sim(world)
	var state := {"pos": PackedVector2Array(), "vel": PackedVector2Array(), "material": PackedInt32Array()}
	var fl := _floor_y(world)
	var id: int = ParticleStep.make_body(state, _box(Vector2(25, fl), 12, 8), _jelly)
	var control: int = ParticleStep.make_body(state, _box(Vector2(75, fl), 12, 8), _jelly)
	var carrot: int = ParticleStep.make_body(state, _box(Vector2(25, fl - 8 * SimParams.SPACING - 0.5), 12, 8), _carrot)
	for f in 90:
		_frame(sim, state)
	var loaded := _height(state, id)
	var free := _height(state, control)
	ParticleStep.erase_particles(state, _live(state, carrot))
	for f in 90:
		_frame(sim, state)
	var back := absf(_height(state, id) - _height(state, control))
	_report("jelly 12x8 under a 12x8 carrot: %.2f px tall against %.2f px unloaded (%.0f%% squashed); 1.5 s after the carrot is erased %.3f px off the unloaded height"
			% [loaded, free, 100.0 * (1.0 - loaded / free), back])
	expect(loaded < 0.95 * free, "the carrot squashes the jelly by over 5%%: %.2f px against %.2f" % [loaded, free])
	expect(back < 0.5, "the jelly springs back within 0.5 px of an unloaded one: %.3f px" % back)


## ADR 0005 item 4: same-body pairs further apart in the rest shape than the region collide, so a
## 40x3 jelly strip dropped across a carrot folds over it without passing through itself.
func test_jelly_strip_folds_without_passing_through_itself() -> void:
	var world := Vector2(110, 50)
	var sim = _sim(world)
	var state := {"pos": PackedVector2Array(), "vel": PackedVector2Array(), "material": PackedInt32Array()}
	var fl := _floor_y(world)
	ParticleStep.make_body(state, _box(Vector2(55, fl), 6, 10), _carrot)
	var id: int = ParticleStep.make_body(state, _box(Vector2(55, fl - 10 * SimParams.SPACING - 4.0), 40, 3), _jelly)
	var closest := INF
	for f in 120:
		_frame(sim, state)
		if f % 5 == 4:
			closest = minf(closest, _self_gap(state, id))
	var hang := _lowest(state, id) - (fl - 10 * SimParams.SPACING)
	_report("jelly 40x3 over a carrot, 120 frames: ends hang %.1f px below the carrot's top, closest non-region pair %.2f px"
			% [hang, closest])
	expect(hang > 8.0, "the strip folds over the carrot: ends over 8 px below its top: %.1f" % hang)
	expect(closest > 0.75 * SimParams.SPACING, "no member passes through its own body: closest non-region pair %.2f px" % closest)


## ADR 0008: a soft body set on another soft body rests on it. Two 16x10 jellies at stiffness 0.5
## and region 2 (a carrot set soft with the parameter panel, as body_probe set=carrot.stiffness=),
## the upper one 2 px over the lower (just touching), 270 frames. Before ADR 0008 the upper one's
## bottom members slipped between the lower one's and it draped over it (ADR 0008 Context).
func test_soft_body_rests_on_a_soft_body() -> void:
	var world := Vector2(64, 48)
	var sim = _sim(world, {"stiffness": 0.5, "region": 2.0})
	var state := {"pos": PackedVector2Array(), "vel": PackedVector2Array(), "material": PackedInt32Array()}
	var fl := _floor_y(world)
	var low: int = ParticleStep.make_body(state, _box(Vector2(32, fl), 16, 10), _jelly)
	var top: int = ParticleStep.make_body(state, _box(Vector2(32, fl - 10 * SimParams.SPACING), 16, 10), _jelly)
	var most_inside := 0
	var speed := 0.0
	for f in 270:
		_frame(sim, state)
		if f % 10 == 9:
			most_inside = maxi(most_inside, _members_in_lattice(state, top, low) + _members_in_lattice(state, low, top))
		if f >= 240:
			speed = maxf(speed, maxf(_max_member_speed(state, low), _max_member_speed(state, top)))
	var inside := _members_in_lattice(state, top, low) + _members_in_lattice(state, low, top)
	var above: float = _fit(state, low).c.y - _fit(state, top).c.y
	_report("16x10 jelly (stiffness 0.5, region 2) on another, 270 frames: members inside the other %d at the end (most %d at a sample), the upper one's centre %.2f px above the lower one's, |rotation| %.4f / %.4f rad, fastest member over the last 30 frames %.3f px/s"
			% [inside, most_inside, above, absf(_fit(state, low).theta), absf(_fit(state, top).theta), speed])
	expect_eq(most_inside, 0, "no member inside the other jelly at any sample")
	expect(above > 5.0 * SimParams.SPACING, "the upper jelly stays on top: centres %.2f px apart" % above)
	expect(speed < 1.0, "both come to rest, every member under 1 px/s: %.3f" % speed)


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


## 96 px wide: in a 48 px pool the cork, rising at its full buoyancy (p_ref the pressure at its
## top, not 0, see the next test), drifted into a wall and rested on its side against it.
func test_light_box_rises_from_the_bottom() -> void:
	var world := Vector2(96, 60)
	var sim = _sim(world)
	# The pool leaves an 8-column gap on the floor for a cork, with the water around it.
	var state := _pool(world, 48, 18, 8)
	var id: int = ParticleStep.make_body(state, _box(Vector2(48, _floor_y(world)), 8, 6), _cork)
	var late := _settle_in_water(sim, state, id, 420)
	_report("cork box let go on the floor of a pool, 420 frames, last 60: mean draft %.2f of its height, mean speed %.2f px/s, max tilt %.3f rad, %d water inside"
			% [late.draft, late.speed, late.turn, _inside(state, id, _water).size()])
	expect(late.draft > 0.25 and late.draft < 0.7, "the cork rises and floats about half under: draft %.2f" % late.draft)
	# It comes up fast and rocks in this narrow pool's slosh for seconds (still +-0.4 rad at
	# 7 s); the check is that it floats on a face, not on its side (1.57 rad).
	expect(late.turn < 0.6, "the cork floats face up or down, tilt < 0.6 rad: %.3f" % late.turn)


## A bare boundary member (nothing within 1.5 spacings) under water is not out of the water: it
## reads the grid's pressure at its outline point, not 0, so a submerged body's p_ref stays the
## pressure at its top. Read as 0, a void beside one member set p_ref to 0 and the pushes went
## absolute; deep down they hit the half-spacing cap on every face and cancelled. On the GPU a
## 16 x 10 cork under 240 px of poured water, whose small voids sat beside some member nearly
## every substep, stayed on the floor (body_probe pourfloor, pourdrop). Here the pool is
## shallow enough that the cork rose anyway, but p_ref fell to the floor value by frame 30.
func test_submerged_body_keeps_its_reference_pressure() -> void:
	var world := Vector2(96, 60)
	var sim = _sim(world)
	var state := _pool(world, 48, 18, 8)
	var id: int = ParticleStep.make_body(state, _box(Vector2(48, _floor_y(world)), 8, 6), _cork)
	var surface := _floor_y(world) - 17 * SimParams.SPACING
	var lowest := INF
	var frames := 0
	for f in 90:
		_frame(sim, state)
		var top := INF
		for m in _live(state, id):
			top = minf(top, state.pos[m].y)
		if top > surface + 6.0:  # well under the water
			lowest = minf(lowest, state.bodies[id].p_ref)
			frames += 1
	_report("cork box rising from the floor of a 36 px pool, 90 frames: lowest p_ref %.0f over %d frames well under water (floor value %.0f)"
			% [lowest, frames, SimParams.GRAVITY * SimParams.BODY_SURFACE_DROP])
	# Enough frames under water to see p_ref (30 since its whole bottom face is wet, item 15,
	# which lifts it faster; 31+ before).
	expect(frames >= 20, "the cork stays well under water for at least 20 frames: %d" % frames)
	expect(lowest > 1.5 * SimParams.GRAVITY * SimParams.BODY_SURFACE_DROP,
			"under water, p_ref stays the pressure at the cork's top, over 1.5 x the floor value: %.0f" % lowest)


## ADR 0003 item 15: a cork pressed into a sand bed under water rises. Its bottom and lower
## sides touch grains, not water particles; counting only liquid neighbours as its wet face it
## had no lift and stayed in the bed (the owner's report: 10k sand, 10 corks, 20k water, and
## some corks never came up; body_probe sandcorks, 7 of 10 stayed down).
func test_cork_pressed_into_wet_sand_rises() -> void:
	var world := Vector2(64, 60)
	var sim = _sim(world)
	var sp := SimParams.SPACING
	var cols := 31
	var mid := 0.5 * (cols - 1)
	var x0 := 0.5 * (world.x - (cols - 1) * sp)
	var bed_rows := 8
	var sunk := 3  # rows of the bed the cork sits in
	var state := {"pos": PackedVector2Array(), "vel": PackedVector2Array(), "material": PackedInt32Array()}
	for r in 18:
		for c in cols:
			var in_cork := absf(c - mid) < 4.0 and r >= bed_rows - sunk and r < bed_rows - sunk + 6
			if in_cork:
				continue
			state.pos.append(Vector2(x0 + c * sp, _floor_y(world) - r * sp))
			state.vel.append(Vector2.ZERO)
			state.material.append(_sand if r < bed_rows else _water)
	var bottom := _floor_y(world) - (bed_rows - sunk) * sp
	var id: int = ParticleStep.make_body(state, _box(Vector2(world.x * 0.5, bottom), 8, 6), _cork)
	var start := _lowest(state, id)
	# Small and short (~80 s; 47 columns, 24 rows and 300 frames took ~150 s): the CPU
	# reference runs in GDScript. Before item 15: -0.7 px, draft 2.05; after: 8.6 px, 0.97.
	for f in 180:
		_frame(sim, state)
	var risen := start - _lowest(state, id)
	_report("8x6 cork pressed 3 rows into a sand bed under 14 px of water, 180 frames: risen %.1f px, draft %.2f"
			% [risen, _draft(state, id)])
	expect(risen > 5.0, "the cork leaves the bed and rises: %.1f px" % risen)
	expect(_draft(state, id) < 1.2, "the cork reaches the surface: draft %.2f" % _draft(state, id))


## ADR 0003 known limit: water's pressure pushes act on a body's wet particles only, relative to
## its top (p_ref), so a jelly's bottom and lower sides are pushed at up to ~9 g and it was
## squeezed out of shape, with water inside (GPU: 4.4 px off, 20-26 inside). The pushes on a soft
## body are projected onto its rigid motion, so the water moves and turns it without deforming it.
## 150 frames (240 took twice as long): without the projection, 6 water particles got inside in
## both, and the shape error read the same (1.49 px at 240, 1.51 at 150).
func test_sunk_jelly_keeps_its_shape() -> void:
	var world := Vector2(64, 60)
	# The control: the same jelly on the dry floor sags under its own weight.
	var dry_sim = _sim(world)
	var dry := {"pos": PackedVector2Array(), "vel": PackedVector2Array(), "material": PackedInt32Array()}
	var dry_id: int = ParticleStep.make_body(dry, _box(Vector2(32, _floor_y(world)), 16, 10), _jelly)
	for f in 120:
		_frame(dry_sim, dry)
	var sag: float = _fit(dry, dry_id).err
	# The 16x10 jelly main.tscn drops (density 1.1), let go on the floor of a pool, 10 rows of
	# water around it and 10 over it.
	var sim = _sim(world)
	var state := _pool(world, 32, 20, 16, 10)
	var id: int = ParticleStep.make_body(state, _box(Vector2(32, _floor_y(world)), 16, 10), _jelly)
	var most_inside := 0
	var worst := 0.0
	for f in 150:
		_frame(sim, state)
		if f % 10 == 9:
			most_inside = maxi(most_inside, _inside(state, id, _water).size())
			if f >= 90:
				worst = maxf(worst, _fit(state, id).err)
	var above := _floor_y(world) - _lowest(state, id)
	_report("jelly 16x10 on the floor of a pool, 150 frames: shape error up to %.3f px over the last second (%.3f px dry on the floor), %d water inside at the end (most %d), lowest particle %.2f px above the floor, speed %.3f px/s"
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


## ADR 0009: a jelly at the parameter panel's lowest stiffness (0.2) set on sand rests on it. A 12x4
## jelly set on a settled 28x10 bed, 300 frames. Before ADR 0009 grains in the stretched gaps of its
## bottom row were pushed out of its outline every iteration, nothing pushed the member back, and it
## kept moving (a member at 39 px/s over the last 60 frames) and dug 9.4 px into the bed (owner
## report 2026-10-14, body_probe sandjelly). ADR 0009 left it 5.30 px down; with ADR 0013 (grains
## touch a soft member at 1.25 spacings, region members kept in order) it sits 3.12 px down, but
## its bottom row takes until ~480 frames to settle (3.87 px/s at 300), hence 540 frames.
func test_soft_jelly_rests_on_sand() -> void:
	var world := Vector2(64, 80)
	var sim = _sim(world, {"stiffness": 0.2})
	var state := _bed(world, 28, 10)
	for f in 60:
		_frame(sim, state)
	var top := _top_of(state, _sand)
	var id: int = ParticleStep.make_body(state, _box(Vector2(32, top - SimParams.SPACING - 0.5), 12, 4), _jelly)
	var speed := 0.0
	for f in 540:
		_frame(sim, state)
		if f >= 480:
			speed = maxf(speed, _max_member_speed(state, id))
	var sunk := _lowest(state, id) - top
	_report("12x4 jelly (stiffness 0.2) set on a sand bed, 540 frames: fastest member over the last 60 frames %.2f px/s, lowest member %.2f px below the bed's top"
			% [speed, sunk])
	expect(speed < 2.0 * REST_SPEED, "it rests, every member under %.1f px/s: %.2f" % [2.0 * REST_SPEED, speed])
	expect(sunk < 2.0 * SimParams.SPACING, "it doesn't dig into the bed, lowest member under 2 spacings below its top: %.2f px" % sunk)


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
## update, stop_not_launch). The fast drops start the box 20 px above at DROP_SPEED instead (see
## _drop_fast): the same impact in a world a fifth the size, 240 frames instead of 400.
func test_fast_box_drop_stacks_off_centre() -> void:
	var world := Vector2(80, 80)
	var sim = _sim(world)
	var state := {"pos": PackedVector2Array(), "vel": PackedVector2Array(), "material": PackedInt32Array()}
	var floor_y := _floor_y(world)
	var below: int = ParticleStep.make_body(state, _box(Vector2(40, floor_y), 16, 10), _carrot)
	var above: int = ParticleStep.make_body(state, _box(Vector2(44, floor_y - 20.0 - 20.0), 16, 10), _carrot)
	_drop_fast(state, above)
	var touched := false
	var rebound := 0.0
	var max_speed := 0.0
	for f in 240:
		_frame(sim, state)
		var v := _body_vel(state, above)
		touched = touched or _closest_cross_pair(state) < SimParams.SPACING
		if touched:
			rebound = maxf(rebound, -v.y)
		if f >= 180:
			max_speed = maxf(max_speed, v.length())
	var inside := _members_inside(state, below, above) + _members_inside(state, above, below)
	var on_top: bool = _fit(state, above).c.y < _fit(state, below).c.y - 10.0 * SimParams.SPACING + 1.0
	var gap := _closest_cross_pair(state)
	_report("16x10 carrot dropped as from 330 px, 4 px off centre, onto another, 240 frames: on top %s, fastest rebound %.1f px/s, %d members inside the other, closest cross-body pair %.3f px, speed (last 60 frames) %.3f px/s"
			% [on_top, rebound, inside, gap, max_speed])
	expect(on_top, "the box stays on the other")
	expect(rebound < 20.0, "no bounce, rebound < 20 px/s: %.1f" % rebound)
	expect_eq(inside, 0, "no member inside the other box at the end")
	expect(gap >= 0.8 * SimParams.SPACING, "closest cross-body pair >= 0.8 spacing: %.3f px" % gap)
	expect(max_speed < REST_SPEED, "at rest, speed < %.1f px/s: %.3f" % [REST_SPEED, max_speed])


## Without swept contacts the box lodged in the plank (26 members inside, rebound 36 px/s).
func test_fast_box_drop_on_plank_stays_on_top() -> void:
	var world := Vector2(80, 80)
	var sim = _sim(world)
	var state := {"pos": PackedVector2Array(), "vel": PackedVector2Array(), "material": PackedInt32Array()}
	var floor_y := _floor_y(world)
	var plank: int = ParticleStep.make_body(state, _box(Vector2(40, floor_y), 16, 2), _carrot)
	var above: int = ParticleStep.make_body(state, _box(Vector2(44, floor_y - 4.0 - 20.0), 16, 10), _carrot)
	_drop_fast(state, above)
	var r := _drop_run(sim, state, plank, above, 240)
	var on_top: bool = _fit(state, above).c.y < _fit(state, plank).c.y - 6.0 * SimParams.SPACING + 1.0
	_report("16x10 carrot dropped as from 330 px, 4 px off centre, onto a 16x2 plank, 240 frames: on top %s, %s"
			% [on_top, _drop_line(r)])
	expect(on_top, "the box doesn't tunnel through the plank")
	_expect_drop(r)


func test_boxes_colliding_sideways_stay_apart() -> void:
	var world := Vector2(160, 160)
	var sim = _sim(world)
	var state := {"pos": PackedVector2Array(), "vel": PackedVector2Array(), "material": PackedInt32Array()}
	var floor_y := _floor_y(world)
	var left: int = ParticleStep.make_body(state, _box(Vector2(40, floor_y - 120.0), 16, 10), _carrot)
	var right: int = ParticleStep.make_body(state, _box(Vector2(120, floor_y - 120.0), 16, 10), _carrot)
	for m in _live(state, left):
		state.vel[m] = Vector2(200.0, 0.0)
	for m in _live(state, right):
		state.vel[m] = Vector2(-200.0, 0.0)
	var r := _drop_run(sim, state, left, right, 300)
	var apart: float = absf(_fit(state, right).c.x - _fit(state, left).c.x)
	_report("two 16x10 carrots flying at each other at 200 px/s each, 300 frames: centres %.2f px apart, %s"
			% [apart, _drop_line(r)])
	expect(apart > 16.0 * SimParams.SPACING - 1.0, "side by side, not one inside the other: %.2f px apart" % apart)
	_expect_drop(r)


func test_fast_box_drop_on_a_stack_of_three() -> void:
	var world := Vector2(80, 120)
	var sim = _sim(world)
	var state := {"pos": PackedVector2Array(), "vel": PackedVector2Array(), "material": PackedInt32Array()}
	var floor_y := _floor_y(world)
	var stack: Array[int] = []
	for k in 3:
		stack.append(ParticleStep.make_body(state, _box(Vector2(40, floor_y - k * 10.0 * SimParams.SPACING), 16, 10), _carrot))
	var above: int = ParticleStep.make_body(state, _box(Vector2(44, floor_y - 60.0 - 20.0), 16, 10), _carrot)
	_drop_fast(state, above)
	var r := _drop_run(sim, state, stack[2], above, 240)
	var on_top: bool = _fit(state, above).c.y < _fit(state, stack[2]).c.y - 10.0 * SimParams.SPACING + 1.0
	var lean := 0.0
	for id in stack:
		lean = maxf(lean, absf(_fit(state, id).theta))
	_report("16x10 carrot dropped as from 330 px, 4 px off centre, onto a stack of three, 240 frames: on top %s, the stack's |rotation| %.3f rad, %s"
			% [on_top, lean, _drop_line(r)])
	expect(on_top, "the box stays on the stack")
	expect(lean < 0.05, "the stack stays standing, |rotation| < 0.05 rad: %.3f" % lean)
	_expect_drop(r)


func test_erasing_part_of_a_body_works_its_outline_out_again() -> void:
	_sim()
	var state := {"pos": PackedVector2Array(), "vel": PackedVector2Array(), "material": PackedInt32Array()}
	var a: int = ParticleStep.make_body(state, _box(Vector2(20, 50), 8, 6), _carrot)
	var b: int = ParticleStep.make_body(state, _box(Vector2(60, 50), 8, 6), _carrot)
	var sp := SimParams.SPACING
	# Row 1, column 1 is inside the box: its way out is 1.5 spacings to the nearest outline.
	expect(absf(state.edge[9].length() - 1.5 * sp) < 1e-3, "inner member's way out is 1.5 spacings: %.3f" % state.edge[9].length())
	var b_edge: Vector2 = state.edge[48 + 9]
	ParticleStep.erase_particles(state, PackedInt32Array([0, 1, 2]))
	# The eraser took the three members above and left of it: it is on the outline now (index 6
	# after the erase), half a spacing in, out upward toward where the erased members were.
	var e: Vector2 = state.edge[6]
	expect(not state.bodies[a].stale and not state.bodies[b].stale, "both bodies have an outline to push out with")
	expect(absf(e.length() - 0.5 * sp) < 1e-3, "the uncovered member is half a spacing inside the new outline: %.3f" % e.length())
	expect(e.y < 0.0, "its way out leads up, where the erased members were: %s" % str(e))
	expect_eq(state.edge[45 + 9], b_edge, "the other body's outline is unchanged")


func test_erasing_a_body_in_two_makes_two_bodies() -> void:
	var sim = _sim()
	var state := {"pos": PackedVector2Array(), "vel": PackedVector2Array(), "material": PackedInt32Array()}
	var id: int = ParticleStep.make_body(state, _box(Vector2(40, FLOOR), 16, 10), _carrot)
	for f in 60:
		_frame(sim, state)
	var pieces := _erase_middle_columns(state, id)
	expect_eq(pieces.size(), 2, "bodies left after erasing the middle two columns")
	if pieces.size() != 2:
		return
	expect(pieces.has(id), "one piece keeps the body's id")
	for p in pieces:
		expect_eq(_live(state, p).size(), 70, "members of body %d (7 columns x 10 rows)" % p)
		expect(not state.bodies[p].stale, "body %d has an outline to push out with" % p)
	# Lift the right piece: it rises on its own, the left one stays on the floor.
	var left: int = pieces[0] if _fit(state, pieces[0]).c.x < _fit(state, pieces[1]).c.x else pieces[1]
	var right: int = pieces[1] if left == pieces[0] else pieces[0]
	var left_start := _fit(state, left)
	var right_start := _fit(state, right)
	for m in _live(state, right):
		state.vel[m] = Vector2(0.0, -120.0)
	for f in 10:
		_frame(sim, state)
	var lf := _fit(state, left)
	var rf := _fit(state, right)
	var left_moved: float = lf.c.distance_to(left_start.c)
	var rise: float = right_start.c.y - rf.c.y
	_report("box erased in two, right piece lifted: right rose %.2f px, left moved %.4f px and turned %.5f rad, shape errors %.4f / %.4f px"
			% [rise, left_moved, lf.theta, lf.err, rf.err])
	expect(rise > 4.0, "the lifted piece rises, > 4 px: %.2f" % rise)
	expect(left_moved < 0.1, "the other piece stays where it was, < 0.1 px: %.4f" % left_moved)
	expect(absf(lf.theta) < 0.01, "the other piece stays upright, |rotation| < 0.01 rad: %.4f" % lf.theta)
	expect(lf.err < 0.1 and rf.err < 0.1, "both pieces keep their shape within 0.1 px: %.4f, %.4f" % [lf.err, rf.err])


func test_pieces_keep_the_motion_they_had() -> void:
	var sim = _sim(Vector2(120, 160))
	var state := {"pos": PackedVector2Array(), "vel": PackedVector2Array(), "material": PackedInt32Array()}
	# Two boxes falling side by side; the right one is the control, left whole.
	var id: int = ParticleStep.make_body(state, _box(Vector2(30, 40), 16, 10), _carrot)
	var control: int = ParticleStep.make_body(state, _box(Vector2(90, 40), 16, 10), _carrot)
	for f in 20:
		_frame(sim, state)
	var pieces := _erase_middle_columns(state, id)
	expect_eq(pieces.size(), 2, "bodies left of the erased box")
	for f in 5:
		_frame(sim, state)
	var v := _body_vel(state, control)
	var cy: float = _fit(state, control).c.y
	for p in pieces:
		var fit := _fit(state, p)
		var dv: float = _body_vel(state, p).distance_to(v)
		_report("falling box erased in two, piece %d 5 frames after: %.3f px/s off the control's velocity, %.4f px off its height, shape error %.4f px"
				% [p, dv, absf(fit.c.y - cy), fit.err])
		expect(dv < 0.5, "piece %d falls as the control does, within 0.5 px/s: %.3f" % [p, dv])
		expect(absf(fit.c.y - cy) < 0.1, "piece %d is level with the control, within 0.1 px: %.4f" % [p, absf(fit.c.y - cy)])
		expect(fit.err < 0.1, "piece %d keeps its shape within 0.1 px: %.4f" % [p, fit.err])


func test_body_pieces_on_the_rest_lattice() -> void:
	var sp := SimParams.SPACING
	var rest := PackedVector2Array()
	# Three columns on the left, a gap of one column, two on the right, and a lone particle
	# diagonal to the right piece's corner (connected: diagonals touch).
	for y in 4:
		for x in [0, 1, 2, 4, 5]:
			rest.append(Vector2(x, y) * sp)
	rest.append(Vector2(6, 4) * sp)
	var pieces: Array = ParticleStep.body_pieces(rest)
	expect_eq(pieces.size(), 2, "pieces")
	if pieces.size() == 2:
		expect_eq(pieces[0].size(), 12, "the largest piece comes first")
		expect_eq(pieces[1].size(), 9, "the right piece with its diagonal neighbour")


func test_split_plan_for_the_gpu() -> void:
	var sp := SimParams.SPACING
	# A 6 x 2 body whose two middle columns were erased (slots 100.., member range 4..15).
	var rest := PackedVector2Array()
	var slots := PackedInt32Array()
	var live := PackedByteArray()
	for y in 2:
		for x in 6:
			rest.append(Vector2(x, y) * sp)
			slots.append(100 + y * 6 + x)
			live.append(0 if x == 2 or x == 3 else 1)
	var bodies := [{"first": 0, "count": 0, "made": 0}, {"first": 0, "count": 4, "made": 1, "rest": PackedVector2Array()},
			{"first": 4, "count": 12, "made": 1, "rest": rest}]
	var plan: Dictionary = ParticleSim.plan_split(bodies, 2, slots, live, 8, 1000)
	expect_eq(plan.count, 8, "one entry per live member")
	expect_eq(plan.new_ids, PackedInt32Array([3]), "the right piece gets the next free id")
	expect_eq(bodies[2].count, 4, "the kept piece holds the front of the old range")
	expect_eq(bodies[3].first, 12, "the new piece's range starts after the 8 members live at the readback")
	expect_eq(bodies[3].made, ParticleSim.NOT_MADE, "the new piece is made when the split is sent")
	var e: PackedByteArray = plan.entries
	expect_eq([e.decode_u32(0), e.decode_u32(4), e.decode_u32(8), e.decode_u32(12)], [100, 2, 2, 4], "first entry: slot, old id, id, member")
	expect_eq([e.decode_u32(24), e.decode_u32(28)], [4, ParticleSim.SPLIT_FIRST], "it writes the kept piece's record")
	expect_eq([e.decode_u32(4 * 32), e.decode_u32(4 * 32 + 8), e.decode_u32(4 * 32 + 12)], [104, 3, 12], "the right piece's first entry")
	# No id left (max id 2): the right piece stays on the old id, with its own outline.
	bodies = [{"first": 0, "count": 0, "made": 0}, {"first": 0, "count": 4, "made": 1, "rest": PackedVector2Array()},
			{"first": 4, "count": 12, "made": 1, "rest": rest}]
	plan = ParticleSim.plan_split(bodies, 2, slots, live, 2, 1000)
	expect(plan.new_ids.is_empty(), "no new body when no id is free")
	expect_eq(bodies[2].count, 8, "the piece stays on the old body")
	e = plan.entries
	expect_eq(e.decode_u32(28), ParticleSim.SPLIT_FIRST, "one record entry")
	expect_eq(e.decode_u32(7 * 32 + 8), 2, "the last member keeps the old id")
	expect(absf(Vector2(e.decode_float(4 * 32 + 16), e.decode_float(4 * 32 + 20)).length() - 0.5 * sp) < 1e-3,
			"an attached piece still gets its own outline")


# --- Helpers -----------------------------------------------------------------------

## A ParticleStep over the shipped table: rigid "carrot" (stiffness 1), "jelly" (stiffness
## 0.3) and "cork" (rigid, density 0.5: it floats).
## `jelly` sets jelly's parameters for this sim, as the parameter panel does (column -> value).
func _sim(world := WORLD, jelly := {}):
	var table = MaterialTable.new()
	var problems: PackedStringArray = table.load_file()
	expect(problems.is_empty(), "materials.json: %s" % "; ".join(problems))
	_carrot = table.id_of("carrot")
	_jelly = table.id_of("jelly")
	for column in jelly:
		table.set_value(_jelly, column, jelly[column])
	_cork = table.id_of("cork")
	_water = table.id_of("water")
	_sand = table.id_of("sand")
	_region = table.materials[_jelly].region
	return ParticleStep.new(world, table)


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


## Erases the two columns of a body's rest lattice nearest its centroid (a 16-column box loses
## columns 7 and 8). Returns the ids of the bodies that hold what is left of it.
func _erase_middle_columns(state: Dictionary, id: int) -> Array:
	var live := _live(state, id)
	var c0 := Vector2.ZERO
	for m in live:
		c0 += state.rest[m]
	c0 /= live.size()
	var gone := PackedInt32Array()
	for m in live:
		if absf(state.rest[m].x - c0.x) < SimParams.SPACING:
			gone.append(m)
	var others := {}
	for b in state.body:
		if b != id:
			others[b] = true
	ParticleStep.erase_particles(state, gone)
	var ids := []
	for b in state.body:
		if not others.has(b) and not ids.has(b):
			ids.append(b)
	return ids


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


## Sets a body falling at DROP_SPEED. Started 20 px above what it hits, it lands at 386.5 px/s,
## as one dropped from 330 px (387.1 px/s), and the tests' numbers match the 330 px drops on the
## shipped code, without swept contacts and without stop_not_launch (2026-10-14).
func _drop_fast(state: Dictionary, id: int) -> void:
	for m in _live(state, id):
		state.vel[m] = Vector2(0.0, DROP_SPEED)


## Runs a body-on-body impact: `moving` flies at `hit`. Returns the fastest rebound after they
## touch (speed apart along the line between their centroids), the largest |rotation| any
## body reached, the most members inside another body in a frame and in how many frames, and
## at the end: members inside, the closest cross-body pair, shape error and speed over the last
## 60 frames.
func _drop_run(sim, state: Dictionary, hit: int, moving: int, frames: int) -> Dictionary:
	var r := {"rebound": 0.0, "tilt": 0.0, "most_inside": 0, "frames_inside": 0, "speed": 0.0}
	var touched := false
	var ids: Array = range(1, state.bodies.size())
	for f in frames:
		_frame(sim, state)
		touched = touched or _pair_gap(state, hit, moving) < SimParams.SPACING
		var dir: Vector2 = (_fit(state, moving).c - _fit(state, hit).c).normalized()
		if touched:
			r.rebound = maxf(r.rebound, (_body_vel(state, moving) - _body_vel(state, hit)).dot(dir))
		var inside := 0
		for a in ids:
			r.tilt = maxf(r.tilt, absf(_fit(state, a).theta))
			for o in ids:
				if a != o:
					inside += _members_inside(state, a, o)
		r.most_inside = maxi(r.most_inside, inside)
		r.frames_inside += 1 if inside > 0 else 0
		r.inside = inside
		if f >= frames - 60:
			for a in ids:
				r.speed = maxf(r.speed, _body_vel(state, a).length())
	r.gap = _closest_cross_pair(state)
	r.err = 0.0
	for a in ids:
		r.err = maxf(r.err, _fit(state, a).err)
	return r


func _drop_line(r: Dictionary) -> String:
	return "fastest rebound %.1f px/s, largest |rotation| %.3f rad, most members inside another %d (in %d frames), %d at the end, closest cross-body pair %.3f px, shape error %.4f px, speed (last 60 frames) %.3f px/s" \
			% [r.rebound, r.tilt, r.most_inside, r.frames_inside, r.inside, r.gap, r.err, r.speed]


func _expect_drop(r: Dictionary) -> void:
	expect(r.rebound < 20.0, "no bounce, rebound < 20 px/s: %.1f" % r.rebound)
	expect_eq(r.inside, 0, "no member inside another body at the end")
	expect(r.gap >= 0.8 * SimParams.SPACING, "closest cross-body pair >= 0.8 spacing: %.3f px" % r.gap)
	expect(r.err < 0.1, "rigid bodies keep their shape: %.4f px" % r.err)
	expect(r.speed < REST_SPEED, "at rest, speed < %.1f px/s: %.3f" % [REST_SPEED, r.speed])


## Closest pair of particles between two bodies.
func _pair_gap(state: Dictionary, a: int, b: int) -> float:
	var best := INF
	var others := _live(state, b)
	for i in _live(state, a):
		for j in others:
			best = minf(best, state.pos[i].distance_to(state.pos[j]))
	return best


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


## Height of a body: lowest member centre minus highest.
func _height(state: Dictionary, id: int) -> float:
	var top := INF
	for m in _live(state, id):
		top = minf(top, state.pos[m].y)
	return _lowest(state, id) - top


## Mean y of the members whose rest offset x is within a spacing of +-x (both sides).
func _rest_column_y(state: Dictionary, live: PackedInt32Array, x: float) -> float:
	var y := 0.0
	var n := 0
	for m in live:
		if absf(absf(state.rest[m].x) - x) < SimParams.SPACING:
			y += state.pos[m].y
			n += 1
	return y / n


func _max_member_speed(state: Dictionary, id: int) -> float:
	var v := 0.0
	for m in _live(state, id):
		v = maxf(v, state.vel[m].length())
	return v


## Closest pair of a soft body's members that are not in each other's region (further apart in
## the rest shape than its material's region radius): ADR 0005 item 4's self-contacts.
func _self_gap(state: Dictionary, id: int) -> float:
	var w := _region * SimParams.SPACING + 0.01
	var live := _live(state, id)
	var best := INF
	for a in live.size():
		for b in range(a + 1, live.size()):
			if state.rest[live[a]].distance_to(state.rest[live[b]]) > w:
				best = minf(best, state.pos[live[a]].distance_to(state.pos[live[b]]))
	return best


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


## Members of body `id` inside body `other`'s lattice, soft bodies included: each member is taken
## into `other`'s rest frame by a local fit (an affine map, rest -> now, over `other`'s members
## within 1.5 spacings on the rest lattice of its member nearest the point) and counts if it lands
## inside the bounding box of `other`'s rest lattice (past its boundary members). The whole-body
## fit of _members_inside reads a squashed jelly's own dent as overlap.
func _members_in_lattice(state: Dictionary, id: int, other: int) -> int:
	var live := _live(state, other)
	var lo := Vector2(INF, INF)
	var hi := -lo
	for m in live:
		lo = lo.min(state.rest[m])
		hi = hi.max(state.rest[m])
	var n := 0
	for i in _live(state, id):
		var p: Vector2 = state.pos[i]
		var j := -1
		var best := INF
		for m in live:
			var d2: float = p.distance_squared_to(state.pos[m])
			if d2 < best:
				best = d2
				j = m
		if best > 4.0 * SimParams.SPACING * SimParams.SPACING:
			continue
		var near := PackedInt32Array()
		var qm := Vector2.ZERO
		var xm := Vector2.ZERO
		for m in live:
			if state.rest[m].distance_to(state.rest[j]) <= 1.5 * SimParams.SPACING:
				near.append(m)
				qm += state.rest[m]
				xm += state.pos[m]
		qm /= near.size()
		xm /= near.size()
		# x - xm = F (q - qm) with F = (sum x q^T)(sum q q^T)^-1, so q = qm + F^-1 (p - xm).
		var qq := Transform2D(Vector2.ZERO, Vector2.ZERO, Vector2.ZERO)
		var xq := Transform2D(Vector2.ZERO, Vector2.ZERO, Vector2.ZERO)
		for m in near:
			var q: Vector2 = state.rest[m] - qm
			var x: Vector2 = state.pos[m] - xm
			qq.x += q * q.x
			qq.y += q * q.y
			xq.x += x * q.x
			xq.y += x * q.y
		if absf(qq.determinant()) < 1e-6:
			continue
		var f := xq * qq.affine_inverse()
		if absf(f.determinant()) < 1e-6:
			continue
		var q_p: Vector2 = qm + f.affine_inverse().basis_xform(p - xm)
		if q_p.x > lo.x and q_p.x < hi.x and q_p.y > lo.y and q_p.y < hi.y:
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
