## Body probe: the cluster solid scenarios of tests/test_bodies.gd on the GPU sim, plus
## GPU-only checks and timing loads (docs/adr/0002-cluster-solid-layout.md). Needs a real
## window (no --headless). Run it in a copy of the repo, not the repo itself:
##   Godot_console.exe --path <copy> --script res://tools/body_probe.gd -- [scenarios] [from=N] [shots=F,...] [grid]
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
##            speed over the last 60 frames) with no sand grain inside its outline (the
##            push-out, ADR 0003; before it, 16 grains got in)
##   sandlow  the same box placed 2 px above the bed's top: it must rest on the bed (shape,
##            speed), with no grain inside, its lowest particle no more than a spacing below
##            the bed's top before the drop
##   sandrow  seven such boxes along the bed (x 80 to 560): how much they tilt and sink
##   watersink  a pool from wall to wall (320 x 40 water, 80 px deep), then at frame 120 an 8x6
##            carrot (density 1.2) dropped from 20 px above the water, 600 frames: it sinks to the
##            floor (or onto one layer of water on it) and keeps its shape, with no water inside its
##            outline at any sample (ADR 0003)
##   waterjelly a 16x10 jelly (density 1.1, stiffness 0.3; the size main.tscn drops) dropped as
##            watersink, 600 frames: it sinks and keeps its shape within 2 px (its sag on the floor
##            is ~1 px), with no water inside
##   waterfloat the same pool, an 8x6 cork (density 0.5) set on the water at frame 120, 900
##            frames: over the last 60, its mean draft (share of its height under the water's
##            top particles) 0.25 to 0.7, mean speed under 3 px/s, tilt off level under 0.35 rad
##            (CPU: draft 0.5-0.7, tilted up to ~0.3 rad), no water inside
##   waterdrop  the cork dropped from 60 px above the water: it plunges, comes back up and floats,
##            as waterfloat
##   waterbig   a 40x20 cork set on the water: its cells are bed for the grid (ADR 0003), as
##            waterfloat over 1500 frames: its plunge sets off the pool's symmetric slosh (both
##            ends rise and fall together, ~2.8 s), which it heaves with until that dies out,
##            ~10 s (still 2.6-4 px/s at 900 frames)
##   waterbox   a 16x10 cork (the size main.tscn's Drop buttons make) set on the water, as
##            waterfloat
##   waterdeep  a 270 px deep pool from wall to wall (320 x 135 water), a 16x10 cork let go at y 12
##            at frame 120 (main.tscn's Drop cork): it plunges and floats, as waterfloat
##   waterdeeptilt  the same, the cork turned 30 deg
##   pourfloor  a 16x10 cork on the floor, then 4 x "+10k water" from the top 30 frames apart (main.tscn's
##            fill, as the owner clicks it), 1500 frames: the cork rises through ~240 px of poured
##            water and floats, as waterfloat. Before a bare member read the grid (ADR 0003 item 4),
##            the pour's voids beside it took its buoyancy and it stayed on the floor
##   pourdrop   the same pour, the cork dropped turned 30 deg at frame 75, while it pours
##   sandcorks  as the owner reported, 2026-10-13: "+10k sand" at frame 1, ten 16x10 corks dropped
##            as main.tscn's Drop cork (y 12) along the world from frame 240, then 2 x "+10k water"
##            at frames 600 and 630, 2400 frames: every cork rises off the sand and floats (mean
##            draft under RISEN over the last 60 frames). Corks wedged in a wall corner under the
##            sand slope often stay down (ADR 0003 item 15, Known limits), so it fails now and
##            then. Prints each cork's centre, speed, draft, p_ref, wet flag, its bottom's height
##            over the sand beside it and the grains over its top; with "grid", the grid's columns
##            and each cork's pressure push by row against its weight
##   boxdrop  a 16x10 carrot resting on the floor, a second dropped 150 px straight onto it (frame
##            60), 600 frames: no member of either inside the other's rest lattice at the end,
##            both keep their shape and come to rest (body-body push-out). At ~270 px/s a box
##            moves over a spacing a substep, so members may dip in at the impact: the check
##            allows overlap in 4 samples (5 frames apart), under 2 spacings deep
##   boxtilt  as boxdrop, the falling box turned 30 deg and 6 px to the right, so a corner hits
##   boxhigh  as boxdrop from 330 px (main.tscn's Drop buttons, ~390 px/s at the impact), 4 px to
##            the right: also whether the top box stays on the other. At 1.6 spacings a substep
##            it dipped ~2.5 spacings in for a frame, tilting 0.17 rad, until the swept contacts
##            (ADR 0003 item 14); before item 13 it bounced off
##   plank    as boxhigh onto a 16x2 plank on the floor: whether the carrot tunnels through
##            a body only 2 particles thick at ~390 px/s
##   boxside  two 16x10 carrots let go 120 px above the floor 50 px apart, flying at each other
##            at 200 px/s each (400 px/s together, as boxhigh's impact): no member inside the
##            other at the end, and how fast they come apart again (the rebound, under 20 px/s)
##   boxstack as boxhigh onto a stack of three 16x10 carrots: the top one stays on, the stack
##            stays standing (lower boxes under 0.05 rad at the end)
##            All box scenarios print the largest |rotation| any box reached (the impact tilt).
##   erasemid a 16x10 carrot at rest on the floor, at frame 61 a 10 px eraser at its centroid
##            (it takes a lens of 4 to 10 columns), 240 frames: the two parts left become two
##            bodies (ADR 0004; how many frames that takes), each with its record's live count,
##            a fresh outline (no BODY_STALE), its shape, and no kick (largest speed after the
##            erase, at rest at the end)
##   erasejelly the same with a 16x10 jelly (stiffness 0.3; shape within 2 px, its sag is ~1 px)
##   erasebridge a 30x5 carrot plank laid on two 4x12 pillars under its ends, its middle erased
##            at frame 61 (8 px eraser), 300 frames: each half, now held at its outer end only,
##            tips into the gap (|rotation| over 0.3 rad, centroid down over 5 px). Held as one
##            body, the plank stayed level on the pillars
##   erasedrag the 16x10 carrot, an eraser of 6 px dragged down through its middle from frame 61,
##            3 px a frame for 20 frames (a split while the stroke goes on): two bodies at the
##            end, fresh outlines, shapes, at rest
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
## Pool of the water scenarios: wall to wall, 80 px deep.
const POOL_ROWS := 40
## Pool of the deep water scenarios: wall to wall, 270 px deep (~43k particles, the owner's
## screen of water when a dropped cork stayed on the floor, 2026-10-13).
const DEEP_ROWS := 135
## Blocks of "+10k water" the pour scenarios drop, 30 frames apart.
const POURS := 4
## Mean draft (share of its height under the water) under which a sandcorks cork has risen: ten
## 16x10 corks crowd half the surface and press each other a little under it (draft up to ~1.1).
const RISEN := 1.5

