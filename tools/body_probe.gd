## Body probe: the cluster solid scenarios of tests/test_bodies.gd on the GPU sim, plus
## GPU-only checks and timing loads (docs/adr/0002-cluster-solid-layout.md). Needs a real
## window (no --headless). Run it in a copy of the repo, not the repo itself:
##   Godot_console.exe --path <copy> --script res://tools/body_probe.gd -- [scenarios] [from=N] [shots=F,...] [grid]
## scenarios: a comma list, default "tests" (the first seven, as in test_bodies.gd):
##   floor    8x6 rigid box resting on the floor, 240 frames: shape error, and |rotation| and
##            centroid speed over the last 120 frames
##   jelly    10x8 jelly (the shipped stiffness and region) squashed to half height and 1.4x width on the floor,
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
##   waterjelly a 16x10 jelly (density 1.1; the size main.tscn drops) dropped as
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
##            ~10 s (still 2.6-4 px/s at 900 frames). Also checks the gap under it, as corkstrip
##            (13-18 px while the grid's floater test stopped 3 cells up, ADR 0003 item 18)
##   waterbox   a 16x10 cork (the size main.tscn's Drop buttons make) set on the water, as
##            waterfloat
##   waterstrip a 180x10 cork (a brush stroke across the screen) set on the water, 1500 frames, as
##            waterfloat, and the gap under it, as corkstrip
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
##            sand slope used to stay down and shake (ADR 0003 item 15, Known limits; item 16
##            stopped the shaking), so it may still fail now and then. Prints each cork's centre, speed, draft, p_ref, wet flag, its bottom's height
##            over the sand beside it and the grains over its top; with "grid", the grid's columns
##            and each cork's pressure push by row against its weight
##   corkstrip  as the owner reported, 2026-10-14: "add a long horizontal strip of cork, then add 20k
##            water": a 180x10 cork (STRIP_COLS x STRIP_ROWS, about one body-brush stroke across the
##            screen) let go at y 30, on the floor by frame ~120, then 2 x "+10k water" at frames 240
##            and 270, 2400 frames: it rises off the floor and floats (mean draft over the last 60
##            frames under 1) on the water, not over a cell of air (the median gap between its bottom and
##            the water under it under GAP_MAX; 18 px before ADR 0003 item 18). It stayed on the floor while each member's pressure push was clamped on
##            its own (body_project.glsl). Takes ~15 s to come up. "trace" prints its bottom's height,
##            speed and p_ref every sample, with "refs" what set a low p_ref; "bare" the bare members
##            and the grid's p at their outline points every 60 frames
##   sandjelly  as the owner reported, 2026-10-14: "+10k sand" at frame 1, then at frame 240 a level
##            stroke of the body brush (a capsule, as main.tscn paints it) of jelly at y 60 across the
##            pile, 1200 frames: members still moving (over 5 px/s) and members under the sand's top
##            beside them. Rests at every stiffness since ADR 0009 (0.95: 72-174 members under the
##            sand's top, 0.2: 351-499) and stays on top since ADR 0013 (1-40 under at 0.2-0.95). Before it, at stiff=0.2 the strip dug down through the
##            pile (1779 of 1780 under the top) with members at up to 55 px/s, and 0.5 and 0.8 kept
##            a few members moving at 8-13 px/s
##   sandstroke the same pile; at frame 300 a jelly stroke painted level across its top, depth= px into it
##            (default STROKE_DEPTH) and span= px each side of the middle (default 170), with the
##            brush's own rules (core/body_brush.gd: occupied spots left out, pieces), so it can
##            leave pieces of any size: every piece and whether it keeps moving. "trace" prints the
##            fastest member of each piece every sample. With span=280 the stroke reaches the left
##            wall, and a member in the floor corner may read 6-14 px/s while it holds within 0.1 px,
##            so it can FAIL at any stiffness (also on main; ADR 0009 Known limits)
##   sandbits   the same pile; at frame 240 ten small jellies (2x2 to 5x3, as a stroke painted over
##            grains leaves them) dropped from y 200 along it, read as sandstroke
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
##            With "vtrace" (also jellydrop) they read back every frame and print the falling body's
##            centroid fall and speed beside free fall with drag 0.6/s, to 60 frames after it touches
##            (VT lines): a body that stops dead at the touch and then speeds up from rest was rewound
##            whole by the swept contact (status-archive § A body dropped onto another freezes)
##   erasemid a 16x10 carrot at rest on the floor, at frame 61 a 10 px eraser at its centroid
##            (it takes a lens of 4 to 10 columns), 240 frames: the two parts left become two
##            bodies (ADR 0004; how many frames that takes), each with its record's live count,
##            a fresh outline (no BODY_STALE), its shape, and no kick (largest speed after the
##            erase, at rest at the end)
##   erasejelly the same with a 16x10 jelly, 360 frames: each half (about 4 x 10) may buckle and tip
##            onto its side (ADR 0005 Known limits), so its shape within 4 px, at rest at the end
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
##   brushcap one 50x40 box (2000 particles, the body brush's cap SimParams.BODY_BRUSH_MAX)
##            dropped, 900 frames, timed from 300
##   huge     one 125x80 box (10000 particles) dropped, 900 frames, timed from 300
## Soft bodies bend (ADR 0005), with the shipped jelly or stiff= / region= (below):
##   droop    a 24x6 jelly plank laid on two 6x10 carrot pillars 30 px apart (centres; a 20 px gap),
##            as test_jelly_plank_bends_over_a_gap, 300 frames: its middle sags over 2 px below the
##            columns over the pillars, stays on them (down under 10 px), and rests (every member
##            under 2.5 px/s over the last 60 frames)
##   creep    a 16x10 jelly let go turned 30 deg, its lowest corner 1 px over the floor, 1800 frames:
##            it falls onto a corner and rests lopsided at low stiffness. Prints its centroid every
##            300 frames, then how fast the centroid moves sideways from frame 600 on (px/s, the
##            STATUS creep) and the fastest member over the last 60 frames. No pass mark
##   drape    a 40x4 jelly plank on two 4x20 carrot pillars 60 px apart (centres), 300 frames, no
##            pass mark: at the shipped jelly it falls through the gap, straightens on the floor
##            and pushes the pillars over (ADR 0005 Known limits). Reports the sag, how far the
##            ends slid in and the fastest member over the last 60 frames
##   wobble   a 16x10 jelly dropped 100 px onto the floor, 240 frames, every 3 frames: its height
##            and shape error, the peak error at the impact, how many times the height swings
##            more than 0.5 px across where it ends, the last frame it was more than 0.5 px off
##            (settled), and the fastest member at the end (no flying members)
##   squash   a 16x10 carrot set on a 16x10 jelly, 360 frames; at frame 180 the carrot is erased
##            (5 eraser circles under 1 frame each, along its bottom row): the jelly's height under
##            the carrot against an unloaded 16x10 jelly beside it, and how close it gets back
##   fold     a 50x3 jelly strip dropped across a 6x12 carrot, 300 frames: its ends fold down; the
##            closest pair of its members further apart in the rest shape than the region (no
##            member passes through its own body), at the end and over the run
##   jellystack two 16x10 jellies, the upper one just touching the lower (2 px over it), 300 frames
##   jellydrop  a 16x10 jelly dropped 150 px onto another resting on the floor, 360 frames
##            Both, and stack3, stack5 and boxstack with carrot set soft (set=carrot.stiffness=S),
##            also print the soft verdict (ADR 0008): members inside another body's lattice by a
##            local fit, how many bodies still stand on the one below, the fastest member over the
##            last 60 frames; PASS with nothing inside at the end and every member under 1 px/s
##   softcap  one 50x40 jelly (2000 particles, as brushcap) dropped, 900 frames, timed from 300
##   softmany 256 8x6 jellies (as many), 1500 frames, timed from 900
## stiff=S region=W replace the jelly row's stiffness and region for this run (tuning).
## frames=N runs every scenario for N frames instead of its own count (checks over "the last 60
## frames" move with it), e.g. to see whether a soft stack that leans over comes to rest.
## set=cork.density=5[,...] [setat=N] edit material parameters as the parameter panel does
## (tools/probe_params.gd), at frame N of every scenario (default: before its first frame).
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
const ProbeParams = preload("res://tools/probe_params.gd")
const BodyBrush = preload("res://core/body_brush.gd")

