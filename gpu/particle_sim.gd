## GPU particle simulation (spec 2.1, 2.2, 2.6 steps 1-5 and 8).
##
## A fixed pool of `cap` particles with a free-list, a spatial hash rebuilt every
## frame, PBF liquids, frictional powders and cluster solids (rigid and soft bodies by
## shape matching, docs/adr/0002-cluster-solid-layout.md), drawn as plain points into an
## art-resolution texture shown through `texture` (a Texture2DRD).
##
## Passes per frame, each timed separately in the debug overlay. predict to velocity run
## once per substep, with dt = SimParams.DT / substeps (times summed over substeps):
##   brush     a planned body split (body_split, ADR 0004), then add (spawn + finalize),
##             erase (erase + finalize) or one body (make_body)
##   predict   gravity, predicted positions
##   hash      clear, count, 3-step prefix sum, scatter (copies state into cell order)
##   hydro     liquid density projection grid (splat, density, then all SOR sweeps in one
##             128-thread workgroup, hydro_solve)
##   solve     bodies' swept contacts (body_sweep), grid pressure push (pressure, the bodies
##             pass's projection and move back out of other bodies, apply), then
##             solver_iterations x (lambda, delta, apply, then the bodies pass)
##   bodies    one 128-thread workgroup per body id: a soft body's pressure pushes projected
##             onto its rigid motion and every body moved back out of the bodies it went into
##             this substep (body_project) between pressure and its apply, and shape
##             matching (body_match) after each iteration's apply; its own passes so their
##             time shows separately
##   regions   soft bodies bend (ADR 0005): after each body pass, every member of a soft body
##             fits its region (body_region_fit) and moves toward its regions' goals
##             (body_region_goal), one thread per particle; skipped while no soft body exists
##   velocity  update, XSPH, commit
##   render    clear image, draw liquid points, then powder points on top
##
## The live particle count comes back through a 16-byte async readback each frame
## (SPEC 2.7). It lags a frame or two. The GPU enforces the cap on its own.
##
## Main-thread methods: start(), frame(), make_body(), request_clear(), request_check(), shutdown().
## Methods ending in _rt run on the render thread.
extends RefCounted

const ComputeContext = preload("res://gpu/compute_context.gd")
const SimParams = preload("res://core/sim_params.gd")
const ParticleStep = preload("res://cpu_ref/particle_step.gd")
const ParticlePool = preload("res://cpu_ref/particle_pool.gd")
const MaterialTable = preload("res://cpu_ref/material_table.gd")

const SHADER_DIR := "res://gpu/shaders/sim/"
const KERNELS := [
	"body_split", "brush_spawn", "brush_erase", "brush_finalize", "predict",
	"hash_clear", "hash_count", "scan_local", "scan_blocks", "scan_add", "hash_scatter",
	"hydro_splat", "hydro_phi", "hydro_solve", "body_sweep", "solve_pressure", "solve_lambda", "solve_delta", "solve_apply",
	"body_project", "body_match", "body_region_fit", "body_region_goal",
	"velocity_update", "velocity_xsph", "velocity_commit",
	"render_clear", "render_points", "render_gap", "render_powder",
]
## Must match Params in common.glslinc.
const PUSH_SIZE := 128
## Prefix sum: 256 elements per workgroup, at most 256 workgroups (one scan_blocks group).
const SCAN_BLOCK := 256
const MAX_SCAN_BLOCKS := 256
const SCAN_SHARED_BYTES := 64 * 4
## hydro_solve: threads in its one workgroup, and the most coarse cells it holds in shared
## memory (phi vec2, p and rho floats each, plus three bits). Mirror: LOCAL_SIZE_X in
## hydro_solve.glsl, HYDRO_MAX_CELLS in hydro.glslinc.
const HYDRO_SOLVE_THREADS := 128
## body_project, body_match: threads in each body's workgroup. Mirror: LOCAL_SIZE_X in both.
const BODY_THREADS := 128
const HYDRO_MAX_CELLS := 960
const HYDRO_SHARED_BYTES := HYDRO_MAX_CELLS * 16 + HYDRO_MAX_CELLS * 3 / 8

