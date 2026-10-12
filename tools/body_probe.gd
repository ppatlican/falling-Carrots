## Body probe: the cluster solid scenarios of tests/test_bodies.gd on the GPU sim, plus
## GPU-only checks and timing loads (docs/adr/0002-cluster-solid-layout.md). Needs a real
## window (no --headless). Run it in a copy of the repo, not the repo itself:
##   Godot_console.exe --path <copy> --script res://tools/body_probe.gd -- [scenarios] [from=N] [shots=F,...]
## scenarios: a comma list, default "tests" (the first seven, as in test_bodies.gd):
##   floor    8x6 rigid box resting on the floor, 240 frames: shape error, and |rotation| and
##            centroid speed over the last 120 frames
##   jelly    10x8 jelly (stiffness 0.3) squashed to half height and 1.4x width on the floor,
##            next to an unsquashed control 160 px left, 120 frames: frames until its shape
##            error is under 10% of the start, and at the end its largest distance from the
##            control (shifted onto it)
##   stack3   three 8x5 boxes 1 px apart, each 2 px right of the one below, 300 frames:
##            closest cross-body pair, |rotation|, speed over the last 60 frames
##   stack5   five aligned 8x5 boxes, 300 frames: closest cross-body pair, speed
##   erase    10x6 box at rest for 120 frames, the left half erased (a 200 px eraser whose
##            edge runs through its centroid), 120 more: shape error, sideways drift,
##            rotation, live members read back from its record (30)
##   spawnin  8x6 box spawned 4 px into the floor, 120 frames: peak upward speed, final speed
##   corner   12x5 box dropped on a corner at 30 deg, its lowest corner 4 px up, 300 frames:
##            how far it turns, how far from face-down it ends, wobble and speed at the end
##   sand     a sand bed from wall to wall (320 x 31 grains, so it packs down but doesn't
##            slump), then at frame 300 an 8x6 box dropped from 100 px above the bed's top
##            (it lands at ~280 px/s), 900 frames: the box rests on the bed (shape, rotation,
##            speed over the last 60 frames) and the sand grains inside its outline. Grains
##            get in on such an impact, in the CPU reference too (ADR 0002 known limits), so
##            a count above 0 reads KNOWN
##   sandlow  the same box placed 2 px above the bed's top: it must rest on the bed (shape,
##            speed), with no grain inside, its lowest particle no more than a spacing below
##            the bed's top before the drop
##   sandrow  seven such boxes along the bed (x 80 to 560): how much they tilt and sink
##   reuse    two 8x6 boxes; the first erased whole at frame 60, a new box made at frame 90:
##            the erased body's id and member range are freed and the new box gets them
##            (ParticleSim frees a body when its live count reads back 0), 200 frames
##   many     256 8x6 boxes (one spawns per frame) dropped from a grid into a heap, 1500
##            frames, timed from frame 900: the body pass with every id in use
##   big      one 100x50 box (5000 particles) dropped, 900 frames, timed from 300
##   huge     one 125x80 box (10000 particles) dropped, 900 frames, timed from 300
## Bodies spawn one per frame from frame 1, so a stack's upper boxes start a few frames late.
## Thresholds are the CPU test's (tests/test_bodies.gd); each result line ends PASS or FAIL.
## TIME lines: mean GPU time per pass from frame `from` of each scenario (default: 120 for the
## tests; see above for the loads). Time with --disable-vsync (docs/agents/gpu-probe.md).
## shots=F1,F2 saves the rendered frame of every scenario at those frames to
## user://body_<scenario>_<F>.png.
extends SceneTree

const ComputeContext = preload("res://gpu/compute_context.gd")
const ParticleSim = preload("res://gpu/particle_sim.gd")
const GameConfig = preload("res://core/game_config.gd")
const MaterialTable = preload("res://cpu_ref/material_table.gd")
const SimParams = preload("res://core/sim_params.gd")

const TESTS := ["floor", "jelly", "stack3", "stack5", "erase", "spawnin", "corner"]
## Lowest y a body particle's centre reaches: the fixed 0.5-spacing wall inset.
const FLOOR := 360.0 - 0.5 * SimParams.SPACING
const X := 320.0
## Fastest a body counts as at rest (px/s), as in test_bodies.gd.
const REST_SPEED := 0.5
## Body records read back each sample (ids 0..RECORDS-1).
const RECORDS := 257
## Sand bed of the sand scenarios: wall to wall, so it only packs down.
const BED_COLS := 320
const BED_ROWS := 31

