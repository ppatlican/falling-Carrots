## Water feel probe: measures how fast water falls and spreads on the GPU sim, against the
## ideal, so "floaty" and "thick" become numbers. Needs a real window (no --headless).
## Run it in a copy of the repo, not the repo itself:
##   Godot_console.exe --path <copy> --script res://tools/water_feel_probe.gd -- <scenario> [frames] [every=N]
##   fall   a 40x40 px block of water dropped from the top: mean fall speed and drop
##          against free fall (v = g t), until it lands
##   dam    a 100 px wide, 240 px tall column of water released at the left wall: the
##          front's x and speed, then the mean speed while it sloshes and settles
##   pour   a 40 px deep pool, a brush pouring into it for 3 s, then a 4000-particle
##          block dropped into it (look at it with shots=)
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


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() >= 1:
		scenario = args[0]
	if args.size() >= 2 and args[1].is_valid_int():
		max_frames = int(args[1])
	for a in args:
		if a.begins_with("every="):
			sample_every = maxi(1, int(a.substr(6)))
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
		if scenario == "dam":
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
	sim.frame(brush, 0)
	if frame_i in shots:
		RenderingServer.call_on_render_thread(_shot_rt.bind(frame_i))
	if scenario != "pour" and frame_i % sample_every == 0 and not pending:
		pending = true
		got = {}
		RenderingServer.call_on_render_thread(_request.bind(frame_i))
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
