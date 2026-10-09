## GPU probe: fills the GPU sim with block fills, steps it and prints settling metrics.
## Needs a real window (no --headless). Run it in a copy of the repo, not the repo itself:
##   Godot_console.exe --path <copy> --script res://tools/gpu_probe.gd -- <mat>[,<mat>] <frames> [blocks] [spawn_y] [top]
##   mat      material name; "water,sand" drops one block of each, 240 frames apart
##   blocks   10k block fills (default 5); by default all at y=8 in consecutive frames
##   spawn_y  above 8: stack the blocks upward from this y (279 = 10k at rest on the floor)
##   top      list the highest particles instead of the fastest risers
## Every sample (60 frames): speed, wall and RMS-drift stats per material. Every 5th sample:
## a grid of 20 px cells (S speed, V mean vy, N count, M count of the last material) and
## the 12 fastest-rising (or highest) particles with their neighbourhood.
extends SceneTree

const ComputeContext = preload("res://gpu/compute_context.gd")
const ParticleSim = preload("res://gpu/particle_sim.gd")
const GameConfig = preload("res://core/game_config.gd")
const MaterialTable = preload("res://cpu_ref/material_table.gd")
const SimParams = preload("res://core/sim_params.gd")

const SAMPLE_EVERY := 60
const WALL_BAND := 8.0

var ctx
var sim
var table
var mat_id := -1
var fill_name := "sand"
var max_frames := 1500
var blocks := 5
var spawn_y := 8.0
var seq: Array = []
var frame_i := 0
var ready := false
var pending := false
var got := {}
var prev_vy := {}
var prev_pos := {}
var cap := 50000
var ground_y := 0.0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() >= 1:
		fill_name = args[0]
	if args.size() >= 2:
		max_frames = int(args[1])
	if args.size() >= 3:
		blocks = int(args[2])
	if args.size() >= 4:
		spawn_y = float(args[3])
	var config = GameConfig.load_from_file()
	cap = config.particle_cap
	table = MaterialTable.new()
	var problems: PackedStringArray = table.load_file()
	if problems.size() > 0:
		print("MATERIAL PROBLEMS: ", problems)
	for nm in fill_name.split(","):
		seq.append(table.id_of(nm))
	mat_id = seq[seq.size() - 1]
	print("probe fill=%s mat=%d cap=%d frames=%d" % [fill_name, mat_id, cap, max_frames])
	ctx = ComputeContext.new()
	sim = ParticleSim.new(ctx, cap, config.solver_iterations, table)
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
	print("setup ok")


func _process(_delta: float) -> bool:
	if not ready:
		return false
	frame_i += 1
	var brush := {"op": ParticleSim.BRUSH_NONE, "pos": Vector2.ZERO, "radius": 0.0,
			"material": mat_id, "count": 0, "cols": 1}
	var mixed := seq.size() > 1
	var k_block := (frame_i - 1) / 240 if mixed else frame_i - 1
	if mixed:
		brush.material = seq[mini(k_block, seq.size() - 1)]
	if (mixed and (frame_i - 1) % 240 == 0 and k_block < blocks) or (not mixed and frame_i <= blocks):
		var cols := SimParams.BENCH_COLS
		brush.op = ParticleSim.BRUSH_BLOCK
		brush.count = SimParams.BENCH_BLOCK
		brush.cols = cols
		brush.pos = Vector2((SimParams.WORLD_SIZE.x - cols * SimParams.SPACING) * 0.5, spawn_y - (80.0 * (frame_i - 1) if spawn_y > 8.0 else 0.0))
	sim.frame(brush, 0)
	if frame_i % SAMPLE_EVERY == 0 and not pending:
		pending = true
		got = {}
		RenderingServer.call_on_render_thread(_request)
	if frame_i >= max_frames:
		print("done after %d frames, live %d" % [frame_i, sim.live_count])
		sim.shutdown()
		quit(0)
	return false


func _request() -> void:
	for name in ["pos", "vel", "mat_flags"]:
		ctx.readback_async_rt(name, _on_data.bind(name))