## Brush operations (BRUSH_* in common.glslinc).
const BRUSH_NONE := 0
const BRUSH_CIRCLE := 1
const BRUSH_BLOCK := 2
const BRUSH_ERASE := 3
const BRUSH_BODY := 4
## Bytes per body record (Body in common.glslinc), and the offset of its live count.
const BODY_BYTES := 48
const BODY_LIVE_OFFSET := 8
## Offset of a body record's flags (info.w), and its stale-outline flag (BODY_STALE).
const BODY_FLAGS_OFFSET := 12
const BODY_STALE := 1
## "made" of a body that hasn't spawned yet.
const NOT_MADE := 1 << 62
## body_split entry flag: the first entry of a piece, which writes its record. Mirror:
## SPLIT_FIRST in body_split.glsl.
const SPLIT_FIRST := 1

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
## Highest body id (config.json body_cap); records are 1..body_cap.
var body_cap: int
## Bodies in use (made and not yet found empty).
var body_count := 0

var _ctx
var _iterations: int
var _substeps: int
var _material_bytes: PackedByteArray
var _grid: Vector2i
var _n_cells: int
var _rest_density: float
var _gpu_ready := false
var _frame := 0
var _counter_in_flight := false
var _clear_pending := false
var _check: Dictionary = {}
## Bodies as the CPU hands them out (ADR 0002): index = body id, 0 unused. Each
## { "first", "count" (0 = free id), "made" (frame it spawned, NOT_MADE until then),
## "rest" (rest offset of each member of the range, for splitting it, ADR 0004), "material" (the
## regions pass runs while a body of a soft material exists, ADR 0005) }.
## ParticleStep._first_fit allocates member ranges from these, as in the CPU reference.
var _bodies: Array = []
## Material ids whose stiffness is under 1 (soft bodies, ADR 0005). The parameter panel can move
## a material across 1 while its bodies exist (update_material, ADR 0007).
var _soft_materials := {}
## Materials with cohesion or adhesion (ADR 0011): while any is, Params.sticky is 1 and
## velocity_xsph runs the stickiness loop (stick.glslinc); otherwise it costs nothing.
var _sticky_materials := {}
## Bodies waiting to spawn, one per frame: { "id", "material", "spawn" (bytes), "mean", "count" }.
var _pending_bodies: Array = []
## Ids found empty, whose GPU records are zeroed next frame.
var _freed_ids := PackedInt32Array()
var _body_check_wanted := false
var _body_check_in_flight := false
## Splitting bodies the eraser cut (ADR 0004): the body records read back after an erase show
## which bodies lost members (BODY_STALE); their member ranges and every slot's flags are read
## back next (_split_ids, in flight until _split_data has both), then the split is planned
## (plan_split) and waits in _pending_split until a frame with no body spawn sends it.
var _split_ids := PackedInt32Array()
var _split_in_flight := false
var _split_data := {}
## { "entries" (bytes for body_spawn), "count", "new_ids", "read_frame" }, or empty.
var _pending_split := {}
## Last frame the eraser ran, and how often bodies were forgotten (request_clear), so a
## readback from before a clear is dropped.
var _last_erase_frame := -1
var _clears := 0


func _init(ctx, particle_cap: int, solver_iterations: int, material_table, substeps := 1, max_bodies := 256) -> void:
	_ctx = ctx
	cap = particle_cap
	body_cap = max_bodies
	_reset_bodies()
	_iterations = solver_iterations
	_substeps = maxi(1, substeps)
	_material_bytes = material_table.pack_gpu()
	for id in material_table.materials:
		if float(material_table.materials[id].stiffness) < 1.0:
			_soft_materials[id] = true
		_note_sticky(material_table, id)
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
		return ComputeContext.join_errors(errors)
	RenderingServer.call_on_render_thread(_setup_rt.bind(spirv))
	return ""


func _setup_rt(spirv: Dictionary) -> void:
	var err: String = _ctx.check_limits_rt(ComputeContext.groups_for(cap), PUSH_SIZE,
			maxi(SCAN_SHARED_BYTES, HYDRO_SHARED_BYTES), maxi(HYDRO_SOLVE_THREADS, BODY_THREADS))
	if err == "" and _hydro_cells() > HYDRO_MAX_CELLS:
		err = "density projection grid has %d cells, hydro_solve holds at most %d" % [_hydro_cells(), HYDRO_MAX_CELLS]
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


