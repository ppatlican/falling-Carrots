## Material table loader, validator and GPU packer (spec section 3).
## The table lives in res://data/materials.json as { "materials": [ row, ... ] }.
## Milestone 2 validates rows and fields. Missing-texture and reaction checks
## land with textures (Milestone 5) and reactions (Milestone 7).
##
## Usage:
##   var table = MaterialTable.new()
##   var problems = table.load_file()   # loads and validates; empty means OK
##   var bytes = table.pack_gpu()       # MAX_MATERIALS * GPU_STRIDE bytes
##
## The parameter panel (ADR 0007) edits rows while the sim runs: set_value() clamps a column
## to its validator range (range_of), pack_row() packs the one row to upload, reset() puts back
## the row as loaded.
extends RefCounted

const DEFAULT_PATH := "res://data/materials.json"
## Hard cap from the spec. IDs are 0..MAX_MATERIALS-1 and index the GPU table.
const MAX_MATERIALS := 64
## Class order defines the class number the shaders see (common.glslinc CLASS_*).
const CLASSES := ["liquid", "powder", "cluster", "gas", "static"]

## Required numeric columns. Each is [name, min, max]. The ranges of the parameter panel's
## columns are its sliders' ends; each end was checked on the GPU probe (ADR 0001 decision 4,
## ADR 0007).
const NUMBER_FIELDS := [
	# A jelly at 0.01 under a carrot stayed squashed flat; at 100 a box sank through a sand bed
	# to the floor. Steel, the densest v1 material, is ~8.
	["density", 0.1, 10.0],
	["friction", 0.0, 1.0],
	["viscosity", 0.0, 1.0],
	# per second: v *= exp(-drag * dt). Falling stops at GRAVITY / drag: 80 px/s at 5. At 60
	# water hung in the air at 7 px/s; at 10, 300 grains of a 50k sand fill still slid after
	# 50 s, where at 5 they died down (ADR 0007).
	["drag", 0.0, 5.0],
	# Stickiness (ADR 0011): a pair's pull at 1 is SimParams.STICK_G x gravity, split by mass.
	#   cohesion: between particles of one material (in no body, or in different bodies).
	#   adhesion: between different materials (the larger of the two) and toward the walls.
	["cohesion", 0.0, 1.0],
	["adhesion", 0.0, 1.0],
	["wind_coupling", 0.0, 10.0],
	["stiffness", 0.0, 1.0],
	["conductivity", 0.0, 100.0],
	["heat_capacity", 0.01, 100.0],
	["lifetime", 0.0, 1000.0],
]
## Required temperature columns: a number, or null for "never".
const TEMP_FIELDS := ["ignition_temp", "boil_temp", "melt_temp"]
## Cluster-only columns, required on cluster rows: [name, min, max].
##   region: a soft body's region radius in spacings (ADR 0005): each member is shape-matched
##   with the members whose rest offsets lie within it. 1.5 takes its 8 lattice neighbours (the
##   floppiest), 2.0 (H) also the 4 two spacings out. Read only at stiffness < 1.
##   plasticity: how much of a soft body's deformation past the yield it keeps, per 1/60 s (ADR
##   0012): 0 springs back (jelly), 1 keeps all of it at once (dough). Read only at stiffness < 1.
const CLUSTER_FIELDS := [
	["region", 1.5, 2.0],
	["plasticity", 0.0, 1.0],
]
## How a soft body (cluster, stiffness < 1) keeps its shape: the optional cluster column
## `soft_model`, one of these names; a row without it is "regions". Its index goes to the GPU
## (Material.info.y) and to the CPU reference (materials[id].soft_model).
##   regions: regional shape matching (ADR 0005).
##   joints: pair joints between region pairs, equal and opposite (ADR 0016, an experiment).
const SOFT_MODELS := ["regions", "joints"]
## Narrower ranges of NUMBER_FIELDS columns for one class: { class: [[name, min, max], ...] }.
## Each end was checked on the GPU probe (ADR 0001 decision 4, ADR 0007).
##   liquid drag: below 0.1 a pool never comes to rest (gpu_probe water: at 0, 11 px/s of
##   churn after 40 s; at 0.05, still 3 px/s).
##   cluster drag: a soft body with no friction and drag under 0.5 jiggles for good (body_probe
##   wobble, fold: 7-22 px/s at the end at drag 0-0.3, 0.4 px/s at 0.5).
##   cluster stiffness: same-body particles don't push on each other, so a body at stiffness 0
##   collapses onto one point (ADR 0002); below 0.2 a jelly ends as a puddle that doesn't spring
##   back (body_probe wobble, squash) and its members sink into a sand bed.
##   liquid density: at most 4 to 1 against water either way, as FleX's two-phase liquid
##   (ADR 0010).
const CLASS_RANGES := {
	"liquid": [["density", 0.5, 2.0], ["drag", 0.1, 5.0]],
	"cluster": [["drag", 0.5, 5.0], ["stiffness", 0.2, 1.0]],
}
## Columns the parameter panel shows, per class, in display order (ADR 0007; liquid density,
## ADR 0010; cohesion and adhesion, ADR 0011). Nothing reads the heat, wind and lifetime columns, so they have no slider.
const PANEL_FIELDS := {
	"liquid": ["density", "viscosity", "drag", "cohesion", "adhesion"],
	"powder": ["density", "friction", "drag", "cohesion", "adhesion"],
	"cluster": ["density", "friction", "drag", "stiffness", "region", "plasticity", "cohesion", "adhesion"],
	"gas": [],
	"static": [],
}

