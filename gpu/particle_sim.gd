## GPU particle simulation (spec 2.1, 2.2, 2.6 steps 1-5 and 8).
##
## A fixed pool of `cap` particles with a free-list, a spatial hash rebuilt every
## frame, PBF liquids and frictional powders, drawn as plain points into an
## art-resolution texture shown through `texture` (a Texture2DRD).
##
## Passes per frame, each timed separately in the debug overlay:
##   brush     add (spawn + finalize) or erase (erase + finalize)
##   predict   gravity, predicted positions
##   hash      clear, count, 3-step prefix sum, scatter (copies state into cell order)
##   solve     solver_iterations x (lambda, delta, apply)
##   velocity  update, XSPH, commit
##   render    clear image, draw points
##
## The live particle count comes back through a 16-byte async readback each frame
## (SPEC 2.7). It lags a frame or two. The GPU enforces the cap on its own.
##
## Main-thread methods: start(), frame(), request_clear(), request_check(), shutdown().
## Methods ending in _rt run on the render thread.
extends RefCounted

const ComputeContext = preload("res://gpu/compute_context.gd")
const SimParams = preload("res://core/sim_params.gd")
const ParticleStep = preload("res://cpu_ref/particle_step.gd")
const ParticlePool = preload("res://cpu_ref/particle_pool.gd")

const SHADER_DIR := "res://gpu/shaders/sim/"
const KERNELS := [
	"brush_spawn", "brush_erase", "brush_finalize", "predict",
	"hash_clear", "hash_count", "scan_local", "scan_blocks", "scan_add", "hash_scatter",
	"solve_lambda", "solve_delta", "solve_apply",
	"velocity_update", "velocity_xsph", "velocity_commit",
	"render_clear", "render_points",
]
## Must match Params in common.glslinc.
const PUSH_SIZE := 96
## Prefix sum: 256 elements per workgroup, at most 256 workgroups (one scan_blocks group).
const SCAN_BLOCK := 256
const MAX_SCAN_BLOCKS := 256
const SCAN_SHARED_BYTES := 64 * 4

## Brush operations (BRUSH_* in common.glslinc).
const BRUSH_NONE := 0
const BRUSH_CIRCLE := 1
const BRUSH_BLOCK := 2
const BRUSH_ERASE := 3

## view_flags bits (VIEW_* in common.glslinc).
const VIEW_HASH := 1

## Emitted on the main thread. error is "" on success.
signal setup_finished(error: String)
## Emitted on the main thread with the GPU self-check result.
signal check_finished(ok: bool, message: String)

## Assign to a Sprite2D. Valid after setup_finished("").
var texture := Texture2DRD.new()
## Live particles, from the latest counter readback.
var live_count := 0
var cap: int

var _ctx
var _iterations: int
var _material_bytes: PackedByteArray
var _grid: Vector2i
var _n_cells: int
var _rest_density: float
var _gpu_ready := false
var _frame := 0
var _counter_in_flight := false
var _clear_pending := false
var _check: Dictionary = {}


func _init(ctx, particle_cap: int, solver_iterations: int, material_table) -> void:
	_ctx = ctx
	cap = particle_cap
	_iterations = solver_iterations
	_material_bytes = material_table.pack_gpu()
	_grid = SimParams.grid_size()
	_n_cells = _grid.x * _grid.y
	_rest_density = ParticleStep.rest_density_for(SimParams.H, SimParams.SPACING)


## Loads shaders on the main thread, then schedules GPU setup. Returns "" or an error.
func start() -> String:
	if ceili(float(_n_cells + 1) / SCAN_BLOCK) > MAX_SCAN_BLOCKS:
		return "hash grid too large for the prefix sum: %d cells" % _n_cells
	var errors := PackedStringArray()
	var spirv := {}
	for k in KERNELS:
		spirv[k] = ComputeContext.load_spirv(SHADER_DIR + k + ".glsl", errors)
	if not errors.is_empty():
		return "\n".join(errors)
	RenderingServer.call_on_render_thread(_setup_rt.bind(spirv))
	return ""