## Cluster solid buffers, bindings 23 to 28 (common.glslinc). [binding, name, bytes]
func _body_buffer_specs() -> Array:
	return [
		[23, "rest_offset", cap * 16],
		[24, "body_members", cap * 4],
		[25, "bodies", (body_cap + 1) * BODY_BYTES],
		[26, "body_spawn", cap * 32],
		[27, "region_frame", cap * 16],
		[28, "body_push", cap * 8],
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
	bindings.append([specs.size(), RenderingDevice.UNIFORM_TYPE_IMAGE, image])  # binding 19
	# Liquid density projection grid (hydro.glslinc), bindings 20 to 22 and 29.
	# [binding, name, bytes per cell]: phi and acc hold liquid, powder, body volume and weight;
	# acc also the liquid's mass over water's; hydro_rho holds each cell's liquid density (ADR 0010).
	for spec in [[20, "hydro_phi", 16], [21, "hydro_p", 4], [22, "hydro_acc", 20], [29, "hydro_rho", 4]]:
		var hydro_bytes: int = _hydro_cells() * spec[2]
		var hrid: RID = _ctx.create_buffer_rt(spec[1], hydro_bytes, PackedByteArray())
		if not hrid.is_valid():
			return "could not create buffer '%s' (%d bytes)" % [spec[1], hydro_bytes]
		bindings.append([spec[0], RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, hrid])
	for spec in _body_buffer_specs():
		var brid: RID = _ctx.create_buffer_rt(spec[1], spec[2], PackedByteArray())
		if not brid.is_valid():
			return "could not create buffer '%s' (%d bytes)" % [spec[1], spec[2]]
		bindings.append([spec[0], RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, brid])
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
	_ctx.add_pass("brush", [d.call("body_split", 0), d.call("brush_spawn", 0), d.call("brush_erase", 0),
			d.call("brush_finalize", 0)])
	var hydro := ComputeContext.groups_for(_hydro_cells())
	var hydro_pass := [d.call("hydro_splat", all), d.call("hydro_phi", hydro), d.call("hydro_solve", 1)]
	for _s in _substeps:
		_ctx.add_pass("predict", [d.call("predict", all)])
		_ctx.add_pass("hash", [
			d.call("hash_clear", cells), d.call("hash_count", all),
			d.call("scan_local", ceili(float(_n_cells + 1) / SCAN_BLOCK)), d.call("scan_blocks", 1),
			d.call("scan_add", cells), d.call("hash_scatter", all),
		])
		_ctx.add_pass("hydro", hydro_pass)
		# Bodies' swept contacts, a soft body's pressure pushes made rigid and every body moved back
		# out of the bodies it went into before they're applied, then shape matching after every
		# iteration's apply. Workgroups (one per body id) are set per frame.
		_ctx.add_pass("solve", [d.call("body_sweep", all), d.call("solve_pressure", all)])
		_ctx.add_pass("bodies", [d.call("body_project", 0)])
		var solve := [d.call("solve_apply", all)]
		for _i in _iterations:
			solve.append_array([d.call("solve_lambda", all), d.call("solve_delta", all), d.call("solve_apply", all)])
			_ctx.add_pass("solve", solve)
			_ctx.add_pass("bodies", [d.call("body_match", 0)])
			_ctx.add_pass("regions", [d.call("body_region_fit", 0), d.call("body_region_goal", 0)])
			solve = []
		_ctx.add_pass("velocity", [d.call("velocity_update", all), d.call("velocity_xsph", all), d.call("velocity_commit", all)])
	_ctx.add_pass("render", [d.call("render_clear", pixels), d.call("render_points", all), d.call("render_gap", all),
			d.call("render_powder", all)])


## Coarse cells of the density projection grid (hydro_size() in hydro.glslinc).
func _hydro_cells() -> int:
	var c := SimParams.HYDRO_CELL
	return ((_grid.x + c - 1) / c) * ((_grid.y + c - 1) / c)


func _finish_setup(err: String, image: RID) -> void:
	if err == "":
		texture.texture_rd_rid = image
	setup_finished.emit(err)


# --- Per frame --------------------------------------------------------------------

## Schedules one simulation frame. brush: { "op": BRUSH_*, "pos": Vector2,
## "radius": float, "material": int, "count": int, "cols": int }. A body waiting from
## make_body() spawns instead of the brush this frame (one body per frame).
func frame(brush: Dictionary, view_flags: int) -> void:
	_frame += 1
	var clear := _clear_pending
	_clear_pending = false
	if clear:
		live_count = 0
	var spawn := PackedByteArray()
	var split_count := 0
	if not clear and not _pending_bodies.is_empty():
		var b: Dictionary = _pending_bodies.pop_front()
		_bodies[b.id].made = _frame
		spawn = b.spawn
		brush = {"op": BRUSH_BODY, "pos": b.mean, "material": b.material | (b.id << 16), "count": b.count,
				"body_first": _bodies[b.id].first}
	elif not clear and not _pending_split.is_empty():
		# A split shares body_spawn with a body spawn, so it waits for a frame without one. The
		# eraser runs after it in this frame and marks what it cuts again itself.
		spawn = _pending_split.entries
		split_count = _pending_split.count
		spawn.encode_u32(0, split_count)
		spawn.encode_u32(4, 1 if _last_erase_frame > _pending_split.read_frame else 0)
		for id in _pending_split.new_ids:
			_bodies[id].made = _frame
		_pending_split = {}
		# Check again: bodies the eraser cut meanwhile are split next, empty ones freed.
		_body_check_wanted = true
	# Erasing is the only way a body loses members: read the records back afterwards to free
	# the ids and member ranges of bodies erased completely and split the ones left in pieces.
	if brush.op == BRUSH_ERASE:
		_last_erase_frame = _frame
		if body_count > 0:
			_body_check_wanted = true
	var check_bytes := 0
	if _body_check_wanted and not _body_check_in_flight and not _split_in_flight and _split_ids.is_empty():
		_body_check_wanted = false
		_body_check_in_flight = true
		check_bytes = (_body_max_id() + 1) * BODY_BYTES
	# The members of the bodies to split, once no planned split is waiting to be sent.
	var split_range := Vector2i.ZERO
	if not _split_ids.is_empty() and not _split_in_flight and _pending_split.is_empty() and not clear:
		var ids := PackedInt32Array()
		split_range = Vector2i(cap, 0)
		for id in _split_ids:
			if _bodies[id].count > 0:
				ids.append(id)
				split_range = Vector2i(mini(split_range.x, _bodies[id].first), maxi(split_range.y, _bodies[id].first + _bodies[id].count))
		_split_ids = PackedInt32Array()
		if not ids.is_empty():
			_split_in_flight = true
			_split_data = {"ids": ids, "first": split_range.x, "frame": _frame, "clears": _clears}
	var freed := _freed_ids
	_freed_ids = PackedInt32Array()
	RenderingServer.call_on_render_thread(_frame_rt.bind(_push(brush, view_flags), int(brush.op), int(brush.count),
			float(brush.get("radius", SimParams.BRUSH_RADIUS)), clear, spawn, split_count, freed, _body_max_id(),
			check_bytes, split_range, _frame, _any_soft()))


## Empties the pool at the start of the next frame. Bodies are forgotten now, so bodies
## made after this call spawn after the clear.
func request_clear() -> void:
	_clear_pending = true
	_clears += 1
	_reset_bodies()


## Makes one body (a rigid or soft body, by the material's stiffness) from spawned
## positions, as cpu_ref/particle_step.gd make_body does: the lowest free body id, a member
## range by first fit, rest offsets from the positions relative to their mean, and each
## member's way out of the rest shape (ParticleStep.rest_outline, ADR 0003). It spawns
## with the next frame() that has no other body waiting. material should be a cluster
## material. Returns the body id, or 0 when no id, member range or pool room is free (as
## the brush stops when the pool is full). rest_shape (same size as positions, optional)
## gives the rest offsets instead, for a body spawned deformed (the probes' squashed jelly).
## velocity (optional) is every member's speed at the spawn (the probes' sideways collision).
func make_body(positions: PackedVector2Array, material: int, rest_shape := PackedVector2Array(),
		velocity := Vector2.ZERO) -> int:
	var count := positions.size()
	if rest_shape.is_empty():
		rest_shape = positions
	if rest_shape.size() != count:
		return 0
	var waiting := 0
	for b in _pending_bodies:
		waiting += b.count
	if count == 0 or count > cap - live_count - waiting:
		return 0
	var id := 1
	while id < _bodies.size() and _bodies[id].count > 0:
		id += 1
	if id > body_cap:
		return 0
	var first: int = ParticleStep._first_fit(_bodies, count)
	if first + count > cap:
		return 0
	if id == _bodies.size():
		_bodies.append({})
	_bodies[id] = {"first": first, "count": count, "made": NOT_MADE, "material": material}
	var mean := Vector2.ZERO
	var rest_mean := Vector2.ZERO
	for k in count:
		mean += positions[k]
		rest_mean += rest_shape[k]
	mean /= count
	rest_mean /= count
	var shape := PackedVector2Array()
	for q in rest_shape:
		shape.append(q - rest_mean)
	var out: PackedVector2Array = ParticleStep.rest_outline(shape)
	_bodies[id].rest = shape
	var spawn := PackedFloat32Array()
	spawn.resize(count * 8)
	for k in count:
		var p := positions[k]
		spawn[k * 8] = p.x
		spawn[k * 8 + 1] = p.y
		spawn[k * 8 + 2] = shape[k].x
		spawn[k * 8 + 3] = shape[k].y
		spawn[k * 8 + 4] = out[k].x
		spawn[k * 8 + 5] = out[k].y
		spawn[k * 8 + 6] = velocity.x
		spawn[k * 8 + 7] = velocity.y
	_pending_bodies.append({"id": id, "material": material, "spawn": spawn.to_byte_array(), "mean": mean, "count": count})
	body_count += 1
	return id


## Uploads one material's row after the parameter panel changed it (ADR 0007): every particle
## and body of that material uses it from the next frame on; nothing is rebuilt or reset. The
## shaders read the row every substep; only which materials are soft is kept here, so a
## stiffness that crosses 1 turns that material's bodies soft or rigid at once.
func update_material(material_table, id: int) -> void:
	var row: PackedByteArray = material_table.pack_row(id)
	for k in row.size():
		_material_bytes[id * MaterialTable.GPU_STRIDE + k] = row[k]
	_note_sticky(material_table, id)
	var became_soft := false
	if float(material_table.materials[id].stiffness) < 1.0:
		became_soft = not _soft_materials.has(id)
		_soft_materials[id] = true
	else:
		_soft_materials.erase(id)
	if _gpu_ready:
		RenderingServer.call_on_render_thread(_update_material_rt.bind(id, row, became_soft))


## Keeps _sticky_materials up to date with a material's row.
func _note_sticky(material_table, id: int) -> void:
	var row: Dictionary = material_table.materials[id]
	if float(row.get("cohesion", 0.0)) > 0.0 or float(row.get("adhesion", 0.0)) > 0.0:
		_sticky_materials[id] = true
	else:
		_sticky_materials.erase(id)


func _update_material_rt(id: int, row: PackedByteArray, became_soft: bool) -> void:
	_ctx.update_buffer_rt("materials", id * MaterialTable.GPU_STRIDE, row)
	# Region rotations left from earlier soft bodies in these slots would turn the new soft
	# members' push-out until their first region fit; zero makes member_rot use the body's.
	if became_soft:
		_ctx.rd.buffer_clear(_ctx.buffer("region_frame"), 0, cap * 16)


## Reads every slot's position and flags back, a frame or two late, for the body brush to
## refuse occupied spots. Calls callback(pos, flags) on the main thread with the pos (cap x 8
## bytes) and mat_flags (cap x 4 bytes) buffers, both empty if a readback failed.
func request_particles(callback: Callable) -> void:
	RenderingServer.call_on_render_thread(_particles_rt.bind(callback))


func _particles_rt(callback: Callable) -> void:
	var got := {}
	var done := func(data: PackedByteArray, what: String) -> void:
		got[what] = data
		if got.size() == 2:
			callback.call_deferred(got.pos, got.flags)
	if not _gpu_ready:
		callback.call_deferred(PackedByteArray(), PackedByteArray())
		return
	var e1: Error = _ctx.readback_async_rt("pos", done.bind("pos"))
	var e2: Error = _ctx.readback_async_rt("mat_flags", done.bind("flags"))
	if e1 != OK or e2 != OK:
		callback.call_deferred(PackedByteArray(), PackedByteArray())


func _reset_bodies() -> void:
	_bodies = [{"first": 0, "count": 0, "made": 0}]
	_pending_bodies.clear()
	_freed_ids = PackedInt32Array()
	_split_ids = PackedInt32Array()
	_pending_split = {}
	body_count = 0


## True while a soft body is in use (made or waiting to spawn): the regions pass runs then.
func _any_soft() -> bool:
	for id in range(1, _bodies.size()):
		if _bodies[id].count > 0 and _soft_materials.has(_bodies[id].get("material", -1)):
			return true
	return false


## Highest body id in use: the body pass runs one workgroup per id up to it.
func _body_max_id() -> int:
	for id in range(_bodies.size() - 1, 0, -1):
		if _bodies[id].count > 0:
			return id
	return 0


func _frame_rt(push: PackedByteArray, op: int, count: int, radius: float, clear: bool, spawn: PackedByteArray,
		split_count: int, freed: PackedInt32Array, body_groups: int, check_bytes: int, split_range: Vector2i,
		frame_number: int, soft: bool) -> void:
	if not _gpu_ready:
		return
	if clear:
		_ctx.update_buffer_rt("free_stack", 0, ParticlePool.initial_stack(cap).to_byte_array())
		_ctx.update_buffer_rt("counters", 0, _initial_counters())
		_ctx.rd.buffer_clear(_ctx.buffer("mat_flags"), 0, cap * 4)
		_ctx.rd.buffer_clear(_ctx.buffer("bodies"), 0, (body_cap + 1) * BODY_BYTES)
	# A freed id's record goes back to empty before anything can reuse the id.
	var empty := PackedByteArray()
	empty.resize(BODY_BYTES)
	for id in freed:
		_ctx.update_buffer_rt("bodies", id * BODY_BYTES, empty)
	if not spawn.is_empty():
		_ctx.update_buffer_rt("body_spawn", 0, spawn)
	# Circle: one thread per lattice spot (brush_spawn.glsl).
	var spawn_threads := brush_lattice_spots(radius) if op == BRUSH_CIRCLE else count if op == BRUSH_BLOCK or op == BRUSH_BODY else 0
	_ctx.set_groups_rt("brush", 0, ComputeContext.groups_for(split_count) if split_count > 0 else 0)
	_ctx.set_groups_rt("brush", 1, ComputeContext.groups_for(spawn_threads) if spawn_threads > 0 else 0)
	_ctx.set_groups_rt("brush", 2, ComputeContext.groups_for(cap) if op == BRUSH_ERASE else 0)
	_ctx.set_groups_rt("brush", 3, 1 if op != BRUSH_NONE else 0)
	_ctx.set_groups_rt("bodies", 0, body_groups)  # one workgroup per body id
	var region_groups := ComputeContext.groups_for(cap) if soft else 0
	_ctx.set_groups_rt("regions", 0, region_groups)
	_ctx.set_groups_rt("regions", 1, region_groups)
	_ctx.set_push_all_rt(push)
	_ctx.record_frame_rt()
	if not _counter_in_flight:
		_counter_in_flight = true
		_ctx.readback_async_rt("counters", _on_counters_rt)
	if check_bytes > 0:
		var err: Error = _ctx.readback_async_rt("bodies", _on_body_records_rt.bind(frame_number), 0, check_bytes)
		if err != OK:
			_on_body_records_rt(PackedByteArray(), frame_number)
	if split_range.y > split_range.x:
		var e1: Error = _ctx.readback_async_rt("body_members", _on_split_data_rt.bind("members"),
				split_range.x * 4, (split_range.y - split_range.x) * 4)
		var e2: Error = _ctx.readback_async_rt("mat_flags", _on_split_data_rt.bind("flags"))
		if e1 != OK or e2 != OK:
			_on_split_data_rt(PackedByteArray(), "failed")


func _on_body_records_rt(data: PackedByteArray, frame_number: int) -> void:
	_on_body_records.call_deferred(data, frame_number)


## Frees the ids and member ranges of bodies whose live count read back 0, and queues the
## bodies the eraser cut (BODY_STALE) for a split check. The data is from the end of frame
## frame_number, so a body spawned after that is left alone.
func _on_body_records(data: PackedByteArray, frame_number: int) -> void:
	_body_check_in_flight = false
	for id in range(1, _bodies.size()):
		var b: Dictionary = _bodies[id]
		var at := id * BODY_BYTES
		if b.count == 0 or b.made > frame_number or at + BODY_BYTES > data.size():
			continue
		if data.decode_u32(at + BODY_LIVE_OFFSET) == 0:
			b.count = 0
			_freed_ids.append(id)
			body_count -= 1
		elif data.decode_u32(at + BODY_FLAGS_OFFSET) & BODY_STALE and not _split_ids.has(id):
			_split_ids.append(id)


func _on_split_data_rt(data: PackedByteArray, what: String) -> void:
	_on_split_data.call_deferred(data, what)


## Plans the split of the bodies in _split_data once both readbacks are in: one entry per
## member still live (its slot alive with the body's id), at most cap - 1 (body_spawn holds a
## header and 2 x cap - 2 entry rows); a body that doesn't fit waits for the next check.
func _on_split_data(data: PackedByteArray, what: String) -> void:
	if _split_data.is_empty():
		return
	_split_data[what] = data
	if what != "failed" and not (_split_data.has("members") and _split_data.has("flags")):
		return
	var job := _split_data
	_split_data = {}
	_split_in_flight = false
	if what == "failed" or job.clears != _clears or job.flags.size() < cap * 4:
		return
	var entries := PackedByteArray()
	entries.resize(16)  # the header row, filled in when the split is sent
	var n := 0
	var new_ids := PackedInt32Array()
	for id in job.ids:
		var b: Dictionary = _bodies[id]
		if b.count == 0:
			continue
		var slots := PackedInt32Array()
		var live := PackedByteArray()
		var n_live := 0
		for k in b.count:
			var at: int = (b.first - job.first + k) * 4
			var slot: int = job.members.decode_u32(at) if at + 4 <= job.members.size() else cap
			var flags: int = job.flags.decode_u32(slot * 4) if slot < cap else 0
			var alive: bool = slot < cap and flags & 0x100 != 0 and flags >> 16 == id
			slots.append(slot)
			live.append(1 if alive else 0)
			n_live += 1 if alive else 0
		if n_live == 0:
			continue  # erased whole: the next records check frees it
		if n + n_live > cap - 1:
			_split_ids.append(id)
			continue
		var plan: Dictionary = plan_split(_bodies, id, slots, live, body_cap, cap)
		entries.append_array(plan.entries)
		n += plan.count
		new_ids.append_array(plan.new_ids)
		body_count += plan.new_ids.size()
	if n > 0:
		_pending_split = {"entries": entries, "count": n, "new_ids": new_ids, "read_frame": job.frame}


## Plans one body's split after an erase (ADR 0004), as ParticleStep.split_body does in the CPU
## reference. slots is its member range as read back, live[k] 1 where slot k still carries the
## body. The pieces are the live members connected on the rest lattice (ParticleStep.body_pieces).
## The largest keeps the id and moves to the front of the range; each other piece takes the
## lowest free id and a member range by first fit, or stays on the old id (and in its range)
## when none is free. Every piece's outline is worked out again (ParticleStep.rest_outline).
## Updates bodies (the new ids' "made" is NOT_MADE until the split is sent) and returns
## { "entries": bytes for body_split.glsl, two vec4 rows per live member, "count", "new_ids" }.
static func plan_split(bodies: Array, id: int, slots: PackedInt32Array, live: PackedByteArray,
		max_id: int, member_cap: int) -> Dictionary:
	var b: Dictionary = bodies[id]
	var shape := PackedVector2Array()
	var live_k := PackedInt32Array()
	for k in slots.size():
		if live[k] != 0:
			live_k.append(k)
			shape.append(b.rest[k])
	var pieces: Array = ParticleStep.body_pieces(shape)
	# While the other pieces get their ranges, the old body holds as many members as are live.
	b.count = live_k.size()
	var kept := PackedInt32Array()  # indices into live_k, kept piece first
	var placed := []  # [new id, first, piece] per piece with its own body
	for p in pieces.size():
		var piece: PackedInt32Array = pieces[p]
		if p > 0:
			var new_id := 1
			while new_id < bodies.size() and bodies[new_id].count > 0:
				new_id += 1
			var first: int = ParticleStep._first_fit(bodies, piece.size())
			if new_id <= max_id and first + piece.size() <= member_cap:
				if new_id == bodies.size():
					bodies.append({})
				var rest := PackedVector2Array()
				for k in piece:
					rest.append(shape[k])
				bodies[new_id] = {"first": first, "count": piece.size(), "made": NOT_MADE, "rest": rest,
						"material": b.get("material", -1)}
				placed.append([new_id, first, piece])
				continue
		kept.append_array(piece)
	var kept_rest := PackedVector2Array()
	for k in kept:
		kept_rest.append(shape[k])
	b.count = kept.size()
	b.rest = kept_rest
	# Outlines per piece, also for a piece left on the old id.
	var outline := PackedVector2Array()
	outline.resize(shape.size())
	for piece in pieces:
		var piece_rest := PackedVector2Array()
		for k in piece:
			piece_rest.append(shape[k])
		var out: PackedVector2Array = ParticleStep.rest_outline(piece_rest)
		for j in piece.size():
			outline[piece[j]] = out[j]
	var rows := PackedByteArray()
	rows.resize(live_k.size() * 32)
	var count := 0
	var new_ids := PackedInt32Array()
	var groups := [[id, b.first, kept]]
	groups.append_array(placed)
	for g in groups:
		var piece: PackedInt32Array = g[2]
		if g[0] != id:
			new_ids.append(g[0])
		for j in piece.size():
			var k: int = piece[j]
			var at := count * 32
			rows.encode_u32(at, slots[live_k[k]])
			rows.encode_u32(at + 4, id)
			rows.encode_u32(at + 8, g[0])
			rows.encode_u32(at + 12, g[1] + j)
			rows.encode_float(at + 16, outline[k].x)
			rows.encode_float(at + 20, outline[k].y)
			rows.encode_u32(at + 24, piece.size())
			rows.encode_u32(at + 28, SPLIT_FIRST if j == 0 else 0)
			count += 1
	return {"entries": rows, "count": count, "new_ids": new_ids}


## Circle brush threads: the rest-spacing lattice over the brush's bounding square
## (brush_lattice_side() in common.glslinc).
static func brush_lattice_spots(radius: float) -> int:
	var side := ceili(2.0 * radius / SimParams.SPACING) + 1
	return side * side


func _on_counters_rt(data: PackedByteArray) -> void:
	_set_live_count.call_deferred(data.decode_u32(4) if data.size() >= 8 else -1)


func _set_live_count(count: int) -> void:
	_counter_in_flight = false
	if count >= 0 and not _clear_pending:
		live_count = count


## Push constants, same layout as Params in common.glslinc (128 bytes).
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
	b.encode_float(48, SimParams.DT / _substeps)
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
	b.encode_float(96, SimParams.STACK_K)
	b.encode_float(100, SimParams.MAX_SEPARATION)
	b.encode_float(104, SimParams.WET_SLIP)
	b.encode_u32(108, body_count)
	b.encode_u32(112, _body_max_id())
	b.encode_u32(116, brush.get("body_first", 0))
	b.encode_u32(120, _iterations)
	b.encode_u32(124, 1 if not _sticky_materials.is_empty() else 0)
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
