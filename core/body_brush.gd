## Body brush (Milestone 3 step 5, ADR 0002 item 17): turns a mouse stroke into bodies.
##
## A stroke is a set of spots on the world's rest-spacing lattice, spot (i, j) at
## ((i + 0.5) x SPACING, (j + 0.5) x SPACING), so strokes painted over each other line up. A
## stroke stops growing at SimParams.BODY_BRUSH_MAX spots. When it ends, the spots that
## already hold a particle are left out (a body never spawns into grains, water or another
## body), then every spot not in a full 2 x 2 square of what is left (so each body is at least
## 2 particles thick), and each piece left, connected on the rest lattice as the eraser's split
## counts it (ParticleStep.body_pieces), becomes one body.
## The pool is read back a few frames before the bodies spawn, so a spot also counts as held
## when a particle will have moved onto it by then (occupied_spots' ahead) or a body not in the
## readback yet will spawn on it (occupy). Without these, strokes drawn while paused, or over a
## falling body, spawned bodies inside each other, which tore them into pieces that hung in
## the air (2026-10-17).
extends RefCounted

const SimParams = preload("res://core/sim_params.gd")
const ParticleStep = preload("res://cpu_ref/particle_step.gd")

## A spot is occupied when a particle is closer to it than this (px): nearer than a contact.
const OCCUPIED_REACH := 0.75 * SimParams.SPACING
## mat_flags: the ALIVE bit (common.glslinc).
const ALIVE := 0x100


static func spot_pos(s: Vector2i) -> Vector2:
	return (Vector2(s) + Vector2(0.5, 0.5)) * SimParams.SPACING


## Adds to stroke (spot -> true) the spots inside the world within radius of the segment from
## a to b, in order along it, stopping at max_spots. Returns false once the stroke is full.
static func paint(stroke: Dictionary, a: Vector2, b: Vector2, radius: float, max_spots := SimParams.BODY_BRUSH_MAX) -> bool:
	var sp := SimParams.SPACING
	var cols := int(SimParams.WORLD_SIZE.x / sp)
	var rows := int(SimParams.WORLD_SIZE.y / sp)
	var lo := ((a.min(b) - Vector2(radius, radius)) / sp - Vector2(0.5, 0.5)).floor()
	var hi := ((a.max(b) + Vector2(radius, radius)) / sp - Vector2(0.5, 0.5)).ceil()
	var ab := b - a
	var len2 := ab.length_squared()
	var new_spots := []  # [distance along the segment, spot]
	for j in range(maxi(0, int(lo.y)), mini(rows - 1, int(hi.y)) + 1):
		for i in range(maxi(0, int(lo.x)), mini(cols - 1, int(hi.x)) + 1):
			var s := Vector2i(i, j)
			if stroke.has(s):
				continue
			var p := spot_pos(s)
			var t := 0.0 if len2 == 0.0 else (p - a).dot(ab) / len2
			if p.distance_squared_to(a + ab * clampf(t, 0.0, 1.0)) <= radius * radius:
				new_spots.append([t, s])
	new_spots.sort_custom(func(x, y): return x[0] < y[0])
	for e in new_spots:
		if stroke.size() >= max_spots:
			return false
		stroke[e[1]] = true
	return stroke.size() < max_spots


## The spots (spot -> true) within OCCUPIED_REACH of a live particle, from the pool as read
## back: pos (cap x vec2) and mat_flags (cap x uint) bytes. With vel (cap x vec2, px/s) and
## ahead (s), also the spots along each particle's path for ahead from the readback: where it
## will be when a body made now spawns.
static func occupied_spots(pos: PackedByteArray, flags: PackedByteArray, vel := PackedByteArray(),
		ahead := 0.0) -> Dictionary:
	var occupied := {}
	var n := mini(pos.size() / 8, flags.size() / 4)
	var moving := ahead > 0.0 and vel.size() >= n * 8
	for i in n:
		if flags.decode_u32(i * 4) & ALIVE == 0:
			continue
		var p := Vector2(pos.decode_float(i * 8), pos.decode_float(i * 8 + 4))
		var to := p
		if moving:
			to += Vector2(vel.decode_float(i * 8), vel.decode_float(i * 8 + 4)) * ahead
		_mark_path(occupied, p, to)
	return occupied


## Adds to occupied the spots of bodies that will spawn at positions (made, but not in the
## readback yet), and below them as far as they fall from rest in ahead (s).
static func occupy(occupied: Dictionary, positions: PackedVector2Array, ahead := 0.0) -> void:
	var drop := Vector2(0.0, 0.5 * SimParams.GRAVITY * ahead * ahead)
	for p in positions:
		_mark_path(occupied, p, p + drop)


## Marks the spots within OCCUPIED_REACH of the segment from a to b, sampled every quarter
## spacing.
static func _mark_path(occupied: Dictionary, a: Vector2, b: Vector2) -> void:
	var sp := SimParams.SPACING
	var steps := ceili(a.distance_to(b) / (0.25 * sp))
	for k in steps + 1:
		var p := a if steps == 0 else a.lerp(b, float(k) / steps)
		var c := Vector2i((p / sp - Vector2(0.5, 0.5)).floor())
		for dy in 2:
			for dx in 2:
				var s := c + Vector2i(dx, dy)
				if spot_pos(s).distance_squared_to(p) < OCCUPIED_REACH * OCCUPIED_REACH:
					occupied[s] = true


## The bodies a finished stroke makes: one PackedVector2Array of spawn positions per piece,
## largest first.
static func bodies(stroke: Dictionary, occupied: Dictionary) -> Array:
	var free := {}
	for s in stroke:
		if not occupied.has(s):
			free[s] = true
	var kept := PackedVector2Array()
	for s in free:
		if _in_full_square(free, s):
			kept.append(spot_pos(s))
	var out := []
	for piece in ParticleStep.body_pieces(kept):
		var positions := PackedVector2Array()
		for k in piece:
			positions.append(kept[k])
		out.append(positions)
	return out


## Whether s is one corner of a 2 x 2 square of spots all in free.
static func _in_full_square(free: Dictionary, s: Vector2i) -> bool:
	for oy in [-1, 0]:
		for ox in [-1, 0]:
			var c := s + Vector2i(ox, oy)
			if free.has(c) and free.has(c + Vector2i(1, 0)) and free.has(c + Vector2i(0, 1)) \
					and free.has(c + Vector2i(1, 1)):
				return true
	return false