var ctx
var sim
var table
var carrot := -1
var jelly := -1
var cork := -1
var sand := -1
var water := -1
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
		elif a == "grid":
			pass  # debug: water scenarios print grid columns
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


## The shipped table plus test-only rigid ("carrot", stiffness 1), jelly (stiffness 0.3) and
## cork (rigid, density 0.5) rows, as tests/test_bodies.gd _sim(): materials.json gets cluster
## rows in step 5.
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
	var k: Dictionary = sand_row.duplicate(true)
	k.merge({"id": 4, "name": "cork", "class": "cluster", "color": "#c8a46e", "density": 0.5, "stiffness": 1.0, "tags": []}, true)
	rows.append(c)
	rows.append(j)
	rows.append(k)
	var t = MaterialTable.new()
	var problems: PackedStringArray = t.load_rows(rows)
	if not problems.is_empty():
		print("MATERIAL PROBLEMS: ", problems)
	carrot = t.id_of("carrot")
	jelly = t.id_of("jelly")
	cork = t.id_of("cork")
	sand = t.id_of("sand")
	water = t.id_of("water")
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
		"erasemid", "erasejelly", "erasedrag":
			sc.hold = 60
			sc.target = _body(_box(Vector2(X, FLOOR), 16, 10), jelly if name == "erasejelly" else carrot)
			sc.split_at = -1
			sc.max_after = 0.0
		"erasebridge":
			sc.frames = 300
			sc.hold = 60
			sc.split_at = -1
			# Pillars under the plank's ends; the plank's bottom row a spacing above their tops.
			var sp := SimParams.SPACING
			_body(_box(Vector2(X - 26.0, FLOOR), 4, 12), carrot)
			_body(_box(Vector2(X + 26.0, FLOOR), 4, 12), carrot)
			sc.target = _body(_box(Vector2(X, FLOOR - 12.0 * sp), 30, 5), carrot)
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
		"watersink", "waterjelly", "waterfloat", "waterdrop", "waterbig", "waterbox", "waterdeep", "waterdeeptilt", "pourfloor", "pourdrop":
			sc.frames = {"watersink": 600, "waterjelly": 600, "waterbig": 1500}.get(name, 900)
			sc.every = 10
			sc.from = 600
			sc.rows = DEEP_ROWS if name.begins_with("waterdeep") else POOL_ROWS
			sc.slots = BED_COLS * sc.rows
			sc.hold = 119
			if name.begins_with("pour"):
				# As the owner fills main.tscn: "+10k water" every 30 frames, POURS times.
				sc.frames = 1500
				sc.slots = POURS * SimParams.BENCH_BLOCK
				sc.hold = -2
				sc.water_top = 90.0
				if name == "pourfloor":
					_body(_box(Vector2(X, FLOOR), 16, 10), cork)  # read the water's top, then make the body at 120
			sc.most_inside = 0
			sc.late = []
		"sandcorks":
			sc.frames = 2400
			sc.every = 10
			sc.from = 1200
			sc.slots = 3 * SimParams.BENCH_BLOCK
			sc.late = {}
			sc.risen = {}
		"boxdrop", "boxtilt", "boxhigh", "plank", "boxside", "boxstack":
			sc.frames = 600
			sc.every = 5
			sc.most_inside = 0
			sc.late_speed = 0.0
			sc.max_tilt = 0.0
			sc.rebound = 0.0
			sc.touched = false
			match name:
				"plank":
					_body(_box(Vector2(X, FLOOR), 16, 2), carrot)
				"boxside":
					# Bodies spawn one per frame, so the second starts where and as fast as it
					# would be had it been made with the first (one frame of 2 substeps of fall),
					# and they meet level, as in the CPU test. Started a frame late (0.9 px lower)
					# it passes too: the pair turns together up to 0.07 rad before it lands.
					for k in 2:
						var side := -1.0 if k == 0 else 1.0
						var sub := SimParams.DT / 2.0
						var at := Vector2(X + side * 40.0 - side * 200.0 * SimParams.DT * k,
								FLOOR - 120.0 + 3.0 * SimParams.GRAVITY * sub * sub * k)
						_body(_box(at, 16, 10), carrot, PackedVector2Array(),
								Vector2(-side * 200.0, SimParams.GRAVITY * SimParams.DT * k))
				"boxstack":
					for k in 3:
						_body(_box(Vector2(X, FLOOR - k * 10.0 * SimParams.SPACING), 16, 10), carrot)
				_:
					_body(_box(Vector2(X, FLOOR), 16, 10), carrot)
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
func _body(points: PackedVector2Array, material: int, rest := PackedVector2Array(), velocity := Vector2.ZERO) -> int:
	var id: int = sim.make_body(points, material, rest, velocity)
	if id == 0:
		print("make_body refused (%d particles)" % points.size())
		return 0
	sc.ids.append(id)
	sc.slots += points.size()
	return id