var ctx
var sim
var table
var carrot := -1
var jelly := -1
var sand := -1
var queue: Array = []
var sc := {}  # the running scenario
var frame_i := 0
var waiting := false  # stepping held until a sample is analysed (erase)
var got := {}  # frame -> { buffer name: bytes }
var time_from := -1  # from "from=N"; -1 = the scenario's default
var shots := PackedInt32Array()
var ready := false
var failed := 0


func _initialize() -> void:
	var names := "tests"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("from="):
			time_from = int(a.substr(5))
		elif a.begins_with("shots="):
			for v in a.substr(6).split(","):
				shots.append(int(v))
		else:
			names = a
	for nm in names.split(","):
		if nm == "tests":
			queue.append_array(TESTS)
		else:
			queue.append(nm)
	var config = GameConfig.load_from_file()
	table = _table()
	ctx = ComputeContext.new()
	sim = ParticleSim.new(ctx, config.particle_cap, config.solver_iterations, table, config.substeps, config.body_cap)
	print("body probe: %s, cap %d, body_cap %d, %d substeps x %d iterations"
			% [", ".join(queue), config.particle_cap, config.body_cap, config.substeps, config.solver_iterations])
	sim.setup_finished.connect(_on_setup)
	var err: String = sim.start()
	if err != "":
		print("START FAILED: ", err)
		quit(1)


func _on_setup(err: String) -> void:
	if err != "":
		print("SETUP FAILED: ", err)
		quit(1)
		return
	ready = true


## The shipped table plus test-only rigid ("carrot", stiffness 1) and jelly (stiffness 0.3)
## rows, as tests/test_bodies.gd _sim(): materials.json gets cluster rows in step 5.
func _table():
	var shipped = MaterialTable.new()
	shipped.load_file()
	var rows := []
	for id in shipped.materials:
		rows.append(shipped.materials[id].duplicate(true))
	var sand_row: Dictionary = shipped.materials[shipped.id_of("sand")]
	var c: Dictionary = sand_row.duplicate(true)
	c.merge({"id": 2, "name": "carrot", "class": "cluster", "color": "#e8792b", "density": 1.2, "stiffness": 1.0, "tags": []}, true)
	var j: Dictionary = sand_row.duplicate(true)
	j.merge({"id": 3, "name": "jelly", "class": "cluster", "color": "#d94f8a", "density": 1.1, "stiffness": 0.3, "tags": []}, true)
	rows.append(c)
	rows.append(j)
	var t = MaterialTable.new()
	var problems: PackedStringArray = t.load_rows(rows)
	if not problems.is_empty():
		print("MATERIAL PROBLEMS: ", problems)
	carrot = t.id_of("carrot")
	jelly = t.id_of("jelly")
	sand = t.id_of("sand")
	return t


func _process(_delta: float) -> bool:
	if not ready or waiting:
		return false
	if sc.is_empty():
		if queue.is_empty():
			print("\nbody probe done, %d failed checks" % failed)
			sim.shutdown()
			quit(0 if failed == 0 else 1)
			return false
		_start(queue.pop_front())
		return false
	if frame_i >= sc.frames:
		return false  # waiting for the last samples
	frame_i += 1
	var brush := {"op": ParticleSim.BRUSH_NONE, "pos": Vector2.ZERO, "radius": 0.0, "material": 0, "count": 0, "cols": 1}
	_scenario_brush(brush)
	sim.frame(brush, 0)
	if frame_i >= sc.from:
		for t in ctx.get_timings():
			if t.gpu_us >= 0:
				var acc: Array = sc.times.get(t.name, [0.0, 0])
				sc.times[t.name] = [acc[0] + t.gpu_us, acc[1] + 1]
	if frame_i in shots:
		RenderingServer.call_on_render_thread(_shot_rt.bind(sc.name, frame_i))
	if frame_i % sc.every == 0 or frame_i == sc.frames or frame_i == sc.get("hold", -1):
		if frame_i == sc.get("hold", -1):
			waiting = true
		RenderingServer.call_on_render_thread(_request_rt.bind(frame_i, sc.slots))
	return false


