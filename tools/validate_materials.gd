## Material table validator. Run after editing data/materials.json:
##   godot --headless --path <project> --script res://tools/validate_materials.gd
## Prints every problem. Exit code 0 when the table is valid, 1 otherwise.
extends SceneTree

const MaterialTable = preload("res://cpu_ref/material_table.gd")


func _initialize() -> void:
	var table = MaterialTable.new()
	var problems: PackedStringArray = table.load_file()
	for p in problems:
		print("PROBLEM " + p)
	if problems.is_empty():
		var names := PackedStringArray()
		for id in table.materials:
			names.append("%d %s (%s)" % [id, table.materials[id].name, table.materials[id]["class"]])
		print("materials.json OK: %d materials: %s" % [names.size(), ", ".join(names)])
	quit(0 if problems.is_empty() else 1)