func _scenario_brush(brush: Dictionary) -> void:
	if sc.name in ["sand", "sandlow", "sandrow"]:
		if frame_i == 1:
			brush.merge({"op": ParticleSim.BRUSH_BLOCK, "material": sand, "count": BED_COLS * BED_ROWS, "cols": BED_COLS,
					"pos": Vector2(1.0, FLOOR - (BED_ROWS - 1) * SimParams.SPACING)}, true)
		elif frame_i == sc.hold + 1:
			for k in sc.xs.size():  # the first spawns in this frame, the others one per frame
				_body(_box(Vector2(sc.xs[k], sc.bed_tops[k] - sc.fall), 8, 6), carrot)
	elif sc.name == "sandcorks":
		var cols := SimParams.BENCH_COLS
		var block := {"op": ParticleSim.BRUSH_BLOCK, "count": SimParams.BENCH_BLOCK, "cols": cols,
				"pos": Vector2((SimParams.WORLD_SIZE.x - cols * SimParams.SPACING) * 0.5, 8.0)}
		if frame_i == 1:
			brush.merge(block, true)
			brush.material = sand
		elif frame_i == 240:
			for k in 10:  # the first spawns in this frame, the others one per frame
				_body(_box(Vector2(55.0 + k * 58.0, 30.0), 16, 10), cork)
		elif frame_i == 600 or frame_i == 630:
			brush.merge(block, true)
			brush.material = water
	elif sc.name.begins_with("pour"):
		if frame_i % 30 == 0 and frame_i <= 30 * POURS:
			var cols := SimParams.BENCH_COLS
			brush.merge({"op": ParticleSim.BRUSH_BLOCK, "material": water, "count": SimParams.BENCH_BLOCK, "cols": cols,
					"pos": Vector2((SimParams.WORLD_SIZE.x - cols * SimParams.SPACING) * 0.5, 8.0)}, true)
		elif sc.name == "pourdrop" and frame_i == 75:
			# As main.tscn's Drop cork while the water is still coming in, turned 30 deg.
			_body(_box(Vector2(X, 30.0), 16, 10, deg_to_rad(30.0)), cork, _box(Vector2(X, 30.0), 16, 10))
	elif sc.name.begins_with("water"):
		if frame_i == 1:
			brush.merge({"op": ParticleSim.BRUSH_BLOCK, "material": water, "count": BED_COLS * sc.rows, "cols": BED_COLS,
					"pos": Vector2(1.0, FLOOR - (sc.rows - 1) * SimParams.SPACING)}, true)
		elif frame_i == sc.hold + 1:
			var top: float = sc.water_top
			match sc.name:
				"watersink":
					_body(_box(Vector2(X, top - 20.0), 8, 6), carrot)
				"waterjelly":
					_body(_box(Vector2(X, top - 20.0), 16, 10), jelly)
				"waterfloat":
					_body(_box(Vector2(X, top - 1.0), 8, 6), cork)
				"waterdrop":
					_body(_box(Vector2(X, top - 60.0), 8, 6), cork)
				"waterbig":
					_body(_box(Vector2(X, top - 1.0), 40, 20), cork)
				"waterbox":
					_body(_box(Vector2(X, top - 1.0), 16, 10), cork)
				"waterdeep", "waterdeeptilt":
					# As main.tscn's Drop cork: a 16x10 cork let go at y 12 (bottom row at 30).
					var tilt := deg_to_rad(30.0) if sc.name == "waterdeeptilt" else 0.0
					_body(_box(Vector2(X, 30.0), 16, 10, tilt), cork, _box(Vector2(X, 30.0), 16, 10))
	elif sc.name in ["boxdrop", "boxtilt", "boxhigh", "plank", "boxstack"] and frame_i == 60:
		var tilt := deg_to_rad(30.0) if sc.name == "boxtilt" else 0.0
		var dx: float = {"boxtilt": 6.0, "boxhigh": 4.0, "plank": 4.0, "boxstack": 4.0}.get(sc.name, 0.0)
		# Height of what it lands on, in spacings: the plank's 2 rows, the stack's 3 boxes.
		var under: float = {"plank": 2.0, "boxstack": 30.0}.get(sc.name, 10.0)
		var fall := 150.0 if sc.name in ["boxdrop", "boxtilt"] else 330.0
		var at := Vector2(X + dx, FLOOR - under * SimParams.SPACING - fall)
		# An upright rest shape, so _members_inside's box is the body's own.
		_body(_box(at, 16, 10, tilt), carrot, _box(at, 16, 10))
	elif sc.name == "reuse":
		if frame_i == 60:
			brush.merge({"op": ParticleSim.BRUSH_ERASE, "pos": Vector2(X - 40.0, FLOOR - 5.0), "radius": 20.0}, true)
		elif frame_i == 85:
			sc.count_after_erase = sim.body_count
		elif frame_i == 90:
			sc.new_id = _body(_box(Vector2(X - 40.0, FLOOR), 8, 6), carrot)  # spawns in this frame
			sc.new_first = sim._bodies[sc.new_id].first
	elif sc.name in ["erasemid", "erasejelly", "erasebridge"] and frame_i == sc.hold + 1:
		brush.merge({"op": ParticleSim.BRUSH_ERASE, "pos": sc.erase_at, "radius": 8.0 if sc.name == "erasebridge" else 10.0}, true)
	elif sc.name == "erasedrag" and frame_i > sc.hold and frame_i <= sc.hold + 20:
		var k: int = frame_i - sc.hold - 1
		brush.merge({"op": ParticleSim.BRUSH_ERASE, "pos": sc.erase_at + Vector2(0.0, -30.0 + 3.0 * k), "radius": 6.0}, true)
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
		"erasemid", "erasejelly", "erasebridge", "erasedrag":
			_sample_split(f, b, bodies)
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
				_result(line, rests and inside == 0)
		"watersink", "waterjelly", "waterfloat", "waterdrop", "waterbig", "waterbox", "waterdeep", "waterdeeptilt", "pourfloor", "pourdrop":
			if f == sc.hold:
				sc.water_top = _top_of(b, water, X, 40.0)
				waiting = false
			if not bodies.has(1):
				return
			var fit := _fit(bodies[1])
			var inside := _inside(b, bodies[1], fit, water)
			sc.most_inside = maxi(sc.most_inside, inside)
			if f % 60 == 0 or (sc.name.begins_with("waterdeep") and f % 20 == 0) or (sc.name.begins_with("pour") and f % 20 == 0):
				print("  f=%d c=(%.1f, %.1f) rot %.3f v=%s draft %.2f inside %d; water top at x 40 / 600 %.1f / %.1f; p_ref %.0f" % [f, fit.c.x, fit.c.y, fit.theta,
						_mean_vel(bodies[1]), _draft(b, bodies[1]), inside, _top_of(b, water, 40.0, 17.0), _top_of(b, water, 600.0, 17.0),
						b.bodies.decode_float(1 * ParticleSim.BODY_BYTES + 40)])
			if f % 300 == 0 and OS.get_cmdline_user_args().has("grid"):
				_print_grid_columns(b, [fit.c.x, fit.c.x + 120.0])
				var top := INF
				var left := INF
				var right := -INF
				for q in bodies[1].pos:
					top = minf(top, q.y)
					left = minf(left, q.x)
					right = maxf(right, q.x)
				var on_top := 0
				for i in b.mat_flags.size() / 4:
					var mf: int = b.mat_flags.decode_u32(i * 4)
					var q := Vector2(b.pos.decode_float(i * 8), b.pos.decode_float(i * 8 + 4))
					if (mf & 0x100) != 0 and (mf & 0xFF) == water and q.y < top and q.x > left and q.x < right:
						on_top += 1
				_print_pressure_push(b, bodies[1])
				print("  record: p_ref %.1f p_min bits %x flags %d; water over the body %d" % [
						b.bodies.decode_float(1 * ParticleSim.BODY_BYTES + 40), b.bodies.decode_u32(1 * ParticleSim.BODY_BYTES + 44),
						b.bodies.decode_u32(1 * ParticleSim.BODY_BYTES + 12), on_top])
			if f > sc.frames - 60:
				var theta: float = fit.theta
				sc.late.append([_draft(b, bodies[1]), _mean_vel(bodies[1]).length(), absf(theta - roundf(theta / PI) * PI)])
			if f == sc.frames:
				var draft := 0.0
				var speed := 0.0
				var tilt := 0.0
				for v in sc.late:
					draft += v[0] / sc.late.size()
					speed += v[1] / sc.late.size()
					tilt = maxf(tilt, v[2])
				var bottom := -INF
				for q in bodies[1].pos:
					bottom = maxf(bottom, q.y)
				if sc.name == "watersink":
					_result("carrot dropped into an 80 px pool: lowest particle %.2f px above the floor, water inside its outline %d at the end (most %d at a sample), shape error %.4f px, rotation %.4f rad, speed %.3f px/s"
							% [FLOOR - bottom, inside, sc.most_inside, fit.err, fit.theta, _mean_vel(bodies[1]).length()],
							FLOOR - bottom < 2.0 * SimParams.SPACING and sc.most_inside == 0 and fit.err < 0.1)
				elif sc.name == "waterjelly":
					_result("16x10 jelly (density 1.1) dropped into an 80 px pool: lowest particle %.2f px above the floor, water inside its outline %d at the end (most %d at a sample), shape error %.3f px, speed %.3f px/s"
							% [FLOOR - bottom, inside, sc.most_inside, fit.err, _mean_vel(bodies[1]).length()],
							FLOOR - bottom < 2.0 * SimParams.SPACING and sc.most_inside == 0 and fit.err < 2.0)
				else:
					_result("%s: cork, last 60 frames: mean draft %.2f of its height, mean speed %.2f px/s, max tilt %.3f rad; water inside %d at the end (most %d at a sample), shape error %.4f px"
							% [sc.name, draft, speed, tilt, inside, sc.most_inside, fit.err],
							draft > 0.25 and draft < 0.7 and speed < 3.0 and tilt < 0.35 and inside == 0 and fit.err < 0.1)
		"sandcorks":
			_sample_sandcorks(f, b, bodies)
		"boxdrop", "boxtilt", "boxhigh", "plank", "boxside", "boxstack":
			if bodies.size() < sc.ids.size() or sc.ids.size() < 2:
				return
			var ids: Array = bodies.keys()
			ids.sort()
			var fits := {}
			for id in ids:
				fits[id] = _fit(bodies[id])
				sc.max_tilt = maxf(sc.max_tilt, absf(fits[id].theta))
			var inside := 0
			for a in ids:
				for o in ids:
					if a != o:
						inside += _members_inside(bodies[a], bodies[o])
			sc.most_inside = maxi(sc.most_inside, inside)
			sc.most_deep = maxf(sc.get("most_deep", 0.0), sc.deepest)
			sc.overlap_samples = sc.get("overlap_samples", 0) + (1 if inside > 0 else 0)
			# The moving box (the last made) and the one it hits (the one made before it).
			var top: int = ids[-1]
			var low: int = ids[-2]
			if not sc.touched:
				for p in bodies[top].pos:
					for q in bodies[low].pos:
						if p.distance_to(q) < SimParams.SPACING:
							sc.touched = true
							break
					if sc.touched:
						break
			if sc.touched:
				# Speed apart along the line from the hit box to the moving one, after they met.
				var dir: Vector2 = (fits[top].c - fits[low].c).normalized()
				if sc.name != "boxside":
					dir = Vector2.UP
				sc.rebound = maxf(sc.rebound, (_mean_vel(bodies[top]) - _mean_vel(bodies[low])).dot(dir))
			if f > sc.frames - 60:
				for id in bodies:
					sc.late_speed = maxf(sc.late_speed, _mean_vel(bodies[id]).length())
			if f % 60 == 0 or inside > 0:
				print("  f=%d top box c=(%.1f, %.1f) rot %.3f v=%s, members inside another %d (deepest %.2f px into an outline), shape errors %s" % [f, fits[top].c.x, fits[top].c.y,
						fits[top].theta, _mean_vel(bodies[top]), inside, sc.deepest, ", ".join(ids.map(func(id): return "%.3f" % fits[id].err))])
			sc.deepest = 0.0
			if f == sc.frames:
				var err := 0.0
				var low_tilt := 0.0
				for id in ids:
					err = maxf(err, fits[id].err)
					if id != top:
						low_tilt = maxf(low_tilt, absf(fits[id].theta))
				var gap := _closest_cross_pair(bodies)
				var below: float = {"plank": 2.0}.get(sc.name, 10.0)
				var on_top: bool = fits[top].c.y < fits[low].c.y - 0.5 * (10.0 + below) * SimParams.SPACING + 1.0
				if sc.name == "boxside":
					on_top = absf(fits[top].c.x - fits[low].c.x) > 16.0 * SimParams.SPACING - 1.0  # side by side
				_result("%s: 16x10 carrot dropped onto another (%s at the end: %s): members inside another %d at the end (most %d, deepest %.2f px into an outline, in %d samples), closest cross-body pair %.3f px, max shape error %.4f px, max speed (last 60 frames) %.3f px/s, largest |rotation| %.3f rad, rebound %.1f px/s, lower boxes' |rotation| at the end %.3f rad"
						% [sc.name, "side by side" if sc.name == "boxside" else "on top", on_top, inside, sc.most_inside, sc.most_deep, sc.overlap_samples, gap, err,
						sc.late_speed, sc.max_tilt, sc.rebound, low_tilt],
						inside == 0 and sc.overlap_samples <= 4
						and sc.most_deep < 2.0 * SimParams.SPACING
						and gap >= 0.8 * SimParams.SPACING and err < 0.1 and sc.late_speed < REST_SPEED
						and (on_top or sc.name == "boxtilt") and (sc.rebound < 20.0 or sc.name in ["boxdrop", "boxtilt"])
						and (low_tilt < 0.05 or sc.name != "boxstack"))
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


