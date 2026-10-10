## Thin wrapper around the MAIN RenderingDevice for compute work.
##
## Rules this class enforces (see docs/SPEC.md, Milestone 1):
## - Always the main device (RenderingServer.get_rendering_device()), never a local one,
##   so buffers and textures can feed rendering (Texture2DRD).
## - Never submit()/sync(): the engine submits our compute lists with the frame.
## - Every method ending in _rt must run on the render thread. Call them from a
##   Callable passed to RenderingServer.call_on_render_thread().
## - Resources are named. free_all_rt() releases everything this context created.
##
## A frame is a list of passes. Each pass is recorded as its own compute list,
## followed by a GPU timestamp, so per-pass GPU time is measurable (timestamps can't
## be captured inside a compute list that already has dispatches). The engine inserts
## barriers between lists automatically. Dispatches inside one pass are separated
## with compute_list_add_barrier().
extends RefCounted

## Threads per workgroup for every 1D particle shader (local_size_x in GLSL).
const WORKGROUP_SIZE := 64
## Prefix for our timestamp names, so we can ignore the engine's own timestamps.
const TS_PREFIX := "fc:"
const TS_BEGIN := TS_PREFIX + "begin"

var rd: RenderingDevice

var _shaders := {}       # name -> RID
var _pipelines := {}     # name -> RID
var _buffers := {}       # name -> RID
var _textures := {}      # name -> RID
var _uniform_sets := {}  # name -> RID
## Ordered pass list: [{ "name": String, "dispatches": [Dictionary] }]
## Each dispatch: { "pipeline": RID, "uniform_set": RID, "push": PackedByteArray, "groups_x": int }
var _passes: Array = []

## Timing results, written on the render thread and read on the main thread.
var _mutex := Mutex.new()
var _cpu_us := {}  # pass name -> CPU microseconds spent recording the pass
var _gpu_us := {}  # pass name -> GPU microseconds, float (lags a frame or two)


func _init() -> void:
	rd = RenderingServer.get_rendering_device()


## True when compute is possible. Null under Compatibility and in headless mode.
static func is_available() -> bool:
	return RenderingServer.get_rendering_device() != null


## Loads a .glsl compute shader and returns its SPIR-V, or null after appending
## a readable message to `errors`. Safe on the main thread (no device calls).
static func load_spirv(path: String, errors: PackedStringArray) -> RDShaderSPIRV:
	var file := load(path) as RDShaderFile
	if file == null:
		errors.append("shader %s: could not load as RDShaderFile (is it imported?)" % path)
		return null
	if file.base_error != "":
		errors.append("shader %s: %s" % [path, file.base_error])
		return null
	var spirv := file.get_spirv()
	if spirv == null:
		errors.append("shader %s: no SPIR-V produced" % path)
		return null
	if spirv.compile_error_compute != "":
		errors.append("shader %s: compile error:\n%s" % [path, spirv.compile_error_compute])
		return null
	return spirv


## Number of workgroups needed to cover `count` elements.
static func groups_for(count: int) -> int:
	return ceili(float(count) / WORKGROUP_SIZE)