# --- Scenarios ------------------------------------------------------------------------

func _start(name: String) -> void:
	sim.request_clear()
	sim.frame({"op": ParticleSim.BRUSH_NONE, "count": 0}, 0)  # the clear runs in this frame
	frame_i = 0
	got = {}
	sc = {"name": name, "frames": 240, "every": 1, "slots": 0, "from": 120, "times": {}, "ids": [], "max_turn": 0.0,
			"max_speed": 0.0, "run_min": INF}
	match name:
		"floor":
			_body(_box(Vector2(X, FLOOR - 2.0), 8, 6), carrot)
		"jelly":
			sc.frames = 120
			var rest := _box(Vector2(X, FLOOR), 10, 8)
			var squashed := PackedVector2Array()
			for p in rest:
				squashed.append(Vector2(X + (p.x - X) * 1.4, FLOOR - (FLOOR - p.y) * 0.5))
			_body(squashed, jelly, rest)
			var control := PackedVector2Array()
			for p in rest:
				control.append(p - Vector2(160.0, 0.0))
			_body(control, jelly)
			sc.start = _fit_points(squashed, rest).err
			sc.back = -1
		"stack3", "stack5":
			sc.frames = 300
			var n := 3 if name == "stack3" else 5
			for k in n:
				var bottom := FLOOR - 1.0 - k * (5.0 * SimParams.SPACING + 1.0)
				_body(_box(Vector2(X - 4.0 + (2.0 * k if n == 3 else 0.0), bottom), 8, 5), carrot)
		"erase":
			sc.hold = 120
			_body(_box(Vector2(X, FLOOR - 6.0), 10, 6), carrot)
		"spawnin":
			sc.frames = 120
			sc.peak_up = 0.0
			_body(_box(Vector2(X, FLOOR + 4.0), 8, 6), carrot)
		"corner":
			sc.frames = 300
			sc.tilt = deg_to_rad(30.0)
			sc.late = []
			var pts := _box(Vector2(X, 40.0), 12, 5, sc.tilt)
			var lowest := -INF
			for p in pts:
				lowest = maxf(lowest, p.y)
			for i in pts.size():
				pts[i].y += FLOOR - 4.0 - lowest
			_body(pts, carrot)
		"sand", "sandlow", "sandrow":
			sc.frames = 900
			sc.every = 10
			sc.from = 600
			sc.slots = BED_COLS * BED_ROWS
			sc.hold = 299  # read the bed's top under the box, then drop the box at 300
			sc.fall = 100.0 if name == "sand" else 2.0
			sc.xs = [80.0, 160.0, 240.0, 320.0, 400.0, 480.0, 560.0] if name == "sandrow" else [X]
			sc.late_speed = 0.0
		"reuse":
			sc.frames = 200
			_body(_box(Vector2(X - 40.0, FLOOR), 8, 6), carrot)
			_body(_box(Vector2(X + 40.0, FLOOR), 8, 6), carrot)
		"many":
			sc.frames = 1500
			sc.every = 60
			sc.from = 900
			for row in 8:
				for col in 32:
					_body(_box(Vector2(12.0 + 7.0 + col * 19.5, 30.0 + (7 - row) * 18.0), 8, 6), carrot)
		"big", "huge":
			sc.frames = 900
			sc.every = 60
			sc.from = 300
			if name == "big":
				_body(_box(Vector2(X, 150.0), 100, 50), carrot)
			else:
				_body(_box(Vector2(X, 200.0), 125, 80), carrot)
		_:
			print("unknown scenario ", name)
			sc = {}
			return
	if time_from >= 0:
		sc.from = time_from
	print("\n== %s: %d frames, %d bodies made at the start" % [name, sc.frames, sc.ids.size()])


## Makes a body and counts its particles into the readback.
func _body(points: PackedVector2Array, material: int, rest := PackedVector2Array()) -> int:
	var id: int = sim.make_body(points, material, rest)
	if id == 0:
		print("make_body refused (%d particles)" % points.size())
		return 0
	sc.ids.append(id)
	sc.slots += points.size()
	return id