## The erase-split scenarios: the target body's pieces are the ids other than the ones made
## at the start besides it (the bridge's pillars).
func _sample_sandcorks(f: int, b: Dictionary, bodies: Dictionary) -> void:
	if f % 60 != 0 and f <= sc.frames - 60:
		return
	var ids: Array = bodies.keys()
	ids.sort()
	var line := "  f=%d" % f
	for id in ids:
		var top := INF
		var bottom := -INF
		var left := INF
		var right := -INF
		for q in bodies[id].pos:
			top = minf(top, q.y)
			bottom = maxf(bottom, q.y)
			left = minf(left, q.x)
			right = maxf(right, q.x)
		var over := 0
		for i in b.mat_flags.size() / 4:
			var mf: int = b.mat_flags.decode_u32(i * 4)
			if (mf & 0x100) == 0 or (mf & 0xFF) != sand or (mf >> 16) != 0:
				continue
			var q := Vector2(b.pos.decode_float(i * 8), b.pos.decode_float(i * 8 + 4))
			if q.x > left and q.x < right and q.y < top:
				over += 1
		var c := 0.5 * Vector2(left + right, top + bottom)
		var base: int = id * ParticleSim.BODY_BYTES
		var draft := _draft(b, bodies[id]) if f > 630 else 0.0
		if f > sc.frames - 60:
			sc.late[id] = sc.late.get(id, []) + [draft]
		if f > 630 and draft < RISEN and not sc.risen.has(id):
			sc.risen[id] = f
		if f % 60 == 0:
			var beside := minf(_sand_top(b, left - 12.0, 8.0), _sand_top(b, right + 12.0, 8.0))
			var low_fill := INF  # the grid's least liquid fill at the bottom row (BODY_PORE_WET)
			for q in bodies[id].pos:
				if q.y > bottom - 0.5 * SimParams.SPACING:
					low_fill = minf(low_fill, _grid_liquid(b, q))
			line += " | %d (%.0f,%.0f) v%.0f d%.2f pr%.0f w%d bed%.0f over%d lq%.2f" % [id, c.x, c.y, _mean_vel(bodies[id]).length(), draft,
					b.bodies.decode_float(base + 40), (b.bodies.decode_u32(base + 12) >> 2) & 1, beside - bottom, over, low_fill]
	if f % 60 == 0:
		print(line)
	if (f == 540 or f == 1800) and OS.get_cmdline_user_args().has("grid"):
		_print_grid_columns(b, [284.0, 100.0])
	if f >= 900 and f % 300 == 0 and OS.get_cmdline_user_args().has("grid"):
		_print_grid_columns(b, [8.0, 24.0, 616.0, 632.0])
	if (f == 900 or f == 1200 or f == sc.frames) and OS.get_cmdline_user_args().has("grid"):
		for id in ids:
			_print_cork_push(b, id, bodies[id])
	if f == sc.frames:
		var stuck := []
		for id in sc.late:
			var mean := 0.0
			for v in sc.late[id]:
				mean += v / sc.late[id].size()
			if mean >= RISEN:
				stuck.append("%d (draft %.2f)" % [id, mean])
		var times := []
		for id in ids:
			times.append("%.1f" % ((sc.risen[id] - 630) / 60.0) if sc.risen.has(id) else "-")
		_result("sandcorks: %d of %d corks float; under water: %s; seconds from the second pour to the surface: %s"
				% [ids.size() - stuck.size(), ids.size(), ", ".join(stuck), " ".join(times)],
				ids.size() == 10 and stuck.is_empty())


