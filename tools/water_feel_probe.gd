## Water feel probe: measures how fast water falls and spreads on the GPU sim, against the
## ideal, so "floaty" and "thick" become numbers. Needs a real window (no --headless).
## Run it in a copy of the repo, not the repo itself:
##   Godot_console.exe --path <copy> --script res://tools/water_feel_probe.gd -- <scenario> [frames] [every=N]
##   set=water.drag=60[,...] [setat=N] edits material parameters as the parameter panel does
##   (tools/probe_params.gd), at frame N (default: before the first frame)
##   fall   a 40x40 px block of water dropped from the top: mean fall speed and drop
##          against free fall (v = g t), until it lands
##   dam    a 100 px wide, 240 px tall column of water released at the left wall: the
##          front's x and speed, then the mean speed while it sloshes and settles
##   surface  a 126 px deep pool spawned at rest: speeds of the top layer only (the
##          highest particle per 4 px column and those within 3 px below it)
##   pour   a 40 px deep pool, a brush pouring into it for 3 s, then a 4000-particle
##          block dropped into it (look at it with shots=)
##   sandair  sand spawned by a brush in mid-air (r=1.5 px, n=2 grains per frame, spawn=20
##          frames, move=1 steps the brush 28 px per frame, move=0 holds it still): how many grains are still in the air (y < 150) once free fall
##          would have landed them all (should be 0)
##   erase  sand pile built with the moving brush (frames 1-PILE), then the eraser scrubbing
##          sideways across it while rising from the floor (to ERASE_END), as the owner
##          does: grains with nothing under them (no grain within 4 px below and not on
##          the floor) that are still (< SLEEP_SPEED) are clumps held in the air (should be 0)
##   shaft  the erase pile, then the eraser cut straight down at x=300 and x=345: dry sand
##          should cave in to its angle of repose, so the empty 2 px cells left in
##          x 285..360, y 260..356 should drop back towards 0, not stay open
##   sink   40k water as four +10k blocks 30 frames apart, then +10k sand at frame SINK_SAND
##          (as the owner does): sand grains that are still (< 0.5 px/s) with water right
##          under them are held up by water, a raft (should be 0), and the sand's mean depth
##   sandpour  the owner's sand poured into a pool: 30k water as three +10k blocks 30 frames
##          apart, then the sand brush (default radius) held at y 60 over the pool from frame
##          POUR_FROM to POUR_TO, still at x 320 (move=0) or swept over x 260..380 at 2 px per
##          frame (move=1, default), so the sand builds a column under the water; pour_y=Y
##          moves the brush (under the surface, y > ~175, it draws sand into the water), and
##          move=2 strokes it up and down at x 320 between y 340 and 140: the sink stats and
##          POCKETS
##   soak   a dry pile built with the moving brush (the erase pile, frames 1-ERASE_PILE),
##          then 3 x +10k water 30 frames apart from SOAK_WATER: water poured over dry sand
##          that settled with voids held open: the sink stats and POCKETS
##   bowl   a sand floor and two sand columns at the walls that slump into slopes, then 3 x 9000
##          water 30 frames apart from BOWL_WATER (the owner's pool in a sand bowl): water speed
##          next to sand (a grain within 6 px) and away from it, and coherent flow, the length
##          of the mean water velocity per 20 px cell (jitter averages out, a current doesn't),
##          and water inside the sand bed (6 of the 9 2 px cells around it hold sand). nosand
##          drops the sand (control). cols=N rows=N size the sand columns (default 75x100,
##          which leaves a steep right mound; 110x60 slumps into gentle slopes; cols=0 none).
##          floor=N rows of the sand floor (default 16; floor=12 cols=0 lines only the floor
##          of an otherwise pure pool, a control for the floor's grid boundary). Every 10th
##          sample a flow map of the 20 px cells, and at the end the flow averaged from 30 s
##          and the density projection grid averaged from 30 s: BOWLP the pressure in cells
##          of hydrostatic head (open water at rest rises 1.00 per cell), BOWLF each cell's
##          liquid/powder density over rest.
##   mounds the owner's scene of 2026-10-11: two sand columns at x 210 and 430 (sand=N grains
##          each, default 6000) that slump into mounds reaching the walls with a V between,
##          then water blocks 30 frames apart from BOWL_WATER (water=N in total, default
##          32000) until the peaks (y ~190) are ~70 px under: the bowl's stats and dumps, and at the end MOUNDS, the sand top and water
##          surface y per 20 px column
##   POCKETS (sink and bowl, every sample): water held inside the sand bed. enclosed: water
##          with sand above, below (or the floor) and on both sides within 24 px (the water
##          held in the bed); pocket: enclosed water with sand in at most 5 of the 25 2 px
##          cells around it (open water inside the bed, not pore water); groups: connected
##          pockets of 6+ 2 px cells, and the biggest. sink, sandpour and soak also print
##          the grid averaged from 30 s at the end (BOWLP, BOWLF, as in bowl)
##   layers two liquids (ADR 0010) that start mixed, and whether they layer: mix=rows (default)
##          builds a 64-row, 318-column pool at rest from the floor up, one row per frame,
##          rows alternating oil and water (2 px layers); mix=alt clicks +10k four times 30
##          frames apart, oil, water, oil, water (blocks at y 8, as main.gd's button); mix=pour
##          puts 2 x +10k water (30 frames apart), then from frame 120 paints oil into the pool
##          with the circle brush at y pour_y (default 320 here) swept across x 60..580 at 2 px
##          per frame until 10k are in; mix=pourwater does it the other way round (oil pool,
##          water brush). light=NAME heavy=NAME pick the liquids (default oil and water). Every
##          sample: LAYERS, the mean y of each, their gap and the gap two flat layers of those
##          counts would have (full), oil_above (share of light liquid above the heavy one's
##          mean y), top (per 20 px column, the share of light liquid among the column's top
##          k particles, k its light count: 1 is layered, ~its share is mixed), and mean speed.
##          At the end LAYERPROF, the light liquid's share per 8 px band. Judge on plateaus.
##   hover  the surface pool: water particles in the loose fringe above the dense surface
##          (the first 2 px row at least half full), and their mean vy (> 0 is falling)
## Every sample (every=N frames, default 3): one line per scenario, see _analyse.
##   shots=F1,F2,...  save the rendered frame at these frames as user://feel_<scenario><tag>_<F>.png
##   tag=T  added to the shot file names, so runs in parallel don't overwrite each other
extends SceneTree

const ComputeContext = preload("res://gpu/compute_context.gd")
const ParticleSim = preload("res://gpu/particle_sim.gd")
const GameConfig = preload("res://core/game_config.gd")
const MaterialTable = preload("res://cpu_ref/material_table.gd")
const SimParams = preload("res://core/sim_params.gd")
const ProbeParams = preload("res://tools/probe_params.gd")

const FALL_COLS := 20
const FALL_COUNT := 400
const DAM_COLS := 50
const DAM_ROWS := 120