func _scenario_brush(brush: Dictionary) -> void:
	if sc.name.begins_with("sand"):
		if frame_i == 1:
			brush.merge({"op": ParticleSim.BRUSH_BLOCK, "material": sand, "count": BED_COLS * BED_ROWS, "cols": BED_COLS,
					"pos": Vector2(1.0, FLOOR - (BED_ROWS - 1) * SimParams.SPACING)}, true)
		elif frame_i == sc.hold + 1:
			for k in sc.xs.size():  # the first spawns in this frame, the others one per frame
				_body(_box(Vector2(sc.xs[k], sc.bed_tops[k] - sc.fall), 8, 6), carrot)
	elif sc.name == "reuse":
		if frame_i == 60:
			brush.merge({"op": ParticleSim.BRUSH_ERASE, "pos": Vector2(X - 40.0, FLOOR - 5.0), "radius": 20.0}, true)
		elif frame_i == 85:
			sc.count_after_erase = sim.body_count
		elif frame_i == 90:
			sc.new_id = _body(_box(Vector2(X - 40.0, FLOOR), 8, 6), carrot)  # spawns in this frame
			sc.new_first = sim._bodies[sc.new_id].first
	elif sc.name == "erase" and frame_i == sc.hold + 1:
		# The eraser's edge runs through the centroid: it takes the columns left of it.
		var r := 200.0
		brush.merge({"op": ParticleSim.BRUSH_ERASE, "pos": sc.erase_at - Vector2(r, 0.0), "radius": r}, true)


