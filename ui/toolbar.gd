## Bottom toolbar: material buttons, benchmark fills, clear, and the capacity meter.
## Builds itself from the material table, so new materials get a button for free.
## Taps work on phones through the default mouse-from-touch emulation.
extends CanvasLayer

signal material_selected(id: int)
## A benchmark fill: add SimParams.BENCH_BLOCK particles of this material at once.
signal fill_requested(id: int)
signal clear_requested

const FONT_SIZE := 8

var _meter: ProgressBar
var _meter_label: Label
var _material_buttons := {}  # id -> Button


## materials: { id: row } from cpu_ref/material_table.gd. bench_label: e.g. "+10k".
func build(materials: Dictionary, selected: int, bench_label: String) -> void:
	layer = 50
	var bar := HBoxContainer.new()
	bar.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	bar.offset_top = -18
	bar.offset_left = 4
	bar.offset_right = -4
	bar.offset_bottom = -2
	bar.add_theme_constant_override("separation", 3)
	add_child(bar)

	var group := ButtonGroup.new()
	var ids := materials.keys()
	ids.sort()
	for id in ids:
		var b := _button(bar, materials[id].name)
		b.toggle_mode = true
		b.button_group = group
		b.button_pressed = id == selected
		b.modulate = Color.html(materials[id].color).lightened(0.3)
		b.pressed.connect(func(): material_selected.emit(id))
		_material_buttons[id] = b
	for id in ids:
		_button(bar, "%s %s" % [bench_label, materials[id].name]).pressed.connect(func(): fill_requested.emit(id))
	_button(bar, "Clear").pressed.connect(func(): clear_requested.emit())

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(spacer)
	_meter_label = Label.new()
	_meter_label.add_theme_font_size_override("font_size", FONT_SIZE)
	bar.add_child(_meter_label)
	_meter = ProgressBar.new()
	_meter.custom_minimum_size = Vector2(90, 10)
	_meter.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_meter.show_percentage = false
	_meter.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_child(_meter)


func _button(bar: Container, text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", FONT_SIZE)
	bar.add_child(b)
	return b


## Updates the capacity meter. Turns red and says FULL at the cap.
func set_capacity(live: int, cap: int) -> void:
	_meter.max_value = cap
	_meter.value = live
	var full := live >= cap
	_meter_label.text = "%s%d / %d" % ["FULL  " if full else "", live, cap]
	_meter.modulate = Color(1, 0.35, 0.3) if full else Color.WHITE