func _setup_rt(spirv: Dictionary) -> void:
	var err: String = _ctx.check_limits_rt(ComputeContext.groups_for(cap), PUSH_SIZE, SCAN_SHARED_BYTES)
	for k in KERNELS:
		if err == "":
			err = _ctx.create_pipeline_rt(k, spirv[k])
	if err == "":
		err = _create_resources_rt()
	if err != "":
		_finish_setup.call_deferred(err, RID())
		return
	_build_passes_rt()
	_gpu_ready = true
	_finish_setup.call_deferred("", _ctx.texture("image"))


## Buffer list in binding order (see common.glslinc). [name, bytes, initial data]
func _buffer_specs() -> Array:
	var cells_bytes := (_n_cells + 1) * 4
	return [
		["pos", cap * 8, PackedByteArray()],
		["pred", cap * 8, PackedByteArray()],
		["vel", cap * 8, PackedByteArray()],
		["mat_flags", cap * 4, PackedByteArray()],
		["free_stack", cap * 4, ParticlePool.initial_stack(cap).to_byte_array()],
		["counters", 16, _initial_counters()],
		["cell_count", cells_bytes, PackedByteArray()],
		["cell_start", cells_bytes, PackedByteArray()],
		["block_sums", MAX_SCAN_BLOCKS * 4, PackedByteArray()],
		["particle_cell", cap * 4, PackedByteArray()],
		["particle_rank", cap * 4, PackedByteArray()],
		["sorted_ids", cap * 4, PackedByteArray()],
		["lambda", cap * 4, PackedByteArray()],
		["scratch", cap * 8, PackedByteArray()],
		["materials", _material_bytes.size(), _material_bytes],
		["s_pred", cap * 8, PackedByteArray()],
		["s_pos", cap * 8, PackedByteArray()],
		["s_vel", cap * 8, PackedByteArray()],
		["s_mat", cap * 4, PackedByteArray()],
	]


func _initial_counters() -> PackedByteArray:
	return PackedInt32Array([cap, 0, 0, 0]).to_byte_array()


func _create_resources_rt() -> String:
	var bindings := []
	var specs := _buffer_specs()
	for b in specs.size():
		var spec: Array = specs[b]
		var rid: RID = _ctx.create_buffer_rt(spec[0], spec[1], spec[2])
		if not rid.is_valid():
			return "could not create buffer '%s' (%d bytes)" % [spec[0], spec[1]]
		bindings.append([b, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, rid])
	var size := Vector2i(SimParams.WORLD_SIZE)
	var image: RID = _ctx.create_storage_texture_rt("image", size.x, size.y)
	if not image.is_valid():
		return "could not create the %dx%d render texture" % [size.x, size.y]
	bindings.append([specs.size(), RenderingDevice.UNIFORM_TYPE_IMAGE, image])  # binding 19, last
	# Every kernel gets the full set; unused bindings are ignored by the engine.
	for k in KERNELS:
		if not _ctx.create_uniform_set_rt(k, k, 0, bindings).is_valid():
			return "could not create the uniform set for '%s'" % k
	return ""


