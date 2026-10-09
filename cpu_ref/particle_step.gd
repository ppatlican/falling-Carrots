## CPU reference: simplified 2D PBD particle step (spec 2.6 steps 2-5):
## predict positions, solve constraints, update velocities.
## STUB (Milestone 1). Implemented in Milestones 2-3.
extends RefCounted

const GRAVITY := Vector2(0, 98.0)  # placeholder, art pixels / s^2


## Advances particles in place. state holds "pos", "prev_pos" and "vel"
## (PackedVector2Array) and "material" (PackedInt32Array). The stub does nothing.
func step(_state: Dictionary, _dt: float, _iterations: int) -> void:
	pass
