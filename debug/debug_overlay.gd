## Debug overlay (spec section 6): FPS, frame time, per-pass CPU/GPU time,
## particle count vs cap, and visualization toggles. F3 (toggle_debug) shows/hides it.
## Pass times are averaged over AVERAGE_SEC so they're readable from a screenshot.
## The wind and temperature views don't exist yet (Milestones 6, 7): their
## toggles are wired to the flags below but show "n/a".
extends CanvasLayer

## Emitted when a visualization toggle changes. view: "hash_grid" | "wind" | "temperature".
signal view_toggled(view: String, enabled: bool)
## Emitted when the "GPU check" button is pressed.
signal check_requested

const REFRESH_SEC := 0.25
const AVERAGE_SEC := 1.0
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
## Running sums for the averaging window: pass name -> [cpu_sum, gpu_sum, samples].
var _sums := {}
var _since_average := 0.0
var _frame_ms_sum := 0.0
var _frames_in_window := 0
## Last completed window: [{ name, cpu_us, gpu_us }], plus its average frame time.
var _averaged: Array = []
var _window_frame_ms := 0.0


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
	_add_toggle(box, "Wind (n/a)", "wind")
	_add_toggle(box, "Temperature (n/a)", "temperature")
	var button := Button.new()
	button.text = "GPU check"
	button.add_theme_font_size_override("font_size", FONT_SIZE)
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(func(): check_requested.emit())
	box.add_child(button)


func _add_toggle(box: Container, text: String, view: String) -> void:
	var check := CheckBox.new()
	check.text = text
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
	_accumulate(delta)
	_since_refresh += delta
	if _since_refresh < REFRESH_SEC or not visible:
		return
	_since_refresh = 0.0
	_label.text = _build_text()


## Adds this frame's timings to the window; closes the window every AVERAGE_SEC.
func _accumulate(delta: float) -> void:
	if compute == null:
		return
	for t in compute.get_timings():
		if t.gpu_us < 0:
			continue
		var s: Array = _sums.get(t.name, [0, 0.0, 0])
		s[0] += t.cpu_us
		s[1] += t.gpu_us
		s[2] += 1
		_sums[t.name] = s
	_frame_ms_sum += delta * 1000.0
	_frames_in_window += 1
	_since_average += delta
	if _since_average < AVERAGE_SEC:
		return
	_averaged = []
	for t in compute.get_timings():
		var s: Array = _sums.get(t.name, [0, 0, 0])
		_averaged.append({
			"name": t.name,
			"cpu_us": -1 if s[2] == 0 else s[0] / s[2],
			"gpu_us": -1.0 if s[2] == 0 else s[1] / s[2],
		})
	_window_frame_ms = _frame_ms_sum / _frames_in_window
	_sums.clear()
	_since_average = 0.0
	_frame_ms_sum = 0.0
	_frames_in_window = 0


func _build_text() -> String:
	var lines := PackedStringArray()
	lines.append("FPS %d   frame %.2f ms (1 s avg %.2f)" % [Engine.get_frames_per_second(), _frame_ms_avg, _window_frame_ms])
	lines.append("particles %d / %d" % [particle_count, particle_cap])
	if compute != null:
		lines.append("pass (1 s avg) cpu us   gpu us")
		var cpu_total := 0
		var gpu_total := 0.0
		for t in _averaged:
			lines.append("%-12s %7s %8s" % [t.name, _us(t.cpu_us, false), _us(t.gpu_us, true)])
			cpu_total += maxi(t.cpu_us, 0)
			gpu_total += maxf(t.gpu_us, 0.0)
		lines.append("%-12s %7d %8.1f" % ["TOTAL", cpu_total, gpu_total])
	for key in _status:
		lines.append(_status[key])
	return "\n".join(lines)


func _us(v: float, decimals: bool) -> String:
	if v < 0:
		return "-"
	return "%.1f" % v if decimals else str(int(v))