func _sample_split(f: int, b: Dictionary, bodies: Dictionary) -> void:
	var pieces := []
	for id in bodies:
		if id == sc.target or not sc.ids.has(id):
			pieces.append(id)
	if f == sc.hold:
		sc.erase_at = _fit(bodies[sc.target]).c
		sc.start_y = sc.erase_at.y
		waiting = false
		return
	if f <= sc.hold:
		return
	if sc.split_at < 0 and pieces.size() >= 2:
		sc.split_at = f - sc.hold - 1
	if sc.name != "erasebridge":
		for id in pieces:
			sc.max_after = maxf(sc.max_after, _mean_vel(bodies[id]).length())
	if f != sc.frames:
		return
	var stale := 0
	var records_ok := true
	var err := 0.0
	var speed := 0.0
	var sizes := []
	var turns := []
	var drops := []
	for id in pieces:
		var at: int = id * ParticleSim.BODY_BYTES
		var live: int = b.bodies.decode_u32(at + ParticleSim.BODY_LIVE_OFFSET)
		stale += 1 if b.bodies.decode_u32(at + ParticleSim.BODY_FLAGS_OFFSET) & ParticleSim.BODY_STALE else 0
		records_ok = records_ok and live == bodies[id].pos.size()
		var fit := _fit(bodies[id])
		err = maxf(err, fit.err)
		speed = maxf(speed, _mean_vel(bodies[id]).length())
		sizes.append(bodies[id].pos.size())
		turns.append(snappedf(fit.theta, 0.001))
		drops.append(snappedf(fit.c.y - sc.start_y, 0.01))
	var line := "%s: %d bodies left of the erased one (ids %s, members %s), split seen %d frames after the erase; records' live counts match %s, stale outlines %d; max shape error %.4f px, rotations %s rad, centroids down %s px, speed at the end %.3f px/s" % [
			sc.name, pieces.size(), str(pieces), str(sizes), sc.split_at, records_ok, stale, err, str(turns), str(drops), speed]
	var ok: bool = pieces.size() == 2 and records_ok and stale == 0
	if sc.name == "erasebridge":
		ok = ok and absf(turns[0]) > 0.3 and absf(turns[1]) > 0.3 and drops[0] > 5.0 and drops[1] > 5.0 and err < 0.1
	else:
		line += ", largest piece speed after the erase %.3f px/s" % sc.max_after
		ok = ok and err < (2.0 if sc.name == "erasejelly" else 0.1) and speed < REST_SPEED
	_result(line, ok)


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
	for spec in [["pos", n * 8], ["vel", n * 8], ["mat_flags", n * 4], ["rest_offset", n * 16],
			["bodies", RECORDS * ParticleSim.BODY_BYTES], ["hydro_p", 0], ["hydro_phi", 0]]:
		ctx.readback_async_rt(spec[0], _on_data_rt.bind(spec[0], f), 0, spec[1])


