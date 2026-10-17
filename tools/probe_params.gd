## Parameter edits for the GPU probes (ADR 0007), through the parameter panel's path: the
## table clamps the value to the validator range and the sim uploads the row while it runs.
##   set=<material>.<column>=<value>[,...]   e.g. set=water.drag=60,sand.friction=0
##                                           (soft_model takes a name: set=jelly.soft_model=regions)
##   setat=N                                 apply at frame N (default: right after setup)
## Prints one PARAM line per edit with the value actually stored.
extends RefCounted


## [[material, column, value], ...] from the command line's set= arguments.
static func parse(args: PackedStringArray) -> Array:
	var sets := []
	for a in args:
		if not a.begins_with("set="):
			continue
		for item in a.substr(4).split(","):
			var mat_rest := item.split(".", true, 1)
			var col_val := mat_rest[1].split("=", true, 1) if mat_rest.size() == 2 else PackedStringArray()
			if col_val.size() != 2:
				print("PARAM bad set item '%s' (want material.column=value)" % item)
				continue
			sets.append([mat_rest[0], col_val[0], col_val[1]])
	return sets


## The frame from setat=N, or 0 for right after setup.
static func frame(args: PackedStringArray) -> int:
	for a in args:
		if a.begins_with("setat="):
			return maxi(0, int(a.substr(6)))
	return 0


## True for the parse() and frame() arguments, so a probe can skip them.
static func is_arg(a: String) -> bool:
	return a.begins_with("set=") or a.begins_with("setat=")


static func apply(table, sim, sets: Array) -> void:
	for s in sets:
		var id: int = table.id_of(s[0])
		if id < 0:
			print("PARAM unknown material '%s'" % s[0])
			continue
		if s[1] == "soft_model":
			var model: String = table.set_soft_model(id, s[2])
			if model == "":
				print("PARAM %s.soft_model: '%s' isn't a soft model of a cluster material" % [s[0], s[2]])
				continue
			sim.update_material(table, id)
			print("PARAM %s.soft_model = %s" % [s[0], model])
			continue
		if table.range_of(s[1], table.materials[id]["class"]).is_empty():
			print("PARAM %s has no column '%s' with a range" % [s[0], s[1]])
			continue
		var asked := float(s[2])
		var v: float = table.set_value(id, s[1], asked)
		sim.update_material(table, id)
		print("PARAM %s.%s = %s%s" % [s[0], s[1], v, "" if v == asked else " (asked %s, clamped)" % asked])
