## Parameter panel (ADR 0007): one row re-packs as the whole table packs it, edits stop at the
## validator's ranges, reset puts the loaded row back, the sliders reach both ends of each range,
## and a stiffness edit across 1 turns a material's bodies soft or rigid in ParticleSim.
extends "res://tests/test_case.gd"

## Test groups for run_tests.gd (-- @name); which to run for a change: docs/agents/testing.md.
const FILE_GROUPS := ["setup", "quick"]

const MaterialTable = preload("res://cpu_ref/material_table.gd")
const ParticleSim = preload("res://gpu/particle_sim.gd")
const ParameterPanel = preload("res://ui/parameter_panel.gd")


func _table():
	var table = MaterialTable.new()
	var problems: PackedStringArray = table.load_file()
	expect(problems.is_empty(), "materials.json problems: %s" % "; ".join(problems))
	return table


func test_pack_row_matches_the_table() -> void:
	var table = _table()
	var all: PackedByteArray = table.pack_gpu()
	for id in table.materials:
		var o: int = id * MaterialTable.GPU_STRIDE
		expect_eq(table.pack_row(id), all.slice(o, o + MaterialTable.GPU_STRIDE), "row %d" % id)
	var water: int = table.id_of("water")
	table.set_value(water, "drag", 2.5)
	expect_eq(table.pack_row(water).decode_float(28), 2.5, "an edited drag packs at offset 28")
	expect_eq(table.pack_gpu().decode_float(water * MaterialTable.GPU_STRIDE + 28), 2.5, "and in the table")


func test_every_panel_column_has_a_range_holding_the_shipped_value() -> void:
	var table = _table()
	for cls in MaterialTable.CLASSES:
		expect(MaterialTable.PANEL_FIELDS.has(cls), "panel columns listed for %s" % cls)
		for column in MaterialTable.PANEL_FIELDS.get(cls, []):
			var r := MaterialTable.range_of(column, cls)
			expect(r.size() == 2 and r[1] > r[0], "%s %s has a range, got %s" % [cls, column, r])
	for id in table.materials:
		var row: Dictionary = table.materials[id]
		for column in MaterialTable.PANEL_FIELDS[row["class"]]:
			var r := MaterialTable.range_of(column, row["class"])
			var v := float(row[column])
			expect(v >= r[0] and v <= r[1], "%s %s=%s in %s" % [row.name, column, v, r])


func test_edits_stop_at_the_validator_range() -> void:
	var table = _table()
	for id in table.materials:
		var row: Dictionary = table.materials[id]
		for column in MaterialTable.PANEL_FIELDS[row["class"]]:
			var r := MaterialTable.range_of(column, row["class"])
			expect_eq(table.set_value(id, column, r[0] - 1000.0), r[0], "%s %s below its range" % [row.name, column])
			expect_eq(table.set_value(id, column, r[1] + 1000.0), r[1], "%s %s above its range" % [row.name, column])
	# Every material at the top of every range, then the bottom, is still a valid table.
	for end in [1, 0]:
		for id in table.materials:
			var row: Dictionary = table.materials[id]
			for column in MaterialTable.PANEL_FIELDS[row["class"]]:
				var r := MaterialTable.range_of(column, row["class"])
				table.set_value(id, column, r[1] if end == 1 else r[0])
		var rows := []
		for id in table.materials:
			rows.append(table.materials[id].duplicate(true))
		var problems: PackedStringArray = MaterialTable.new().load_rows(rows)
		expect(problems.is_empty(), "table with every slider at its %s: %s" % ["max" if end == 1 else "min", "; ".join(problems)])


func test_cluster_stiffness_stops_above_zero() -> void:
	var table = _table()
	var jelly: int = table.id_of("jelly")
	expect(table.set_value(jelly, "stiffness", 0.0) > 0.0, "a body at stiffness 0 collapses (ADR 0002)")


func test_colour_and_reset() -> void:
	var table = _table()
	var sand: int = table.id_of("sand")
	var loaded: Dictionary = table.materials[sand].duplicate(true)
	table.set_value(sand, "friction", 0.1)
	table.set_color(sand, Color(0.2, 0.4, 0.6, 0.5))
	expect_eq(table.materials[sand].color, "#336699", "colour stored as #rrggbb")
	expect(Color.html_is_valid(table.materials[sand].color), "a valid colour")
	table.reset(sand)
	expect_eq(table.materials[sand], loaded, "reset puts the loaded row back")
	table.set_value(sand, "friction", 0.2)
	expect_eq(float(loaded.friction), 0.6, "an edit after reset leaves the loaded copy alone")
	table.reset(sand)
	expect_eq(float(table.materials[sand].friction), 0.6, "reset again")


func test_sliders_reach_both_ends_of_each_range() -> void:
	for cls in MaterialTable.PANEL_FIELDS:
		for column in MaterialTable.PANEL_FIELDS[cls]:
			var r := MaterialTable.range_of(column, cls)
			var curved: bool = column in ParameterPanel.CURVED
			expect_eq(ParameterPanel.from_slider(0.0, r, curved), r[0], "%s %s left end" % [cls, column])
			expect_eq(ParameterPanel.from_slider(1.0, r, curved), r[1], "%s %s right end" % [cls, column])
			for v in [r[0], r[1], lerpf(r[0], r[1], 0.37)]:
				var back := ParameterPanel.from_slider(ParameterPanel.to_slider(v, r, curved), r, curved)
				expect(absf(back - v) <= 0.006 * maxf(absf(v), 1e-3) + 1e-6, "%s %s %s round trip, got %s" % [cls, column, v, back])


func test_curved_slider_keeps_shipped_values_off_the_left_end() -> void:
	var table = _table()
	for id in table.materials:
		var row: Dictionary = table.materials[id]
		for column in ParameterPanel.CURVED:
			if column in MaterialTable.PANEL_FIELDS[row["class"]]:
				var s := ParameterPanel.to_slider(float(row[column]), MaterialTable.range_of(column, row["class"]), true)
				expect(s > 0.08, "%s %s=%s sits at %.3f of the track" % [row.name, column, row[column], s])


func test_stiffness_across_one_turns_bodies_soft_or_rigid() -> void:
	var table = _table()
	var carrot: int = table.id_of("carrot")
	var jelly: int = table.id_of("jelly")
	var sim = ParticleSim.new(null, 4000, 3, table, 2, 16)
	var box := PackedVector2Array()
	for y in 3:
		for x in 3:
			box.append(Vector2(100 + 2 * x, 100 + 2 * y))
	expect(sim.make_body(box, carrot) > 0, "carrot body made")
	expect(not sim._any_soft(), "a carrot is rigid")
	table.set_value(carrot, "stiffness", 0.5)
	sim.update_material(table, carrot)
	expect(sim._any_soft(), "carrot at stiffness 0.5: the regions pass runs")
	expect_eq(sim._material_bytes.decode_float(carrot * MaterialTable.GPU_STRIDE + 36), 0.5, "stiffness re-packed")
	table.set_value(carrot, "stiffness", 1.0)
	sim.update_material(table, carrot)
	expect(not sim._any_soft(), "back at 1: rigid again")
	expect(sim.make_body(box, jelly) > 0, "jelly body made")
	expect(sim._any_soft(), "a jelly is soft")
	table.set_value(jelly, "stiffness", 1.0)
	sim.update_material(table, jelly)
	expect(not sim._any_soft(), "jelly at 1 runs no regions pass")
