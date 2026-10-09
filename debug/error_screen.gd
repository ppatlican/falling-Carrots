## Full-screen fatal error message (e.g. no RenderingDevice, shader compile failure).
## Hidden until show_error() is called.
extends CanvasLayer

var _label: Label


func _ready() -> void:
	layer = 200
	visible = false
	var bg := ColorRect.new()
	bg.color = Color(0.12, 0.02, 0.02)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	_label = Label.new()
	_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_label.offset_left = 24
	_label.offset_right = -24
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.add_theme_font_size_override("font_size", 10)
	add_child(_label)


func show_error(message: String) -> void:
	push_error(message)
	_label.text = "Cannot start\n\n" + message
	visible = true