var scenario := "fall"
var max_frames := 600
var sample_every := 3
var ctx
var sim
var table
var param_sets: Array = []  # from "set=" (tools/probe_params.gd)
var param_frame := 0  # from "setat=N"
var water := -1
var sand := -1
var cap := 50000
var frame_i := 0
var ready := false
var pending := false
var got := {}
var y0 := 0.0
var landed := false
var last_front := 0.0
var last_front_t := 0.0
var shots := PackedInt32Array()
var shot_tag := ""
var pour_y := 60.0
var dump_at := -1  # from "dump=F": write every live particle (material, x, y, vx, vy) to user://feel_<scenario>_<F>.csv
var sand_r := 1.5
var sand_n := 2
var sand_frames := 20
var sand_moving := 1
var bowl_sand := true
var mounds := false
var mounds_water := 32000
var mounds_sand := 6000
var bowl_samples := 0
var layer_mix := "rows"
var light := -1
var heavy := -1
var layer_light_name := "oil"
var layer_heavy_name := "water"
var layer_poured := 0
var bowl_avg_v := {}  # 20 px cell -> summed mean water velocity over samples from BOWL_AVG_FROM
var bowl_avg_n := {}
const BOWL_AVG_FROM := 30.0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() >= 1:
		scenario = args[0]
	if args.size() >= 2 and args[1].is_valid_int():
		max_frames = int(args[1])
	for a in args:
		if a.begins_with("every="):
			sample_every = maxi(1, int(a.substr(6)))
		if a.begins_with("r="):
			sand_r = float(a.substr(2))
		if a.begins_with("n="):
			sand_n = int(a.substr(2))
		if a.begins_with("spawn="):
			sand_frames = int(a.substr(6))
		if a.begins_with("cols="):
			bowl_col_cols = int(a.substr(5))
		if a.begins_with("rows="):
			bowl_col_rows = int(a.substr(5))
		if a.begins_with("floor="):
			bowl_floor_rows = int(a.substr(6))
		if a.begins_with("sand="):
			mounds_sand = int(a.substr(5))
		if a.begins_with("water="):
			mounds_water = int(a.substr(6))
		if a.begins_with("dump="):
			dump_at = int(a.substr(5))
		if a == "nosand":
			bowl_sand = false
		if a.begins_with("move="):
			sand_moving = int(a.substr(5))
		if a.begins_with("mix="):
			layer_mix = a.substr(4)
		if a.begins_with("light="):
			layer_light_name = a.substr(6)
		if a.begins_with("heavy="):
			layer_heavy_name = a.substr(6)
		if a.begins_with("pour_y="):
			pour_y = float(a.substr(7))
		if a.begins_with("tag="):
			shot_tag = a.substr(4)
		if a.begins_with("shots="):
			for v in a.substr(6).split(","):
				shots.append(int(v))
	if scenario == "mounds":
		scenario = "bowl"
		mounds = true
	param_sets = ProbeParams.parse(args)
	param_frame = ProbeParams.frame(args)
	var config = GameConfig.load_from_file()
	cap = config.particle_cap
	table = MaterialTable.new()
	var problems: PackedStringArray = table.load_file()
	if problems.size() > 0:
		print("MATERIAL PROBLEMS: ", problems)
	water = table.id_of("water")
	sand = table.id_of("sand")
	light = table.id_of(layer_light_name)
	heavy = table.id_of(layer_heavy_name)
	if scenario == "layers" and not Array(args).any(func(a): return a.begins_with("pour_y=")):
		pour_y = 320.0
	print("feel probe scenario=%s frames=%d g=%.0f dt=%.5f" % [scenario, max_frames, SimParams.GRAVITY, SimParams.DT])
	ctx = ComputeContext.new()
	sim = ParticleSim.new(ctx, cap, config.solver_iterations, table, config.substeps, config.body_cap)
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


func _process(_delta: float) -> bool:
	if not ready:
		return false
	frame_i += 1
	if frame_i == maxi(1, param_frame):
		ProbeParams.apply(table, sim, param_sets)
	var brush := {"op": ParticleSim.BRUSH_NONE, "pos": Vector2.ZERO, "radius": 0.0,
			"material": water, "count": 0, "cols": 1}
	if frame_i == 1:
		brush.op = ParticleSim.BRUSH_BLOCK
		if scenario == "surface" or scenario == "hover":
			brush.count = 20000
			brush.cols = 319
			brush.pos = Vector2(1.0, SimParams.WORLD_SIZE.y - 1.0 - 63 * SimParams.SPACING)
		elif scenario == "dam":
			brush.count = DAM_COLS * DAM_ROWS
			brush.cols = DAM_COLS
			brush.pos = Vector2(1.0, SimParams.WORLD_SIZE.y - 1.0 - DAM_ROWS * SimParams.SPACING)
		else:
			brush.count = FALL_COUNT
			brush.cols = FALL_COLS
			brush.pos = Vector2(310.0, 8.0)
			y0 = 8.0 + (FALL_COUNT / FALL_COLS - 1) * SimParams.SPACING * 0.5
	if scenario == "pour":
		brush = _pour_brush()
	if scenario == "sandair":
		brush = _sandair_brush()
	if scenario == "erase":
		brush = _erase_brush()
	if scenario == "shaft":
		brush = _shaft_brush()
	if scenario == "sink":
		brush = _sink_brush()
	if scenario == "sandpour":
		brush = _sandpour_brush()
	if scenario == "soak":
		brush = _soak_brush()
	if scenario == "bowl":
		brush = _bowl_brush()
	if scenario == "layers":
		brush = _layers_brush()
	sim.frame(brush, 0)
	if frame_i in shots:
		RenderingServer.call_on_render_thread(_shot_rt.bind(frame_i))
	if scenario != "pour" and frame_i % sample_every == 0 and not pending:
		pending = true
		got = {}
		RenderingServer.call_on_render_thread(_request.bind(frame_i))
	if frame_i >= max_frames and scenario == "bowl" and not bowl_avg_n.is_empty():
		# Time-averaged flow from BOWL_AVG_FROM: vx,vy per 20 px cell in px/s (a steady loop
		# survives the average, wandering eddies don't).
		for gy in int(SimParams.WORLD_SIZE.y / 20.0):
			var row := ""
			for gx in int(SimParams.WORLD_SIZE.x / 20.0):
				var g := Vector2i(gx, gy)
				if not bowl_avg_n.has(g):
					row += "      ."
					continue
				var m: Vector2 = bowl_avg_v[g] / float(bowl_avg_n[g])
				row += "%+3d,%+3d" % [roundi(m.x), roundi(m.y)]
			print("BOWLAVG ", row)
		_bowl_pressure_print()
		if mounds:
			_mounds_profile()
	if frame_i >= max_frames and scenario in ["sink", "sandpour", "soak"]:
		_bowl_pressure_print()
	if frame_i >= max_frames and scenario == "layers":
		_layers_profile()
	if frame_i >= max_frames:
		print("done after %d frames, live %d" % [frame_i, sim.live_count])
		sim.shutdown()
		quit(0)
	return false


func _pour_brush() -> Dictionary:
	var brush := {"op": ParticleSim.BRUSH_NONE, "pos": Vector2.ZERO, "radius": SimParams.BRUSH_RADIUS,
			"material": water, "count": 0, "cols": 1}
	if frame_i == 1:
		brush.op = ParticleSim.BRUSH_BLOCK
		brush.count = 6000
		brush.cols = 300
		brush.pos = Vector2(20.0, SimParams.WORLD_SIZE.y - 41.0)
	elif frame_i >= 30 and frame_i <= 210:
		brush.op = ParticleSim.BRUSH_CIRCLE
		brush.pos = Vector2(200.0, 40.0)
		brush.count = SimParams.brush_rate()
	elif frame_i == 300:
		brush.op = ParticleSim.BRUSH_BLOCK
		brush.count = 4000
		brush.cols = 40
		brush.pos = Vector2(420.0, 20.0)
	return brush