func _build_passes_rt() -> void:
	var all := ComputeContext.groups_for(cap)
	var cells := ComputeContext.groups_for(_n_cells + 1)
	var pixels := ComputeContext.groups_for(int(SimParams.WORLD_SIZE.x * SimParams.WORLD_SIZE.y))
	var d := func(k: String, groups: int) -> Array: return [k, k, groups]
	# Brush dispatch sizes are set per frame (0 = skipped).
	_ctx.add_pass("brush", [d.call("brush_spawn", 0), d.call("brush_erase", 0), d.call("brush_finalize", 0)])
	_ctx.add_pass("predict", [d.call("predict", all)])
	_ctx.add_pass("hash", [
		d.call("hash_clear", cells), d.call("hash_count", all),
		d.call("scan_local", ceili(float(_n_cells + 1) / SCAN_BLOCK)), d.call("scan_blocks", 1),
		d.call("scan_add", cells), d.call("hash_scatter", all),
	])
	var solve := []
	for _i in _iterations:
		solve.append_array([d.call("solve_lambda", all), d.call("solve_delta", all), d.call("solve_apply", all)])
	_ctx.add_pass("solve", solve)
	_ctx.add_pass("velocity", [d.call("velocity_update", all), d.call("velocity_xsph", all), d.call("velocity_commit", all)])
	_ctx.add_pass("render", [d.call("render_clear", pixels), d.call("render_points", all)])


func _finish_setup(err: String, image: RID) -> void:
	if err == "":
		texture.texture_rd_rid = image
	setup_finished.emit(err)


# --- Per frame --------------------------------------------------------------------

## Schedules one simulation frame. brush: { "op": BRUSH_*, "pos": Vector2,
## "radius": float, "material": int, "count": int, "cols": int }.
func frame(brush: Dictionary, view_flags: int) -> void:
	_frame += 1
	var clear := _clear_pending
	_clear_pending = false
	if clear:
		live_count = 0
	RenderingServer.call_on_render_thread(_frame_rt.bind(_push(brush, view_flags), int(brush.op), int(brush.count), clear))


## Empties the pool at the start of the next frame.
func request_clear() -> void:
	_clear_pending = true


func _frame_rt(push: PackedByteArray, op: int, count: int, clear: bool) -> void:
	if not _gpu_ready:
		return
	if clear:
		_ctx.update_buffer_rt("free_stack", 0, ParticlePool.initial_stack(cap).to_byte_array())
		_ctx.update_buffer_rt("counters", 0, _initial_counters())
		_ctx.rd.buffer_clear(_ctx.buffer("mat_flags"), 0, cap * 4)
	var spawning := op == BRUSH_CIRCLE or op == BRUSH_BLOCK
	_ctx.set_groups_rt("brush", 0, ComputeContext.groups_for(count) if spawning else 0)
	_ctx.set_groups_rt("brush", 1, ComputeContext.groups_for(cap) if op == BRUSH_ERASE else 0)
	_ctx.set_groups_rt("brush", 2, 1 if op != BRUSH_NONE else 0)
	_ctx.set_push_all_rt(push)
	_ctx.record_frame_rt()
	if not _counter_in_flight:
		_counter_in_flight = true
		_ctx.readback_async_rt("counters", _on_counters_rt)


func _on_counters_rt(data: PackedByteArray) -> void:
	_set_live_count.call_deferred(data.decode_u32(4) if data.size() >= 8 else -1)


func _set_live_count(count: int) -> void:
	_counter_in_flight = false
	if count >= 0 and not _clear_pending:
		live_count = count