## GPU layout: one std430 struct of 5 vec4s per material (see common.glslinc Material).
##   vec4  color                                        offset 0
##   vec4  density, friction, viscosity, drag           offset 16
##   vec4  wind_coupling, stiffness, conductivity, heat_capacity  offset 32
##   uvec4 class, soft_model (SOFT_MODELS index), 0, 0  offset 48
##   vec4  region, cohesion, adhesion, plasticity (region and plasticity 0 for non-clusters)  offset 64
const GPU_STRIDE := 80

## Rows keyed by material id (int). Each row is the Dictionary from the file.
var materials := {}
var _rows: Array = []
## Rows as loaded, keyed by id, for reset().
var _loaded := {}


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
	var problems := validate()
	_loaded.clear()
	for id in materials:
		_loaded[id] = materials[id].duplicate(true)
	return problems


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
	for nf in NUMBER_FIELDS:
		var v = row.get(nf[0])
		var f := [nf[0]] + range_of(nf[0], str(row.get("class")))
		if not _is_number(v):
			p.append("%s: '%s' must be a number" % [label, f[0]])
		elif float(v) < f[1] or float(v) > f[2]:
			p.append("%s: '%s'=%s out of range [%s, %s]" % [label, f[0], v, f[1], f[2]])
	if row.get("class") == "cluster":
		for f in CLUSTER_FIELDS:
			var v = row.get(f[0])
			if not _is_number(v):
				p.append("%s: '%s' must be a number for a cluster material" % [label, f[0]])
			elif float(v) < f[1] or float(v) > f[2]:
				p.append("%s: '%s'=%s out of range [%s, %s]" % [label, f[0], v, f[1], f[2]])
	if row.has("soft_model"):
		if row.get("class") != "cluster":
			p.append("%s: 'soft_model' is only for cluster materials" % label)
		elif not row.get("soft_model") in SOFT_MODELS:
			p.append("%s: unknown soft_model '%s' (known: %s)" % [label, row.get("soft_model"), ", ".join(SOFT_MODELS)])
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


## SOFT_MODELS index of a material id: 0 (regions) for a row without the column.
func soft_model_of(id: int) -> int:
	return maxi(0, SOFT_MODELS.find(materials[id].get("soft_model", "regions")))


## Sets a loaded cluster material's soft_model (a SOFT_MODELS name, or its index as text, for
## the probes' set=jelly.soft_model=joints). Returns the name stored, or "" if it isn't one.
## The caller uploads the row (ParticleSim.update_material).
func set_soft_model(id: int, model: String) -> String:
	var model_name := model
	if model.is_valid_int() and int(model) >= 0 and int(model) < SOFT_MODELS.size():
		model_name = SOFT_MODELS[int(model)]
	if materials[id]["class"] != "cluster" or not model_name in SOFT_MODELS:
		return ""
	materials[id].soft_model = model_name
	return model_name


## The validator's [min, max] for a column on rows of a class ("liquid", "cluster", ...), as
## 64-bit floats (a Vector2 would round 0.01 below the validator's minimum): CLASS_RANGES,
## else CLUSTER_FIELDS, else NUMBER_FIELDS. Columns in none of them give [].
static func range_of(column: String, cls: String) -> Array:
	for f in CLASS_RANGES.get(cls, []):
		if f[0] == column:
			return [float(f[1]), float(f[2])]
	if cls == "cluster":
		for f in CLUSTER_FIELDS:
			if f[0] == column:
				return [float(f[1]), float(f[2])]
	for f in NUMBER_FIELDS:
		if f[0] == column:
			return [float(f[1]), float(f[2])]
	return []


## Sets a numeric column of a loaded material, clamped to range_of. Returns the value stored.
## The caller uploads the row (ParticleSim.update_material).
func set_value(id: int, column: String, value: float) -> float:
	var row: Dictionary = materials[id]
	var r := range_of(column, row["class"])
	assert(not r.is_empty(), "no range for column '%s'" % column)
	var v := clampf(value, r[0], r[1])
	row[column] = v
	return v


## Sets a loaded material's colour (the renderer ignores alpha, so it is dropped).
func set_color(id: int, color: Color) -> void:
	materials[id].color = "#" + color.to_html(false)


## Puts a material's row back as it was loaded.
func reset(id: int) -> void:
	materials[id] = _loaded[id].duplicate(true)


## Packs one material into its GPU_STRIDE bytes (the Material struct in common.glslinc).
func pack_row(id: int) -> PackedByteArray:
	var row: Dictionary = materials[id]
	var b := PackedByteArray()
	b.resize(GPU_STRIDE)
	var c := Color.html(row.color)
	var floats := [c.r, c.g, c.b, c.a,
			row.density, row.friction, row.viscosity, row.drag,
			row.wind_coupling, row.stiffness, row.conductivity, row.heat_capacity]
	for k in floats.size():
		b.encode_float(k * 4, floats[k])
	b.encode_u32(48, class_of(id))
	b.encode_u32(52, soft_model_of(id))
	b.encode_float(64, float(row.get("region", 0.0)))
	b.encode_float(68, float(row.cohesion))
	b.encode_float(72, float(row.adhesion))
	b.encode_float(76, float(row.get("plasticity", 0.0)))
	return b


## Packs every material into the GPU table (unused ids stay zero).
func pack_gpu() -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(MAX_MATERIALS * GPU_STRIDE)
	for id in materials:
		var row := pack_row(id)
		for k in GPU_STRIDE:
			b[id * GPU_STRIDE + k] = row[k]
	return b