func _on_data(data: PackedByteArray, name: String) -> void:
	got[name] = data
	if got.size() == 3:
		pending = false
		_analyse(got)


func _analyse(b: Dictionary) -> void:
	var n := cap
	var sum_speed := {}
	var stats := {}
	for m in seq:
		stats[m] = {"n": 0, "max_speed": 0.0, "sum_speed": 0.0, "moving": 0, "top_y": 1e9,
				"wall_up": 0.0, "wall_n": 0, "rev": 0, "sum_vy": 0.0, "max_up": 0.0, "bottom_moving": 0, "bottom_vertical": 0}
	var alive := 0
	var sum_d2 := 0.0
	var cnt_d := 0
	var sum_cy := 0.0
	ground_y = 0.0
	for i in n:
		if (int(b.mat_flags.decode_u32(i * 4)) & 0x100) != 0:
			ground_y = maxf(ground_y, b.pos.decode_float(i * 8 + 4))
	for i in n:
		var f := int(b.mat_flags.decode_u32(i * 4))
		if (f & 0x100) == 0:
			continue
		alive += 1
		var m := f & 0xFF
		if not stats.has(m):
			continue
		var s = stats[m]
		var x: float = b.pos.decode_float(i * 8)
		var y: float = b.pos.decode_float(i * 8 + 4)
		var vx: float = b.vel.decode_float(i * 8)
		var vy: float = b.vel.decode_float(i * 8 + 4)
		var sp := Vector2(vx, vy).length()
		s.n += 1
		s.sum_speed += sp
		s.sum_vy += vy
		if sp > s.max_speed:
			s.max_speed = sp
		if sp > 3.0:
			s.moving += 1
			if y > ground_y - 40.0:
				s.bottom_moving += 1
			if y > ground_y - 40.0 and sp > 3.0 and absf(vx) < 1.0:
				s.bottom_vertical += 1
		if y < s.top_y:
			s.top_y = y
		if vy < s.max_up:
			s.max_up = vy
		if x < WALL_BAND or x > SimParams.WORLD_SIZE.x - WALL_BAND:
			s.wall_n += 1
			if vy < s.wall_up:
				s.wall_up = vy
		# reversal: vertical velocity sign flip against the last sample for the same particle
		if prev_vy.has(i):
			var pv: float = prev_vy[i]
			if absf(pv) > 3.0 and absf(vy) > 3.0 and signf(pv) != signf(vy):
				s.rev += 1
		prev_vy[i] = vy
		var cur := Vector2(x, y)
		if prev_pos.has(i):
			var d: Vector2 = cur - prev_pos[i]
			sum_d2 += d.length_squared()
			cnt_d += 1
		prev_pos[i] = cur
		sum_cy += y
	for m in seq:
		var sm = stats[m]
		if sm.n > 0:
			print("  mat%d n=%d mean_speed=%.2f max_speed=%.2f mean_vy=%.2f max_up=%.2f wall_up=%.2f" % [m, sm.n, sm.sum_speed / sm.n, sm.max_speed, sm.sum_vy / sm.n, sm.max_up, sm.wall_up])
	var s = stats[mat_id]
	if frame_i % 300 == 1:
		_grid_dump(b)
		_fast_dump(b)
	print("  rms_disp_per_sample=%.3f px  centroid_y=%.2f" % [sqrt(sum_d2 / maxf(cnt_d, 1)), sum_cy / maxf(s.n, 1)])
	var mean_speed: float = s.sum_speed / maxf(s.n, 1)
	print("f=%5d alive=%5d mat_n=%5d mean_speed=%7.2f max_speed=%8.2f moving(>3)=%5d bottom_moving=%5d rev=%5d top_y=%7.2f mean_vy=%7.3f wall_n=%4d wall_max_up_vy=%8.2f max_up_vy=%8.2f" % [
			frame_i, alive, s.n, mean_speed, s.max_speed, s.moving, s.bottom_moving, s.rev,
			s.top_y if s.n > 0 else -1.0, s.sum_vy / maxf(s.n, 1), s.wall_n, s.wall_up, s.max_up])


