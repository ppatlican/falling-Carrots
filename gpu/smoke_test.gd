## Milestone 1 smoke test for the compute plumbing.
##
## Two passes over a 50k-element buffer:
##   smoke_fill  writes hash_u32(i) into the buffer
##   smoke_draw  reads it and draws one pixel per element into a texture
## The texture is shown on screen through `texture` (a Texture2DRD). An async
## readback then checks every buffer value against the CPU mirror in smoke_hash.gd.
##
## Main-thread methods: start(), frame(), request_readback(), shutdown().
## Methods ending in _rt run on the render thread.
extends RefCounted

const ComputeContext = preload("res://gpu/compute_context.gd")
const SmokeHash = preload("res://gpu/smoke_hash.gd")

const ELEMENT_COUNT := 50000
const TEX_W := 250
const TEX_H := 200  # TEX_W * TEX_H == ELEMENT_COUNT
const FILL_SHADER := "res://gpu/shaders/smoke/smoke_fill.glsl"
const DRAW_SHADER := "res://gpu/shaders/smoke/smoke_draw.glsl"

## Emitted on the main thread. error is "" on success.
signal setup_finished(error: String)
## Emitted on the main thread with a human-readable result.
signal readback_finished(ok: bool, message: String)

## Assign to a Sprite2D/TextureRect. Valid after setup_finished("").
var texture := Texture2DRD.new()

var _ctx
var _max_groups_x: int
var _gpu_ready := false


## max_groups_x: the largest dispatch the game will need (e.g. for particle_cap),
## checked against device limits during setup.
func _init(ctx, max_groups_x: int) -> void:
	_ctx = ctx
	_max_groups_x = maxi(max_groups_x, ComputeContext.groups_for(ELEMENT_COUNT))


## Loads shaders on the main thread, then schedules GPU setup. Returns "" or an error.
func start() -> String:
	var errors := PackedStringArray()
	var fill := ComputeContext.load_spirv(FILL_SHADER, errors)
	var draw := ComputeContext.load_spirv(DRAW_SHADER, errors)
	if not errors.is_empty():
		return "\n".join(errors)
	RenderingServer.call_on_render_thread(_setup_rt.bind(fill, draw))
	return ""


func _setup_rt(fill: RDShaderSPIRV, draw: RDShaderSPIRV) -> void:
	var err: String = _ctx.check_limits_rt(_max_groups_x)
	if err == "":
		err = _ctx.create_pipeline_rt("smoke_fill", fill)
	if err == "":
		err = _ctx.create_pipeline_rt("smoke_draw", draw)
	if err != "":
		_finish_setup.call_deferred(err, RID())
		return

	var values: RID = _ctx.create_buffer_rt("smoke_values", ELEMENT_COUNT * 4)
	var image: RID = _ctx.create_storage_texture_rt("smoke_image", TEX_W, TEX_H)
	if not values.is_valid() or not image.is_valid():
		_finish_setup.call_deferred("could not create smoke buffer or texture", RID())
		return

	var fill_set: RID = _ctx.create_uniform_set_rt("smoke_fill", "smoke_fill", 0, [
		[0, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, values],
	])
	var draw_set: RID = _ctx.create_uniform_set_rt("smoke_draw", "smoke_draw", 0, [
		[0, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, values],
		[1, RenderingDevice.UNIFORM_TYPE_IMAGE, image],
	])
	if not fill_set.is_valid() or not draw_set.is_valid():
		_finish_setup.call_deferred("could not create smoke uniform sets", RID())
		return

	var groups: int = ComputeContext.groups_for(ELEMENT_COUNT)
	_ctx.add_pass("smoke_fill", [["smoke_fill", "smoke_fill", groups]])
	_ctx.add_pass("smoke_draw", [["smoke_draw", "smoke_draw", groups]])
	_ctx.set_push_rt("smoke_fill", _push(0.0))
	_gpu_ready = true
	_finish_setup.call_deferred("", image)


func _finish_setup(err: String, image: RID) -> void:
	if err == "":
		texture.texture_rd_rid = image
	setup_finished.emit(err)


## Schedules this frame's compute work. Call once per _process.
func frame(time: float) -> void:
	RenderingServer.call_on_render_thread(_frame_rt.bind(time))


func _frame_rt(time: float) -> void:
	if not _gpu_ready:
		return
	_ctx.set_push_rt("smoke_draw", _push(time))
	_ctx.record_frame_rt()


## 16-byte push constant: count, width, time, pad.
func _push(time: float) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(16)
	b.encode_u32(0, ELEMENT_COUNT)
	b.encode_u32(4, TEX_W)
	b.encode_float(8, time)
	b.encode_u32(12, 0)
	return b


## Starts the async readback check. Result arrives via readback_finished.
func request_readback() -> void:
	RenderingServer.call_on_render_thread(_readback_rt)


func _readback_rt() -> void:
	var err: Error = _ctx.readback_async_rt("smoke_values", _on_readback_rt)
	if err != OK:
		_verify.call_deferred(PackedByteArray(), "buffer_get_data_async failed: %s" % error_string(err))


func _on_readback_rt(data: PackedByteArray) -> void:
	_verify.call_deferred(data, "")


func _verify(data: PackedByteArray, err: String) -> void:
	if err != "":
		readback_finished.emit(false, err)
		return
	if data.size() != ELEMENT_COUNT * 4:
		readback_finished.emit(false, "readback size %d, expected %d" % [data.size(), ELEMENT_COUNT * 4])
		return
	var bad := 0
	var first_bad := -1
	for i in ELEMENT_COUNT:
		if data.decode_u32(i * 4) != SmokeHash.hash_u32(i):
			bad += 1
			if first_bad < 0:
				first_bad = i
	if bad == 0:
		readback_finished.emit(true, "readback OK: %d/%d values match" % [ELEMENT_COUNT, ELEMENT_COUNT])
	else:
		readback_finished.emit(false, "readback FAILED: %d mismatches, first at index %d" % [bad, first_bad])


## Frees GPU resources. Call from the owner's _exit_tree.
func shutdown() -> void:
	_gpu_ready = false
	texture.texture_rd_rid = RID()
	RenderingServer.call_on_render_thread(_ctx.free_all_rt)