## Checks device limits for our 64-thread 1D dispatches, shared memory and push
## constants. Returns "" if OK, else the problem.
func check_limits_rt(max_groups_x: int, push_bytes := 16, shared_bytes := 0) -> String:
	var size_x := rd.limit_get(RenderingDevice.LIMIT_MAX_COMPUTE_WORKGROUP_SIZE_X)
	var invocations := rd.limit_get(RenderingDevice.LIMIT_MAX_COMPUTE_WORKGROUP_INVOCATIONS)
	var count_x := rd.limit_get(RenderingDevice.LIMIT_MAX_COMPUTE_WORKGROUP_COUNT_X)
	var max_push := rd.limit_get(RenderingDevice.LIMIT_MAX_PUSH_CONSTANT_SIZE)
	var max_shared := rd.limit_get(RenderingDevice.LIMIT_MAX_COMPUTE_SHARED_MEMORY_SIZE)
	print("[compute] device '%s': workgroup size x %d, invocations %d, count x %d (need %d), push %d B, shared %d B"
			% [rd.get_device_name(), size_x, invocations, count_x, max_groups_x, max_push, max_shared])
	if max_push < push_bytes:
		return "GPU push constant limit too small: need %d bytes, device allows %d" % [push_bytes, max_push]
	if max_shared < shared_bytes:
		return "GPU shared memory limit too small: need %d bytes, device allows %d" % [shared_bytes, max_shared]
	if size_x < WORKGROUP_SIZE or invocations < WORKGROUP_SIZE:
		return "GPU workgroup limit too small: need %d threads, device allows %d (x) / %d (total)" \
				% [WORKGROUP_SIZE, size_x, invocations]
	if count_x < max_groups_x:
		return "GPU dispatch limit too small: need %d workgroups, device allows %d. Lower particle_cap in config.json." \
				% [max_groups_x, count_x]
	return ""


# --- Resource creation (render thread) -------------------------------------------

## Creates a shader and its compute pipeline under `name`. Returns "" or an error.
func create_pipeline_rt(name: String, spirv: RDShaderSPIRV) -> String:
	var shader := rd.shader_create_from_spirv(spirv, name)
	if not shader.is_valid():
		return "shader_create_from_spirv failed for '%s'" % name
	_shaders[name] = shader
	var pipeline := rd.compute_pipeline_create(shader)
	if not pipeline.is_valid():
		return "compute_pipeline_create failed for '%s'" % name
	_pipelines[name] = pipeline
	return ""


## Creates a storage buffer. Leave data empty for a zero-filled buffer.
func create_buffer_rt(name: String, size_bytes: int, data := PackedByteArray()) -> RID:
	var rid := rd.storage_buffer_create(size_bytes, data)
	if rid.is_valid():
		_buffers[name] = rid
	return rid


## Creates an RGBA8 texture that compute can write (image2D) and the renderer can sample.
## Copy-from is set so probes can save it (tools/water_feel_probe.gd shots=).
func create_storage_texture_rt(name: String, width: int, height: int) -> RID:
	var fmt := RDTextureFormat.new()
	fmt.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	fmt.width = width
	fmt.height = height
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
			| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	var rid := rd.texture_create(fmt, RDTextureView.new())
	if rid.is_valid():
		_textures[name] = rid
	return rid


## Builds a uniform set for the named pipeline's shader.
## bindings: Array of [binding: int, uniform_type: RenderingDevice.UniformType, rid: RID]
func create_uniform_set_rt(name: String, pipeline_name: String, set_index: int, bindings: Array) -> RID:
	var uniforms: Array[RDUniform] = []
	for b in bindings:
		var u := RDUniform.new()
		u.binding = b[0]
		u.uniform_type = b[1]
		u.add_id(b[2])
		uniforms.append(u)
	var rid := rd.uniform_set_create(uniforms, _shaders[pipeline_name], set_index)
	if rid.is_valid():
		_uniform_sets[name] = rid
	return rid


## Writes bytes into a buffer. Render thread, between frames (not inside a compute list).
func update_buffer_rt(name: String, offset: int, data: PackedByteArray) -> Error:
	return rd.buffer_update(_buffers[name], offset, data.size(), data)


func buffer(name: String) -> RID:
	return _buffers.get(name, RID())


func texture(name: String) -> RID:
	return _textures.get(name, RID())


# --- Pass list --------------------------------------------------------------------

## Appends a pass. dispatches: Array of [pipeline_name, uniform_set_name, groups_x].
## Dispatches run in order with a barrier between each. Passes may share a name (one
## per substep); their times are summed under that name.
func add_pass(pass_name: String, dispatches: Array) -> void:
	var list := []
	for d in dispatches:
		list.append({
			"pipeline": _pipelines[d[0]],
			"uniform_set": _uniform_sets[d[1]],
			"groups_x": d[2],
			"push": PackedByteArray(),
		})
	_passes.append({"name": pass_name, "dispatches": list})


