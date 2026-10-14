## Draws the body brush's stroke while it is painted (core/body_brush.gd): one spot per
## rest-spacing lattice point, in the material's colour, see-through until it becomes bodies.
extends Node2D

const BodyBrush = preload("res://core/body_brush.gd")
const SimParams = preload("res://core/sim_params.gd")

var spots: Dictionary = {}
var color := Color.WHITE


func show_stroke(stroke: Dictionary, material_color: Color) -> void:
	spots = stroke
	color = Color(material_color, 0.6)
	queue_redraw()


func _draw() -> void:
	var half := Vector2.ONE * SimParams.SPACING * 0.5
	for s in spots:
		draw_rect(Rect2(BodyBrush.spot_pos(s) - half, half * 2.0), color)
