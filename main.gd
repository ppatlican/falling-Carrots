## Game entry point (Milestone 2): loads config and the material table, checks for
## compute support, runs the GPU particle sim, and routes brush input to it.
## Left mouse (draw) adds the selected material; right mouse (erase) removes any.
extends Node2D

const GameConfig = preload("res://core/game_config.gd")
const SimParams = preload("res://core/sim_params.gd")
const MaterialTable = preload("res://cpu_ref/material_table.gd")
const ComputeContext = preload("res://gpu/compute_context.gd")
const ParticleSim = preload("res://gpu/particle_sim.gd")

const NO_DEVICE_MESSAGE := "This game needs GPU compute (Vulkan, Mobile renderer).\n" \
		+ "No RenderingDevice is available: the GPU or driver may not support Vulkan, " \
		+ "or the game was started with the Compatibility renderer or --headless."

@onready var _overlay = $DebugOverlay
@onready var _error_screen = $ErrorScreen
@onready var _toolbar = $Toolbar
@onready var _view: Sprite2D = $SimView

var _config
var _table
var _sim
var _running := false
var _paused := false
var _material := 0
var _drawing := false
var _erasing := false
var _pending_fill := -1  # material id of a requested benchmark fill, or -1
var _view_flags := 0


func _ready() -> void:
	_config = GameConfig.load_from_file()
	for e in _config.errors:
		push_warning("config.json: " + e)
	_overlay.particle_cap = _config.particle_cap

	_table = MaterialTable.new()
	var problems: PackedStringArray = _table.load_file()
	if not problems.is_empty():
		_error_screen.show_error("data/materials.json has problems:\n" + "\n".join(problems))
		return
	_material = _table.materials.keys().min()
	_toolbar.build(_table.materials, _material, "+%dk" % (SimParams.BENCH_BLOCK / 1000))
	_toolbar.material_selected.connect(func(id): _material = id)
	_toolbar.fill_requested.connect(func(id): _pending_fill = id)
	_toolbar.clear_requested.connect(_clear)
	_toolbar.set_capacity(0, _config.particle_cap)

	if not ComputeContext.is_available():
		_error_screen.show_error(NO_DEVICE_MESSAGE)
		return

	var ctx = ComputeContext.new()
	_overlay.compute = ctx
	_overlay.view_toggled.connect(_on_view_toggled)
	_overlay.check_requested.connect(func(): _sim.request_check())
	_sim = ParticleSim.new(ctx, _config.particle_cap, _config.solver_iterations, _table, _config.substeps)
	_sim.setup_finished.connect(_on_setup_finished)
	_sim.check_finished.connect(_on_check_finished)
	_view.texture = _sim.texture
	var err: String = _sim.start()
	if err != "":
		_error_screen.show_error(err)


func _on_setup_finished(err: String) -> void:
	if err != "":
		_error_screen.show_error(err)
		return
	_running = true


func _on_check_finished(ok: bool, message: String) -> void:
	print("[sim] " + message)
	if not ok:
		push_error("[sim] " + message)
	_overlay.set_status("check", message)


func _on_view_toggled(view: String, enabled: bool) -> void:
	if view == "hash_grid":
		_view_flags = ParticleSim.VIEW_HASH if enabled else 0


func _clear() -> void:
	if _sim != null:
		_sim.request_clear()


func _unhandled_input(event: InputEvent) -> void:
	# Toolbar buttons consume their own clicks, so strokes only start over the world.
	if event.is_action_pressed("draw"):
		_drawing = true
	elif event.is_action_pressed("erase"):
		_erasing = true
	elif event.is_action_pressed("pause") and not event.is_echo():
		_paused = not _paused
		_overlay.set_status("paused", "PAUSED" if _paused else "")
	elif event.is_action_pressed("clear") and not event.is_echo():
		_clear()


func _process(_delta: float) -> void:
	_drawing = _drawing and Input.is_action_pressed("draw")
	_erasing = _erasing and Input.is_action_pressed("erase")
	if not _running:
		return
	_toolbar.set_capacity(_sim.live_count, _sim.cap)
	_overlay.particle_count = _sim.live_count
	if _paused:
		return
	_sim.frame(_brush(), _view_flags)


## This frame's brush operation. Erase wins over draw; nothing is added at the cap.
func _brush() -> Dictionary:
	var brush := {"op": ParticleSim.BRUSH_NONE, "pos": get_global_mouse_position(),
			"radius": SimParams.BRUSH_RADIUS, "material": _material, "count": 0, "cols": 1}
	var full: bool = _sim.live_count >= _sim.cap
	if _erasing:
		brush.op = ParticleSim.BRUSH_ERASE
	elif _pending_fill >= 0 and not full:
		var cols := SimParams.BENCH_COLS
		brush.op = ParticleSim.BRUSH_BLOCK
		brush.material = _pending_fill
		brush.count = SimParams.BENCH_BLOCK
		brush.cols = cols
		brush.pos = Vector2((SimParams.WORLD_SIZE.x - cols * SimParams.SPACING) * 0.5, 8.0)
	elif _drawing and not full:
		brush.op = ParticleSim.BRUSH_CIRCLE
		brush.count = SimParams.brush_rate()
	_pending_fill = -1
	return brush


func _exit_tree() -> void:
	if _sim != null:
		_sim.shutdown()
