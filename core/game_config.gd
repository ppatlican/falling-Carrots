## Tunables from res://config.json, with safe defaults and clamping.
## Usage: const GameConfig = preload("res://core/game_config.gd")
##        var cfg = GameConfig.load_from_file()
extends RefCounted

const DEFAULT_PATH := "res://config.json"

## Hard cap on live particles (pool size). PC can go higher than phones.
var particle_cap: int = 50000
## PBD solver iterations per frame (spec 2.6, step 4).
var solver_iterations: int = 4
## Simulation substeps per frame (spec 2.6): each runs predict to velocity with dt / substeps.
var substeps: int = 2
## Problems found while loading. Empty means the file was clean.
var errors: PackedStringArray = []


static func load_from_file(path: String = DEFAULT_PATH):
	var cfg = new()
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		cfg.errors.append("cannot read %s, using defaults" % path)
		return cfg
	var data = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY:
		cfg.errors.append("%s is not a JSON object, using defaults" % path)
		return cfg
	cfg.apply(data)
	return cfg


## Applies values from a parsed dictionary. Bad values are reported and clamped.
func apply(data: Dictionary) -> void:
	particle_cap = _read_int(data, "particle_cap", particle_cap, 1024, 4_000_000)
	solver_iterations = _read_int(data, "solver_iterations", solver_iterations, 1, 16)
	substeps = _read_int(data, "substeps", substeps, 1, 8)


func _read_int(data: Dictionary, key: String, fallback: int, lo: int, hi: int) -> int:
	if not data.has(key):
		errors.append("missing '%s', using %d" % [key, fallback])
		return fallback
	var v = data[key]
	# JSON numbers arrive as float; reject fractions and non-numbers.
	if (typeof(v) != TYPE_FLOAT and typeof(v) != TYPE_INT) or float(v) != floorf(float(v)):
		errors.append("'%s' must be a whole number, using %d" % [key, fallback])
		return fallback
	var i := int(v)
	if i < lo or i > hi:
		errors.append("'%s'=%d out of range [%d, %d], clamped" % [key, i, lo, hi])
	return clampi(i, lo, hi)