func _sample(f: int, b: Dictionary) -> void:
	var bodies := _bodies_of(b)
	match sc.name:
		"floor":
			var fit := _fit(bodies[1])
			if f > 120:
				sc.max_turn = maxf(sc.max_turn, absf(fit.theta))
				sc.max_speed = maxf(sc.max_speed, _mean_vel(bodies[1]).length())
			if f == sc.frames:
				_result("rigid box on floor: shape error %.5f px after 240 frames; last 120 frames: max |rotation| %.5f rad, max centroid speed %.3f px/s"
						% [fit.err, sc.max_turn, sc.max_speed], fit.err < 0.1 and sc.max_turn < 0.01 and sc.max_speed < REST_SPEED)
		"jelly":
			if not bodies.has(1):
				return
			var fit := _fit(bodies[1])
			if sc.back < 0 and fit.err < 0.1 * sc.start:
				sc.back = f
			if f == sc.frames and bodies.has(2):
				var control := {}
				for k in bodies[2].rest.size():
					control[_key(bodies[2].rest[k])] = bodies[2].pos[k] + Vector2(160.0, 0.0)
				var off := 0.0
				for k in bodies[1].rest.size():
					off = maxf(off, bodies[1].pos[k].distance_to(control[_key(bodies[1].rest[k])]))
				_result("squashed jelly (stiffness 0.3): shape error %.3f px, under 10%% after %d frames; at 2 s %.3f px from an unsquashed jelly at rest (its sag %.3f px)"
						% [sc.start, sc.back, off, _fit(bodies[2]).err], sc.back > 0 and off < 0.1 * sc.start)
		"stack3", "stack5":
			if sc.name == "stack3" and bodies.size() == 3:
				sc.run_min = minf(sc.run_min, _closest_cross_pair(bodies))
			if f > 240:
				for id in bodies:
					sc.max_speed = maxf(sc.max_speed, _mean_vel(bodies[id]).length())
			if f == sc.frames:
				var gap := _closest_cross_pair(bodies)
				for id in bodies:
					sc.max_turn = maxf(sc.max_turn, absf(_fit(bodies[id]).theta))
				var ok: bool = gap >= 0.8 * SimParams.SPACING and sc.max_speed < REST_SPEED
				if sc.name == "stack3":
					ok = ok and sc.max_turn < 0.02
				var run := " (%.3f px over the run)" % sc.run_min if sc.name == "stack3" else ""
				_result("%s: closest cross-body pair %.3f px at rest%s, max |rotation| %.5f rad, max speed (last 60 frames) %.3f px/s"
						% [sc.name, gap, run, sc.max_turn, sc.max_speed], ok)
		"erase":
			var fit := _fit(bodies[1])
			if f == sc.hold:
				sc.erase_at = fit.c
				waiting = false
			elif f == sc.hold + 1:
				sc.start_x = fit.c.x
				sc.max_drift = 0.0
			elif f > sc.hold + 1:
				sc.max_drift = maxf(sc.max_drift, absf(fit.c.x - sc.start_x))
			if f == sc.frames:
				var live: int = b.bodies.decode_u32(1 * ParticleSim.BODY_BYTES + ParticleSim.BODY_LIVE_OFFSET)
				_result("half-erased box: %d live members (record %d), 120 frames after: shape error %.5f px, sideways drift %.4f px, rotation %.5f rad"
						% [bodies[1].pos.size(), live, fit.err, sc.max_drift, fit.theta],
						live == 30 and bodies[1].pos.size() == 30 and fit.err < 0.1 and sc.max_drift < 0.5 and absf(fit.theta) < 0.01)
		"spawnin":
			var v := _mean_vel(bodies[1])
			sc.peak_up = maxf(sc.peak_up, -v.y)
			if f == sc.frames:
				var bound := sqrt(2.0 * SimParams.GRAVITY * SimParams.SPACING)
				_result("box spawned 4 px into the floor: peak upward centroid speed %.2f px/s (launch from %.0f), final speed %.3f px/s"
						% [sc.peak_up, bound, v.length()], sc.peak_up < bound and v.length() < REST_SPEED)
		"corner":
			var now: float = sc.tilt + _fit(bodies[1]).theta
			sc.max_turn = maxf(sc.max_turn, absf(now - sc.tilt))
			if f > 240:
				sc.late.append(now)
			if f == sc.frames:
				var angle: float = sc.late[-1]
				var off_flat := absf(angle - roundf(angle / (PI / 2.0)) * PI / 2.0)
				var wobble: float = sc.late.max() - sc.late.min()
				var speed := _mean_vel(bodies[1]).length()
				_result("12x5 box dropped on a corner at 30 deg: turned up to %.1f deg, ends %.2f deg from a face down, turns %.4f rad over the last 60 frames, speed %.3f px/s"
						% [rad_to_deg(sc.max_turn), rad_to_deg(off_flat), wobble, speed],
						sc.max_turn > deg_to_rad(15.0) and off_flat < 0.05 and wobble < 0.01 and speed < REST_SPEED)
		"sand", "sandlow", "sandrow":
			if f == sc.hold:
				sc.bed_tops = []
				for x in sc.xs:
					sc.bed_tops.append(_sand_top(b, x, 7.0))
				waiting = false
			if sc.name == "sandrow":
				if f == sc.frames:
					var line := "boxes placed 2 px above a sand bed:"
					var worst_sink := -INF
					for id in bodies:
						var fit := _fit(bodies[id])
						var low := -INF
						for p in bodies[id].pos:
							low = maxf(low, p.y)
						var sink: float = low - sc.bed_tops[id - 1]
						worst_sink = maxf(worst_sink, sink)
						line += " x %.0f rot %.3f sink %.2f inside %d;" % [sc.xs[id - 1], fit.theta, sink, _grains_inside(b, bodies[id], fit)]
					_result(line, bodies.size() == sc.xs.size() and worst_sink < SimParams.SPACING)
					_finish()
				return
			if not bodies.has(1):
				return
			var speed := _mean_vel(bodies[1]).length()
			if f > sc.frames - 60:
				sc.late_speed = maxf(sc.late_speed, speed)
			if f == sc.frames:
				var fit := _fit(bodies[1])
				var inside := _grains_inside(b, bodies[1], fit)
				var bottom := -INF
				for p in bodies[1].pos:
					bottom = maxf(bottom, p.y)
				var line := "box dropped %.0f px onto a sand bed (top y %.2f): lowest particle at y %.2f, %d grains inside its outline, shape error %.4f px, rotation %.4f rad, max speed (last 60 frames) %.3f px/s" \
						% [sc.fall, sc.bed_tops[0], bottom, inside, fit.err, fit.theta, sc.late_speed]
				var rests: bool = fit.err < 0.1 and sc.late_speed < REST_SPEED \
						and (sc.name == "sand" or bottom - sc.bed_tops[0] < SimParams.SPACING)
				if sc.name == "sand" and rests and inside > 0:
					print("BODY %s  KNOWN (grains enter a body on a fast impact)" % line)
				else:
					_result(line, rests and inside == 0)
		"reuse":
			if f == sc.frames:
				var live1: int = b.bodies.decode_u32(1 * ParticleSim.BODY_BYTES + ParticleSim.BODY_LIVE_OFFSET)
				var live2: int = b.bodies.decode_u32(2 * ParticleSim.BODY_BYTES + ParticleSim.BODY_LIVE_OFFSET)
				var err := 0.0
				for id in bodies:
					err = maxf(err, _fit(bodies[id]).err)
				_result("body erased whole: %d bodies in use after (was 2), new body got id %d, member range from %d; at the end ids %s, live %d and %d, max shape error %.4f px"
						% [sc.count_after_erase, sc.new_id, sc.new_first, str(bodies.keys()), live1, live2, err],
						sc.count_after_erase == 1 and sc.new_id == 1 and sc.new_first == 0 and live1 == 48 and live2 == 48 and err < 0.1)
		"many", "big", "huge":
			var max_err := 0.0
			var max_speed := 0.0
			var sum_speed := 0.0
			for id in bodies:
				max_err = maxf(max_err, _fit(bodies[id]).err)
				var s := _mean_vel(bodies[id]).length()
				max_speed = maxf(max_speed, s)
				sum_speed += s
			print("  f=%d bodies=%d max shape error %.4f px, centroid speed mean %.3f max %.3f px/s"
					% [f, bodies.size(), max_err, sum_speed / maxi(bodies.size(), 1), max_speed])
			if f == sc.frames:
				_result("%s: %d bodies at the end, max shape error %.4f px, max centroid speed %.3f px/s"
						% [sc.name, bodies.size(), max_err, max_speed], bodies.size() == sc.ids.size() and max_err < 0.1)
	if f == sc.frames:
		_finish()


