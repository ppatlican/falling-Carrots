## Debug overlay (spec section 6): FPS, frame time, per-pass CPU/GPU time,
## particle count vs cap, and visualization toggles. F3 (toggle_debug) shows/hides it.
## The hash grid, wind and temperature views don't exist yet (Milestones 2, 6, 7):
## their toggles are wired to the flags below but show "n/a".
extends CanvasLayer

## Emitted when a visualization toggle changes. view: "hash_grid" | "wind" | "temperature".
signal view_toggled(view: String, enabled: bool)

const REFRESH_SEC := 0.25
const FONT_SIZE := 8  # base-viewport pixels; canvas_items stretch keeps text crisp

## Set by the owner. compute must provide get_timings() (gpu/compute_context.gd).
var compute = null
var particle_count := 0
var particle_cap := 0

## Visualization flags, read by later milestones' renderers.
var show_hash_grid := false
var show_wind := false
var show_temperature := false

var _label: Label
var _status := {}  # key -> line, for one-off messages such as the smoke test result
var _frame_ms_avg := 0.0
var _since_refresh := 0.0


func _ready() -> void:
	layer = 100
	var panel := PanelContainer.new()
	panel.position = Vector2(4, 4)
	panel.self_modulate = Color(1, 1, 1, 0.8)
	add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 0)
	panel.add_child(box)
	_label = Label.new()
	_label.add_theme_font_size_override("font_size", FONT_SIZE)
	box.add_child(_label)
	_add_toggle(box, "Hash grid", "hash_grid")
	_add_toggle(box, "Wind", "wind")
	_add_toggle(box, "Temperature", "temperature")


func _add_toggle(box: Container, text: String, view: String) -> void:
	var check := CheckBox.new()
	check.text = "%s (n/a)" % text
	check.add_theme_font_size_override("font_size", FONT_SIZE)
	check.focus_mode = Control.FOCUS_NONE
	check.toggled.connect(_on_toggled.bind(view))
	box.add_child(check)


func _on_toggled(enabled: bool, view: String) -> void:
	set("show_" + view, enabled)
	view_toggled.emit(view, enabled)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_debug") and not event.is_echo():
		visible = not visible
		get_viewport().set_input_as_handled()


## Shows a persistent status line (pass "" to remove it).
func set_status(key: String, text: String) -> void:
	if text == "":
		_status.erase(key)
	else:
		_status[key] = text


func _process(delta: float) -> void:
	_frame_ms_avg = lerpf(_frame_ms_avg, delta * 1000.0, 0.1)
	_since_refresh += delta
	if _since_refresh < REFRESH_SEC or not visible:
		return
	_since_refresh = 0.0
	_label.text = _build_text()


func _build_text() -> String:
	var lines := PackedStringArray()
	lines.append("FPS %d   frame %.2f ms" % [Engine.get_frames_per_second(), _frame_ms_avg])
	lines.append("particles %d / %d" % [particle_count, particle_cap])
	if compute != null:
		lines.append("pass          cpu us   gpu us")
		for t in compute.get_timings():
			lines.append("%-12s %7s %8s" % [t.name, _us(t.cpu_us), _us(t.gpu_us)])
	for key in _status:
		lines.append(_status[key])
	return "\n".join(lines)


func _us(v: int) -> String:
	return "-" if v < 0 else str(v)
