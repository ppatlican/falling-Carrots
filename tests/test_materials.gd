## Material table: the shipped table is valid, the validator catches bad rows,
## and the GPU packing matches the Material struct in common.glslinc.
extends "res://tests/test_case.gd"

## Test groups for run_tests.gd (-- @name); which to run for a change: docs/agents/testing.md.
const FILE_GROUPS := ["setup", "quick"]

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
		"'stiffness'=0.0 out of range": [_with(good, {"class": "cluster", "stiffness": 0.0, "region": 1.5, "plasticity": 0.0})],
		"'region' must be a number for a cluster": [_with(good, {"class": "cluster", "stiffness": 0.5, "plasticity": 0.0})],
		"'region'=1.2 out of range": [_with(good, {"class": "cluster", "stiffness": 0.5, "region": 1.2, "plasticity": 0.0})],
		"'region'=2.5 out of range": [_with(good, {"class": "cluster", "stiffness": 0.5, "region": 2.5, "plasticity": 0.0})],
		"'plasticity' must be a number for a cluster": [_with(good, {"class": "cluster", "stiffness": 0.5, "region": 1.5})],
		"'plasticity'=1.5 out of range": [_with(good, {"class": "cluster", "stiffness": 0.5, "region": 1.5, "plasticity": 1.5})],
	}
	for expected in cases:
		var problems: PackedStringArray = MaterialTable.new().load_rows(cases[expected])
		var found := false
		for p in problems:
			found = found or p.contains(expected)
		expect(found, "expected a problem containing \"%s\", got %s" % [expected, problems])


func test_cluster_stiffness_floor() -> void:
	var problems: PackedStringArray = MaterialTable.new().load_rows(
			[_with(_sand_row(), {"class": "cluster", "stiffness": 0.2, "region": 1.5, "plasticity": 0.0})])
	expect(problems.is_empty(), "cluster at stiffness 0.2: %s" % "; ".join(problems))
	problems = MaterialTable.new().load_rows(
			[_with(_sand_row(), {"class": "cluster", "stiffness": 0.1, "region": 1.5, "plasticity": 0.0})])
	expect(not problems.is_empty(), "a jelly at stiffness 0.1 doesn't spring back (ADR 0007)")


func test_class_ranges() -> void:
	var water := _with(_sand_row(), {"class": "liquid", "name": "w", "drag": 0.05})
	var problems: PackedStringArray = MaterialTable.new().load_rows([water])
	expect(not problems.is_empty() and problems[0].contains("'drag'=0.05 out of range"),
			"a liquid below drag 0.1 churns (ADR 0007): %s" % "; ".join(problems))
	problems = MaterialTable.new().load_rows([_with(_sand_row(), {"drag": 0.0})])
	expect(problems.is_empty(), "a powder may have no drag: %s" % "; ".join(problems))
	expect_eq(MaterialTable.range_of("drag", "liquid"), [0.1, 5.0], "liquid drag range")
	expect_eq(MaterialTable.range_of("drag", "powder"), [0.0, 5.0], "powder drag range")
	expect_eq(MaterialTable.range_of("drag", "cluster"), [0.5, 5.0], "cluster drag range")
	expect_eq(MaterialTable.range_of("density", "cluster"), [0.1, 10.0], "density range")
	expect_eq(MaterialTable.range_of("stiffness", "cluster"), [0.2, 1.0], "cluster stiffness range")
	expect_eq(MaterialTable.range_of("region", "cluster"), [1.5, 2.0], "region range")
	expect_eq(MaterialTable.range_of("region", "powder"), [], "no region outside clusters")
	expect_eq(MaterialTable.range_of("plasticity", "cluster"), [0.0, 1.0], "plasticity range (ADR 0012)")
	expect_eq(MaterialTable.range_of("plasticity", "liquid"), [], "no plasticity outside clusters")
	for cls in ["liquid", "powder", "cluster"]:
		expect_eq(MaterialTable.range_of("cohesion", cls), [0.0, 1.0], "%s cohesion range" % cls)
		expect_eq(MaterialTable.range_of("adhesion", cls), [0.0, 1.0], "%s adhesion range" % cls)


func test_gpu_packing_layout() -> void:
	var table = MaterialTable.new()
	table.load_rows([_with(_sand_row(), {"id": 3, "density": 2.5, "drag": 0.25})])
	var b: PackedByteArray = table.pack_gpu()
	expect_eq(b.size(), MaterialTable.MAX_MATERIALS * MaterialTable.GPU_STRIDE, "table size")
	var o := 3 * MaterialTable.GPU_STRIDE
	expect_eq(b.decode_float(o + 16), 2.5, "density at offset 16")
	expect_eq(b.decode_float(o + 28), 0.25, "drag at offset 28")
	expect_eq(b.decode_u32(o + 48), MaterialTable.CLASSES.find("powder"), "class at offset 48")
	expect_eq(b.decode_float(o + 64), 0.0, "no region for a powder")
	expect_eq(b.decode_float(o + 76), 0.0, "no plasticity for a powder")
	table.load_rows([_with(_sand_row(), {"id": 5, "class": "cluster", "stiffness": 0.3, "region": 1.75, "plasticity": 0.625})])
	expect_eq(table.pack_gpu().decode_float(5 * MaterialTable.GPU_STRIDE + 64), 1.75, "region at offset 64")
	expect_eq(table.pack_gpu().decode_float(5 * MaterialTable.GPU_STRIDE + 76), 0.625, "plasticity at offset 76 (ADR 0012)")
	expect_eq(b.decode_float(0 + 16), 0.0, "unused id 0 stays zero")
	table.load_rows([_with(_sand_row(), {"id": 2, "cohesion": 0.25, "adhesion": 0.75})])
	b = table.pack_gpu()
	expect_eq(b.decode_float(2 * MaterialTable.GPU_STRIDE + 68), 0.25, "cohesion at offset 68 (ADR 0011)")
	expect_eq(b.decode_float(2 * MaterialTable.GPU_STRIDE + 72), 0.75, "adhesion at offset 72")


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