func _result(line: String, ok: bool) -> void:
	print("BODY %s  %s" % [line, "PASS" if ok else "FAIL"])
	if not ok:
		failed += 1


func _finish() -> void:
	var total := 0.0
	for k in sc.times:
		var us: float = sc.times[k][0] / maxi(sc.times[k][1], 1)
		total += us
		print("TIME %-10s gpu_us=%8.1f" % [k, us])
	print("TIME %-10s gpu_us=%8.1f" % ["total", total])
	sc = {}


# --- Readback -----------------------------------------------------------------------

func _request_rt(f: int, slots: int) -> void:
	var n := maxi(slots, 1)
	for spec in [["pos", n * 8], ["vel", n * 8], ["mat_flags", n * 4], ["rest_offset", n * 8],
			["bodies", RECORDS * ParticleSim.BODY_BYTES]]:
		ctx.readback_async_rt(spec[0], _on_data_rt.bind(spec[0], f), 0, spec[1])


func _on_data_rt(data: PackedByteArray, name: String, f: int) -> void:
	_store.call_deferred(data, name, f)


func _store(data: PackedByteArray, name: String, f: int) -> void:
	if not got.has(f):
		got[f] = {}
	got[f][name] = data
	if got[f].size() == 5:
		var b: Dictionary = got[f]
		got.erase(f)
		if not sc.is_empty():
			_sample(f, b)


func _shot_rt(name: String, f: int) -> void:
	var data: PackedByteArray = ctx.rd.texture_get_data(ctx.texture("image"), 0)
	var size := Vector2i(SimParams.WORLD_SIZE)
	var img := Image.create_from_data(size.x, size.y, false, Image.FORMAT_RGBA8, data)
	var path := "user://body_%s_%d.png" % [name, f]
	img.save_png(path)
	print("SHOT ", ProjectSettings.globalize_path(path))


# --- Measures (as tests/test_bodies.gd) -----------------------------------------------