func _layers_brush() -> Dictionary:
	var brush := {"op": ParticleSim.BRUSH_NONE, "pos": Vector2.ZERO, "radius": SimParams.BRUSH_RADIUS,
			"material": light, "count": 0, "cols": 1}
	var f := frame_i - 1
	if layer_mix == "rows":
		if f < 64:
			brush.op = ParticleSim.BRUSH_BLOCK
			brush.material = light if f % 2 == 0 else heavy
			brush.count = 318
			brush.cols = 318
			brush.pos = Vector2(2.0, SimParams.WORLD_SIZE.y - 1.0 - f * SimParams.SPACING)
	elif layer_mix == "alt":
		if f % 30 == 0 and f / 30 < 4:
			brush.op = ParticleSim.BRUSH_BLOCK
			brush.material = light if (f / 30) % 2 == 0 else heavy
			brush.count = SimParams.BENCH_BLOCK
			brush.cols = SimParams.BENCH_COLS
			brush.pos = Vector2((SimParams.WORLD_SIZE.x - SimParams.BENCH_COLS * SimParams.SPACING) * 0.5, 8.0)
	else:  # pour: the pool liquid, then the other painted into it
		var pool := heavy if layer_mix == "pour" else light
		var paint := light if layer_mix == "pour" else heavy
		if f % 30 == 0 and f / 30 < 2:
			brush.op = ParticleSim.BRUSH_BLOCK
			brush.material = pool
			brush.count = SimParams.BENCH_BLOCK
			brush.cols = SimParams.BENCH_COLS
			brush.pos = Vector2((SimParams.WORLD_SIZE.x - SimParams.BENCH_COLS * SimParams.SPACING) * 0.5, 8.0)
		elif f >= 120 and layer_poured < SimParams.BENCH_BLOCK:
			var span := 520.0
			var s := fmod((f - 120) * 2.0, 2.0 * span)
			brush.op = ParticleSim.BRUSH_CIRCLE
			brush.material = paint
			brush.pos = Vector2(60.0 + (s if s < span else 2.0 * span - s), pour_y)
			brush.count = SimParams.brush_rate()
			layer_poured += brush.count  # an upper bound: spots too close to a particle are skipped
	return brush


func _layers(b: Dictionary, t: float) -> void:
	var sum := {light: 0.0, heavy: 0.0}
	var n := {light: 0, heavy: 0}
	var speed := 0.0
	var cols := {}  # 20 px column -> [light count, ys (light negated)]
	for i in cap:
		var fl := int(b.mat_flags.decode_u32(i * 4))
		var m := fl & 0xFF
		if (fl & 0x100) == 0 or not (m == light or m == heavy):
			continue
		var x: float = b.pos.decode_float(i * 8)
		var y: float = b.pos.decode_float(i * 8 + 4)
		sum[m] += y
		n[m] += 1
		speed += Vector2(b.vel.decode_float(i * 8), b.vel.decode_float(i * 8 + 4)).length()
		var c := int(x / 20.0)
		if not cols.has(c):
			cols[c] = [0, []]
		if m == light:
			cols[c][0] += 1
		cols[c][1].append(-y if m == light else y)
	if n[light] == 0 or n[heavy] == 0:
		return
	var heavy_y: float = sum[heavy] / n[heavy]
	var above := 0
	for i in cap:
		var fl := int(b.mat_flags.decode_u32(i * 4))
		if (fl & 0x100) != 0 and (fl & 0xFF) == light and b.pos.decode_float(i * 8 + 4) < heavy_y:
			above += 1
	# Per column: of its k highest particles (k = its light count), how many are light.
	var top_light := 0
	for c in cols:
		var k: int = cols[c][0]
		var ys: Array = cols[c][1]
		ys.sort_custom(func(a, bb): return absf(a) < absf(bb))
		for j in k:
			if ys[j] < 0.0:
				top_light += 1
	# Two flat layers over the floor width: each layer's thickness is its count x spacing^2 / width.
	var full: float = (n[light] + n[heavy]) * SimParams.SPACING * SimParams.SPACING / (SimParams.WORLD_SIZE.x - 2.0) * 0.5
	print("LAYERS t=%.1f light_y=%.1f heavy_y=%.1f gap=%.1f full=%.1f oil_above=%.3f top=%.3f speed=%.2f n=%d/%d" % [
			t, sum[light] / n[light], heavy_y, heavy_y - sum[light] / n[light], full, float(above) / n[light],
			float(top_light) / n[light], speed / (n[light] + n[heavy]), n[light], n[heavy]])


## The light liquid's share per 8 px band, from the last readback (LAYERPROF).
func _layers_profile() -> void:
	if not got.has("pos") or not got.has("mat_flags"):
		return
	var bands := {}
	for i in cap:
		var fl := int(got.mat_flags.decode_u32(i * 4))
		var m := fl & 0xFF
		if (fl & 0x100) == 0 or not (m == light or m == heavy):
			continue
		var band := int(got.pos.decode_float(i * 8 + 4) / 8.0)
		var a: Array = bands.get(band, [0, 0])
		a[0 if m == light else 1] += 1
		bands[band] = a
	var keys := bands.keys()
	keys.sort()
	var line := ""
	for k in keys:
		line += " y%d:%.2f(%d)" % [k * 8, float(bands[k][0]) / (bands[k][0] + bands[k][1]), bands[k][0] + bands[k][1]]
	print("LAYERPROF light share per 8 px band:", line)


func _sandair_brush() -> Dictionary:
	var brush := {"op": ParticleSim.BRUSH_NONE, "pos": Vector2.ZERO, "radius": sand_r,
			"material": sand, "count": 0, "cols": 1}
	if frame_i <= sand_frames:
		brush.op = ParticleSim.BRUSH_CIRCLE
		brush.pos = Vector2(40.0 + 28.0 * (frame_i % 20) * sand_moving + 280.0 * (1 - sand_moving), 40.0)
		brush.count = sand_n
	return brush


const ERASE_PILE := 360
const ERASE_END := 840


func _erase_brush() -> Dictionary:
	var brush := {"op": ParticleSim.BRUSH_NONE, "pos": Vector2.ZERO, "radius": SimParams.BRUSH_RADIUS,
			"material": sand, "count": 0, "cols": 1}
	if frame_i <= ERASE_PILE:
		# Brush swept over x 240..400 at y 200, 8 px per frame, like a held mouse.
		var ph := (frame_i * 8) % 320
		brush.op = ParticleSim.BRUSH_CIRCLE
		brush.pos = Vector2(240.0 + (ph if ph < 160 else 320 - ph), 200.0)
		brush.count = SimParams.brush_rate()
	elif frame_i > ERASE_PILE + 60 and frame_i <= ERASE_END:
		# Eraser scrubbing x 200..440 at 12 px per frame, rising from the floor.
		var k := frame_i - ERASE_PILE - 60
		var ph := (k * 12) % 480
		brush.op = ParticleSim.BRUSH_ERASE
		brush.pos = Vector2(200.0 + (ph if ph < 240 else 480 - ph), SimParams.WORLD_SIZE.y - 4.0 - 0.3 * k)
	return brush


func _shaft_brush() -> Dictionary:
	var brush := _erase_brush() if frame_i <= ERASE_PILE else {"op": ParticleSim.BRUSH_NONE,
			"pos": Vector2.ZERO, "radius": SimParams.BRUSH_RADIUS, "material": sand, "count": 0, "cols": 1}
	var k := frame_i - ERASE_PILE - 60
	if k > 0 and k <= 220:
		# Down at 2 px per frame from y 140, first at x 300, then at x 345.
		brush.op = ParticleSim.BRUSH_ERASE
		brush.pos = Vector2(300.0 if k <= 110 else 345.0, 140.0 + 2.0 * float((k - 1) % 110))
	return brush


const SINK_SAND := 600


