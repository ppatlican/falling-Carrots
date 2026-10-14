## Body brush (core/body_brush.gd, ADR 0002 item 17): strokes on the rest lattice, the size
## cap, occupied spots left out, at least 2 particles thick, one body per piece.
extends "res://tests/test_case.gd"

const BodyBrush = preload("res://core/body_brush.gd")
const SimParams = preload("res://core/sim_params.gd")

const SP := SimParams.SPACING


func test_stroke_paints_lattice_spots_within_radius() -> void:
	var stroke := {}
	BodyBrush.paint(stroke, Vector2(100, 100), Vector2(140, 100), 6.0)
	var far := 0.0
	for s in stroke:
		var p := BodyBrush.spot_pos(s)
		var q := Vector2(clampf(p.x, 100.0, 140.0), 100.0)
		far = maxf(far, p.distance_to(q))
		expect(is_equal_approx(fposmod(p.x, SP), SP * 0.5) and is_equal_approx(fposmod(p.y, SP), SP * 0.5),
				"spot %s on the lattice" % p)
	expect(far <= 6.0, "every spot within the radius of the segment (farthest %.2f)" % far)
	# A 12 px wide band 40 px long plus round ends: ~6 x 20 + a circle's ~28 spots.
	expect(stroke.size() > 130 and stroke.size() < 170, "a full band painted (%d spots)" % stroke.size())


func test_stroke_stays_in_the_world() -> void:
	var stroke := {}
	BodyBrush.paint(stroke, Vector2(-5, -5), Vector2(-5, -5), 10.0)
	expect(not stroke.is_empty(), "the corner of the world is painted")
	for s in stroke:
		expect(s.x >= 0 and s.y >= 0, "spot %s inside the world" % s)


func test_stroke_stops_at_the_cap() -> void:
	var stroke := {}
	var more: bool = BodyBrush.paint(stroke, Vector2(20, 100), Vector2(600, 100), 10.0, 500)
	expect(not more, "paint reports the stroke full")
	expect_eq(stroke.size(), 500, "the stroke stops at the cap")
	BodyBrush.paint(stroke, Vector2(20, 200), Vector2(600, 200), 10.0, 500)
	expect_eq(stroke.size(), 500, "nothing more is painted once full")
	# Filled along the path: 500 spots of a 20 px band reach ~100 px from the start, not a thin
	# strip along the whole segment.
	var right := 0.0
	for s in stroke:
		right = maxf(right, BodyBrush.spot_pos(s).x)
	expect(right < 140.0, "the cap cuts the stroke along its path (reaches x %.0f)" % right)


func test_a_free_box_becomes_one_body() -> void:
	var bodies: Array = BodyBrush.bodies(_box(10, 4, 6, 3), {})
	expect_eq(bodies.size(), 1, "one body")
	if bodies.size() == 1:
		expect_eq(bodies[0].size(), 18, "with every spot")


func test_thin_parts_are_left_out() -> void:
	# A 6 x 3 box with a 1-spot-wide tail 5 spots long: the tail goes, the box stays.
	var stroke := _box(10, 10, 6, 3)
	for i in 5:
		stroke[Vector2i(16 + i, 11)] = true
	var bodies: Array = BodyBrush.bodies(stroke, {})
	expect_eq(bodies.size(), 1, "one body")
	if bodies.size() == 1:
		expect_eq(bodies[0].size(), 18, "the box without its tail")
	expect(BodyBrush.bodies(_box(10, 10, 8, 1), {}).is_empty(), "a 1-spot line makes no body")


func test_occupied_spots_are_left_out_and_split_the_stroke() -> void:
	# A 12 x 4 box with its middle 2 columns occupied: two 5 x 4 bodies, nothing on the taken spots.
	var stroke := _box(20, 20, 12, 4)
	var occupied := {}
	for j in 4:
		for i in 2:
			occupied[Vector2i(25 + i, 20 + j)] = true
	var bodies: Array = BodyBrush.bodies(stroke, occupied)
	expect_eq(bodies.size(), 2, "two bodies")
	for b in bodies:
		expect_eq(b.size(), 20, "each 5 x 4")
		for p in b:
			var s := Vector2i((p / SP - Vector2(0.5, 0.5)).round())
			expect(not occupied.has(s), "no member on an occupied spot")


func test_particles_occupy_the_spots_near_them() -> void:
	# Slot 0 alive on spot (10, 10); slot 1 alive between four spots; slot 2 dead.
	var pos := PackedFloat32Array([
			BodyBrush.spot_pos(Vector2i(10, 10)).x, BodyBrush.spot_pos(Vector2i(10, 10)).y,
			BodyBrush.spot_pos(Vector2i(30, 30)).x + SP * 0.5, BodyBrush.spot_pos(Vector2i(30, 30)).y + SP * 0.5,
			BodyBrush.spot_pos(Vector2i(50, 50)).x, BodyBrush.spot_pos(Vector2i(50, 50)).y]).to_byte_array()
	var flags := PackedInt32Array([BodyBrush.ALIVE | 1, BodyBrush.ALIVE, 0]).to_byte_array()
	var occupied: Dictionary = BodyBrush.occupied_spots(pos, flags)
	expect(occupied.has(Vector2i(10, 10)), "the spot under a particle")
	expect(not occupied.has(Vector2i(11, 10)), "not the next spot along")
	for s in [Vector2i(30, 30), Vector2i(31, 30), Vector2i(30, 31), Vector2i(31, 31)]:
		expect(occupied.has(s), "the four spots around a particle between them (%s)" % s)
	expect(not occupied.has(Vector2i(50, 50)), "a dead slot occupies nothing")
	expect_eq(occupied.size(), 5, "occupied spots")


func _box(x0: int, y0: int, cols: int, rows: int) -> Dictionary:
	var stroke := {}
	for j in rows:
		for i in cols:
			stroke[Vector2i(x0 + i, y0 + j)] = true
	return stroke