const TESTS := ["floor", "jelly", "stack3", "stack5", "erase", "spawnin", "corner"]
## Scenarios of bodies on bodies that also get the soft verdict (_sample_soft_stack) when their
## material is soft: the stacks with carrot set soft (set=carrot.stiffness=), and the jelly ones.
const SOFT_STACKS := ["stack3", "stack5", "boxstack", "jellystack", "jellydrop"]
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
## The long strip of sandjelly and corkstrip: about what one stroke of the body brush (radius 10)
## across the screen makes.
const STRIP_COLS := 180
const STRIP_ROWS := 10
## Most air (px) corkstrip and waterstrip allow between the cork's bottom and the water under it.
const GAP_MAX := 3.0
## How far into the sand pile's top the sandstroke stroke's centre line runs (px).
const STROKE_DEPTH := 4.0

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
var jelly_stiff := -1.0  # from "stiff=S"; -1 = the shipped table's
var jelly_region := -1.0  # from "region=W"
var run_frames := 0  # from "frames=N"
var inverted_trace := false  # from "inv": droop and drape print every sample to frame 60
## From "vtrace": the drop scenarios (VTRACE) read back every frame and print the falling body's
## centroid speed beside free fall with drag 0.6/s, from its spawn to 60 frames after it touches.
var velocity_trace := false
const VTRACE := ["boxdrop", "boxtilt", "boxhigh", "plank", "boxstack", "jellydrop"]
var inverted_at := Vector4.ZERO  # _inverted: the most squeezed member's rest offset, then x from the middle and height over the floor
var shots := PackedInt32Array()
var ready := false
var failed := 0
var param_sets: Array = []  # from "set=" (tools/probe_params.gd)
var param_frame := 0  # from "setat=N"
var stroke_depth := STROKE_DEPTH  # from "depth=D" (sandstroke)
var stroke_span := 170.0  # from "span=S" (sandstroke): half the stroke's length, px


func _initialize() -> void:
	var names := "tests"
	param_sets = ProbeParams.parse(OS.get_cmdline_user_args())
	param_frame = ProbeParams.frame(OS.get_cmdline_user_args())
	for a in OS.get_cmdline_user_args():
		if ProbeParams.is_arg(a):
			pass
		elif a.begins_with("from="):
			time_from = int(a.substr(5))
		elif a.begins_with("shots="):
			for v in a.substr(6).split(","):
				shots.append(int(v))
		elif a.begins_with("stiff="):
			jelly_stiff = float(a.substr(6))
		elif a.begins_with("region="):
			jelly_region = float(a.substr(7))
		elif a == "inv":
			inverted_trace = true
		elif a == "vtrace":
			velocity_trace = true
		elif a.begins_with("frames="):
			run_frames = int(a.substr(7))
		elif a.begins_with("depth="):
			stroke_depth = float(a.substr(6))
		elif a.begins_with("span="):
			stroke_span = float(a.substr(5))
		elif a in ["grid", "bare", "trace", "refs", "ptrace"]:
			pass  # debug: water scenarios print grid columns; ptrace: plastic bodies' tightest rest pair
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