func _sink_brush() -> Dictionary:
	var brush := {"op": ParticleSim.BRUSH_NONE, "pos": Vector2.ZERO, "radius": 0.0,
			"material": water, "count": 0, "cols": 1}
	if (frame_i - 1) % 30 == 0 and frame_i <= 91 or frame_i == SINK_SAND:
		brush.op = ParticleSim.BRUSH_BLOCK
		brush.material = sand if frame_i == SINK_SAND else water
		brush.count = SimParams.BENCH_BLOCK
		brush.cols = SimParams.BENCH_COLS
		brush.pos = Vector2((SimParams.WORLD_SIZE.x - SimParams.BENCH_COLS * SimParams.SPACING) * 0.5, 8.0)
	return brush


const POUR_FROM := 300
const POUR_TO := 1200


func _sandpour_brush() -> Dictionary:
	var brush := {"op": ParticleSim.BRUSH_NONE, "pos": Vector2.ZERO, "radius": SimParams.BRUSH_RADIUS,
			"material": water, "count": 0, "cols": 1}
	if (frame_i - 1) % 30 == 0 and frame_i <= 61:
		brush.op = ParticleSim.BRUSH_BLOCK
		brush.count = SimParams.BENCH_BLOCK
		brush.cols = SimParams.BENCH_COLS
		brush.pos = Vector2((SimParams.WORLD_SIZE.x - SimParams.BENCH_COLS * SimParams.SPACING) * 0.5, 8.0)
	elif frame_i >= POUR_FROM and frame_i <= POUR_TO:
		var ph := (frame_i * 2) % 240
		brush.op = ParticleSim.BRUSH_CIRCLE
		brush.material = sand
		brush.pos = Vector2(260.0 + (ph if ph < 120 else 240 - ph) if sand_moving == 1 else 320.0, pour_y)
		if sand_moving == 2:
			# A vertical stroke: up from the floor through the pool and back, 1 px per frame.
			var pv := (frame_i - POUR_FROM) % 400
			brush.pos = Vector2(320.0, 340.0 - float(pv if pv < 200 else 400 - pv))
		brush.count = SimParams.brush_rate()
	return brush


const SOAK_WATER := 600


func _soak_brush() -> Dictionary:
	if frame_i <= ERASE_PILE:
		return _erase_brush()
	var brush := {"op": ParticleSim.BRUSH_NONE, "pos": Vector2.ZERO, "radius": 0.0,
			"material": water, "count": 0, "cols": 1}
	if frame_i >= SOAK_WATER and (frame_i - SOAK_WATER) % 30 == 0 and frame_i <= SOAK_WATER + 60:
		brush.op = ParticleSim.BRUSH_BLOCK
		brush.count = SimParams.BENCH_BLOCK
		brush.cols = SimParams.BENCH_COLS
		brush.pos = Vector2((SimParams.WORLD_SIZE.x - SimParams.BENCH_COLS * SimParams.SPACING) * 0.5, 8.0)
	return brush


const BOWL_WATER := 300
var bowl_floor_rows := 16  # from "floor=N": rows of the sand floor
var bowl_col_cols := 75  # from "cols=N": width of each sand column, in particles
var bowl_col_rows := 100  # from "rows=N"; cols=110 rows=60 slumps into gentle slopes


func _bowl_brush() -> Dictionary:
	if mounds:
		return _mounds_brush()
	var brush := {"op": ParticleSim.BRUSH_NONE, "pos": Vector2.ZERO, "radius": 0.0,
			"material": sand, "count": 0, "cols": 1}
	var w := SimParams.WORLD_SIZE
	var floor_top := w.y - 1.0 - bowl_floor_rows * SimParams.SPACING
	var col_w := bowl_col_cols * SimParams.SPACING
	if frame_i <= 3 and not bowl_sand:
		return brush
	if frame_i == 1:
		brush.op = ParticleSim.BRUSH_BLOCK
		brush.cols = int(w.x / SimParams.SPACING) - 1
		brush.count = brush.cols * bowl_floor_rows
		brush.pos = Vector2(1.0, floor_top)
	elif (frame_i == 2 or frame_i == 3) and bowl_col_cols > 0:
		brush.op = ParticleSim.BRUSH_BLOCK
		brush.cols = bowl_col_cols
		brush.count = bowl_col_cols * bowl_col_rows
		brush.pos = Vector2(1.0 if frame_i == 2 else w.x - 1.0 - col_w,
				floor_top - 2.0 - bowl_col_rows * SimParams.SPACING)
	elif frame_i >= BOWL_WATER and (frame_i - BOWL_WATER) % 30 == 0 and frame_i <= BOWL_WATER + 60:
		brush.op = ParticleSim.BRUSH_BLOCK
		brush.material = water
		brush.count = 9000
		brush.cols = SimParams.BENCH_COLS
		brush.pos = Vector2((w.x - SimParams.BENCH_COLS * SimParams.SPACING) * 0.5, 8.0)
	return brush


const MOUND_COLS := 60
const MOUND_X := [210.0, 430.0]


func _mounds_brush() -> Dictionary:
	var brush := {"op": ParticleSim.BRUSH_NONE, "pos": Vector2.ZERO, "radius": 0.0,
			"material": sand, "count": 0, "cols": 1}
	var w := SimParams.WORLD_SIZE
	if frame_i == 1 or frame_i == 2:
		var rows := mounds_sand / MOUND_COLS
		brush.op = ParticleSim.BRUSH_BLOCK
		brush.cols = MOUND_COLS
		brush.count = rows * MOUND_COLS
		brush.pos = Vector2(MOUND_X[frame_i - 1] - MOUND_COLS * SimParams.SPACING * 0.5,
				w.y - 1.0 - rows * SimParams.SPACING)
	elif frame_i >= BOWL_WATER and (frame_i - BOWL_WATER) % 30 == 0:
		var left := mounds_water - (frame_i - BOWL_WATER) / 30 * SimParams.BENCH_BLOCK
		if left > 0:
			brush.op = ParticleSim.BRUSH_BLOCK
			brush.material = water
			brush.count = mini(left, SimParams.BENCH_BLOCK)
			brush.cols = SimParams.BENCH_COLS
			brush.pos = Vector2((w.x - SimParams.BENCH_COLS * SimParams.SPACING) * 0.5, 8.0)
	return brush


var mounds_last := {}


## Sand top (highest grain) and water surface (highest water particle) y per 20 px column,
## from the last sample.
func _mounds_profile() -> void:
	if mounds_last.is_empty():
		return
	var b: Dictionary = mounds_last
	var cols := int(SimParams.WORLD_SIZE.x / 20.0)
	var sand_top := PackedFloat32Array()
	var water_top := PackedFloat32Array()
	sand_top.resize(cols)
	water_top.resize(cols)
	sand_top.fill(SimParams.WORLD_SIZE.y)
	water_top.fill(SimParams.WORLD_SIZE.y)
	for i in cap:
		var fl := int(b.mat_flags.decode_u32(i * 4))
		if (fl & 0x100) == 0:
			continue
		var x: float = b.pos.decode_float(i * 8)
		var y: float = b.pos.decode_float(i * 8 + 4)
		var c := clampi(int(x / 20.0), 0, cols - 1)
		if (fl & 0xFF) == sand:
			sand_top[c] = minf(sand_top[c], y)
		elif (fl & 0xFF) == water:
			water_top[c] = minf(water_top[c], y)
	var rs := ""
	var rw := ""
	for c in cols:
		rs += " %3d" % roundi(sand_top[c])
		rw += " %3d" % roundi(water_top[c])
	print("MOUNDS sand_top  ", rs)
	print("MOUNDS water_top ", rw)


