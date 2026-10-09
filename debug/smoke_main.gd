## Milestone 1 compute smoke test (scene: debug/smoke_test.tscn). Loads config,
## checks for compute support, runs the smoke test and hosts the debug overlay.
## Kept so the compute plumbing can be checked on its own; the game is main.tscn.
extends Node2D

const GameConfig = preload("res://core/game_config.gd")
const ComputeContext = preload("res://gpu/compute_context.gd")
const SmokeTest = preload("res://gpu/smoke_test.gd")

## Frames to run before the one-off readback check (lets the GPU settle).
const READBACK_AFTER_FRAMES := 30

const NO_DEVICE_MESSAGE := "This game needs GPU compute (Vulkan, Mobile renderer).\n" \
		+ "No RenderingDevice is available: the GPU or driver may not support Vulkan, " \
		+ "or the game was started with the Compatibility renderer or --headless."

@onready var _overlay = $DebugOverlay
@onready var _error_screen = $ErrorScreen
@onready var _view: Sprite2D = $SmokeView

var _config
var _ctx
var _smoke
var _running := false
var _paused := false
var _time := 0.0
var _frames := 0


func _ready() -> void:
	_config = GameConfig.load_from_file()
	for e in _config.errors:
		push_warning("config.json: " + e)
	_overlay.particle_cap = _config.particle_cap

	if not ComputeContext.is_available():
		_error_screen.show_error(NO_DEVICE_MESSAGE)
		return

	_ctx = ComputeContext.new()
	_overlay.compute = _ctx
	_smoke = SmokeTest.new(_ctx, ComputeContext.groups_for(_config.particle_cap))
	_smoke.setup_finished.connect(_on_setup_finished)
	_smoke.readback_finished.connect(_on_readback_finished)
	_view.texture = _smoke.texture
	var err: String = _smoke.start()
	if err != "":
		_error_screen.show_error(err)
	else:
		_overlay.set_status("smoke", "smoke test: starting")


func _on_setup_finished(err: String) -> void:
	if err != "":
		_error_screen.show_error(err)
		return
	_running = true
	_overlay.set_status("smoke", "smoke test: running")


func _on_readback_finished(ok: bool, message: String) -> void:
	print("[smoke] " + message)
	if not ok:
		push_error("[smoke] " + message)
	_overlay.set_status("smoke", "smoke " + message)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause") and not event.is_echo():
		_paused = not _paused
		_overlay.set_status("paused", "PAUSED" if _paused else "")
	elif event.is_action_pressed("clear") and not event.is_echo():
		_time = 0.0  # nothing to clear yet; resets the smoke animation


func _process(delta: float) -> void:
	if not _running:
		return
	if not _paused:
		_time += delta
	_smoke.frame(_time)
	_frames += 1
	if _frames == READBACK_AFTER_FRAMES:
		_smoke.request_readback()


func _exit_tree() -> void:
	if _smoke != null:
		_smoke.shutdown()