## Push constants, same layout as Params in common.glslinc (96 bytes).
func _push(brush: Dictionary, view_flags: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(PUSH_SIZE)
	var pos: Vector2 = brush.get("pos", Vector2.ZERO)
	b.encode_float(0, pos.x)
	b.encode_float(4, pos.y)
	b.encode_float(8, brush.get("radius", SimParams.BRUSH_RADIUS))
	b.encode_u32(12, brush.get("count", 0))
	b.encode_u32(16, brush.get("op", BRUSH_NONE))
	b.encode_u32(20, brush.get("material", 0))
	b.encode_u32(24, maxi(1, brush.get("cols", 1)))
	b.encode_u32(28, cap)
	b.encode_float(32, SimParams.WORLD_SIZE.x)
	b.encode_float(36, SimParams.WORLD_SIZE.y)
	b.encode_u32(40, _grid.x)
	b.encode_u32(44, _grid.y)
	b.encode_float(48, SimParams.DT)
	b.encode_float(52, SimParams.GRAVITY)
	b.encode_float(56, SimParams.MAX_STEP)
	b.encode_float(60, _rest_density)
	b.encode_u32(64, _frame)
	b.encode_u32(68, view_flags)
	b.encode_float(72, SimParams.H)
	b.encode_float(76, SimParams.SPACING)
	b.encode_float(80, SimParams.LAMBDA_EPS)
	b.encode_float(84, SimParams.SCORR_K)
	b.encode_float(88, SimParams.CONTACT_RELAX)
	b.encode_u32(92, _n_cells)
	return b


# --- GPU self-check (debug readback) -------------------------------------------------

## Reads back the pool and hash once and checks they agree. Result via check_finished.
func request_check() -> void:
	if _check.is_empty():
		RenderingServer.call_on_render_thread(_check_rt)


const CHECK_BUFFERS := ["counters", "mat_flags", "cell_count", "cell_start", "sorted_ids"]


func _check_rt() -> void:
	_check = {}
	for name in CHECK_BUFFERS:
		var err: Error = _ctx.readback_async_rt(name, _on_check_data_rt.bind(name))
		if err != OK:
			_check = {}
			check_finished.emit.call_deferred(false, "readback of %s failed: %s" % [name, error_string(err)])
			return


func _on_check_data_rt(data: PackedByteArray, name: String) -> void:
	_check[name] = data
	if _check.size() == CHECK_BUFFERS.size():
		var buffers := _check
		_check = {}
		_verify.call_deferred(buffers)


func _verify(b: Dictionary) -> void:
	var problems := PackedStringArray()
	var free_count: int = b.counters.decode_u32(0)
	var live: int = b.counters.decode_u32(4)
	if free_count + live != cap:
		problems.append("free %d + live %d != cap %d" % [free_count, live, cap])
	var alive := PackedByteArray()
	alive.resize(cap)
	var n_alive := 0
	for i in cap:
		if b.mat_flags.decode_u32(i * 4) & 0x100:
			alive[i] = 1
			n_alive += 1
	if n_alive != live:
		problems.append("%d alive flags, live count %d" % [n_alive, live])
	var total := 0
	var max_cell := 0
	var max_cell_index := 0
	for c in _n_cells:
		var count: int = b.cell_count.decode_u32(c * 4)
		total += count
		if count > max_cell:
			max_cell = count
			max_cell_index = c
		if b.cell_start.decode_u32((c + 1) * 4) - b.cell_start.decode_u32(c * 4) != count:
			problems.append("prefix sum wrong at cell %d" % c)
			break
	if total != live or b.cell_start.decode_u32(_n_cells * 4) != live:
		problems.append("hash holds %d particles (end %d), live %d" % [total, b.cell_start.decode_u32(_n_cells * 4), live])
	var seen := PackedByteArray()
	seen.resize(cap)
	for t in mini(live, cap):
		var i: int = b.sorted_ids.decode_u32(t * 4)
		if i >= cap or alive[i] == 0 or seen[i] == 1:
			problems.append("sorted list entry %d is %d (dead, duplicate or out of range)" % [t, i])
			break
		seen[i] = 1
	if problems.is_empty():
		# Rest packing is about (H / SPACING)^2 = 4 per cell; much more means crowding.
		check_finished.emit(true, "GPU check OK: %d live, hash and free-list consistent, fullest cell %d (cell x %d, y %d)"
				% [live, max_cell, max_cell_index % _grid.x, max_cell_index / _grid.x])
	else:
		check_finished.emit(false, "GPU check FAILED: " + "; ".join(problems))


## Frees GPU resources. Call from the owner's _exit_tree.
func shutdown() -> void:
	_gpu_ready = false
	texture.texture_rd_rid = RID()
	RenderingServer.call_on_render_thread(_ctx.free_all_rt)