## Sets the push constant bytes (a multiple of 16) for every dispatch in a pass.
func set_push_rt(pass_name: String, push: PackedByteArray) -> void:
	for p in _passes:
		if p.name == pass_name:
			for d in p.dispatches:
				d.push = push


## Sets the same push constant bytes on every dispatch of every pass.
func set_push_all_rt(push: PackedByteArray) -> void:
	for p in _passes:
		for d in p.dispatches:
			d.push = push


## Changes one dispatch's workgroup count for this and later frames. 0 skips it.
func set_groups_rt(pass_name: String, dispatch_index: int, groups_x: int) -> void:
	for p in _passes:
		if p.name == pass_name:
			p.dispatches[dispatch_index].groups_x = groups_x


## Records all passes for this frame. Call once per frame on the render thread.
func record_frame_rt() -> void:
	_collect_timestamps_rt()
	var cpu := {}
	rd.capture_timestamp(TS_BEGIN)
	for p in _passes:
		var t0 := Time.get_ticks_usec()
		var list := rd.compute_list_begin()
		var first := true
		for d in p.dispatches:
			if d.groups_x <= 0:
				continue
			if not first:
				rd.compute_list_add_barrier(list)
			first = false
			rd.compute_list_bind_compute_pipeline(list, d.pipeline)
			rd.compute_list_bind_uniform_set(list, d.uniform_set, 0)
			if not d.push.is_empty():
				rd.compute_list_set_push_constant(list, d.push, d.push.size())
			rd.compute_list_dispatch(list, d.groups_x, 1, 1)
		rd.compute_list_end()
		rd.capture_timestamp(TS_PREFIX + p.name)
		cpu[p.name] = cpu.get(p.name, 0) + Time.get_ticks_usec() - t0
	_mutex.lock()
	_cpu_us = cpu
	_mutex.unlock()


## Reads the most recent completed frame's timestamps (they lag a frame or two).
func _collect_timestamps_rt() -> void:
	var count := rd.get_captured_timestamps_count()
	var gpu := {}
	var prev_time := -1
	for i in count:
		var ts_name := rd.get_captured_timestamp_name(i)
		if not ts_name.begins_with(TS_PREFIX):
			continue
		var t := rd.get_captured_timestamp_gpu_time(i)
		if ts_name != TS_BEGIN and prev_time >= 0:
			# GPU timestamps are nanoseconds (Vulkan driver); report microseconds.
			var pass_name := ts_name.trim_prefix(TS_PREFIX)
			gpu[pass_name] = gpu.get(pass_name, 0.0) + (t - prev_time) / 1000.0
		prev_time = t
	if gpu.is_empty():
		return
	_mutex.lock()
	_gpu_us = gpu
	_mutex.unlock()


## Per-pass timings, safe to call from the main thread.
## Returns [{ "name", "cpu_us", "gpu_us" }] in pass order; values are -1 until available.
func get_timings() -> Array:
	var out := []
	var seen := {}
	_mutex.lock()
	for p in _passes:
		if seen.has(p.name):
			continue
		seen[p.name] = true
		out.append({
			"name": p.name,
			"cpu_us": _cpu_us.get(p.name, -1),
			"gpu_us": _gpu_us.get(p.name, -1),
		})
	_mutex.unlock()
	return out


# --- Debug readback ---------------------------------------------------------------

## Asynchronous readback, for debugging only. callback(data: PackedByteArray) runs
## later on the render thread. Never use buffer_get_data (it stalls the GPU).
func readback_async_rt(buffer_name: String, callback: Callable) -> Error:
	return rd.buffer_get_data_async(_buffers[buffer_name], callback)


# --- Cleanup ----------------------------------------------------------------------

## Frees every RID this context created. Dependents first, shaders last.
func free_all_rt() -> void:
	_passes.clear()
	for group in [_uniform_sets, _pipelines, _buffers, _textures, _shaders]:
		for rid in group.values():
			if rid.is_valid():
				rd.free_rid(rid)
		group.clear()