func _bowl_stats(b: Dictionary, t: float) -> void:
	mounds_last = b
	var sand_cells := {}
	var sand_n := 0
	var sand_speed := 0.0
	var sand_moving := 0
	for i in cap:
		var fl := int(b.mat_flags.decode_u32(i * 4))
		if (fl & 0x100) == 0 or (fl & 0xFF) != sand:
			continue
		sand_n += 1
		var sv := Vector2(b.vel.decode_float(i * 8), b.vel.decode_float(i * 8 + 4)).length()
		sand_speed += sv
		if sv > 1.0:
			sand_moving += 1
		sand_cells[Vector2i(int(b.pos.decode_float(i * 8) / 2.0), int(b.pos.decode_float(i * 8 + 4) / 2.0))] = true
	var n := 0
	var near_n := 0
	var near_speed := 0.0
	var bulk_speed := 0.0
	var fast := 0
	var cell_v := {}
	var cell_n := {}
	var cell_near := {}
	var bed_n := 0
	var bed_speed := 0.0
	var bed_vy := 0.0
	for i in cap:
		var fl := int(b.mat_flags.decode_u32(i * 4))
		if (fl & 0x100) == 0 or (fl & 0xFF) != water:
			continue
		var p := Vector2(b.pos.decode_float(i * 8), b.pos.decode_float(i * 8 + 4))
		var v := Vector2(b.vel.decode_float(i * 8), b.vel.decode_float(i * 8 + 4))
		n += 1
		if v.length() > 3.0:
			fast += 1
		var c := Vector2i(int(p.x / 2.0), int(p.y / 2.0))
		var near := false
		for dy in range(-3, 4):
			for dx in range(-3, 4):
				if sand_cells.has(c + Vector2i(dx, dy)):
					near = true
					break
			if near:
				break
		var sand_around := 0
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				if sand_cells.has(c + Vector2i(dx, dy)):
					sand_around += 1
		if sand_around >= 6:
			bed_n += 1
			bed_speed += v.length()
			bed_vy += v.y
		if near:
			near_n += 1
			near_speed += v.length()
		else:
			bulk_speed += v.length()
		var g := Vector2i(int(p.x / 20.0), int(p.y / 20.0))
		cell_v[g] = cell_v.get(g, Vector2.ZERO) + v
		cell_n[g] = cell_n.get(g, 0) + 1
		if near:
			cell_near[g] = true
	if n == 0:
		print("BOWL t=%.2f sand=%d sand_speed=%.2f (no water yet)" % [t, sand_n, sand_speed / maxi(sand_n, 1)])
		return
	# Coherent flow: |mean v| per 20 px cell with at least 20 water particles.
	var flow_near := 0.0
	var flow_near_n := 0
	var flow_bulk := 0.0
	var flow_bulk_n := 0
	var flow_max := 0.0
	var flow_max_at := Vector2i.ZERO
	for g in cell_n:
		if cell_n[g] < 20:
			continue
		var m: float = (cell_v[g] / float(cell_n[g])).length()
		if cell_near.has(g):
			flow_near += m
			flow_near_n += 1
		else:
			flow_bulk += m
			flow_bulk_n += 1
		if m > flow_max:
			flow_max = m
			flow_max_at = g
	print("BOWL t=%.2f water=%d near_sand=%d speed near=%.2f bulk=%.2f fast(>3)=%d | flow near=%.2f (%d cells) bulk=%.2f (%d) max=%.1f at (%d,%d) px | in bed=%d speed=%.2f vy=%.2f | sand=%d speed=%.2f moving(>1)=%d" % [
			t, n, near_n, near_speed / maxi(near_n, 1), bulk_speed / maxi(n - near_n, 1), fast,
			flow_near / maxi(flow_near_n, 1), flow_near_n, flow_bulk / maxi(flow_bulk_n, 1), flow_bulk_n,
			flow_max, flow_max_at.x * 20 + 10, flow_max_at.y * 20 + 10,
			bed_n, bed_speed / maxi(bed_n, 1), bed_vy / maxi(bed_n, 1), sand_n, sand_speed / maxi(sand_n, 1), sand_moving])
	bowl_samples += 1
	_bowl_pressure(b, t)
	if t >= BOWL_AVG_FROM:
		for g in cell_n:
			if cell_n[g] >= 20:
				bowl_avg_v[g] = bowl_avg_v.get(g, Vector2.ZERO) + cell_v[g] / float(cell_n[g])
				bowl_avg_n[g] = bowl_avg_n.get(g, 0) + 1
	if bowl_samples % 10 == 0:
		# Flow map: per 20 px cell, the mean water velocity as an arrow and |v| in px/s
		# ('.' under 1, '#' sand-only, ' ' empty).
		var rows := PackedStringArray()
		for gy in int(SimParams.WORLD_SIZE.y / 20.0):
			var row := ""
			for gx in int(SimParams.WORLD_SIZE.x / 20.0):
				var g := Vector2i(gx, gy)
				if cell_n.get(g, 0) < 20:
					row += "  ."
					continue
				var m: Vector2 = cell_v[g] / float(cell_n[g])
				if m.length() < 1.0:
					row += "  ."
					continue
				var arrows := ["→", "↘", "↓", "↙", "←", "↖", "↑", "↗"]
				var a: String = arrows[int(round(m.angle() / (PI / 4.0))) % 8]
				row += "%s%2d" % [a, mini(int(m.length()), 99)]
			rows.append(row)
		print("BOWLMAP t=%.2f\n%s" % [t, "\n".join(rows)])


var bowl_p_sum := PackedFloat32Array()
var bowl_phi_sum := PackedVector2Array()
var bowl_p_n := 0


## Density projection grid pressure, in cells of hydrostatic head (p / (GRAVITY * 16 px)):
## a column at rest carried by the grid rises by 1.0 per cell below its surface. Summed
## from BOWL_AVG_FROM, printed as BOWLP at the end with each cell's fill: w liquid,
## s powder (powder * 0.7 over 0.5), m both, ' ' air.
func _bowl_pressure(b: Dictionary, t: float) -> void:
	var gw := ceili(SimParams.WORLD_SIZE.x / 16.0)
	var gh := ceili(SimParams.WORLD_SIZE.y / 16.0)
	if bowl_p_sum.is_empty():
		bowl_p_sum.resize(gw * gh)
		bowl_phi_sum.resize(gw * gh)
	if t < BOWL_AVG_FROM:
		return
	bowl_p_n += 1
	for c in gw * gh:
		bowl_p_sum[c] += b.hydro_p.decode_float(c * 4)
		bowl_phi_sum[c] += Vector2(b.hydro_phi.decode_float(c * 16), b.hydro_phi.decode_float(c * 16 + 4))


func _bowl_pressure_print() -> void:
	if bowl_p_n == 0:
		return
	var gw := ceili(SimParams.WORLD_SIZE.x / 16.0)
	var gh := ceili(SimParams.WORLD_SIZE.y / 16.0)
	var head := SimParams.GRAVITY * 16.0
	for gy in gh:
		var row := ""
		var rowf := ""
		for gx in gw:
			var c := gy * gw + gx
			var phi: Vector2 = bowl_phi_sum[c] / float(bowl_p_n)
			var p: float = bowl_p_sum[c] / float(bowl_p_n) / head
			var liquid := phi.x >= 0.3
			var powder := phi.y * 0.7 >= 0.5
			var tag := "m" if liquid and powder else ("w" if liquid else ("s" if powder else " "))
			row += "%5.2f%s" % [p, tag] if liquid else "     %s" % tag
			rowf += " %5.3f/%4.2f" % [phi.x, phi.y]
		print("BOWLP %2d %s" % [gy, row])
		print("BOWLF %2d %s" % [gy, rowf])

