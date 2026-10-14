## Parameter panel (ADR 0007): sliders for the selected material's parameters, a colour picker
## and reset, top right; the header folds it to one line. Each slider stops at the validator's
## range for its column (MaterialTable.range_of); main.gd applies an edit to the table and
## uploads the row (ParticleSim.update_material). Its clicks are GUI input, so they never
## start a brush stroke.
extends CanvasLayer

## A slider moved: the new value of a column (within its range).
signal value_changed(id: int, column: String, value: float)
signal color_changed(id: int, color: Color)
signal reset_requested(id: int)

const MaterialTable = preload("res://cpu_ref/material_table.gd")

const FONT_SIZE := 8
const WIDTH := 132
## Columns whose range spans orders of magnitude (density 0.01-100, drag 0-60 per second) move
## along a power curve, so the shipped values sit away from the left end of the track.
const CURVED := ["density", "drag"]
const CURVE_POWER := 3.0
## Slider positions run 0..1 in this many steps.
const STEPS := 1000

var _id := -1
var _row: Dictionary = {}
var _body: VBoxContainer
var _sliders: VBoxContainer
var _title: Label
var _fold: Button
var _color: ColorPickerButton
## column -> { "slider": HSlider, "value": Label, "box": Container, "range": [min, max] }
var _rows := {}
## Set while the panel writes slider positions itself, so those don't come back as edits.
var _syncing := false


func _ready() -> void:
	layer = 60
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	panel.offset_left = -WIDTH - 4
	panel.offset_right = -4
	panel.offset_top = 4
	panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	panel.self_modulate = Color(1, 1, 1, 0.85)
	add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 1)
	panel.add_child(box)

	var head := HBoxContainer.new()
	box.add_child(head)
	_title = _label(head, "")
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_fold = _button(head, "▾")
	_fold.pressed.connect(_on_fold)

	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 0)
	box.add_child(_body)
	_sliders = VBoxContainer.new()
	_sliders.add_theme_constant_override("separation", 0)
	_body.add_child(_sliders)
	var foot := HBoxContainer.new()
	_body.add_child(foot)
	_label(foot, "colour")
	_color = ColorPickerButton.new()
	_color.edit_alpha = false
	_color.focus_mode = Control.FOCUS_NONE
	_color.custom_minimum_size = Vector2(24, 10)
	_color.color_changed.connect(_on_color)
	foot.add_child(_color)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	foot.add_child(spacer)
	_button(foot, "Reset").pressed.connect(func(): reset_requested.emit(_id))


## Shows a material's parameters. row: its row in the material table (read, never written).
func show_material(id: int, row: Dictionary) -> void:
	if id != _id or row["class"] != _row.get("class", ""):
		_build_sliders(row["class"])
	_id = id
	_row = row
	_title.text = row.name
	_title.modulate = Color.html(row.color).lightened(0.3)
	_syncing = true
	_color.color = Color.html(row.color)
	for column in _rows:
		var r: Dictionary = _rows[column]
		r.slider.value = to_slider(float(row[column]), r.range, column in CURVED)
		r.value.text = _format(float(row[column]))
	_syncing = false
	# A region is read only below stiffness 1 (ADR 0005).
	if _rows.has("region"):
		_rows.region.box.visible = float(row.stiffness) < 1.0


func _build_sliders(cls: String) -> void:
	for c in _sliders.get_children():
		c.queue_free()
	_rows.clear()
	for column in MaterialTable.PANEL_FIELDS.get(cls, []):
		var r := MaterialTable.range_of(column, cls)
		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", -2)
		_sliders.add_child(box)
		var line := HBoxContainer.new()
		box.add_child(line)
		var name_label := _label(line, column)
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_label.tooltip_text = "%s to %s" % [_format(r[0]), _format(r[1])]
		name_label.mouse_filter = Control.MOUSE_FILTER_PASS
		var value := _label(line, "")
		var slider := HSlider.new()
		slider.min_value = 0.0
		slider.max_value = 1.0
		slider.step = 1.0 / STEPS
		slider.focus_mode = Control.FOCUS_NONE
		slider.custom_minimum_size = Vector2(WIDTH - 8, 10)
		slider.value_changed.connect(_on_slider.bind(column))
		box.add_child(slider)
		_rows[column] = {"slider": slider, "value": value, "box": box, "range": r}


func _on_slider(s: float, column: String) -> void:
	if _syncing or _id < 0:
		return
	var r: Dictionary = _rows[column]
	var v := from_slider(s, r.range, column in CURVED)
	r.value.text = _format(v)
	if column == "stiffness" and _rows.has("region"):
		_rows.region.box.visible = v < 1.0
	value_changed.emit(_id, column, v)


func _on_color(c: Color) -> void:
	if _syncing or _id < 0:
		return
	_title.modulate = c.lightened(0.3)
	color_changed.emit(_id, c)


func _on_fold() -> void:
	_body.visible = not _body.visible
	_fold.text = "▾" if _body.visible else "▸"


## Value at slider position s (0..1) for a column with range r ([min, max], from
## MaterialTable.range_of): linear, or along the power curve. Both ends map exactly onto the
## range's ends.
static func from_slider(s: float, r: Array, curved: bool) -> float:
	var t := clampf(s, 0.0, 1.0)
	if curved:
		t = pow(t, CURVE_POWER)
	# Three significant digits are plenty for a slider, and keep the shown value exact.
	return clampf(_round3(lerpf(r[0], r[1], t)), r[0], r[1])


## Slider position (0..1) of a value; the inverse of from_slider.
static func to_slider(v: float, r: Array, curved: bool) -> float:
	var t := clampf(inverse_lerp(r[0], r[1], v), 0.0, 1.0)
	return pow(t, 1.0 / CURVE_POWER) if curved else t


static func _round3(v: float) -> float:
	if v == 0.0:
		return 0.0
	var step := pow(10.0, floorf(log(absf(v)) / log(10.0)) - 2.0)
	return snappedf(v, step)


static func _format(v: float) -> String:
	return String.num(_round3(v), 3)


func _label(parent: Container, text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", FONT_SIZE)
	parent.add_child(l)
	return l


func _button(parent: Container, text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", FONT_SIZE)
	parent.add_child(b)
	return b
