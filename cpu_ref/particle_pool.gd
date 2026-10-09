## CPU mirror of the GPU particle pool's free-list (gpu/shaders/sim/brush_*.glsl).
## The free-list is a stack of free slot indices plus free_count.
##   spawn: thread t takes stack[free_count - 1 - t] while t < free_count,
##          then free_count -= min(requested, free_count). The pool can't overfill.
##   erase: each erased particle pushes its slot at stack[free_count++].
## Nothing is ever deleted except by erase.
extends RefCounted

var cap: int
var free_stack := PackedInt32Array()
var free_count := 0
var alive := PackedByteArray()


func _init(capacity: int) -> void:
	cap = capacity
	free_stack = initial_stack(capacity)
	free_count = capacity
	alive.resize(capacity)
	alive.fill(0)


## Initial stack contents, so slot 0 is handed out first. The GPU uses the same bytes.
static func initial_stack(capacity: int) -> PackedInt32Array:
	var s := PackedInt32Array()
	s.resize(capacity)
	for i in capacity:
		s[i] = capacity - 1 - i
	return s


func live_count() -> int:
	return cap - free_count


## Adds up to `requested` particles. Returns the slots used.
func spawn(requested: int) -> PackedInt32Array:
	var n := mini(requested, free_count)
	var slots := PackedInt32Array()
	for t in n:
		var slot := free_stack[free_count - 1 - t]
		alive[slot] = 1
		slots.append(slot)
	free_count -= n
	return slots


## Removes the given live slots and returns them to the free-list.
func erase(slots: PackedInt32Array) -> void:
	for slot in slots:
		if alive[slot] == 1:
			alive[slot] = 0
			free_stack[free_count] = slot
			free_count += 1