## Water held inside a sand bed (see POCKETS in the header): enclosed water has sand above
## it, below it (or the floor) and on both sides within POCKET_REACH 2 px cells. A pocket
## particle is enclosed water with at most POCKET_SAND of the 25 2 px cells around it (5x5)
## holding sand: open water inside the bed, not pore water. Water ignores sand in its
## density, so pore water sits at full density among the grains (~20 water neighbours, as
## in open water) and only the sand around tells the two apart.
## Pockets: 4-connected groups of pocket cells of at least POCKET_MIN cells.
const POCKET_REACH := 12
const POCKET_SAND := 5
const POCKET_MIN := 6


func _pocket_stats(b: Dictionary, t: float) -> void:
	var sand_cells := {}
	var wps := PackedVector2Array()
	for i in cap:
		var fl := int(b.mat_flags.decode_u32(i * 4))
		if (fl & 0x100) == 0:
			continue
		var p := Vector2(b.pos.decode_float(i * 8), b.pos.decode_float(i * 8 + 4))
		var c := Vector2i(int(p.x / 2.0), int(p.y / 2.0))
		if (fl & 0xFF) == sand:
			sand_cells[c] = true
		elif (fl & 0xFF) == water:
			wps.append(p)
	var floor_cell := int(SimParams.WORLD_SIZE.y / 2.0) - 1
	var enclosed := 0
	var pocket := 0
	var hist := PackedInt32Array()
	hist.resize(6)
	var pocket_cells := {}
	for p in wps:
		var c := Vector2i(int(p.x / 2.0), int(p.y / 2.0))
		var up := false
		var down := c.y + POCKET_REACH >= floor_cell
		var left := false
		var right := false
		for r in range(1, POCKET_REACH + 1):
			for o in [-1, 0, 1]:
				up = up or sand_cells.has(c + Vector2i(o, -r))
				down = down or sand_cells.has(c + Vector2i(o, r))
				left = left or sand_cells.has(c + Vector2i(-r, o))
				right = right or sand_cells.has(c + Vector2i(r, o))
		if not (up and down and left and right):
			continue
		enclosed += 1
		var ns := 0
		for dy in range(-2, 3):
			for dx in range(-2, 3):
				if sand_cells.has(c + Vector2i(dx, dy)):
					ns += 1
		hist[mini(ns / 5, 5)] += 1
		if ns <= POCKET_SAND:
			pocket += 1
			pocket_cells[c] = true
	# Connected groups of pocket cells.
	var seen := {}
	var groups := 0
	var biggest := 0
	for c0 in pocket_cells:
		if seen.has(c0):
			continue
		var stack := [c0]
		seen[c0] = true
		var size := 0
		while not stack.is_empty():
			var c: Vector2i = stack.pop_back()
			size += 1
			for o in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var nc: Vector2i = c + o
				if pocket_cells.has(nc) and not seen.has(nc):
					seen[nc] = true
					stack.append(nc)
		if size >= POCKET_MIN:
			groups += 1
			biggest = maxi(biggest, size)
	print("POCKETS t=%.2f enclosed=%d pocket(<=%d sand)=%d groups(>=%d cells)=%d biggest=%d | sand cells of 25 around 0-4,5-9,10-14,15-19,20-24,25: %s" % [
			t, enclosed, POCKET_SAND, pocket, POCKET_MIN, groups, biggest, str(hist)])


func _sink_stats(b: Dictionary, t: float) -> void:
	var wet := {}
	for i in cap:
		var fl := int(b.mat_flags.decode_u32(i * 4))
		if (fl & 0x100) != 0 and (fl & 0xFF) == water:
			var y: float = b.pos.decode_float(i * 8 + 4)
			wet[Vector2i(int(b.pos.decode_float(i * 8) / 2.0), int(y / 2.0))] = true
	var n := 0
	var still := 0
	var raft := 0
	var raft_y := 0.0
	var sum_y := 0.0
	var sum_vy := 0.0
	for i in cap:
		var fl := int(b.mat_flags.decode_u32(i * 4))
		if (fl & 0x100) == 0 or (fl & 0xFF) != sand:
			continue
		var p := Vector2(b.pos.decode_float(i * 8), b.pos.decode_float(i * 8 + 4))
		var v := Vector2(b.vel.decode_float(i * 8), b.vel.decode_float(i * 8 + 4))
		n += 1
		sum_y += p.y
		sum_vy += v.y
		if v.length() >= 0.5:
			continue
		still += 1
		var c := Vector2i(int(p.x / 2.0), int(p.y / 2.0))
		if wet.has(c + Vector2i(0, 1)) or wet.has(c + Vector2i(0, 2)):
			raft += 1
			raft_y += p.y
	if n == 0:
		return
	print("SINK t=%.2f sand=%d mean_y=%.0f mean_vy=%.1f still=%d raft(still, water under)=%d raft_mean_y=%.0f" % [
			t, n, sum_y / n, sum_vy / n, still, raft, raft_y / maxi(raft, 1)])
	_sink_gap(b, t)
	_bowl_pressure(b, t)


var sink_samples := 0


## Gap between the settled sand and the water on it, per 2 px column: the bed top is the
## highest grain of the run of grains (each within 5 px of the one below) that starts at
## the floor, and the gap is from it up to the lowest water particle above it. Water
## resting on the grains sits one contact distance (SPACING, 2 px) up. Also the empty 2 px
## cells (no particle) in the water between the bed top and the water surface. Every 10th
## sample, per 16 px column, the density projection grid at the bed top: the cell holding
## it and the one above, as liquid+powder*HYDRO_POWDER_FULL fill and p in head below the
## surface (hydrostatic: depth of the cell centre below the water surface / 16).
func _sink_gap(b: Dictionary, t: float) -> void:
	var cols := int(SimParams.WORLD_SIZE.x / 2.0)
	var sand_y := []
	var water_y := []
	sand_y.resize(cols)
	water_y.resize(cols)
	for c in cols:
		sand_y[c] = PackedFloat32Array()
		water_y[c] = PackedFloat32Array()
	var occ := {}
	for i in cap:
		var fl := int(b.mat_flags.decode_u32(i * 4))
		if (fl & 0x100) == 0:
			continue
		var x: float = b.pos.decode_float(i * 8)
		var y: float = b.pos.decode_float(i * 8 + 4)
		var c := clampi(int(x / 2.0), 0, cols - 1)
		occ[Vector2i(c, int(y / 2.0))] = true
		if (fl & 0xFF) == sand:
			sand_y[c].append(y)
		elif (fl & 0xFF) == water:
			water_y[c].append(y)
	var tops := PackedFloat32Array()
	tops.resize(cols)
	var surf := PackedFloat32Array()
	surf.resize(cols)
	var gaps := PackedFloat32Array()
	var q_sum := [0.0, 0.0, 0.0, 0.0]
	var q_n := [0, 0, 0, 0]
	var over3 := 0
	var over5 := 0
	var air := 0
	var air_near := 0
	for c in cols:
		tops[c] = -1.0
		var ss: PackedFloat32Array = sand_y[c]
		var ws: PackedFloat32Array = water_y[c]
		if ss.is_empty() or ws.is_empty():
			continue
		ss.sort()
		var k := ss.size() - 1
		if ss[k] < SimParams.WORLD_SIZE.y - 6.0:
			continue
		while k > 0 and ss[k] - ss[k - 1] <= 5.0:
			k -= 1
		var top: float = ss[k]
		var low := -1.0
		var wtop := 1e9
		for y in ws:
			wtop = minf(wtop, y)
			if y < top and y > low:
				low = y
		if low < 0.0:
			continue
		tops[c] = top
		surf[c] = wtop
		var gap := top - low
		gaps.append(gap)
		q_sum[c * 4 / cols] += gap
		q_n[c * 4 / cols] += 1
		if gap > 3.0:
			over3 += 1
		if gap > 5.0:
			over5 += 1
		for cy in range(int(wtop / 2.0) + 1, int(top / 2.0)):
			if not occ.has(Vector2i(c, cy)):
				air += 1
				if cy * 2.0 > top - 8.0:
					air_near += 1
	if gaps.is_empty():
		return
	gaps.sort()
	var mean := 0.0
	for g in gaps:
		mean += g
	mean /= gaps.size()
	print("SINKGAP t=%.2f cols=%d gap mean=%.2f p50=%.2f p90=%.2f max=%.1f >3px=%d >5px=%d quarters=%.2f/%.2f/%.2f/%.2f | empty 2px cells in water above bed=%d (within 8 px of bed)=%d" % [
			t, gaps.size(), mean, gaps[gaps.size() / 2], gaps[int(gaps.size() * 0.9)], gaps[gaps.size() - 1],
			over3, over5, q_sum[0] / maxi(q_n[0], 1), q_sum[1] / maxi(q_n[1], 1),
			q_sum[2] / maxi(q_n[2], 1), q_sum[3] / maxi(q_n[3], 1), air, air_near])
	sink_samples += 1
	if sink_samples % 10 != 0 or not b.has("hydro_p"):
		return
	var gw := ceili(SimParams.WORLD_SIZE.x / 16.0)
	var head := SimParams.GRAVITY * 16.0
	var line := ""
	for gx in gw:
		var ts := PackedFloat32Array()
		var ws := PackedFloat32Array()
		for c in range(gx * 8, mini(gx * 8 + 8, cols)):
			if tops[c] > 0.0:
				ts.append(tops[c])
				ws.append(surf[c])
		if ts.is_empty():
			line += " | ."
			continue
		ts.sort()
		ws.sort()
		var top: float = ts[ts.size() / 2]
		var wsurf: float = ws[ws.size() / 2]
		var gy := int(top / 16.0)
		var s := ""
		for dy in [1, 0]:
			var cy: int = gy - dy
			if cy < 0:
				continue
			var ci: int = cy * gw + gx
			var phi := Vector2(b.hydro_phi.decode_float(ci * 8), b.hydro_phi.decode_float(ci * 8 + 4))
			var p: float = b.hydro_p.decode_float(ci * 4) / head
			var hyd := ((cy + 0.5) * 16.0 - wsurf) / 16.0
			s += " %.3f+%.2f=%.3f p%+.2f" % [phi.x, phi.y, phi.x + 0.9 * phi.y, p - hyd]
		line += " | x%d top%d%s" % [gx * 16, roundi(top), s]
	print("SINKGRID t=%.2f (per 16 px column: bed top y; cell above then cell at the top: liquid+powder=fill, p minus hydrostatic in head)%s" % [t, line])