## The shipped table: rigid "carrot" (stiffness 1), "jelly" (soft: stiffness 0.95, region 1.5) and "cork" (rigid,
## density 0.5), as tests/test_bodies.gd _sim().
func _table():
	var t = MaterialTable.new()
	var problems: PackedStringArray = t.load_file()
	if not problems.is_empty():
		print("MATERIAL PROBLEMS: ", problems)
	carrot = t.id_of("carrot")
	jelly = t.id_of("jelly")
	cork = t.id_of("cork")
	sand = t.id_of("sand")
	water = t.id_of("water")
	if jelly_stiff > 0.0:
		t.materials[jelly].stiffness = jelly_stiff
	if jelly_region > 0.0:
		t.materials[jelly].region = jelly_region
	print("jelly: stiffness %.3f, region %.2f" % [t.materials[jelly].stiffness, t.materials[jelly].region])
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
	if frame_i == maxi(1, param_frame):
		ProbeParams.apply(table, sim, param_sets)
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
	if frame_i % sc.every == 0 or frame_i == sc.frames or frame_i == sc.get("hold", -1) \
			or (velocity_trace and sc.name in VTRACE):
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
			if name == "erasejelly":
				sc.frames = 360
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
		"watersink", "waterjelly", "waterfloat", "waterdrop", "waterbig", "waterbox", "waterstrip", "waterdeep", "waterdeeptilt", "pourfloor", "pourdrop":
			sc.frames = {"watersink": 600, "waterjelly": 600, "waterbig": 1500, "waterstrip": 1500}.get(name, 900)
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
		"sandjelly":
			sc.frames = 1200
			sc.every = 10
			sc.from = 600
			sc.slots = SimParams.BENCH_BLOCK
			sc.late = []
		"sandstroke":
			sc.frames = 1200
			sc.every = 10
			sc.from = 600
			sc.slots = SimParams.BENCH_BLOCK
			sc.hold = 299  # read the pile, then paint the stroke over its top
			sc.pieces = []
			sc.late = {}
		"sandbits":
			sc.frames = 1200
			sc.every = 10
			sc.from = 600
			sc.slots = SimParams.BENCH_BLOCK
			sc.hold = -2
			sc.pieces = []
			sc.late = {}
		"corkstrip":
			sc.frames = 2400
			sc.every = 10
			sc.from = 600
			sc.slots = 2 * SimParams.BENCH_BLOCK
			sc.late = []
			_body(_box(Vector2(X, 30.0), STRIP_COLS, STRIP_ROWS), cork)
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
		"jellystack":
			sc.frames = 300
			sc.every = 5
			for k in 2:
				_body(_box(Vector2(X, FLOOR - k * 10.0 * SimParams.SPACING), 16, 10), jelly)
		"jellydrop":
			sc.frames = 360
			sc.every = 5
			_body(_box(Vector2(X, FLOOR), 16, 10), jelly)
			_body(_box(Vector2(X, FLOOR - 10.0 * SimParams.SPACING - 150.0), 16, 10), jelly)
		"droop":
			sc.frames = 300
			sc.every = 5
			var sp := SimParams.SPACING
			sc.pillar = 15.0
			_body(_box(Vector2(X - 15.0, FLOOR), 6, 10), carrot)
			_body(_box(Vector2(X + 15.0, FLOOR), 6, 10), carrot)
			sc.target = _body(_box(Vector2(X, FLOOR - 10.0 * sp), 24, 6), jelly)
			sc.late_speed = 0.0
		"creep":
			sc.frames = 1800
			sc.every = 30
			sc.x600 = 0.0
			var pts := _box(Vector2(X, 40.0), 16, 10, deg_to_rad(30.0))
			var lowest := -INF
			for p in pts:
				lowest = maxf(lowest, p.y)
			for i in pts.size():
				pts[i].y += FLOOR - 1.0 - lowest
			sc.target = _body(pts, jelly)
			sc.late_speed = 0.0
		"drape":
			sc.frames = 300
			sc.every = 5
			var sp := SimParams.SPACING
			sc.pillar = 30.0
			_body(_box(Vector2(X - 30.0, FLOOR), 4, 20), carrot)
			_body(_box(Vector2(X + 30.0, FLOOR), 4, 20), carrot)
			sc.target = _body(_box(Vector2(X, FLOOR - 20.0 * sp), 40, 4), jelly)
			sc.late_speed = 0.0
		"wobble":
			sc.frames = 240
			sc.every = 3
			sc.target = _body(_box(Vector2(X, FLOOR - 100.0), 16, 10), jelly)
			sc.trace = []
		"squash":
			sc.frames = 360
			sc.every = 10
			sc.hold = 179
			sc.target = _body(_box(Vector2(X, FLOOR), 16, 10), jelly)
			sc.control = _body(_box(Vector2(X - 120.0, FLOOR), 16, 10), jelly)
			sc.load = _body(_box(Vector2(X, FLOOR - 10.0 * SimParams.SPACING - 0.5), 16, 10), carrot)
			sc.trace = []
		"fold":
			sc.frames = 300
			sc.every = 5
			_body(_box(Vector2(X, FLOOR), 6, 12), carrot)
			sc.target = _body(_box(Vector2(X, FLOOR - 12.0 * SimParams.SPACING - 6.0), 50, 3), jelly)
			sc.run_min = INF
		"softcap":
			sc.frames = 900
			sc.every = 60
			sc.from = 300
			sc.target = _body(_box(Vector2(X, 200.0), 50, 40), jelly)
		"softmany":
			sc.frames = 1500
			sc.every = 60
			sc.from = 900
			for row in 8:
				for col in 32:
					_body(_box(Vector2(12.0 + 7.0 + col * 19.5, 30.0 + (7 - row) * 18.0), 8, 6), jelly)
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
		"big", "huge", "brushcap":
			sc.frames = 900
			sc.every = 60
			sc.from = 300
			if name == "big":
				_body(_box(Vector2(X, 150.0), 100, 50), carrot)
			elif name == "brushcap":
				_body(_box(Vector2(X, 200.0), 50, 40), carrot)
			else:
				_body(_box(Vector2(X, 200.0), 125, 80), carrot)
		_:
			print("unknown scenario ", name)
			sc = {}
			return
	if time_from >= 0:
		sc.from = time_from
	if run_frames > 0:
		sc.frames = run_frames
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
	elif sc.name == "sandjelly":
		var cols := SimParams.BENCH_COLS
		if frame_i == 1:
			brush.merge({"op": ParticleSim.BRUSH_BLOCK, "material": sand, "count": SimParams.BENCH_BLOCK, "cols": cols,
					"pos": Vector2((SimParams.WORLD_SIZE.x - cols * SimParams.SPACING) * 0.5, 8.0)}, true)
		elif frame_i == 240:
			# A level stroke of the body brush in the air (a capsule with rounded ends), as main.tscn paints it.
			var stroke := {}
			BodyBrush.paint(stroke, Vector2(X - 170.0, 60.0), Vector2(X + 170.0, 60.0), SimParams.BRUSH_RADIUS)
			for piece in BodyBrush.bodies(stroke, {}):
				sc.target = _body(piece, jelly)
	elif sc.name == "sandbits":
		var cols := SimParams.BENCH_COLS
		if frame_i == 1:
			brush.merge({"op": ParticleSim.BRUSH_BLOCK, "material": sand, "count": SimParams.BENCH_BLOCK, "cols": cols,
					"pos": Vector2((SimParams.WORLD_SIZE.x - cols * SimParams.SPACING) * 0.5, 8.0)}, true)
		elif frame_i == 240:
			# Small jelly pieces, as a stroke painted over grains leaves them, dropped along the pile.
			var sizes := [Vector2i(2, 2), Vector2i(3, 2), Vector2i(2, 3), Vector2i(3, 3), Vector2i(4, 2), Vector2i(2, 4),
					Vector2i(6, 2), Vector2i(2, 6), Vector2i(4, 4), Vector2i(5, 3)]
			for k in sizes.size():
				_body(_box(Vector2(150.0 + 38.0 * k, 200.0), sizes[k].x, sizes[k].y), jelly)
	elif sc.name == "sandstroke":
		var cols := SimParams.BENCH_COLS
		if frame_i == 1:
			brush.merge({"op": ParticleSim.BRUSH_BLOCK, "material": sand, "count": SimParams.BENCH_BLOCK, "cols": cols,
					"pos": Vector2((SimParams.WORLD_SIZE.x - cols * SimParams.SPACING) * 0.5, 8.0)}, true)
		elif frame_i == sc.hold + 1:
			for piece in sc.pieces:
				_body(piece, jelly)
	elif sc.name == "corkstrip":
		if frame_i == 240 or frame_i == 270:
			var cols := SimParams.BENCH_COLS
			brush.merge({"op": ParticleSim.BRUSH_BLOCK, "material": water, "count": SimParams.BENCH_BLOCK, "cols": cols,
					"pos": Vector2((SimParams.WORLD_SIZE.x - cols * SimParams.SPACING) * 0.5, 8.0)}, true)
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
				"waterstrip":
					_body(_box(Vector2(X, top - 1.0), STRIP_COLS, STRIP_ROWS), cork)
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
	elif sc.name == "squash" and frame_i > sc.hold and frame_i <= sc.hold + 5:
		# Circles of radius 20 whose bottom is half a pixel under the carrot's bottom row, 8 px
		# apart: together they take the carrot and none of the jelly under it.
		var k: int = frame_i - sc.hold - 1
		brush.merge({"op": ParticleSim.BRUSH_ERASE, "pos": Vector2(X - 16.0 + 8.0 * k, sc.load_bottom + 0.5 - 20.0), "radius": 20.0}, true)
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
	if velocity_trace and sc.name in VTRACE:
		_sample_vtrace(f, bodies)
		if f % 5 != 0 and f != sc.frames:
			return  # the scenario's own checks keep their 5-frame samples
	_sample_plastic(f, bodies)
	if sc.name in SOFT_STACKS:
		_sample_soft_stack(f, bodies)
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
				_result("squashed jelly: shape error %.3f px, under 10%% after %d frames; at 2 s %.3f px from an unsquashed jelly at rest (its sag %.3f px)"
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
		"creep":
			var fit := _fit(bodies[1])
			if f > sc.frames - 60:
				sc.late_speed = maxf(sc.late_speed, _max_speed(bodies[1]))
			if f == 600:
				sc.x600 = fit.c.x
			if f % 300 == 0:
				print("  f=%d centroid (%.2f, %.2f), turned %.3f rad, shape error %.2f px, fastest member %.2f px/s"
						% [f, fit.c.x, fit.c.y, fit.theta, fit.err, _max_speed(bodies[1])])
			if f == sc.frames:
				var rate: float = (fit.c.x - sc.x600) / ((sc.frames - 600) / 60.0)
				print("BODY creep: 16x10 jelly let go turned 30 deg: centroid moved %.2f px sideways from frame 600 (%.3f px/s), turned %.3f rad, fastest member over the last 60 frames %.2f px/s  (no pass mark)"
						% [fit.c.x - sc.x600, rate, fit.theta, sc.late_speed])
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
		"watersink", "waterjelly", "waterfloat", "waterdrop", "waterbig", "waterbox", "waterstrip", "waterdeep", "waterdeeptilt", "pourfloor", "pourdrop":
			if f == sc.hold:
				sc.water_top = _top_of(b, water, X, 40.0)
				waiting = false
			if not bodies.has(1):
				return
			var fit := _fit(bodies[1])
			var inside := _inside(b, bodies[1], fit, water)
			sc.most_inside = maxi(sc.most_inside, inside)
			sc.most_deep = maxi(sc.get("most_deep", 0), _inside(b, bodies[1], fit, water, SimParams.SPACING))
			if f % 60 == 0 or (sc.name.begins_with("waterdeep") and f % 20 == 0) or (sc.name.begins_with("pour") and f % 20 == 0):
				print("  f=%d c=(%.1f, %.1f) rot %.3f v=%s draft %.2f inside %d; water top at x 40 / 600 %.1f / %.1f; p_ref %.0f; gap under %.1f px" % [f, fit.c.x, fit.c.y, fit.theta,
						_mean_vel(bodies[1]), _draft(b, bodies[1]), inside, _top_of(b, water, 40.0, 17.0), _top_of(b, water, 600.0, 17.0),
						b.bodies.decode_float(1 * ParticleSim.BODY_BYTES + 40), _gap_under(b, bodies[1])])
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
				sc.late.append([_draft(b, bodies[1]), _mean_vel(bodies[1]).length(), absf(theta - roundf(theta / PI) * PI),
						_gap_under(b, bodies[1])])
			if f == sc.frames:
				var draft := 0.0
				var speed := 0.0
				var tilt := 0.0
				var gap := 0.0
				for v in sc.late:
					draft += v[0] / sc.late.size()
					speed += v[1] / sc.late.size()
					tilt = maxf(tilt, v[2])
					gap += v[3] / sc.late.size()
				var bottom := -INF
				for q in bodies[1].pos:
					bottom = maxf(bottom, q.y)
				if sc.name == "watersink":
					_result("carrot dropped into an 80 px pool: lowest particle %.2f px above the floor, water inside its outline %d at the end (most %d at a sample), shape error %.4f px, rotation %.4f rad, speed %.3f px/s"
							% [FLOOR - bottom, inside, sc.most_inside, fit.err, fit.theta, _mean_vel(bodies[1]).length()],
							FLOOR - bottom < 2.0 * SimParams.SPACING and sc.most_inside == 0 and fit.err < 0.1)
				elif sc.name == "waterjelly":
					_result("16x10 jelly (density 1.1) dropped into an 80 px pool: lowest particle %.2f px above the floor, water inside its outline %d at the end (most %d at a sample, most %d over a spacing in), shape error %.3f px, speed %.3f px/s"
							% [FLOOR - bottom, inside, sc.most_inside, sc.get("most_deep", 0), fit.err, _mean_vel(bodies[1]).length()],
							FLOOR - bottom < 2.0 * SimParams.SPACING and sc.most_inside == 0 and fit.err < 2.0)
				else:
					# The wide floaters must float on the water, not over air (ADR 0003 item 18).
					var wide: bool = sc.name in ["waterbig", "waterstrip"]
					_result("%s: cork, last 60 frames: mean draft %.2f of its height, mean speed %.2f px/s, max tilt %.3f rad; water inside %d at the end (most %d at a sample), shape error %.4f px; gap under it %.1f px%s"
							% [sc.name, draft, speed, tilt, inside, sc.most_inside, fit.err, gap, " (under %.0f)" % GAP_MAX if wide else ""],
							draft > 0.25 and draft < 0.7 and speed < 3.0 and tilt < 0.35 and inside == 0 and fit.err < 0.1
							and (not wide or gap < GAP_MAX))
		"sandcorks":
			_sample_sandcorks(f, b, bodies)
		"sandjelly":
			_sample_sandjelly(f, b, bodies)
		"sandstroke", "sandbits":
			_sample_sandstroke(f, b, bodies)
		"corkstrip":
			_sample_corkstrip(f, b, bodies)
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
		"droop", "drape", "wobble", "squash", "fold":
			_sample_soft(f, bodies)
		"many", "big", "huge", "brushcap", "softcap", "softmany":
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


## The soft body scenarios (ADR 0005).
## The soft verdict for bodies stacked or dropped on soft bodies (ADR 0008), next to a scenario's
## own checks, which are tuned to rigid boxes: members inside another body's lattice by a local
## fit (_members_in_lattice; the whole-body fit of _members_inside reads a squashed jelly's own
## dent as overlap), whether each body still stands on the one made before it (its centre above
## that one's by a quarter of their rest heights, within half that one's width: squashed jellies
## sit closer than rigid boxes) and the fastest member over the last 60 frames. Passes with
## nothing inside at the end and every member under 1 px/s; standing is reported, not required
## (below ~0.8 a stack of soft bodies may lean over, ADR 0008 Known limits).
## "vtrace": the falling body (the last made) each frame: its centroid's fall and speed beside a
## model of free fall with drag 0.6/s stepped as the sim steps (gravity in predict, then
## exp(-drag dt) in velocity_update, per substep), the speed of the body under it and the gap.
func _sample_vtrace(f: int, bodies: Dictionary) -> void:
	if bodies.size() < 2:
		return
	var ids: Array = bodies.keys()
	ids.sort()
	var top: int = ids[-1]
	var c := Vector2.ZERO
	for p in bodies[top].pos:
		c += p
	c /= bodies[top].pos.size()
	if sc.get("vt_id", -1) != top:
		# First seen one frame after it was made.
		sc.vt_id = top
		sc.vt_y0 = c.y
		sc.vt_v = 0.0
		sc.vt_y = 0.0
		sc.vt_touch = -1
	var h := SimParams.DT / 2.0  # config.json's 2 substeps
	for _s in 2:
		var moved: float = sc.vt_v + SimParams.GRAVITY * h
		sc.vt_y += moved * h
		sc.vt_v = moved * exp(-0.6 * h)
	var gap := INF
	for p in bodies[top].pos:
		for id in ids:
			if id == top:
				continue
			for q in bodies[id].pos:
				gap = minf(gap, p.distance_to(q))
	if sc.vt_touch < 0 and gap < SimParams.SPACING:
		sc.vt_touch = f
	if sc.vt_touch >= 0 and f > sc.vt_touch + 60:
		return
	var v := _mean_vel(bodies[top])
	print("  VT f=%d fall %.1f px (model %.1f) vy %.1f px/s (model %.1f) vx %.1f, body under vy %.1f, gap %.2f px%s"
			% [f, c.y - sc.vt_y0, sc.vt_y, v.y, sc.vt_v, v.x, _mean_vel(bodies[ids[-2]]).y, gap,
			" TOUCH" if f == sc.vt_touch else ""])


func _sample_soft_stack(f: int, bodies: Dictionary) -> void:
	var m: int = jelly if sc.name.begins_with("jelly") else carrot
	var n: int = {"stack3": 3, "stack5": 5, "boxstack": 4}.get(sc.name, 2)
	if table.materials[m].stiffness >= 1.0 or bodies.size() < n:
		return
	if f > sc.frames - 60:
		for id in bodies:
			for i in bodies[id].vel.size():
				var v: float = bodies[id].vel[i].length()
				if v > sc.get("soft_speed", 0.0):
					sc.soft_speed = v
					sc.soft_who = "body %d rest (%.0f, %.0f) at (%.1f, %.1f)" % [id, bodies[id].rest[i].x, bodies[id].rest[i].y,
							bodies[id].pos[i].x, bodies[id].pos[i].y]
	if f == sc.frames - 60 or f == sc.frames:
		# How far any member moved over the last 60 frames: a member whose velocity flips while it
		# holds its place reads a speed it doesn't have (ADR 0009 Known limits).
		var now := {}
		for id in bodies:
			now[id] = bodies[id].pos.duplicate()
		if f == sc.frames:
			var moved := 0.0
			for id in now:
				if sc.get("soft_pos", {}).has(id) and sc.soft_pos[id].size() == now[id].size():
					for i in now[id].size():
						moved = maxf(moved, now[id][i].distance_to(sc.soft_pos[id][i]))
			print("  soft: fastest member (last 60 frames) %s; most any member moved over them %.3f px"
					% [sc.get("soft_who", "-"), moved])
		sc.soft_pos = now
	if f % 30 != 0 and f != sc.frames:
		return
	var ids: Array = bodies.keys()
	ids.sort()
	var inside := 0
	for a in ids:
		for o in ids:
			if a != o and _fit(bodies[a]).c.distance_to(_fit(bodies[o]).c) < 60.0:
				inside += _members_in_lattice(bodies[a], bodies[o])
	sc.soft_most = maxi(sc.get("soft_most", 0), inside)
	if f != sc.frames:
		return
	var standing := 0
	var tilt := 0.0
	for k in ids.size():
		var fit := _fit(bodies[ids[k]])
		tilt = maxf(tilt, absf(fit.theta))
		if k == 0:
			continue
		var under := _fit(bodies[ids[k - 1]])
		var size_k := _rest_size(bodies[ids[k]])
		var size_u := _rest_size(bodies[ids[k - 1]])
		if fit.c.y < under.c.y - 0.25 * (size_k.y + size_u.y) and absf(fit.c.x - under.c.x) < 0.5 * size_u.x:
			standing += 1
	var speed: float = sc.get("soft_speed", 0.0)
	_result("%s, soft (stiffness %.2f): members inside another's lattice %d at the end (most %d at a sample), %d of %d bodies standing on the one below, largest |rotation| %.3f rad, fastest member (last 60 frames) %.3f px/s"
			% [sc.name, table.materials[m].stiffness, inside, sc.soft_most, standing, ids.size() - 1, tilt, speed],
			inside == 0 and speed < 1.0)


## Width and height of a body's rest lattice out to its outline (half a spacing past its boundary
## members on each side).
func _rest_size(body: Dictionary) -> Vector2:
	var lo := Vector2(INF, INF)
	var hi := -lo
	for q in body.rest:
		lo = lo.min(q)
		hi = hi.max(q)
	return hi - lo + Vector2.ONE * SimParams.SPACING


## Members of body a inside body b's lattice, soft bodies included (as test_bodies.gd
## _members_in_lattice): each member is taken into b's rest frame by a local fit (an affine map,
## rest -> now, over b's members within 1.5 spacings on the rest lattice of its member nearest the
## point) and counts if it lands inside the bounding box of b's rest lattice.
func _members_in_lattice(a: Dictionary, b: Dictionary) -> int:
	var lo := Vector2(INF, INF)
	var hi := -lo
	for q in b.rest:
		lo = lo.min(q)
		hi = hi.max(q)
	var n := 0
	for p in a.pos:
		var j := -1
		var best := INF
		for k in b.pos.size():
			var d2: float = p.distance_squared_to(b.pos[k])
			if d2 < best:
				best = d2
				j = k
		if best > 4.0 * SimParams.SPACING * SimParams.SPACING:
			continue
		var near := PackedInt32Array()
		var qm := Vector2.ZERO
		var xm := Vector2.ZERO
		for k in b.rest.size():
			if b.rest[k].distance_to(b.rest[j]) <= 1.5 * SimParams.SPACING:
				near.append(k)
				qm += b.rest[k]
				xm += b.pos[k]
		qm /= near.size()
		xm /= near.size()
		# x - xm = F (q - qm) with F = (sum x q^T)(sum q q^T)^-1, so q = qm + F^-1 (p - xm).
		var qq := Transform2D(Vector2.ZERO, Vector2.ZERO, Vector2.ZERO)
		var xq := Transform2D(Vector2.ZERO, Vector2.ZERO, Vector2.ZERO)
		for k in near:
			var q: Vector2 = b.rest[k] - qm
			var x: Vector2 = b.pos[k] - xm
			qq.x += q * q.x
			qq.y += q * q.y
			xq.x += x * q.x
			xq.y += x * q.y
		if absf(qq.determinant()) < 1e-6:
			continue
		var fm := xq * qq.affine_inverse()
		if absf(fm.determinant()) < 1e-6:
			continue
		var q_p: Vector2 = qm + fm.affine_inverse().basis_xform(p - xm)
		if q_p.x > lo.x and q_p.x < hi.x and q_p.y > lo.y and q_p.y < hi.y:
			n += 1
	return n


## Plasticity (ADR 0012), in any scenario: for each soft body whose material has plasticity, at
## the end a PLASTIC line with its rest shape's height and width (the rest lattice it was made
## with is upright, so they read the dent or flattening), the most a rest offset moved over the
## last 120 frames about their mean (creep), the tightest pair of rest offsets (the lattice band,
## from 0.7 spacing), and how far its boundary members' way out (fewer than 8 rest neighbours
## within 1.5 spacings) is from half a spacing out on the rest shape now (the outline following).
func _sample_plastic(f: int, bodies: Dictionary) -> void:
	if OS.get_cmdline_user_args().has("ptrace") and f % 30 == 0:
		for id in bodies:
			var r: PackedVector2Array = bodies[id].rest
			var best := INF
			var pa := Vector2i(-1, -1)
			for a in r.size():
				for b in range(a + 1, r.size()):
					if r[a].distance_to(r[b]) < best:
						best = r[a].distance_to(r[b])
						pa = Vector2i(a, b)
			if pa.x >= 0:
				print("  ptrace f=%d body %d tightest %.3f px: %s %s pos %s %s" % [f, id, best, r[pa.x], r[pa.y], bodies[id].pos[pa.x], bodies[id].pos[pa.y]])
	var late: bool = f >= sc.frames - 120 and not sc.has("plastic_rest") and f < sc.frames
	if not late and f != sc.frames:
		return
	if late:
		sc.plastic_rest = {}
	for id in bodies:
		var m: int = sim._bodies[id].get("material", -1) if id < sim._bodies.size() else -1
		if m < 0 or float(table.materials[m].stiffness) >= 1.0 or float(table.materials[m].get("plasticity", 0.0)) <= 0.0:
			continue
		var rest: PackedVector2Array = bodies[id].rest
		if late:
			sc.plastic_rest[id] = rest
			continue
		var sp := SimParams.SPACING
		var lo := Vector2(INF, INF)
		var hi := -lo
		var mean := Vector2.ZERO
		for q in rest:
			lo = lo.min(q)
			hi = hi.max(q)
			mean += q
		mean /= rest.size()
		var moved := -1.0
		var before: PackedVector2Array = sc.get("plastic_rest", {}).get(id, PackedVector2Array())
		if before.size() == rest.size():
			var mean0 := Vector2.ZERO
			for q in before:
				mean0 += q
			mean0 /= before.size()
			moved = 0.0
			for k in rest.size():
				moved = maxf(moved, (rest[k] - mean).distance_to(before[k] - mean0))
		var tight := INF
		var off := 0.0
		var boundary := 0
		for i in rest.size():
			var n := 0
			var normal := Vector2.ZERO
			for j in rest.size():
				var d2 := rest[i].distance_squared_to(rest[j])
				if j != i and d2 < 2.25 * sp * sp:
					n += 1
					normal += (rest[i] - rest[j]).normalized()
					tight = minf(tight, sqrt(d2))
			if n < 8 and normal.length() > 1e-4:
				boundary += 1
				off = maxf(off, bodies[id].e[i].distance_to(0.5 * sp * normal.normalized()))
		print("PLASTIC %s body %d: %d members, rest shape %.2f x %.2f px, rest moved over the last 120 frames %.4f px, tightest rest pair %.2f px, %d boundary members' way out off by %.4f px"
				% [sc.name, id, rest.size(), hi.x - lo.x, hi.y - lo.y, moved, tight, boundary, off])


func _sample_soft(f: int, bodies: Dictionary) -> void:
	if not bodies.has(sc.target):
		if sc.name != "squash" or f != sc.hold:
			return
	var body: Dictionary = bodies.get(sc.target, {})
	var w: float = table.materials[jelly].region
	match sc.name:
		"droop", "drape":
			if f == sc.every:
				sc.mid0 = _rows_y(body, 0.0)
				sc.left0 = _left(body)
			if f > sc.frames - 60:
				sc.late_speed = maxf(sc.late_speed, _max_speed(body))
			if f % 30 == 0 or (inverted_trace and f <= 60):
				var inv := _inverted(body)
				print("  f=%d middle down %.2f px, ends slid in %.2f px, fastest member %.2f px/s, inside out %d (lowest det F %.2f, rest (%.1f, %.1f), at x %.1f up %.1f)"
						% [f, _rows_y(body, 0.0) - sc.mid0, _left(body) - sc.left0, _max_speed(body), inv.x, inv.y,
						inverted_at.x, inverted_at.y, inverted_at.z, inverted_at.w])
			if f == sc.frames:
				var sag: float = _rows_y(body, 0.0) - 0.5 * (_rows_y(body, -sc.pillar) + _rows_y(body, sc.pillar))
				var down: float = _rows_y(body, 0.0) - sc.mid0
				var line := "%s: jelly plank on two pillars %.0f px apart: middle %.2f px under the columns over the pillars (down %.2f px), ends slid in %.2f px, fastest member over the last 60 frames %.2f px/s" % [
						sc.name, 2.0 * sc.pillar, sag, down, _left(body) - sc.left0, sc.late_speed]
				if sc.name == "drape":
					print("BODY %s  (no pass mark)" % line)
				else:
					_result(line, sag > 2.0 and down < 10.0 and sc.late_speed < 2.5)
		"wobble":
			var h := _height(body)
			sc.trace.append([f, _fit(body).err, h])
			if f == sc.frames:
				var end_h := 0.0
				var end_err := 0.0
				for k in 10:
					end_h += sc.trace[-1 - k][2] / 10.0
					end_err += sc.trace[-1 - k][1] / 10.0
				var peak := 0.0
				var settled := 0
				var swings := 0
				var side := 0
				for v in sc.trace:
					peak = maxf(peak, v[1])
					var off: float = v[2] - end_h
					if absf(off) > 0.5:
						settled = v[0]
						var now := 1 if off > 0.0 else -1
						if now != side:
							swings += 1
							side = now
				var fastest := _max_speed(body)
				_result("wobble: 16x10 jelly dropped 100 px: peak shape error %.2f px, %d swings over 0.5 px, within 0.5 px of its end height %.2f (rest 18) from frame %d, end shape error %.2f px, fastest member at the end %.2f px/s"
						% [peak, swings, end_h, settled, end_err, fastest], settled < 180 and fastest < 5.0)
		"squash":
			if f == sc.hold:
				var low := -INF
				if bodies.has(sc.load):
					for q in bodies[sc.load].pos:
						low = maxf(low, q.y)
				sc.load_bottom = low
				waiting = false
			if body.is_empty() or not bodies.has(sc.control):
				return
			var h := _height(body)
			var h0 := _height(bodies[sc.control])
			sc.trace.append([f, h, h0])
			if f % 30 == 0:
				print("  f=%d jelly height %.2f, unloaded %.2f, shape error %.2f px, fastest %.2f px/s" % [f, h, h0, _fit(body).err, _max_speed(body)])
			if f == sc.hold:
				sc.loaded = h
				sc.loaded_ref = h0
			if f == sc.frames:
				_result("squash: 16x10 jelly under a 16x10 carrot: height %.2f px against %.2f unloaded (%.0f%% flatter); 180 frames after the carrot is erased %.2f px against %.2f (off %.2f px), fastest member %.2f px/s"
						% [sc.loaded, sc.loaded_ref, 100.0 * (1.0 - sc.loaded / sc.loaded_ref), h, h0, absf(h - h0), _max_speed(body)],
						sc.loaded < sc.loaded_ref - 1.0 and absf(h - h0) < 0.5)
		"fold":
			var gap := _self_gap(body, w)
			sc.run_min = minf(sc.run_min, gap)
			if f % 30 == 0:
				var low := -INF
				for q in body.pos:
					low = maxf(low, q.y)
				print("  f=%d lowest member y %.1f (floor %.1f), closest non-region pair %.2f px, fastest %.2f px/s" % [f, low, FLOOR, gap, _max_speed(body)])
			if f == sc.frames:
				_result("fold: 50x3 jelly strip dropped across a carrot: closest pair of its members further apart in the rest shape than the region %.2f px at the end (%.2f over the run), fastest member %.2f px/s"
						% [gap, sc.run_min, _max_speed(body)], sc.run_min >= 0.5 * SimParams.SPACING and _max_speed(body) < 5.0)


## Mean y of a body's members whose rest offset x is within a spacing of rest_x (from its rest centroid).
func _rows_y(body: Dictionary, rest_x: float) -> float:
	var c0 := Vector2.ZERO
	for q in body.rest:
		c0 += q
	c0 /= body.rest.size()
	var y := 0.0
	var n := 0
	for k in body.rest.size():
		if absf(body.rest[k].x - c0.x - rest_x) < 0.75 * SimParams.SPACING:
			y += body.pos[k].y
			n += 1
	return y / maxi(n, 1)


func _left(body: Dictionary) -> float:
	var x := INF
	for q in body.pos:
		x = minf(x, q.x)
	return x


func _height(body: Dictionary) -> float:
	var top := INF
	var bottom := -INF
	for q in body.pos:
		top = minf(top, q.y)
		bottom = maxf(bottom, q.y)
	return bottom - top


## Members of a soft body whose local deformation is inside out: F = P Q^-1 over the members
## within 1.5 spacings of it on the rest shape (P = sum of dp dq^T, Q = sum of dq dq^T), det F <= 0.
## Also the smallest det F (the area ratio; 1 at rest).
func _inverted(body: Dictionary) -> Vector2:
	var reach2 := pow(1.5 * SimParams.SPACING + 1e-3, 2.0)
	var count := 0
	var low := INF
	inverted_at = Vector4.ZERO
	for i in body.pos.size():
		var p00 := 0.0
		var p01 := 0.0
		var p10 := 0.0
		var p11 := 0.0
		var q00 := 0.0
		var q01 := 0.0
		var q11 := 0.0
		for j in body.pos.size():
			var dq: Vector2 = body.rest[j] - body.rest[i]
			if j == i or dq.length_squared() > reach2:
				continue
			var dp: Vector2 = body.pos[j] - body.pos[i]
			p00 += dp.x * dq.x
			p01 += dp.x * dq.y
			p10 += dp.y * dq.x
			p11 += dp.y * dq.y
			q00 += dq.x * dq.x
			q01 += dq.x * dq.y
			q11 += dq.y * dq.y
		var det_q := q00 * q11 - q01 * q01
		if det_q < 1e-6:
			continue
		var det_f := (p00 * p11 - p01 * p10) / det_q
		if det_f < low:
			inverted_at = Vector4(body.rest[i].x, body.rest[i].y, body.pos[i].x - X, FLOOR - body.pos[i].y)
		low = minf(low, det_f)
		if det_f <= 0.0:
			count += 1
	return Vector2(count, low)


func _max_speed(body: Dictionary) -> float:
	var v := 0.0
	for u in body.vel:
		v = maxf(v, u.length())
	return v


## Closest pair of a body's members further apart in its rest shape than the region radius w
## (in spacings): under 0.5 spacing, one has gone through its own body.
func _self_gap(body: Dictionary, w: float) -> float:
	var reach := w * SimParams.SPACING + 1e-3
	var best := INF
	var n: int = body.pos.size()
	for a in n:
		for b in range(a + 1, n):
			if body.rest[a].distance_to(body.rest[b]) > reach:
				best = minf(best, body.pos[a].distance_to(body.pos[b]))
	return best


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


## sandjelly: the jelly strip on the sand pile. Members that keep moving (jitter) or end below the
## sand's top beside them (digging in).
func _sample_sandjelly(f: int, b: Dictionary, bodies: Dictionary) -> void:
	if not bodies.has(1):
		return
	var body: Dictionary = bodies[1]
	var fast := 0
	var top_speed := 0.0
	var worst := -1
	for k in body.vel.size():
		var v: float = body.vel[k].length()
		if v > 5.0:
			fast += 1
		if v > top_speed:
			top_speed = v
			worst = k
	var under := 0
	var grains_in := 0
	if f % 60 == 0 or f == sc.frames:
		var tops := {}
		for q in body.pos:
			var col := int(q.x / 4.0)
			if not tops.has(col):
				tops[col] = _sand_top(b, q.x, 2.0)
			if q.y > tops[col] + 1.0:
				under += 1
		grains_in = _grains_inside(b, body, _fit(body))
		var fit := _fit(body)
		print("  f=%d jelly c=(%.1f, %.1f) err %.2f; members over 5 px/s %d, fastest %.0f px/s at rest (%.0f, %.0f) now (%.0f, %.0f); under the sand top %d; grains inside %d"
				% [f, fit.c.x, fit.c.y, fit.err, fast, top_speed, body.rest[worst].x, body.rest[worst].y, body.pos[worst].x, body.pos[worst].y, under, grains_in])
	if f > sc.frames - 60:
		sc.late.append([fast, top_speed])
	if f == sc.frames:
		var most_fast := 0
		var fastest := 0.0
		for v in sc.late:
			most_fast = maxi(most_fast, v[0])
			fastest = maxf(fastest, v[1])
		_result("sandjelly: last 60 frames: members over 5 px/s at most %d, fastest member %.1f px/s; at the end %d members under the sand's top, %d grains inside"
				% [most_fast, fastest, under, grains_in], most_fast == 0 and fastest < 5.0)


## sandstroke: a body-brush stroke of jelly (core/body_brush.gd, as main.tscn paints it) drawn
## level across the top of the sand pile, STROKE_DEPTH px into it at the middle, so it crosses
## the slopes. Every piece the brush makes, and how much each keeps moving.
func _sample_sandstroke(f: int, b: Dictionary, bodies: Dictionary) -> void:
	if f == sc.hold:
		var top := _sand_top(b, X, 8.0)
		var stroke := {}
		BodyBrush.paint(stroke, Vector2(X - stroke_span, top + stroke_depth), Vector2(X + stroke_span, top + stroke_depth),
				SimParams.BRUSH_RADIUS)
		sc.pieces = BodyBrush.bodies(stroke, BodyBrush.occupied_spots(b.pos, b.mat_flags))
		var sizes := []
		for piece in sc.pieces:
			sizes.append(piece.size())
		print("  sand top at x %.0f: %.1f; stroke %d spots -> pieces %s" % [X, top, stroke.size(), str(sizes)])
		waiting = false
		return
	if f % 60 != 0 and f <= sc.frames - 60 and not OS.get_cmdline_user_args().has("trace"):
		return
	var ids: Array = bodies.keys()
	ids.sort()
	var line := "  f=%d" % f
	var worst := 0.0
	for id in ids:
		var body: Dictionary = bodies[id]
		var fastest := _max_speed(body)
		var c := Vector2.ZERO
		for q in body.pos:
			c += q / body.pos.size()
		var low := 0  # members under the sand's top beside them (small pieces only: it is slow)
		if body.pos.size() < 200 and f % 60 == 0:
			for q in body.pos:
				if q.y > _sand_top(b, q.x, 1.5) + 1.0:
					low += 1
		if f > sc.frames - 60:
			sc.late[id] = maxf(sc.late.get(id, 0.0), fastest)
		if OS.get_cmdline_user_args().has("trace") and f > sc.hold + 200:
			var k_max := 0
			var fast := 0
			for k in body.vel.size():
				if body.vel[k].length() > body.vel[k_max].length():
					k_max = k
				if body.vel[k].length() > 5.0:
					fast += 1
			print("    t f=%d id %d: %d over 5 px/s, fastest %.1f px/s v(%.1f, %.1f) member rest (%.0f, %.0f) at (%.1f, %.1f) err %.2f"
					% [f, id, fast, fastest, body.vel[k_max].x, body.vel[k_max].y, body.rest[k_max].x, body.rest[k_max].y,
					body.pos[k_max].x, body.pos[k_max].y, _fit(body).err])
		if f % 60 == 0 and (body.pos.size() < 200 or fastest > 2.0):
			line += " | %d n%d (%.0f,%.0f) vmax%.0f low%d" % [id, body.pos.size(), c.x, c.y, fastest, low]
		worst = maxf(worst, fastest)
	if f % 60 == 0:
		print(line)
	if f == sc.frames:
		var moving := []
		for id in sc.late:
			if sc.late[id] > 5.0:
				moving.append("%d (n%d, %.0f px/s)" % [id, bodies[id].pos.size(), sc.late[id]])
		_result("sandstroke: %d pieces; still moving over 5 px/s in the last 60 frames: %s" % [ids.size(), ", ".join(moving)],
				moving.is_empty())


## corkstrip: the cork strip on the floor under 20k poured water must rise and float.
func _sample_corkstrip(f: int, b: Dictionary, bodies: Dictionary) -> void:
	if not bodies.has(1):
		return
	var body: Dictionary = bodies[1]
	var fit := _fit(body)
	var draft := _draft(b, body) if f > 300 else 0.0
	if f % 60 == 0:
		var base: int = 1 * ParticleSim.BODY_BYTES
		var bottom := -INF
		for q in body.pos:
			bottom = maxf(bottom, q.y)
		print("  f=%d cork c=(%.1f, %.1f) rot %.3f v=%s bottom %.1f above floor; draft %.2f; water top %.1f; p_ref %.1f flags %d; gap under %.1f px"
				% [f, fit.c.x, fit.c.y, fit.theta, _mean_vel(body), FLOOR - bottom, draft, _top_of(b, water, 40.0, 17.0),
				b.bodies.decode_float(base + 40), b.bodies.decode_u32(base + 12), _gap_under(b, body)])
	if f % 300 == 0 and OS.get_cmdline_user_args().has("grid"):
		_print_grid_columns(b, [fit.c.x, fit.c.x + 200.0])
		_print_pressure_push(b, body)
	if f % 60 == 0 and OS.get_cmdline_user_args().has("bare"):
		_print_bare(b, body, fit.theta)
	elif f > 300 and OS.get_cmdline_user_args().has("trace"):
		var low := -INF
		for q in body.pos:
			low = maxf(low, q.y)
		var p_ref: float = b.bodies.decode_float(ParticleSim.BODY_BYTES + 40)
		print("    t f=%d bottom %.1f vy %.1f p_ref %.0f" % [f, FLOOR - low, _mean_vel(body).y, p_ref])
		if p_ref < 20000.0 and OS.get_cmdline_user_args().has("refs"):
			_print_refs(b, body, fit.theta)
	if f > sc.frames - 60:
		sc.late.append(draft)
		sc.late_gap = sc.get("late_gap", 0.0) + _gap_under(b, body) / 6.0
	if f == sc.frames:
		var mean := 0.0
		for v in sc.late:
			mean += v / sc.late.size()
		_result("corkstrip: 180x10 cork on the floor under 20k water: mean draft over the last 60 frames %.2f (floats under 1), gap under it %.1f px (under %.0f)"
				% [mean, sc.late_gap, GAP_MAX], mean < 1.0 and sc.late_gap < GAP_MAX)


## Median over the middle 80% of a body's width, in 4 px columns, of the height of air between its
## lowest member and the highest water particle under it (0 where water touches it). A floater
## whose bottom face reads the grid's pressure over air rides on a gap (owner report 2026-10-15).
func _gap_under(b: Dictionary, body: Dictionary) -> float:
	var left := INF
	var right := -INF
	for p in body.pos:
		left = minf(left, p.x)
		right = maxf(right, p.x)
	var inset := 0.1 * (right - left)
	var n := int((right - left - 2.0 * inset) / 4.0)
	if n < 1:
		return 0.0
	var bottoms := PackedFloat32Array()
	var tops := PackedFloat32Array()
	bottoms.resize(n)
	tops.resize(n)
	bottoms.fill(-INF)
	tops.fill(INF)
	for p in body.pos:
		var k := int((p.x - left - inset) / 4.0)
		if k >= 0 and k < n:
			bottoms[k] = maxf(bottoms[k], p.y)
	for i in b.mat_flags.size() / 4:
		var mf: int = b.mat_flags.decode_u32(i * 4)
		if (mf & 0x100) == 0 or (mf & 0xFF) != water:
			continue
		var q := Vector2(b.pos.decode_float(i * 8), b.pos.decode_float(i * 8 + 4))
		var k := int((q.x - left - inset) / 4.0)
		if k >= 0 and k < n and q.y > bottoms[k]:
			tops[k] = minf(tops[k], q.y)
	var gaps := []
	for k in n:
		if bottoms[k] > -INF and tops[k] < INF:
			gaps.append(maxf(tops[k] - bottoms[k] - SimParams.SPACING, 0.0))
	if gaps.is_empty():
		return 0.0
	gaps.sort()
	return gaps[gaps.size() / 2]


## Debug ("bare", corkstrip): the boundary members with nothing but their own body within 1.5
## spacings, the grid's p at their outline point (what solve_pressure gives p_min), lowest first.
func _print_bare(b: Dictionary, body: Dictionary, theta: float) -> void:
	var sp := SimParams.SPACING
	var h := SimParams.H
	var cells := {}
	for i in b.mat_flags.size() / 4:
		var mf: int = b.mat_flags.decode_u32(i * 4)
		if (mf & 0x100) == 0 or (mf >> 16) == 1:
			continue
		var q := Vector2(b.pos.decode_float(i * 8), b.pos.decode_float(i * 8 + 4))
		var key := Vector2i((q / h).floor())
		if not cells.has(key):
			cells[key] = PackedVector2Array()
		cells[key].append(q)
	var bare := []
	for m in body.pos.size():
		var x: Vector2 = body.pos[m]
		var e: Vector2 = body.e[m].rotated(theta)
		if body.e[m].length() >= 0.75 * sp:
			continue
		if x.x < 1.5 * sp or x.y < 1.5 * sp or x.x > SimParams.WORLD_SIZE.x - 1.5 * sp or x.y > SimParams.WORLD_SIZE.y - 1.5 * sp:
			continue
		var touching := false
		var k := Vector2i((x / h).floor())
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				for q in cells.get(k + Vector2i(dx, dy), PackedVector2Array()):
					if q.distance_squared_to(x) < 2.25 * sp * sp:
						touching = true
		if not touching:
			bare.append([_grid_p(b, x + e), x, e])
	bare.sort_custom(func(u, v): return u[0] < v[0])
	var line := "    bare %d:" % bare.size()
	for u in bare.slice(0, 6):
		line += " [p%.0f at (%.0f,%.0f) e(%.1f,%.1f)]" % [u[0], u[1].x, u[1].y, u[2].x, u[2].y]
	print(line)


## Debug ("trace" and "refs", corkstrip): what each member gives the body's p_min as solve_pressure
## picks it (wet: p on its liquid side; bare boundary: p at its outline point), lowest first.
func _print_refs(b: Dictionary, body: Dictionary, theta: float) -> void:
	var sp := SimParams.SPACING
	var h := SimParams.H
	var ParticleStep = load("res://cpu_ref/particle_step.gd")
	var cells := {}
	for i in b.mat_flags.size() / 4:
		var mf: int = b.mat_flags.decode_u32(i * 4)
		if (mf & 0x100) == 0 or (mf >> 16) == 1:
			continue
		var q := Vector2(b.pos.decode_float(i * 8), b.pos.decode_float(i * 8 + 4))
		var key := Vector2i((q / h).floor())
		if not cells.has(key):
			cells[key] = []
		cells[key].append([q, mf & 0xFF])
	var refs := []
	for m in body.pos.size():
		var x: Vector2 = body.pos[m]
		var g := Vector2.ZERO
		var touching := false
		var k := Vector2i((x / h).floor())
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				for e in cells.get(k + Vector2i(dx, dy), []):
					var q: Vector2 = e[0]
					if q.distance_squared_to(x) < 2.25 * sp * sp:
						touching = true
					if e[1] == water:
						g += ParticleStep.body_wet_face(q - x, h, sp)
		var e_m: Vector2 = body.e[m].rotated(theta)
		if g.length() > 1e-6:
			refs.append([_grid_p(b, x + 0.5 * sp * g.normalized()), "wet", x, g])
		var at_wall := x.x < 1.5 * sp or x.y < 1.5 * sp or x.x > SimParams.WORLD_SIZE.x - 1.5 * sp or x.y > SimParams.WORLD_SIZE.y - 1.5 * sp
		if not touching and not at_wall and body.e[m].length() < 0.75 * sp:
			refs.append([_grid_p(b, x + e_m), "bare", x, e_m])
	refs.sort_custom(func(u, v): return u[0] < v[0])
	var line := "      refs:"
	for u in refs.slice(0, 5):
		var cell := Vector2i((u[2] / (h * SimParams.HYDRO_CELL)).floor())
		line += " [%s p%.0f at (%.0f,%.0f) dir(%.1f,%.1f) cell %s]" % [u[1], u[0], u[2].x, u[2].y, u[3].x, u[3].y, cell]
	print(line)


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
		ok = ok and err < (4.0 if sc.name == "erasejelly" else 0.1) and speed < REST_SPEED
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
func _inside(b: Dictionary, body: Dictionary, fit: Dictionary, material: int, margin := 0.0) -> int:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for q in body.rest:
		lo = lo.min(q)
		hi = hi.max(q)
	lo += Vector2(margin, margin)
	hi -= Vector2(margin, margin)
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