## Live particles per body id: { id: { "pos", "vel", "rest" } } (PackedVector2Arrays).
func _bodies_of(b: Dictionary) -> Dictionary:
	var out := {}
	var n: int = b.mat_flags.size() / 4
	for i in n:
		var f: int = b.mat_flags.decode_u32(i * 4)
		var id := f >> 16
		if (f & 0x100) == 0 or id == 0:
			continue
		if not out.has(id):
			out[id] = {"pos": PackedVector2Array(), "vel": PackedVector2Array(), "rest": PackedVector2Array()}
		out[id].pos.append(Vector2(b.pos.decode_float(i * 8), b.pos.decode_float(i * 8 + 4)))
		out[id].vel.append(Vector2(b.vel.decode_float(i * 8), b.vel.decode_float(i * 8 + 4)))
		out[id].rest.append(Vector2(b.rest_offset.decode_float(i * 8), b.rest_offset.decode_float(i * 8 + 4)))
	return out


func _fit(body: Dictionary) -> Dictionary:
	return _fit_points(body.pos, body.rest)


## Best fit of a rest shape to positions: centroid c, rest centroid c0, rotation theta and
## the largest distance to the fitted shape (test_bodies.gd _fit).
func _fit_points(pos: PackedVector2Array, rest: PackedVector2Array) -> Dictionary:
	var c := Vector2.ZERO
	var c0 := Vector2.ZERO
	for k in pos.size():
		c += pos[k]
		c0 += rest[k]
	c /= pos.size()
	c0 /= pos.size()
	var dot := 0.0
	var cross := 0.0
	for k in pos.size():
		var p: Vector2 = pos[k] - c
		var q: Vector2 = rest[k] - c0
		dot += p.dot(q)
		cross += q.cross(p)
	var theta := atan2(cross, dot)
	var err := 0.0
	for k in pos.size():
		err = maxf(err, (c + (rest[k] - c0).rotated(theta)).distance_to(pos[k]))
	return {"c": c, "c0": c0, "theta": theta, "err": err}


func _mean_vel(body: Dictionary) -> Vector2:
	var v := Vector2.ZERO
	for u in body.vel:
		v += u
	return v / maxi(body.vel.size(), 1)


func _closest_cross_pair(bodies: Dictionary) -> float:
	var best := INF
	var ids := bodies.keys()
	for a in ids.size():
		for b in range(a + 1, ids.size()):
			for p in bodies[ids[a]].pos:
				for q in bodies[ids[b]].pos:
					best = minf(best, p.distance_to(q))
	return best


func _key(q: Vector2) -> Vector2i:
	return Vector2i(roundi(q.x * 16.0), roundi(q.y * 16.0))


## Sand grains whose position, taken into the box's rest frame, lies inside its rest outline.
func _grains_inside(b: Dictionary, body: Dictionary, fit: Dictionary) -> int:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for q in body.rest:
		lo = lo.min(q)
		hi = hi.max(q)
	var n := 0
	for i in b.mat_flags.size() / 4:
		var f: int = b.mat_flags.decode_u32(i * 4)
		if (f & 0x100) == 0 or (f & 0xFF) != sand:
			continue
		var p := Vector2(b.pos.decode_float(i * 8), b.pos.decode_float(i * 8 + 4))
		var q: Vector2 = (p - fit.c).rotated(-fit.theta) + fit.c0
		if q.x > lo.x and q.x < hi.x and q.y > lo.y and q.y < hi.y:
			n += 1
	return n


## Highest sand grain within half_width of x.
func _sand_top(b: Dictionary, x: float, half_width: float) -> float:
	var top := INF
	for i in b.mat_flags.size() / 4:
		var f: int = b.mat_flags.decode_u32(i * 4)
		if (f & 0x100) == 0 or (f & 0xFF) != sand:
			continue
		var p := Vector2(b.pos.decode_float(i * 8), b.pos.decode_float(i * 8 + 4))
		if absf(p.x - x) < half_width:
			top = minf(top, p.y)
	return top


## A cols x rows lattice at rest spacing whose bottom-centre is at `bottom`, turned by
## `angle` about its centre (test_bodies.gd _box).
func _box(bottom: Vector2, cols: int, rows: int, angle: float = 0.0) -> PackedVector2Array:
	var sp := SimParams.SPACING
	var size := Vector2(cols - 1, rows - 1) * sp
	var centre := bottom - Vector2(0.0, 0.5 * size.y)
	var out := PackedVector2Array()
	for y in rows:
		for x in cols:
			out.append(centre + (Vector2(x, y) * sp - 0.5 * size).rotated(angle))
	return out
