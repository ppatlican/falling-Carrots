## CPU reference: material table loader and validator (spec section 3).
## STUB (Milestone 1). The loader lands in Milestone 2; the full validator
## (duplicate IDs, unknown classes, missing textures, cap overflow, reactions
## referencing missing materials) in Milestone 9.
extends RefCounted

## Hard cap from the spec.
const MAX_MATERIALS := 64
const CLASSES := ["liquid", "powder", "cluster", "gas", "static"]

## Rows keyed by material id. Each row is a Dictionary with the spec's columns.
var materials := {}


## Parses table data (one Dictionary per row). Returns a list of problems.
func load_rows(_rows: Array) -> PackedStringArray:
	return PackedStringArray(["material_table.load_rows: not implemented (Milestone 2)"])


## Checks table integrity. Returns a list of problems (empty means valid).
func validate() -> PackedStringArray:
	return PackedStringArray(["material_table.validate: not implemented (Milestone 9)"])
