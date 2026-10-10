## Material table loader, validator and GPU packer (spec section 3).
## The table lives in res://data/materials.json as { "materials": [ row, ... ] }.
## Milestone 2 validates rows and fields. Missing-texture and reaction checks
## land with textures (Milestone 5) and reactions (Milestone 7).
##
## Usage:
##   var table = MaterialTable.new()
##   var problems = table.load_file()   # loads and validates; empty means OK
##   var bytes = table.pack_gpu()       # MAX_MATERIALS * GPU_STRIDE bytes
extends RefCounted

const DEFAULT_PATH := "res://data/materials.json"
## Hard cap from the spec. IDs are 0..MAX_MATERIALS-1 and index the GPU table.
const MAX_MATERIALS := 64
## Class order defines the class number the shaders see (common.glslinc CLASS_*).
const CLASSES := ["liquid", "powder", "cluster", "gas", "static"]

## Required numeric columns. Each is [name, min, max].
const NUMBER_FIELDS := [
	["density", 0.01, 100.0],
	["friction", 0.0, 1.0],
	["viscosity", 0.0, 1.0],
	["drag", 0.0, 60.0],  # per second: v *= exp(-drag * dt)
	["wind_coupling", 0.0, 10.0],
	["stiffness", 0.0, 1.0],
	["conductivity", 0.0, 100.0],
	["heat_capacity", 0.01, 100.0],
	["lifetime", 0.0, 1000.0],
]
## Required temperature columns: a number, or null for "never".
const TEMP_FIELDS := ["ignition_temp", "boil_temp", "melt_temp"]

## GPU layout: one std430 struct of 4 vec4s per material (see common.glslinc Material).
##   vec4  color                                        offset 0
##   vec4  density, friction, viscosity, drag           offset 16
##   vec4  wind_coupling, stiffness, conductivity, heat_capacity  offset 32
##   uvec4 class, 0, 0, 0                               offset 48
const GPU_STRIDE := 64

## Rows keyed by material id (int). Each row is the Dictionary from the file.
var materials := {}
var _rows: Array = []


## Loads and validates a table file. Returns a list of problems (empty means valid).
func load_file(path: String = DEFAULT_PATH) -> PackedStringArray:
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		return PackedStringArray(["cannot read %s" % path])
	var data = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY or typeof(data.get("materials")) != TYPE_ARRAY:
		return PackedStringArray(["%s must be a JSON object with a 'materials' array" % path])
	return load_rows(data.materials)


## Takes the table rows (one Dictionary per material) and validates them.
## Valid rows are kept in `materials` even when others have problems.
func load_rows(rows: Array) -> PackedStringArray:
	_rows = rows
	materials.clear()
	return validate()


## Checks table integrity. Returns a list of problems (empty means valid).
func validate() -> PackedStringArray:
	var problems := PackedStringArray()
	if _rows.size() > MAX_MATERIALS:
		problems.append("%d materials, the cap is %d" % [_rows.size(), MAX_MATERIALS])
	var names := {}
	for i in _rows.size():
		var row = _rows[i]
		if typeof(row) != TYPE_DICTIONARY:
			problems.append("row %d is not an object" % i)
			continue
		var label := "row %d (%s)" % [i, row.get("name", "?")]
		var row_problems := _check_row(row, label)
		if row_problems.is_empty():
			var id := int(row.id)
			if materials.has(id):
				row_problems.append("%s: duplicate id %d" % [label, id])
			if names.has(row.name):
				row_problems.append("%s: duplicate name '%s'" % [label, row.name])
		if row_problems.is_empty():
			materials[int(row.id)] = row
			names[row.name] = true
		problems.append_array(row_problems)
	return problems


func _check_row(row: Dictionary, label: String) -> PackedStringArray:
	var p := PackedStringArray()
	var id = row.get("id")
	if not _is_whole(id) or int(id) < 0 or int(id) >= MAX_MATERIALS:
		p.append("%s: 'id' must be a whole number 0..%d" % [label, MAX_MATERIALS - 1])
	if typeof(row.get("name")) != TYPE_STRING or row.get("name") == "":
		p.append("%s: 'name' must be a non-empty string" % label)
	if not row.get("class") in CLASSES:
		p.append("%s: unknown class '%s' (known: %s)" % [label, row.get("class"), ", ".join(CLASSES)])
	var color = row.get("color")
	if typeof(color) != TYPE_STRING or not Color.html_is_valid(color):
		p.append("%s: 'color' must be an HTML color like \"#d9b26b\"" % label)
	for f in NUMBER_FIELDS:
		var v = row.get(f[0])
		if not _is_number(v):
			p.append("%s: '%s' must be a number" % [label, f[0]])
		elif float(v) < f[1] or float(v) > f[2]:
			p.append("%s: '%s'=%s out of range [%s, %s]" % [label, f[0], v, f[1], f[2]])
	for f in TEMP_FIELDS:
		if not row.has(f) or (row[f] != null and not _is_number(row[f])):
			p.append("%s: '%s' must be a number or null" % [label, f])
	if typeof(row.get("tags")) != TYPE_ARRAY:
		p.append("%s: 'tags' must be an array" % label)
	return p


static func _is_number(v) -> bool:
	return typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT


static func _is_whole(v) -> bool:
	return _is_number(v) and float(v) == floorf(float(v))


## Returns the material id with this name, or -1.
func id_of(material_name: String) -> int:
	for id in materials:
		if materials[id].name == material_name:
			return id
	return -1


## Class number (index into CLASSES) of a material id.
func class_of(id: int) -> int:
	return CLASSES.find(materials[id]["class"])


## Packs every material into the GPU table (unused ids stay zero).
func pack_gpu() -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(MAX_MATERIALS * GPU_STRIDE)
	for id in materials:
		var row: Dictionary = materials[id]
		var o: int = id * GPU_STRIDE
		var c := Color.html(row.color)
		var floats := [c.r, c.g, c.b, c.a,
				row.density, row.friction, row.viscosity, row.drag,
				row.wind_coupling, row.stiffness, row.conductivity, row.heat_capacity]
		for k in floats.size():
			b.encode_float(o + k * 4, floats[k])
		b.encode_u32(o + 48, class_of(id))
	return b