func _on_data_rt(data: PackedByteArray, name: String, f: int) -> void:
	_store.call_deferred(data, name, f)


func _store(data: PackedByteArray, name: String, f: int) -> void:
	if not got.has(f):
		got[f] = {}
	got[f][name] = data
	if got[f].size() == 7:
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
			out[id] = {"pos": PackedVector2Array(), "vel": PackedVector2Array(), "rest": PackedVector2Array(), "e": PackedVector2Array()}
		out[id].pos.append(Vector2(b.pos.decode_float(i * 8), b.pos.decode_float(i * 8 + 4)))
		out[id].vel.append(Vector2(b.vel.decode_float(i * 8), b.vel.decode_float(i * 8 + 4)))
		out[id].rest.append(Vector2(b.rest_offset.decode_float(i * 16), b.rest_offset.decode_float(i * 16 + 4)))
		out[id].e.append(Vector2(b.rest_offset.decode_float(i * 16 + 8), b.rest_offset.decode_float(i * 16 + 12)))
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
	return _inside(b, body, fit, sand)


## Members of body `other` whose position, taken into `body`'s rest frame, lies inside the
## bounding box of its rest lattice: more than a spacing into it.
func _members_inside(body: Dictionary, other: Dictionary) -> int:
	var fit := _fit(body)
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for q in body.rest:
		lo = lo.min(q)
		hi = hi.max(q)
	var n := 0
	for p in other.pos:
		var q: Vector2 = (p - fit.c).rotated(-fit.theta) + fit.c0
		if q.x > lo.x and q.x < hi.x and q.y > lo.y and q.y < hi.y:
			n += 1
		# Depth inside the outline (half a spacing outside the lattice).
		var depth := minf(minf(q.x - lo.x, hi.x - q.x), minf(q.y - lo.y, hi.y - q.y)) + 0.5 * SimParams.SPACING
		sc.deepest = maxf(sc.get("deepest", 0.0), depth)
	return n


## Particles of `material` whose position, taken into the box's rest frame, lies inside the
## bounding box of its rest lattice.
func _inside(b: Dictionary, body: Dictionary, fit: Dictionary, material: int) -> int:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for q in body.rest:
		lo = lo.min(q)
		hi = hi.max(q)
	var n := 0
	for i in b.mat_flags.size() / 4:
		var f: int = b.mat_flags.decode_u32(i * 4)
		if (f & 0x100) == 0 or (f & 0xFF) != material or (f >> 16) != 0:
			continue
		var p := Vector2(b.pos.decode_float(i * 8), b.pos.decode_float(i * 8 + 4))
		var q: Vector2 = (p - fit.c).rotated(-fit.theta) + fit.c0
		if q.x > lo.x and q.x < hi.x and q.y > lo.y and q.y < hi.y:
			n += 1
	return n


