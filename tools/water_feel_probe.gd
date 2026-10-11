## Water feel probe: measures how fast water falls and spreads on the GPU sim, against the
## ideal, so "floaty" and "thick" become numbers. Needs a real window (no --headless).
## Run it in a copy of the repo, not the repo itself:
##   Godot_console.exe --path <copy> --script res://tools/water_feel_probe.gd -- <scenario> [frames] [every=N]
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
##   bowl   a sand floor and two sand columns at the walls that slump into slopes, then 3 x 9000
##          water 30 frames apart from BOWL_WATER (the owner's pool in a sand bowl): water speed
##          next to sand (a grain within 6 px) and away from it, and coherent flow, the length
##          of the mean water velocity per 20 px cell (jitter averages out, a current doesn't),
##          and water inside the sand bed (6 of the 9 2 px cells around it hold sand). nosand
##          drops the sand (control). cols=N rows=N size the sand columns (default 75x100,
##          which leaves a steep right mound; 110x60 slumps into gentle slopes). Every 10th
##          sample a flow map of the 20 px cells, and at the end the flow averaged from 30 s.
##   hover  the surface pool: water particles in the loose fringe above the dense surface
##          (the first 2 px row at least half full), and their mean vy (> 0 is falling)
## Every sample (every=N frames, default 3): one line per scenario, see _analyse.
##   shots=F1,F2,...  save the rendered frame at these frames as user://feel_<scenario>_<F>.png
extends SceneTree

const ComputeContext = preload("res://gpu/compute_context.gd")
const ParticleSim = preload("res://gpu/particle_sim.gd")
const GameConfig = preload("res://core/game_config.gd")
const MaterialTable = preload("res://cpu_ref/material_table.gd")
const SimParams = preload("res://core/sim_params.gd")

const FALL_COLS := 20
const FALL_COUNT := 400
const DAM_COLS := 50
const DAM_ROWS := 120

var scenario := "fall"
var max_frames := 600
var sample_every := 3
var ctx
var sim
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
var sand_r := 1.5
var sand_n := 2
var sand_frames := 20
var sand_moving := 1
var bowl_sand := true
var bowl_samples := 0
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
		if a == "nosand":
			bowl_sand = false
		if a.begins_with("move="):
			sand_moving = int(a.substr(5))
		if a.begins_with("shots="):
			for v in a.substr(6).split(","):
				shots.append(int(v))
	var config = GameConfig.load_from_file()
	cap = config.particle_cap
	var table = MaterialTable.new()
	var problems: PackedStringArray = table.load_file()
	if problems.size() > 0:
		print("MATERIAL PROBLEMS: ", problems)
	water = table.id_of("water")
	sand = table.id_of("sand")
	print("feel probe scenario=%s frames=%d g=%.0f dt=%.5f" % [scenario, max_frames, SimParams.GRAVITY, SimParams.DT])
	ctx = ComputeContext.new()
	sim = ParticleSim.new(ctx, cap, config.solver_iterations, table, config.substeps)
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
	if scenario == "bowl":
		brush = _bowl_brush()
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


const BOWL_WATER := 300
const BOWL_FLOOR_ROWS := 16
var bowl_col_cols := 75  # from "cols=N": width of each sand column, in particles
var bowl_col_rows := 100  # from "rows=N"; cols=110 rows=60 slumps into gentle slopes


func _bowl_brush() -> Dictionary:
	var brush := {"op": ParticleSim.BRUSH_NONE, "pos": Vector2.ZERO, "radius": 0.0,
			"material": sand, "count": 0, "cols": 1}
	var w := SimParams.WORLD_SIZE
	var floor_top := w.y - 1.0 - BOWL_FLOOR_ROWS * SimParams.SPACING
	var col_w := bowl_col_cols * SimParams.SPACING
	if frame_i <= 3 and not bowl_sand:
		return brush
	if frame_i == 1:
		brush.op = ParticleSim.BRUSH_BLOCK
		brush.cols = int(w.x / SimParams.SPACING) - 1
		brush.count = brush.cols * BOWL_FLOOR_ROWS
		brush.pos = Vector2(1.0, floor_top)
	elif frame_i == 2 or frame_i == 3:
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


func _bowl_stats(b: Dictionary, t: float) -> void:
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
	var path := "user://feel_%s_%d.png" % [scenario, f]
	img.save_png(path)
	print("SHOT ", ProjectSettings.globalize_path(path))


func _request(f: int) -> void:
	for name in ["pos", "vel", "mat_flags"]:
		ctx.readback_async_rt(name, _on_data.bind(name, f))


func _on_data(data: PackedByteArray, name: String, f: int) -> void:
	got[name] = data
	if got.size() == 3:
		pending = false
		_analyse(got, f)


func _analyse(b: Dictionary, f: int) -> void:
	# Frame 1 spawns and steps once, so frame f has had f steps of gravity.
	var t := f * SimParams.DT
	if scenario == "sandair":
		_sandair(b, t)
		return
	if scenario == "hover":
		_hover(b, t)
		return
	if scenario == "erase":
		_erase_stats(b, t)
		return
	if scenario == "shaft":
		_shaft_stats(b, t)
		return
	if scenario == "sink":
		_sink_stats(b, t)
		return
	if scenario == "bowl":
		_bowl_stats(b, t)
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
