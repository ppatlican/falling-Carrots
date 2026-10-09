## Material table: the shipped table is valid, the validator catches bad rows,
## and the GPU packing matches the Material struct in common.glslinc.
extends "res://tests/test_case.gd"

const MaterialTable = preload("res://cpu_ref/material_table.gd")


func test_shipped_table_is_valid() -> void:
	var table = MaterialTable.new()
	var problems: PackedStringArray = table.load_file()
	expect(problems.is_empty(), "materials.json problems: %s" % "; ".join(problems))
	expect(table.id_of("sand") >= 0, "sand exists")
	expect(table.id_of("water") >= 0, "water exists")
	expect_eq(table.class_of(table.id_of("sand")), MaterialTable.CLASSES.find("powder"), "sand class")
	expect_eq(table.class_of(table.id_of("water")), MaterialTable.CLASSES.find("liquid"), "water class")


func test_validator_catches_bad_rows() -> void:
	var good := _sand_row()
	var cases := {
		"duplicate id": [good, _with(_sand_row(), {"name": "sand2"})],
		"duplicate name": [good, _with(_sand_row(), {"id": 1})],
		"unknown class": [_with(good, {"class": "plasma"})],
		"'id' must be": [_with(good, {"id": 64})],
		"'density' must be": [_with(good, {"density": "heavy"})],
		"out of range": [_with(good, {"friction": 2.0})],
		"'color' must be": [_with(good, {"color": "sandy"})],
		"'boil_temp' must be": [_without(good, "boil_temp")],
		"the cap is": _many_rows(MaterialTable.MAX_MATERIALS + 1),
	}
	for expected in cases:
		var problems: PackedStringArray = MaterialTable.new().load_rows(cases[expected])
		var found := false
		for p in problems:
			found = found or p.contains(expected)
		expect(found, "expected a problem containing \"%s\", got %s" % [expected, problems])


func test_gpu_packing_layout() -> void:
	var table = MaterialTable.new()
	table.load_rows([_with(_sand_row(), {"id": 3, "density": 2.5, "drag": 0.25})])
	var b: PackedByteArray = table.pack_gpu()
	expect_eq(b.size(), MaterialTable.MAX_MATERIALS * MaterialTable.GPU_STRIDE, "table size")
	var o := 3 * MaterialTable.GPU_STRIDE
	expect_eq(b.decode_float(o + 16), 2.5, "density at offset 16")
	expect_eq(b.decode_float(o + 28), 0.25, "drag at offset 28")
	expect_eq(b.decode_u32(o + 48), MaterialTable.CLASSES.find("powder"), "class at offset 48")
	expect_eq(b.decode_float(0 + 16), 0.0, "unused id 0 stays zero")


func _sand_row() -> Dictionary:
	var table = MaterialTable.new()
	table.load_file()
	return table.materials[table.id_of("sand")].duplicate(true)


func _with(row: Dictionary, changes: Dictionary) -> Dictionary:
	var r := row.duplicate(true)
	r.merge(changes, true)
	return r


func _without(row: Dictionary, key: String) -> Dictionary:
	var r := row.duplicate(true)
	r.erase(key)
	return r


func _many_rows(count: int) -> Array:
	var rows := []
	for i in count:
		rows.append(_with(_sand_row(), {"id": i % MaterialTable.MAX_MATERIALS, "name": "m%d" % i}))
	return rows