## Debug ("grid" argument): the density projection grid's p and channels down the columns
## at the given x, from y 160 to the floor.
func _print_grid_columns(b: Dictionary, xs: Array) -> void:
	var cell := SimParams.H * SimParams.HYDRO_CELL
	var gw := ceili(SimParams.WORLD_SIZE.x / SimParams.H)
	var size := Vector2i((gw + SimParams.HYDRO_CELL - 1) / SimParams.HYDRO_CELL,
			(ceili(SimParams.WORLD_SIZE.y / SimParams.H) + SimParams.HYDRO_CELL - 1) / SimParams.HYDRO_CELL)
	for x in xs:
		var cx := clampi(int(x / cell), 0, size.x - 1)
		var line := "  column x %.0f:" % ((cx + 0.5) * cell)
		for cy in range(int(160.0 / cell), size.y):
			var c := cy * size.x + cx
			line += " [y%.0f p%.0f w%.2f s%.2f b%.2f bw%.2f]" % [(cy + 0.5) * cell, b.hydro_p.decode_float(c * 4),
					b.hydro_phi.decode_float(c * 16), b.hydro_phi.decode_float(c * 16 + 4),
					b.hydro_phi.decode_float(c * 16 + 8), b.hydro_phi.decode_float(c * 16 + 12)]
		print(line)


## Debug ("grid"): the wet-surface pressure push on a body (as solve_pressure.glsl, with
## p_ref 0 and no floor term) from the read-back particles and grid, against its weight, both
## in px per substep summed over its particles; and its wet particles' mean wet face |g|.
func _print_pressure_push(b: Dictionary, body: Dictionary) -> void:
	var sp := SimParams.SPACING
	var h := SimParams.H
	var dt := SimParams.DT / 2.0
	var ParticleStep = load("res://cpu_ref/particle_step.gd")
	var cells := {}
	for i in b.mat_flags.size() / 4:
		var mf: int = b.mat_flags.decode_u32(i * 4)
		if (mf & 0x100) == 0 or (mf & 0xFF) != water:
			continue
		var q := Vector2(b.pos.decode_float(i * 8), b.pos.decode_float(i * 8 + 4))
		var key := Vector2i((q / h).floor())
		if not cells.has(key):
			cells[key] = PackedVector2Array()
		cells[key].append(q)
	var push := Vector2.ZERO
	var n_wet := 0
	var g_sum := 0.0
	var bottom_p := 0.0
	var n_bottom := 0
	var low := -INF
	for x in body.pos:
		low = maxf(low, x.y)
	for x in body.pos:
		var g := Vector2.ZERO
		var c := Vector2i((x / h).floor())
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				for q in cells.get(c + Vector2i(dx, dy), PackedVector2Array()):
					g += ParticleStep.body_wet_face(q - x, h, sp)
		if g.length() < 1e-6:
			continue
		n_wet += 1
		g_sum += g.length()
		var pw := _grid_p(b, x + 0.5 * sp * g.normalized())
		push += -pw * g * dt * dt / (0.5 * sp)
		if x.y > low - 0.5:
			bottom_p += pw
			n_bottom += 1
	print("  pressure push (y up < 0): (%.2f, %.2f) px/substep, weight %.2f; %d wet, mean |g| %.2f; bottom row %d wet, mean p %.0f"
			% [push.x, push.y, body.pos.size() * SimParams.GRAVITY * dt * dt, n_wet, g_sum / maxi(n_wet, 1), n_bottom, bottom_p / maxi(n_bottom, 1)])
	# Gap under the body: per bottom-row particle, the nearest water particle below it.
	var hist := {}
	for x in body.pos:
		if x.y < low - 0.5:
			continue
		var best := INF
		for q_cell in [Vector2i((x / h).floor()) + Vector2i(0, 1), Vector2i((x / h).floor()) + Vector2i(0, 2),
				Vector2i((x / h).floor()), Vector2i((x / h).floor()) + Vector2i(-1, 1), Vector2i((x / h).floor()) + Vector2i(1, 1)]:
			for q in cells.get(q_cell, PackedVector2Array()):
				if q.y > x.y:
					best = minf(best, x.distance_to(q))
		var key := "none" if best == INF else "%d" % int(best)
		hist[key] = hist.get(key, 0) + 1
	print("  nearest water below the bottom row (px, floor): %s" % str(hist))