func _shaft_stats(b: Dictionary, t: float) -> void:
	var cells := {}
	for i in cap:
		var fl := int(b.mat_flags.decode_u32(i * 4))
		if (fl & 0x100) == 0 or (fl & 0xFF) != sand:
			continue
		cells[Vector2i(int(b.pos.decode_float(i * 8) / 2.0), int(b.pos.decode_float(i * 8 + 4) / 2.0))] = true
	var empty := 0
	for cy in range(130, 178):
		for cx in range(143, 180):
			if not cells.has(Vector2i(cx, cy)):
				empty += 1
	print("SHAFT t=%.2f empty_cells=%d of %d" % [t, empty, 48 * 37])


func _erase_stats(b: Dictionary, t: float) -> void:
	var cells := {}
	var ps := PackedVector2Array()
	var vs := PackedVector2Array()
	for i in cap:
		var fl := int(b.mat_flags.decode_u32(i * 4))
		if (fl & 0x100) == 0 or (fl & 0xFF) != sand:
			continue
		var p := Vector2(b.pos.decode_float(i * 8), b.pos.decode_float(i * 8 + 4))
		ps.append(p)
		vs.append(Vector2(b.vel.decode_float(i * 8), b.vel.decode_float(i * 8 + 4)))
		cells[Vector2i(int(p.x / 2.0), int(p.y / 2.0))] = true
	var unsupported := 0
	var stuck := 0
	var stuck_y := 0.0
	for i in ps.size():
		var p := ps[i]
		if p.y > SimParams.WORLD_SIZE.y - 4.0:
			continue
		var c := Vector2i(int(p.x / 2.0), int(p.y / 2.0))
		var below := false
		for dy in [1, 2]:
			for dx in [-1, 0, 1]:
				if cells.has(c + Vector2i(dx, dy)):
					below = true
		if below:
			continue
		unsupported += 1
		if vs[i].length() < SimParams.SLEEP_SPEED:
			stuck += 1
			stuck_y += p.y
	print("ERASE t=%.2f phase=%s grains=%d unsupported=%d stuck(still, nothing below)=%d stuck_mean_y=%.0f" % [
			t, "pile" if frame_i <= ERASE_PILE else ("erase" if frame_i <= ERASE_END else "after"),
			ps.size(), unsupported, stuck, stuck_y / maxi(stuck, 1)])


func _shot_rt(f: int) -> void:
	var data: PackedByteArray = ctx.rd.texture_get_data(ctx.texture("image"), 0)
	var size := Vector2i(SimParams.WORLD_SIZE)
	var img := Image.create_from_data(size.x, size.y, false, Image.FORMAT_RGBA8, data)
	var path := "user://feel_%s%s_%d.png" % [scenario, shot_tag, f]
	img.save_png(path)
	print("SHOT ", ProjectSettings.globalize_path(path))


func _request(f: int) -> void:
	for name in _readback_names():
		ctx.readback_async_rt(name, _on_data.bind(name, f))


func _readback_names() -> Array:
	if scenario in ["bowl", "sink", "sandpour", "soak"]:
		return ["pos", "vel", "mat_flags", "hydro_p", "hydro_phi"]
	return ["pos", "vel", "mat_flags"]


func _on_data(data: PackedByteArray, name: String, f: int) -> void:
	got[name] = data
	if got.size() == _readback_names().size():
		pending = false
		_analyse(got, f)


