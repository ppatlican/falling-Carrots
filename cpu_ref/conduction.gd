## CPU reference: heat conduction between neighbors (spec section 2.5).
## Conductivity and heat capacity come from the material table.
## STUB (Milestone 1). Implemented in Milestone 7.
extends RefCounted


## Returns new temperatures after one explicit conduction step.
## temps[i] is the temperature of node i; links are [i, j, conductivity] pairs.
## The stub returns the input unchanged (no heat moves).
func step(temps: PackedFloat32Array, _links: Array, _heat_capacity: PackedFloat32Array, _dt: float) -> PackedFloat32Array:
	return temps.duplicate()