## Debug (sandcorks): the wet-surface push on a cork as solve_pressure.glsl gives it, water and
## grains in pore water (BODY_PORE_WET 0.02) both, against p_ref, beside its weight, in px per
## substep summed over the members; and its grain contacts by side (within 1.5 spacings).
func _print_cork_push(b: Dictionary, id: int, body: Dictionary) -> void:
	var sp := SimParams.SPACING
	var h := SimParams.H
	var dt := SimParams.DT / 2.0
	var ParticleStep = load("res://cpu_ref/particle_step.gd")
	var p_ref: float = b.bodies.decode_float(id * ParticleSim.BODY_BYTES + 40)
	var cells := {}
	for i in b.mat_flags.size() / 4:
		var mf: int = b.mat_flags.decode_u32(i * 4)
		if (mf & 0x100) == 0 or (mf >> 16) != 0:
			continue
		var q := Vector2(b.pos.decode_float(i * 8), b.pos.decode_float(i * 8 + 4))
		var key := Vector2i((q / h).floor())
		if not cells.has(key):
			cells[key] = []
		cells[key].append([q, mf & 0xFF])
	var c := Vector2.ZERO
	for x in body.pos:
		c += x / body.pos.size()
	var theta: float = _fit(body).theta
	var push := Vector2.ZERO
	var faces := 0  # members whose outline face is wet through the pores
	var rows := {}  # rest row -> (push y, sum of p, wet members)
	var below := 0
	var beside := 0
	var above := 0
	for m in body.pos.size():
		var x: Vector2 = body.pos[m]
		var g := Vector2.ZERO
		var k := Vector2i((x / h).floor())
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				for e in cells.get(k + Vector2i(dx, dy), []):
					var q: Vector2 = e[0]
					if e[1] == water:
						g += ParticleStep.body_wet_face(q - x, h, sp)
					if e[1] == sand and q.distance_to(x) < 1.5 * sp:
						var d: Vector2 = q - x
						if absf(d.y) > absf(d.x):
							if d.y > 0.0:
								below += 1
							else:
								above += 1
						else:
							beside += 1
		var e_rest: Vector2 = body.e[m]
		var face: Vector2 = e_rest.rotated(theta) / (0.5 * sp)
		if g.length() < face.length() and e_rest.length() < 0.75 * sp and _grid_liquid(b, x + e_rest.rotated(theta)) >= 0.02 \
				and _grid_p(b, x + 0.5 * sp * face.normalized()) > 0.0:
			g = face
			faces += 1
		var pw := _grid_p(b, x + 0.5 * sp * g.normalized()) if g.length() > 1e-6 else 0.0
		if x.y >= SimParams.WORLD_SIZE.y - 1.5 * sp:
			g.y = maxf(g.y, 1.0)
			pw = maxf(pw, _grid_p(b, Vector2(x.x, SimParams.WORLD_SIZE.y)))
		if x.x <= 1.5 * sp:
			g.x = minf(g.x, -1.0)
			pw = maxf(pw, _grid_p(b, Vector2(0.0, x.y)))
		if x.x >= SimParams.WORLD_SIZE.x - 1.5 * sp:
			g.x = maxf(g.x, 1.0)
			pw = maxf(pw, _grid_p(b, Vector2(SimParams.WORLD_SIZE.x, x.y)))
		if g.length() < 1e-6:
			continue
		var d: Vector2 = -maxf(pw - p_ref, 0.0) * g * dt * dt / (0.5 * sp)
		push += d.limit_length(0.5 * sp)
		var row := int(roundf(body.rest[m].y / sp))
		rows[row] = rows.get(row, Vector3.ZERO) + Vector3(d.limit_length(0.5 * sp).y, pw, 1.0)
	print("  cork %d at (%.0f, %.0f) rot %.2f: push (%.2f, %.2f) px/substep, weight %.2f; p_ref %.0f; %d faces wet through the pores; grain contacts below %d beside %d above %d"
			% [id, c.x, c.y, theta, push.x, push.y, body.pos.size() * SimParams.GRAVITY * dt * dt, p_ref, faces, below, beside, above])
	if faces > 0:
		var keys := rows.keys()
		keys.sort()
		var line := "    rows (push y, mean p, wet):"
		for r in keys:
			line += " [%d %.2f %.0f %d]" % [r, rows[r].x, rows[r].y / rows[r].z, rows[r].z]
		print(line)


## Bilinear grid pressure at x, clamped to >= 0 (hydro_p_sample).
func _grid_p(b: Dictionary, x: Vector2) -> float:
	var cell := SimParams.H * SimParams.HYDRO_CELL
	var size := Vector2i((ceili(SimParams.WORLD_SIZE.x / SimParams.H) + SimParams.HYDRO_CELL - 1) / SimParams.HYDRO_CELL,
			(ceili(SimParams.WORLD_SIZE.y / SimParams.H) + SimParams.HYDRO_CELL - 1) / SimParams.HYDRO_CELL)
	var g := x / cell - Vector2(0.5, 0.5)
	var c0 := Vector2i(g.floor())
	var f := g - Vector2(c0)
	var v := []
	for k in 4:
		var c := (c0 + Vector2i(k & 1, k >> 1)).clamp(Vector2i.ZERO, size - Vector2i.ONE)
		v.append(b.hydro_p.decode_float((c.y * size.x + c.x) * 4))
	return maxf(lerpf(lerpf(v[0], v[1], f.x), lerpf(v[2], v[3], f.x), f.y), 0.0)


## The grid's liquid fill at x, bilinear (body_liquid_fill in solve_pressure.glsl).
func _grid_liquid(b: Dictionary, x: Vector2) -> float:
	var cell := SimParams.H * SimParams.HYDRO_CELL
	var size := Vector2i((ceili(SimParams.WORLD_SIZE.x / SimParams.H) + SimParams.HYDRO_CELL - 1) / SimParams.HYDRO_CELL,
			(ceili(SimParams.WORLD_SIZE.y / SimParams.H) + SimParams.HYDRO_CELL - 1) / SimParams.HYDRO_CELL)
	var g := x / cell - Vector2(0.5, 0.5)
	var c0 := Vector2i(g.floor())
	var f := g - Vector2(c0)
	var v := []
	for k in 4:
		var c := (c0 + Vector2i(k & 1, k >> 1)).clamp(Vector2i.ZERO, size - Vector2i.ONE)
		v.append(b.hydro_phi.decode_float((c.y * size.x + c.x) * 16))
	return lerpf(lerpf(v[0], v[1], f.x), lerpf(v[2], v[3], f.x), f.y)


## Highest particle of `material` (in no body) within half_width of x.
func _top_of(b: Dictionary, material: int, x: float, half_width: float) -> float:
	var top := INF
	for i in b.mat_flags.size() / 4:
		var f: int = b.mat_flags.decode_u32(i * 4)
		if (f & 0x100) == 0 or (f & 0xFF) != material or (f >> 16) != 0:
			continue
		var p := Vector2(b.pos.decode_float(i * 8), b.pos.decode_float(i * 8 + 4))
		if absf(p.x - x) < half_width:
			top = minf(top, p.y)
	return top


## Share of a floating body's height under the water: from its outline's bottom up to the
## water's surface (half a spacing over the top water particle, 6 to 40 px clear of its sides).
func _draft(b: Dictionary, body: Dictionary) -> float:
	var sp := SimParams.SPACING
	var top := INF
	var bottom := -INF
	var left := INF
	var right := -INF
	for p in body.pos:
		top = minf(top, p.y)
		bottom = maxf(bottom, p.y)
		left = minf(left, p.x)
		right = maxf(right, p.x)
	var surface := minf(_top_of(b, water, left - 23.0, 17.0), _top_of(b, water, right + 23.0, 17.0)) - 0.5 * sp
	return (bottom + 0.5 * sp - surface) / (bottom - top + sp)


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