func _analyse(b: Dictionary, f: int) -> void:
	# Frame 1 spawns and steps once, so frame f has had f steps of gravity.
	var t := f * SimParams.DT
	if dump_at > 0 and f >= dump_at:
		dump_at = -1
		var file := FileAccess.open("user://feel_%s_%d.csv" % [scenario, f], FileAccess.WRITE)
		for i in cap:
			var fl := int(b.mat_flags.decode_u32(i * 4))
			if (fl & 0x100) != 0:
				file.store_line("%d,%.3f,%.3f,%.2f,%.2f" % [fl & 0xFF, b.pos.decode_float(i * 8), b.pos.decode_float(i * 8 + 4),
						b.vel.decode_float(i * 8), b.vel.decode_float(i * 8 + 4)])
		file.close()
		print("DUMP ", ProjectSettings.globalize_path("user://feel_%s_%d.csv" % [scenario, f]))
	if scenario == "sandair":
		_sandair(b, t)
		return
	if scenario == "hover":
		_hover(b, t)
		return
	if scenario == "layers":
		_layers(b, t)
		return
	if scenario == "erase":
		_erase_stats(b, t)
		return
	if scenario == "shaft":
		_shaft_stats(b, t)
		return
	if scenario == "sink" or scenario == "sandpour" or scenario == "soak":
		_sink_stats(b, t)
		_pocket_stats(b, t)
		_bowl_pressure(b, t)
		return
	if scenario == "bowl":
		_bowl_stats(b, t)
		_pocket_stats(b, t)
		return
	var xs := PackedFloat32Array()
	var n := 0
	var sum_y := 0.0
	var sum_vy := 0.0
	var sum_speed := 0.0
	var max_speed := 0.0
	var max_y := 0.0
	for i in cap:
		var fl := int(b.mat_flags.decode_u32(i * 4))
		if (fl & 0x100) == 0 or (fl & 0xFF) != water:
			continue
		var x: float = b.pos.decode_float(i * 8)
		var y: float = b.pos.decode_float(i * 8 + 4)
		var v := Vector2(b.vel.decode_float(i * 8), b.vel.decode_float(i * 8 + 4))
		n += 1
		xs.append(x)
		sum_y += y
		max_y = maxf(max_y, y)
		sum_vy += v.y
		sum_speed += v.length()
		max_speed = maxf(max_speed, v.length())
	if n == 0:
		return
	if scenario == "surface":
		_surface(b, t)
		return
	if scenario == "dam":
		xs.sort()
		var front := xs[int(0.995 * (xs.size() - 1))]
		var speed := (front - last_front) / maxf(t - last_front_t, 1e-6) if last_front_t > 0.0 else 0.0
		last_front = front
		last_front_t = t
		# Martin & Moyce (1952) scaling: Z = front / a, T = t sqrt(2 g / a), a = column width.
		var a := DAM_COLS * SimParams.SPACING
		var hgt := DAM_ROWS * SimParams.SPACING
		print("DAM t=%.3f T=%.2f front=%.1f Z=%.2f front_speed=%.0f (2sqrt(gH)=%.0f) mean_speed=%.1f max=%.0f n=%d" % [
				t, t * sqrt(2.0 * SimParams.GRAVITY / a), front, front / a, speed,
				2.0 * sqrt(SimParams.GRAVITY * hgt), sum_speed / n, max_speed, n])
	else:
		if landed:
			return
		var ideal_v := SimParams.GRAVITY * t
		var drop := sum_y / n - y0
		var ideal_drop := 0.5 * SimParams.GRAVITY * t * t
		print("FALL t=%.3f vy=%.1f ideal=%.1f (%.0f%%) drop=%.1f ideal=%.1f max_speed=%.0f" % [
				t, sum_vy / n, ideal_v, 100.0 * (sum_vy / n) / maxf(ideal_v, 1e-6), drop, ideal_drop, max_speed])
		if max_y >= SimParams.WORLD_SIZE.y - 3.0:
			landed = true
			print("FALL landed at t=%.3f (free fall from the same height: %.3f)" % [
					t, sqrt(2.0 * (SimParams.WORLD_SIZE.y - 1.0 - (8.0 + (FALL_COUNT / FALL_COLS - 1) * SimParams.SPACING)) / SimParams.GRAVITY)])


func _surface(b: Dictionary, t: float) -> void:
	var cols := int(SimParams.WORLD_SIZE.x / 4.0)
	var top := PackedFloat32Array()
	top.resize(cols)
	top.fill(1e9)
	for i in cap:
		var fl := int(b.mat_flags.decode_u32(i * 4))
		if (fl & 0x100) == 0 or (fl & 0xFF) != water:
			continue
		var c := clampi(int(b.pos.decode_float(i * 8) / 4.0), 0, cols - 1)
		top[c] = minf(top[c], b.pos.decode_float(i * 8 + 4))
	var n := 0
	var sum_vx := 0.0
	var max_vx := 0.0
	var sum_vy := 0.0
	var moving := 0
	var all_n := 0
	var all_sum := 0.0
	for i in cap:
		var fl := int(b.mat_flags.decode_u32(i * 4))
		if (fl & 0x100) == 0 or (fl & 0xFF) != water:
			continue
		var x: float = b.pos.decode_float(i * 8)
		var y: float = b.pos.decode_float(i * 8 + 4)
		var v := Vector2(b.vel.decode_float(i * 8), b.vel.decode_float(i * 8 + 4))
		all_n += 1
		all_sum += v.length()
		if y > top[clampi(int(x / 4.0), 0, cols - 1)] + 3.0:
			continue
		n += 1
		sum_vx += absf(v.x)
		sum_vy += absf(v.y)
		max_vx = maxf(max_vx, absf(v.x))
		if absf(v.x) > 2.0:
			moving += 1
	print("SURFACE t=%.1f top_layer=%d mean|vx|=%.2f max|vx|=%.1f mean|vy|=%.2f moving(|vx|>2)=%d  body_mean=%.2f" % [
			t, n, sum_vx / maxi(n, 1), max_vx, sum_vy / maxi(n, 1), moving, all_sum / maxi(all_n, 1)])


func _sandair(b: Dictionary, t: float) -> void:
	var n := 0
	var air := 0
	var air_vy := 0.0
	var slow := 0
	for i in cap:
		var fl := int(b.mat_flags.decode_u32(i * 4))
		if (fl & 0x100) == 0 or (fl & 0xFF) != sand:
			continue
		n += 1
		if b.pos.decode_float(i * 8 + 4) < 150.0:
			air += 1
			var vy: float = b.vel.decode_float(i * 8 + 4)
			air_vy += vy
			if vy < 0.5 * SimParams.GRAVITY * t:
				slow += 1
	print("SANDAIR t=%.2f grains=%d in_air=%d air_mean_vy=%.1f slow(vy<g*t/2)=%d" % [
			t, n, air, air_vy / maxi(air, 1), slow])


func _hover(b: Dictionary, t: float) -> void:
	var rows := int(SimParams.WORLD_SIZE.y / 2.0)
	var hist := PackedInt32Array()
	hist.resize(rows)
	for i in cap:
		var fl := int(b.mat_flags.decode_u32(i * 4))
		if (fl & 0x100) == 0 or (fl & 0xFF) != water:
			continue
		hist[clampi(int(b.pos.decode_float(i * 8 + 4) / 2.0), 0, rows - 1)] += 1
	var full := int(SimParams.WORLD_SIZE.x / SimParams.SPACING)
	var dense := rows - 1
	for r in rows:
		if hist[r] >= full / 2:
			dense = r
			break
	var line := dense * 2.0 - 4.0
	var n := 0
	var sum_vy := 0.0
	var sum_speed := 0.0
	var top := 1e9
	var near := PackedVector2Array()  # every particle that can neighbour a fringe one
	var fringe := PackedVector2Array()
	var fringe_v := PackedVector2Array()
	for i in cap:
		var fl := int(b.mat_flags.decode_u32(i * 4))
		if (fl & 0x100) == 0 or (fl & 0xFF) != water:
			continue
		var p := Vector2(b.pos.decode_float(i * 8), b.pos.decode_float(i * 8 + 4))
		if p.y < line + SimParams.H:
			near.append(p)
		if p.y >= line:
			continue
		var v := Vector2(b.vel.decode_float(i * 8), b.vel.decode_float(i * 8 + 4))
		n += 1
		sum_vy += v.y
		sum_speed += v.length()
		top = minf(top, p.y)
		fringe.append(p)
		fringe_v.append(v)
	# Loose: fewer than 3 neighbours within H, so nothing holds it up but the grid.
	var loose := 0
	var loose_vy := 0.0
	for f in fringe.size():
		var nb := 0
		for p in near:
			if p.distance_squared_to(fringe[f]) < SimParams.H * SimParams.H:
				nb += 1
		if nb - 1 < 3:
			loose += 1
			loose_vy += fringe_v[f].y
	print("HOVER t=%.2f dense_surface_y=%.0f fringe=%d fringe_height=%.1f mean_vy=%.2f mean_speed=%.2f loose=%d loose_vy=%.1f" % [
			t, dense * 2.0, n, dense * 2.0 - top if n > 0 else 0.0, sum_vy / maxi(n, 1), sum_speed / maxi(n, 1),
			loose, loose_vy / maxi(loose, 1)])