func _grid_dump(b: Dictionary) -> void:
	var gw := 32
	var gh := 18
	var cs := 20.0
	var sp := PackedFloat32Array(); sp.resize(gw * gh)
	var vy := PackedFloat32Array(); vy.resize(gw * gh)
	var nn := PackedInt32Array(); nn.resize(gw * gh)
	var ns := PackedInt32Array(); ns.resize(gw * gh)
	for i in cap:
		if (int(b.mat_flags.decode_u32(i * 4)) & 0x100) == 0:
			continue
		var x: float = b.pos.decode_float(i * 8)
		var y: float = b.pos.decode_float(i * 8 + 4)
		var v := Vector2(b.vel.decode_float(i * 8), b.vel.decode_float(i * 8 + 4))
		var c := clampi(int(y / cs), 0, gh - 1) * gw + clampi(int(x / cs), 0, gw - 1)
		sp[c] += v.length(); vy[c] += v.y; nn[c] += 1
		if (int(b.mat_flags.decode_u32(i * 4)) & 0xFF) == mat_id: ns[c] += 1
	print("GRID speed (count density per 20px cell; rest ~100)  f=%d" % frame_i)
	for r in gh:
		var l1 := ""; var l2 := ""; var l3 := ""; var l4 := ""
		for c in gw:
			var k := r * gw + c
			if nn[k] == 0:
				l1 += "    ."; l2 += "    ."; l3 += "    ."; l4 += "    ."
			else:
				l1 += "%5d" % int(sp[k] / nn[k]); l2 += "%5d" % int(vy[k] / nn[k]); l3 += "%5d" % nn[k]; l4 += "%5d" % ns[k]
		print("S y%3d %s" % [r * 20, l1])
		print("V y%3d %s" % [r * 20, l2])
		print("N y%3d %s" % [r * 20, l3])
		print("M y%3d %s" % [r * 20, l4])


func _fast_dump(b: Dictionary) -> void:
	var ps := PackedVector2Array(); var vs := PackedVector2Array()
	for i in cap:
		if (int(b.mat_flags.decode_u32(i * 4)) & 0x100) == 0:
			continue
		ps.append(Vector2(b.pos.decode_float(i * 8), b.pos.decode_float(i * 8 + 4)))
		vs.append(Vector2(b.vel.decode_float(i * 8), b.vel.decode_float(i * 8 + 4)))
	var cells := {}
	for i in ps.size():
		var c := Vector2i((ps[i] / 4.0).floor())
		if not cells.has(c): cells[c] = PackedInt32Array()
		cells[c].append(i)
	var order := range(ps.size())
	if OS.get_cmdline_user_args().has("top"):
		order.sort_custom(func(a, c): return ps[a].y < ps[c].y)
	else:
		order.sort_custom(func(a, c): return vs[a].y < vs[c].y)
	print("FAST upward particles f=%d" % frame_i)
	for n in 12:
		var i: int = order[n]
		var c := Vector2i((ps[i] / 4.0).floor())
		var below := 0; var nb := 0; var mind := 99.0; var dens := 0.0; var up := 0; var nbv := Vector2.ZERO
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				for j in cells.get(c + Vector2i(dx, dy), PackedInt32Array()):
					if j == i: continue
					var d := ps[i].distance_to(ps[j])
					if d < 4.0:
						nb += 1; mind = minf(mind, d); nbv += vs[j]
						dens += pow(16.0 - d * d, 3) * 4.0 / (PI * 65536.0)
						if ps[j].y < ps[i].y: up += 1
						if ps[j].y > ps[i].y + 0.5: below += 1
		print("  p=(%.1f,%.1f) v=(%.0f,%.0f) nb=%d below=%d above=%d mind=%.2f rho/rho0=%.2f nb_mean_v=(%.0f,%.0f)" % [ps[i].x, ps[i].y, vs[i].x, vs[i].y, nb, below, up, mind, (dens + 0.0796) / 0.2537, (nbv / maxf(nb, 1)).x, (nbv / maxf(nb, 1)).y])
