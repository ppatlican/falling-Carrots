## CPU reference: table-driven reactions (spec section 3, pipeline step 7).
## A rule has a trigger (contact between two materials, or a temperature
## threshold), inputs, outputs, a probability or rate, and an optional heat delta.
## STUB (Milestone 1). Implemented in Milestone 7.
extends RefCounted


## Returns the outcome of applying matching rules to a contact or threshold event,
## e.g. { "outputs": [material ids], "heat_delta": float }, or {} for no reaction.
## rng makes probabilistic rules deterministic in tests.
func evaluate(_rules: Array, _event: Dictionary, _rng: RandomNumberGenerator) -> Dictionary:
	return {}
