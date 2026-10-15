## CPU reference: simplified 2D PBD particle step (spec 2.6 steps 2-5).
## Mirrors the GPU passes in gpu/shaders/sim/ one for one, in plain readable form:
##   predict  -> gravity, step clamp, wall clamp            (predict.glsl)
##   hash     -> neighbours within H                         (hash_*.glsl, scan_*.glsl)
##   hydro    -> liquid density projection grid               (hydro_*.glsl)
##   solve    -> grid pressure push, a soft body's made rigid (solve_pressure.glsl,
##               body_project.glsl; ADR 0003 item 12), then
##               per iteration: lambda, delta, apply         (solve_*.glsl)
##               liquids: PBF density constraint (liquid.glslinc)
##               powders: frictional contacts   (powder.glslinc)
##               bodies: contacts as powders (powder.glslinc), then shape
##               matching (body_match.glsl; ADR 0002), and for soft bodies over
##               small regions (body_region_fit.glsl, body_region_goal.glsl; ADR 0005)
##   velocity -> v = (pred - pos) / dt, drag, XSPH, commit   (velocity_*.glsl)
## Kernels are the 2D poly6 (density) and spiky (gradient) kernels.
## Density is normalised: rho_hat = sum(W) / rest_density, so 1.0 is rest.
extends RefCounted

const SimParams = preload("res://core/sim_params.gd")

const LIQUID := 0
const POWDER := 1
const CLUSTER := 2
## Below this distance two particles count as coincident (see pair_dir).
const MIN_DIST := 1e-4
## Shape matching keeps a body's last rotation when |A_pq| (the length of the vector its
## angle comes from) is below this, per live member, in px^2.
const BODY_ROT_EPS := 1e-4
## Half-width, in spacings, of a body member's lattice cell for the push-out between two soft
## bodies (in_lattice_cell, ADR 0008): a little over half a spacing, so a point at the
## middle of a lattice square, half a spacing from four members, is still in one of their cells.
## Mirror: SOFT_CELL in powder.glslinc.
const SOFT_CELL := 0.55

## World box particles are kept inside.
var world_size: Vector2
## Per material id: { "class": int, "density", "friction", "viscosity", "drag", "stiffness",
## "region" (cluster materials; 0 for the rest) }.
var materials: Dictionary
var rest_density: float
## Liquid mass per coarse cell over water's, from the last _hydro_density (ADR 0010).
var _hydro_mass := PackedFloat32Array()
## _contact_delta's part that pushes a body member away from other bodies (contacts and
## push-out), as powder.glslinc's body_out.
var _body_out := Vector2.ZERO
## For a member of a soft body, the part of _contact_delta's result that comes from other soft
## bodies (their contacts, the push-out and friction; 0 for anything else): what
## _share_pushes_over_regions shares over its region (ADR 0008 item 1).
var _body_share := Vector2.ZERO
## This substep's soft-body regions (_find_regions), each particle's region rotation (state
## "region_rot") and rest offset, for the contacts and the push-out (ADR 0005 items 4 and 6).
var _regions: Array = []
var _region_rot := PackedVector2Array()
var _rest_now := PackedVector2Array()


## material_table: a loaded cpu_ref/material_table.gd.
func _init(world: Vector2, material_table) -> void:
	world_size = world
	materials = {}
	for id in material_table.materials:
		var row: Dictionary = material_table.materials[id]
		materials[id] = {
			"class": material_table.class_of(id),
			"density": float(row.density),
			"friction": float(row.friction),
			"viscosity": float(row.viscosity),
			"drag": float(row.drag),
			"stiffness": float(row.stiffness),
			"region": float(row.get("region", 0.0)),
		}
	rest_density = rest_density_for(SimParams.H, SimParams.SPACING)


# --- Kernels (keep in sync with common.glslinc) ---------------------------------

static func poly6(r2: float, h: float) -> float:
	if r2 >= h * h:
		return 0.0
	var d := h * h - r2
	return 4.0 / (PI * pow(h, 8)) * d * d * d


## Unit vector from p_j to p_i. Particles at the same point (walls and corners clamp
## them together) get a fixed direction per pair instead, opposite for i and j, so
## they always separate. Keep in sync with pair_dir() in common.glslinc.
static func pair_dir(rv: Vector2, r: float, i: int, j: int) -> Vector2:
	if r > MIN_DIST:
		return rv / r
	var a := mini(i, j)
	var b := maxi(i, j)
	var angle := float(((a * 7919) ^ (b * 104729)) & 1023) / 1024.0 * TAU
	var dir := Vector2(cos(angle), sin(angle))
	return dir if i < j else -dir


## Gradient of the spiky kernel with respect to p_i, for rv = p_i - p_j.
static func spiky_grad(rv: Vector2, h: float, i: int, j: int) -> Vector2:
	var r := rv.length()
	if r >= h:
		return Vector2.ZERO
	var d := h - r
	return pair_dir(rv, r, i, j) * (-30.0 / (PI * pow(h, 5)) * d * d)


## Kernel sum at one particle of a square lattice with this spacing (self included).
static func rest_density_for(h: float, spacing: float) -> float:
	var sum := 0.0
	var n := ceili(h / spacing)
	for y in range(-n, n + 1):
		for x in range(-n, n + 1):
			sum += poly6(Vector2(x, y).length_squared() * spacing * spacing, h)
	return sum


## Surface-tension / anti-clumping term from Macklin & Mueller 2013 (n = 4, dq = 0.2h).
## SCORR_K is per 1/60 s step and scales with dt^2 (a position push standing in for a force).
static func scorr(r2: float, h: float, dt: float) -> float:
	var w := poly6(r2, h) / poly6(0.04 * h * h, h)
	return -SimParams.SCORR_K * pow(dt * 60.0, 2.0) * w * w * w * w


# --- Step -------------------------------------------------------------------------

## Advances particles one frame. state: "pos", "vel" (PackedVector2Array) and
## "material" (PackedInt32Array), all the same length, and optionally "hydro_p"
## (PackedFloat32Array, the density projection grid's pressure from the last frame;
## added at 0 if missing) and the body keys (see make_body). Modified in place.
func step(state: Dictionary, dt: float, iterations: int) -> void:
	var pos: PackedVector2Array = state.pos
	var vel: PackedVector2Array = state.vel
	var mat: PackedInt32Array = state.material
	var n := pos.size()
	# Body id per particle (0 = none) and rest offset. Particles added without them are in no body.
	var body: PackedInt32Array = state.get("body", PackedInt32Array())
	body.resize(n)
	var rest: PackedVector2Array = state.get("rest", PackedVector2Array())
	rest.resize(n)
	var edge: PackedVector2Array = state.get("edge", PackedVector2Array())
	edge.resize(n)
	var bodies: Array = state.get("bodies", [])
	var members: PackedInt32Array = state.get("members", PackedInt32Array())
	var h := SimParams.H
	var region_rot: PackedVector2Array = state.get("region_rot", PackedVector2Array())
	region_rot.resize(n)
	_region_rot = region_rot
	_rest_now = rest
	var hydro_p: PackedFloat32Array = state.get("hydro_p", PackedFloat32Array())
	var hsize := hydro_size(world_size)
	hydro_p.resize(hsize.x * hsize.y)

	# Predict.
	var pred := PackedVector2Array()
	pred.resize(n)
	for i in n:
		vel[i].y += SimParams.GRAVITY * dt
		var move := (vel[i] * dt).limit_length(SimParams.MAX_STEP)
		pred[i] = _clamp_to_world(pos[i] + move, i, body[i] != 0)

	# Neighbour lists from the predicted positions (the GPU rebuilds its hash here too).
	var neighbours := _find_neighbours(pred, h)
	_regions = _find_regions(pred, mat, body, rest)

	# Density projection grid, then its push on liquids and on bodies' wet surfaces
	# (hydro_*.glsl, solve_pressure.glsl).
	var phi := _hydro_density(pred, mat, body)
	_hydro_solve(phi, hydro_p, dt, _hydro_mass)
	var delta := PackedVector2Array()
	delta.resize(n)
	# Swept contacts: each body that went into another this substep rewound along its path to
	# where they first touched (body_sweep.glsl, body_project.glsl).
	var back := _sweep_bodies(pos, pred, mat, body, edge, bodies, members, neighbours)
	for i in n:
		if _class(mat[i]) == LIQUID:
			# Over the particle's mass (ADR 0010): a liquid lighter than the one around it rises.
			delta[i] = _hydro_delta(pred[i], phi, hydro_p, dt) / materials[mat[i]].density
		elif body[i] != 0:
			delta[i] = _body_pressure_delta(i, pred, mat, body, edge, bodies[body[i]], neighbours[i], phi, hydro_p, dt)
		else:
			delta[i] = Vector2.ZERO
		if body[i] == 0:  # a body's pushes are clamped once their rigid part is taken
			delta[i] = delta[i].limit_length(0.5 * SimParams.SPACING)
	_project_body_pushes(delta, pred, mat, body, bodies, members)
	for i in n:
		pred[i] = _apply_delta(i, pos[i], pred[i] + delta[i] + back[i], mat[i], body[i] != 0)

	# Solver iterations: lambda, delta, apply, then shape matching.
	var lambda := PackedFloat32Array()
	lambda.resize(n)
	# A body member's push from other bodies this substep, summed over the iterations and spread
	# over its body (velocity_update takes its separating speed out). GPU: vel (solve_delta).
	var pushed := back.duplicate()
	# This iteration's push and friction from other soft bodies, per soft member (GPU: body_push,
	# solve_delta).
	var body_push := PackedVector2Array()
	body_push.resize(n)
	for _it in iterations:
		for i in n:
			lambda[i] = minf(_lambda(i, pred, mat, neighbours[i], h), 0.0) if _class(mat[i]) == LIQUID else 0.0
		for i in n:
			var d := Vector2.ZERO
			if _class(mat[i]) == LIQUID:
				d = _liquid_delta(i, pred, mat, lambda, neighbours[i], h, dt)
			d += _contact_delta(i, pos, pred, mat, body, edge, bodies, neighbours[i])
			delta[i] = d.limit_length(0.5 * SimParams.SPACING)
			body_push[i] = Vector2.ZERO
			if body[i] != 0 and d.length() > 1e-9:
				var scale := delta[i].length() / d.length()
				pushed[i] += _body_out * scale
				body_push[i] = _body_share * scale
		_share_pushes_over_regions(delta, body_push)
		for i in n:
			pred[i] = _apply_delta(i, pos[i], pred[i] + delta[i], mat[i], body[i] != 0)
		_match_shapes(pred, mat, body, rest, bodies, members, dt, iterations)
		_match_regions(pred, mat, rest, dt, iterations)
		_spread_body_pushes(pushed, body, bodies, members)

	# Velocity update, drag, then XSPH viscosity from the raw velocities.
	var new_vel := PackedVector2Array()
	new_vel.resize(n)
	for i in n:
		var v := (pred[i] - pos[i]) / dt
		if body[i] != 0:
			v = stop_not_launch(v, pushed[i], dt)
		var v_pre := vel[i].limit_length(SimParams.MAX_STEP / dt)
		if _class(mat[i]) == POWDER:
			# Sleeping (velocity_update.glsl): a grain held up that barely moved stays put.
			var stopped := v_pre.y - v.y > 0.5 * SimParams.GRAVITY * dt  # held up, not just pushed
			if stopped and pred[i].distance_to(pos[i]) < SimParams.SLEEP_SPEED * dt and _cradled(i, pred, mat, neighbours[i]):
				pred[i] = pos[i]
				v = Vector2.ZERO
			v = limit_separation(v, v_pre, SimParams.MAX_SEPARATION, 0.0)
		elif body[i] != 0:
			# Bodies never sleep; their push-outs get a kick cap like liquids (BODY_KICK).
			v = limit_separation(v, v_pre, 0.0, SimParams.BODY_KICK * SimParams.GRAVITY * dt)
		else:
			v = limit_separation(v, v_pre, 0.0, SimParams.LIQUID_KICK * SimParams.GRAVITY * dt)
		vel[i] = v * exp(-materials[mat[i]].drag * dt)
	for i in n:
		new_vel[i] = vel[i] + _xsph(i, pred, vel, mat, neighbours[i], h, dt) \
				+ _powder_liquid_drag(i, pred, vel, mat, neighbours[i], h, dt) \
				+ (_body_liquid_drag(i, pred, vel, mat, neighbours[i], h, dt) if body[i] != 0 else Vector2.ZERO)
	for i in n:
		vel[i] = new_vel[i]
		pos[i] = pred[i]
	state.pos = pos
	state.vel = vel
	state.hydro_p = hydro_p
	state.region_rot = _region_rot


## Swept contacts between bodies (ADR 0003 item 14): each body is rewound along its path by the
## largest share of the substep any of its members went on after touching another body
## (_sweep_delta; the member that touched first sets it), every member by that share of its own
## move, not clamped. Returns each particle's move (0 outside bodies), which also starts its push
## from other bodies (pushed). Mirror: body_sweep.glsl, and body_project.glsl for the rewind.
func _sweep_bodies(pos: PackedVector2Array, pred: PackedVector2Array, mat: PackedInt32Array,
		body: PackedInt32Array, edge: PackedVector2Array, bodies: Array, members: PackedInt32Array,
		neighbours: Array) -> PackedVector2Array:
	var back := PackedVector2Array()
	back.resize(pred.size())
	for id in range(1, bodies.size()):
		var b: Dictionary = bodies[id]
		var live := PackedInt32Array()
		var rewind := 0.0
		for k in range(b.first, b.first + b.count):
			var m := members[k]
			if body[m] != id:
				continue
			live.append(m)
			rewind = maxf(rewind, _sweep_delta(m, pos, pred, mat, body, edge, bodies, neighbours[m]))
		if rewind > 0.0:
			for m in live:
				back[m] = -rewind * (pred[m] - pos[m])
	return back


## Body member i's swept contact with other bodies (body_sweep.glsl): if it started this substep
## outside another body's outline (at most SWEEP_DEPTH inside) and is predicted to end inside
## it, at least SWEEP_DEPTH further in, the share of the substep after it first touched: its
## depth past the face it came through, less any it started with, over how far the two came
## together along the face's normal (0 if it didn't go in). Both bodies rewind that share of
## their paths, so together they undo the overlap. Along the face's normal instead, a carrot
## landing near a plank's corner (a diagonal normal) was moved back sideways and slid off; by
## contact mass, the plank's share went into the floor. The face is that of the other body's
## member nearest it at the start: a fast carrot's bottom row ends past the top rows of the body
## below, and through a 2-row plank, where the nearest member at the end has its outline facing
## the wrong way.
func _sweep_delta(i: int, pos: PackedVector2Array, pred: PackedVector2Array, mat: PackedInt32Array,
		body: PackedInt32Array, edge: PackedVector2Array, bodies: Array, nb: PackedInt32Array) -> float:
	var near0 := -1  # other-body member nearest at the start
	var near0_d2 := INF
	var near1 := -1  # other-body member nearest at the end, within a spacing
	var near1_d := SimParams.SPACING
	for j in nb:
		if body[j] == 0 or body[j] == body[i]:
			continue
		var d2 := pos[i].distance_squared_to(pos[j])
		if d2 < near0_d2:
			near0 = j
			near0_d2 = d2
		var d_end := pred[i].distance_to(pred[j])
		if d_end < near1_d:
			near1 = j
			near1_d = d_end
	if near1 < 0:
		return 0.0
	# Ends inside the other body's outline: a member passing beside a corner doesn't count.
	if _push_out(pred[i], pred[near1], edge[near1], bodies[body[near1]], _member_rot(near1, mat, body, bodies)) == Vector2.ZERO:
		return 0.0
	var b: Dictionary = bodies[body[near0]]
	if b.stale or edge[near0].length() < 1e-6:
		return 0.0
	var r := _member_rot(near0, mat, body, bodies)
	var e := Vector2(r.x * edge[near0].x - r.y * edge[near0].y, r.y * edge[near0].x + r.x * edge[near0].y)
	var len := e.length()
	var normal := e / len
	var d0 := len - normal.dot(pos[i] - pos[near0])
	var d1 := len - normal.dot(pred[i] - pred[near0])
	var gone_in := d1 - maxf(d0, 0.0)
	if d0 > SimParams.SWEEP_DEPTH * SimParams.SPACING or gone_in < SimParams.SWEEP_DEPTH * SimParams.SPACING:
		return 0.0
	# How far they came together along N: d1 - d0, at least gone_in.
	return minf(gone_in / (d1 - d0), 1.0)


## A body's push from other bodies this substep (o, contacts and push-out) may stop it along
## its direction n but not send it away: the rest only undoes the overlap (pre-stabilization,
## Macklin et al. 2014). As speed, a carrot dropped 330 px onto another bounced back out at
## 78 px/s and slid off (body_probe boxhigh). Same as velocity_update.glsl.
static func stop_not_launch(v: Vector2, o: Vector2, dt: float) -> Vector2:
	var o_len := o.length()
	if o_len <= 1e-6:
		return v
	var n := o / o_len
	var v_n := v.dot(n)
	var w_n := v_n - o_len / dt  # without the push
	return v + ((w_n if w_n >= 0.0 else minf(v_n, 0.0)) - v_n) * n


## Each live member's push from other bodies so far becomes its body's mean: shape matching
## spreads a push on a few members over the whole body. Mirror: body_match.glsl.
func _spread_body_pushes(pushed: PackedVector2Array, body: PackedInt32Array, bodies: Array,
		members: PackedInt32Array) -> void:
	for id in range(1, bodies.size()):
		var b: Dictionary = bodies[id]
		var sum := Vector2.ZERO
		var live := 0
		for k in range(b.first, b.first + b.count):
			if body[members[k]] == id:
				sum += pushed[members[k]]
				live += 1
		if live == 0:
			continue
		for k in range(b.first, b.first + b.count):
			if body[members[k]] == id:
				pushed[members[k]] = sum / live


## The solver's correction may stop a particle but leave it at most
## max(sep, its speed along the correction before the solver) + kick in that direction.
## Powders: sep MAX_SEPARATION, kick 0. Liquids: sep 0, kick LIQUID_KICK * GRAVITY * dt.
## Body particles: sep 0, kick BODY_KICK * GRAVITY * dt.
## v_pre is the velocity the particle was predicted with. Same as velocity_update.glsl.
static func limit_separation(v: Vector2, v_pre: Vector2, sep: float, kick: float) -> Vector2:
	var dv := v - v_pre
	var dv_len := dv.length()
	if dv_len <= 1e-6:
		return v
	var n := dv / dv_len
	var excess := v.dot(n) - (maxf(sep, v_pre.dot(n)) + kick)
	return v - excess * n if excess > 0.0 else v


func _class(m: int) -> int:
	return materials[m]["class"]


## Each particle gets its own wall inset (0.5 to 0.75 spacing) so wall clamping
## can't stack particles on exactly the same point. Body particles all use 0.5 spacing:
## shape matching keeps them apart, and a varied inset would tilt a body resting on a
## wall. Same as common.glslinc.
func _clamp_to_world(p: Vector2, slot: int, in_body: bool) -> Vector2:
	var r := SimParams.SPACING * (0.5 if in_body else 0.5 + 0.25 * float(slot % 7) / 6.0)
	return p.clamp(Vector2(r, r), world_size - Vector2(r, r))


## Wall clamp. Powders and body particles pressed into a wall get friction. Floor: the
## sideways move is cut by their friction coefficient. Side walls: Coulomb, the vertical
## move cancelled is at most friction x how far the grain was pressed into the wall
## (solve_apply.glsl). Without the side-wall part, contacts push wall grains up the wall.
func _apply_delta(i: int, old: Vector2, p: Vector2, m: int, in_body: bool) -> Vector2:
	var c := _clamp_to_world(p, i, in_body)
	if _class(m) == POWDER or in_body:
		var mu: float = materials[m].friction
		if p.y > c.y:
			c.x = lerpf(c.x, old.x, mu)
		var pen_x := absf(p.x - c.x)
		if pen_x > 0.0:
			var slide := c.y - old.y
			c.y -= signf(slide) * minf(absf(slide), mu * pen_x)
	return c


func _find_neighbours(pred: PackedVector2Array, h: float) -> Array:
	var cells := {}
	for i in pred.size():
		var key := Vector2i((pred[i] / h).floor())
		if not cells.has(key):
			cells[key] = PackedInt32Array()
		cells[key].append(i)
	var out := []
	for i in pred.size():
		var list := PackedInt32Array()
		var c := Vector2i((pred[i] / h).floor())
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				for j in cells.get(c + Vector2i(dx, dy), PackedInt32Array()):
					if j != i and pred[i].distance_squared_to(pred[j]) < h * h:
						list.append(j)
		out.append(list)
	return out


## Share of a liquid's density a neighbour of class c counts for when it doesn't move with
## the constraint: a grain its solid share (LIQUID_POWDER_SHARE), a body particle 1 (it sits
## on the rest-spacing lattice, so it fills a water particle's room; ADR 0003). 0 for the rest.
## Mirror: displacing_share in liquid.glslinc.
func _displacing_share(c: int) -> float:
	if c == POWDER:
		return SimParams.LIQUID_POWDER_SHARE
	return 1.0 if c == CLUSTER else 0.0


## PBF lambda. Liquid neighbours count toward density, grains and body particles at their
## share (_displacing_share, liquid.glslinc), but only liquid neighbours move, so only they
## add to the gradient sum.
func _lambda(i: int, pred: PackedVector2Array, mat: PackedInt32Array, nb: PackedInt32Array, h: float) -> float:
	var wall := wall_density(pred[i], h, rest_density, world_size)
	var density: float = poly6(0.0, h) + wall.x
	var grad_i := Vector2(wall.y, wall.z) / rest_density
	var grad_sum := 0.0
	for j in nb:
		if _class(mat[j]) != LIQUID:
			var share := _displacing_share(_class(mat[j]))
			var rp := pred[i] - pred[j]
			density += share * poly6(rp.length_squared(), h)
			grad_i += share * spiky_grad(rp, h, i, j) / rest_density
			continue
		var rv := pred[i] - pred[j]
		density += poly6(rv.length_squared(), h)
		var g := spiky_grad(rv, h, i, j) / rest_density
		grad_i += g
		grad_sum += g.length_squared()
	var c := density / rest_density - 1.0
	return -c / (grad_sum + grad_i.length_squared() + SimParams.LAMBDA_EPS)


func _liquid_delta(i: int, pred: PackedVector2Array, mat: PackedInt32Array, lambda: PackedFloat32Array,
		nb: PackedInt32Array, h: float, dt: float) -> Vector2:
	var wall := wall_density(pred[i], h, rest_density, world_size)
	var d := lambda[i] * Vector2(wall.y, wall.z)
	var rho_i: float = materials[mat[i]].density
	for j in nb:
		if _class(mat[j]) != LIQUID:
			d += lambda[i] * _displacing_share(_class(mat[j])) * spiky_grad(pred[i] - pred[j], h, i, j)
			continue
		var rv := pred[i] - pred[j]
		d += (lambda[i] + lambda[j] + scorr(rv.length_squared(), h, dt)) * liquid_pair_share(rho_i, materials[mat[j]].density) \
				* spiky_grad(rv, h, i, j)
	return d / rest_density


## Share of a liquid pair's correction that particle i (density rho_i) takes, against the
## two-water-particle split (ADR 0010, FleX 2014 7.1.1): its mass share, 2 rho_j / (rho_i +
## rho_j). Both sides change momentum alike, the pair separates as two water particles do, and
## the light side moves at most twice as far. Exactly 1 between two liquids of one density.
## Mirror: liquid_pair_share in liquid.glslinc.
static func liquid_pair_share(rho_i: float, rho_j: float) -> float:
	return 2.0 * rho_j / (rho_i + rho_j)


# --- Cluster solids (ADR 0002) ------------------------------------------------------

## Shape matching (Mueller et al. 2005, rotation only), after each iteration's apply step.
## Per body: its live members (a member counts only while it carries the body's id), their
## centroid c, the rest centroid c0 of their rest offsets, A_pq = sum (p - c)(q - c0)^T and
## the rotation from it (kept when live < 2 or |A_pq| is near 0); then every live member
## moves toward its goal c + R(q - c0) by k = 1 - (1 - stiffness)^(dt * 60 / iterations),
## so stiffness is the share of the shape error removed per 1/60 s. A soft body (stiffness < 1)
## gets its record here but no goals: _match_regions moves its members (ADR 0005 item 7).
## Mirrored by the fused body pass, body_match.glsl (one workgroup per body).
func _match_shapes(pred: PackedVector2Array, mat: PackedInt32Array, body: PackedInt32Array,
		rest: PackedVector2Array, bodies: Array, members: PackedInt32Array, dt: float, iterations: int) -> void:
	for id in range(1, bodies.size()):
		var b: Dictionary = bodies[id]
		# The reference pressure solve_pressure found this substep, and whether the body was wet,
		# carry to the next substep (ADR 0003 item 4); only the first pass of a substep finds them.
		if b.get("p_min") != null:
			b.p_ref = maxf(b.p_min, SimParams.GRAVITY * SimParams.BODY_SURFACE_DROP)
			b.p_min = null
			b.wet = b.get("wet_now", false)
			b.wet_now = false
		var live := PackedInt32Array()
		var c := Vector2.ZERO
		var c0 := Vector2.ZERO
		for k in range(b.first, b.first + b.count):
			var m := members[k]
			if body[m] == id:
				live.append(m)
				c += pred[m]
				c0 += rest[m]
		b.live = live.size()
		if live.is_empty():
			continue
		c /= live.size()
		c0 /= live.size()
		# In 2D the rotation of A_pq's polar decomposition is atan2(A10 - A01, A00 + A11).
		var a := Vector2.ZERO
		for m in live:
			var p := pred[m] - c
			var q := rest[m] - c0
			a += Vector2(p.dot(q), q.cross(p))
		if live.size() >= 2 and a.length() > BODY_ROT_EPS * live.size():
			b.rot = a.normalized()
		b.centroid = c
		b.rest_centroid = c0
		var s: float = materials[mat[live[0]]].stiffness
		if s < 1.0:
			continue  # a soft body is matched over its regions (_match_regions, ADR 0005)
		var k := 1.0 - pow(1.0 - s, dt * 60.0 / iterations)
		var rot: Vector2 = b.rot
		for m in live:
			var q := rest[m] - c0
			var goal := c + Vector2(rot.x * q.x - rot.y * q.y, rot.y * q.x + rot.x * q.y)
			pred[m] += k * (goal - pred[m])


## A body's pressure pushes (ADR 0003 item 12) replaced by their rigid part: every live
## member moves by the members' mean push plus the turn about their centroid whose torque the
## pushes give, θ = Σ r × δ / Σ |r|², linearised (θ is at most a few hundredths of a radian). The
## water moves and turns a jelly without squeezing it: relative to p_ref (its top) the pushes on
## its bottom and lower sides reach ~9 g, and a 16 x 10 jelly crumpled 4.4-5.0 px out of shape
## with water inside (body_probe waterjelly). The result is clamped as a liquid's push; the pushes
## are not clamped one member at a time before it, or a body lost its buoyancy whenever its p_ref
## read low: both its top and bottom pushes were cut to the clamp (body_probe corkstrip). Rigid
## bodies are projected too: they were clamped the same way.
## Members of a body share a material, so their masses are equal. Mirror: body_project.glsl.
func _project_body_pushes(delta: PackedVector2Array, pred: PackedVector2Array, mat: PackedInt32Array,
		body: PackedInt32Array, bodies: Array, members: PackedInt32Array) -> void:
	for id in range(1, bodies.size()):
		var b: Dictionary = bodies[id]
		var live := PackedInt32Array()
		var c := Vector2.ZERO
		var push := Vector2.ZERO
		for k in range(b.first, b.first + b.count):
			var m := members[k]
			if body[m] == id:
				live.append(m)
				c += pred[m]
				push += delta[m]
		if live.is_empty():
			continue
		c /= live.size()
		push /= live.size()
		var torque := 0.0
		var inertia := 0.0
		for m in live:
			var r := pred[m] - c
			torque += r.cross(delta[m])
			inertia += r.length_squared()
		var turn := torque / inertia if inertia > BODY_ROT_EPS * live.size() else 0.0
		for m in live:
			var r := pred[m] - c
			delta[m] = (push + turn * Vector2(-r.y, r.x)).limit_length(0.5 * SimParams.SPACING)


## Soft bodies bend (ADR 0005): shape matching over small overlapping regions (Rivers & James
## 2007, FastLSM; Mueller & Chentanez 2011), after _match_shapes in every iteration. Each member
## r of a soft body has a region, _regions[r]: itself and the members of its body whose rest
## offsets lie within the material's region radius of its own (_find_regions).
##   Fit (body_region_fit.glsl): per region, its centroid c, rest centroid c0 and rotation R, as
##   _match_shapes fits a whole body (R kept from the last fit when the region has under 2
##   members or |A_pq| is near 0), kept as R and t = c - R c0.
##   Goal (body_region_goal.glsl): member i moves toward the mean, over the regions that hold it
##   (the members of its own region: the relation is symmetric), of t_r + R_r q_i, by the
##   stiffness formula of _match_shapes.
## Each region is rigid but neighbouring ones turn by different amounts, so the body bends where
## it is loaded and springs back to its rest shape. The rotations stay in state "region_rot"
## (the push-out reads them, and the next fit keeps one when it can't find one).
func _match_regions(pred: PackedVector2Array, mat: PackedInt32Array, rest: PackedVector2Array,
		dt: float, iterations: int) -> void:
	var n := pred.size()
	var shift := PackedVector2Array()
	shift.resize(n)
	for r in n:
		var list: PackedInt32Array = _regions[r]
		if list.is_empty():
			continue
		var c := Vector2.ZERO
		var c0 := Vector2.ZERO
		for m in list:
			c += pred[m]
			c0 += rest[m]
		c /= list.size()
		c0 /= list.size()
		var a := Vector2.ZERO
		for m in list:
			var p := pred[m] - c
			var q := rest[m] - c0
			a += Vector2(p.dot(q), q.cross(p))
		var rot := _region_rot[r]
		if rot.length_squared() < 0.25:
			rot = Vector2(1.0, 0.0)  # a fresh slot (make_body writes (1, 0), as brush_spawn does)
		if list.size() >= 2 and a.length() > BODY_ROT_EPS * list.size():
			rot = a.normalized()
		_region_rot[r] = rot
		shift[r] = c - _rotate(rot, c0)
	for i in n:
		var list: PackedInt32Array = _regions[i]
		if list.is_empty():
			continue
		var goal := Vector2.ZERO
		for r in list:
			goal += shift[r] + _rotate(_region_rot[r], rest[i])
		goal /= list.size()
		var k := 1.0 - pow(1.0 - materials[mat[i]].stiffness, dt * 60.0 / iterations)
		pred[i] += k * (goal - pred[i])


## Between two soft bodies a contact moves a patch, not one member (ADR 0008 item 1): each member
## of a soft body hands what it gets from other soft bodies this iteration (body_push: their
## contacts, the push-out and their friction) out in equal parts to the members of its region,
## itself included, so member i moves by sum over r in its region of body_push[r] / |r's region|
## instead of its own (the relation is symmetric). Pushed on its own, a member that carries a
## contact moves out of line with its neighbours by far more than its region pulls it back in an
## iteration (k 0.08 at stiffness 0.5), so one soft body's members slipped between the other's and
## it draped over it; shared, the patch moves together, as shape matching spreads a rigid body's
## push. Shared this way the body's total push is kept: with each member taking its region's mean
## instead, members near an edge (smaller regions) counted for more, and a soft stack 2 px off
## centre crept sideways for good (CPU 0.02 px/s, GPU 0.1 px/s) until it slipped. The friction goes
## with the push: shared without it, the contact row was held by friction while the patch behind
## it moved, and three 8x5 bodies stacked at stiffness 0.2 rocked sideways in turn, growing from
## 0.05 to 4 px/s within 7 s. What a soft body gets from rigid bodies, grains and water, and its
## self-contacts, stay on the member: a jelly plank whose pushes from its two carrot pillars were
## shared slid off them into the gap (body_probe droop). Mirror: solve_apply.glsl (body_push from
## solve_delta.glsl).
func _share_pushes_over_regions(delta: PackedVector2Array, body_push: PackedVector2Array) -> void:
	var share := PackedVector2Array()
	share.resize(delta.size())
	for i in delta.size():
		var list: PackedInt32Array = _regions[i]
		if list.is_empty():
			continue
		var got := Vector2.ZERO
		for r in list:
			got += body_push[r] / _regions[r].size()
		share[i] = got - body_push[i]
	for i in delta.size():
		delta[i] += share[i]


## Per particle, its region (ADR 0005 item 3): empty outside soft bodies; for a member of a soft
## body (cluster, stiffness < 1), itself and every member of its body in the 3 x 3 hash cells
## (of size H) around its own whose rest offset is within the material's region radius of its
## rest offset. The GPU finds them the same way (FOR_EACH_NEIGHBOUR, from the cell each particle
## was hashed into), so a member stretched out of those cells drops out until it comes back.
## Worked out once per substep, from the positions the hash is built from.
func _find_regions(pred: PackedVector2Array, mat: PackedInt32Array, body: PackedInt32Array,
		rest: PackedVector2Array) -> Array:
	var h := SimParams.H
	var n := pred.size()
	var cells := {}
	for i in n:
		if _soft(i, mat, body):
			var key := Vector2i((pred[i] / h).floor())
			if not cells.has(key):
				cells[key] = PackedInt32Array()
			cells[key].append(i)
	var out := []
	out.resize(n)
	for i in n:
		var list := PackedInt32Array()
		if _soft(i, mat, body):
			var reach := _region_reach(mat[i])
			var c := Vector2i((pred[i] / h).floor())
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					for j in cells.get(c + Vector2i(dx, dy), PackedInt32Array()):
						if body[j] == body[i] and rest[i].distance_squared_to(rest[j]) <= reach * reach:
							list.append(j)
		out[i] = list
	return out


## True for a member of a soft body (stiffness < 1), which is matched over regions.
func _soft(i: int, mat: PackedInt32Array, body: PackedInt32Array) -> bool:
	return body[i] != 0 and materials[mat[i]].stiffness < 1.0


## Region radius of a cluster material in px, with a little slack for rest offsets on the
## lattice that differ by float rounding. Mirror: region_reach in common.glslinc.
func _region_reach(m: int) -> float:
	return materials[m].region * SimParams.SPACING + 1e-3


## Same-body pair i, j that collides (ADR 0005 item 4): in a soft body, members further apart in
## the rest shape than the region radius, so a floppy body folded onto itself lies on itself
## instead of passing through. Pairs within it are held by their regions, and a rigid body's
## by its shape. Mirror: self_contact in powder.glslinc.
func _self_contact(i: int, j: int, mat: PackedInt32Array) -> bool:
	if materials[mat[i]].stiffness >= 1.0:
		return false
	var reach := _region_reach(mat[i])
	return _rest_now[i].distance_squared_to(_rest_now[j]) > reach * reach


## The rotation a member's way out of the rest shape is turned by (ADR 0005 item 6): in a soft
## body its region's from the last fit, so the outline bends with the body; else its body's.
func _member_rot(j: int, mat: PackedInt32Array, body: PackedInt32Array, bodies: Array) -> Vector2:
	if materials[mat[j]].stiffness < 1.0 and j < _region_rot.size() and _region_rot[j].length_squared() > 0.25:
		return _region_rot[j]
	return bodies[body[j]].rot


static func _rotate(r: Vector2, v: Vector2) -> Vector2:
	return Vector2(r.x * v.x - r.y * v.y, r.y * v.x + r.x * v.y)


## Makes one body of `material` from spawned positions (the body brush, Milestone 3 step 5;
## on the GPU, ParticleSim.make_body):
## appends its particles at rest, takes the lowest free body id, sets rest offsets from the
## positions (relative to their mean) and gives it a member range (first fit). Adds the body
## keys to state when missing:
##   "body": PackedInt32Array, body id per particle, 0 = none; ids 1..N
##   "rest": PackedVector2Array, rest offset per particle (px)
##   "edge": PackedVector2Array, per particle the way out of its body's rest shape
##           (rest_outline; ADR 0003)
##   "bodies": Array, index 0 unused; per body { first, count, live, centroid,
##             rot (Vector2(cos, sin)), rest_centroid, stale (outline out of date after an
##             erase), p_ref, p_min (reference pressure, ADR 0003) }, as the GPU's body records
##   "members": PackedInt32Array, particle indices; body b owns [first, first + count)
## Returns the body id.
static func make_body(state: Dictionary, positions: PackedVector2Array, material: int) -> int:
	_ensure_body_keys(state)
	var pos: PackedVector2Array = state.pos
	var vel: PackedVector2Array = state.vel
	var mat: PackedInt32Array = state.material
	var body: PackedInt32Array = state.body
	var rest: PackedVector2Array = state.rest
	var edge: PackedVector2Array = state.edge
	var region_rot: PackedVector2Array = state.region_rot
	region_rot.resize(pos.size())
	var bodies: Array = state.bodies
	var members: PackedInt32Array = state.members
	var id := 1
	while id < bodies.size() and bodies[id].count > 0:
		id += 1
	var count := positions.size()
	var first := _first_fit(bodies, count)
	if id == bodies.size():
		bodies.append({})
	if members.size() < first + count:
		members.resize(first + count)
	var mean := Vector2.ZERO
	for p in positions:
		mean += p
	mean /= count
	var shape := PackedVector2Array()
	for p in positions:
		shape.append(p - mean)
	var out := rest_outline(shape)
	for k in count:
		members[first + k] = pos.size()
		pos.append(positions[k])
		vel.append(Vector2.ZERO)
		mat.append(material)
		body.append(id)
		rest.append(shape[k])
		edge.append(out[k])
		region_rot.append(Vector2(1.0, 0.0))
	bodies[id] = _new_body(first, count, mean)
	state.pos = pos
	state.vel = vel
	state.material = mat
	state.body = body
	state.rest = rest
	state.edge = edge
	state.region_rot = region_rot
	state.members = members
	return id


static func _new_body(first: int, count: int, centroid: Vector2) -> Dictionary:
	return {"first": first, "count": count, "live": count, "centroid": centroid,
			"rot": Vector2(1.0, 0.0), "rest_centroid": Vector2.ZERO, "stale": false,
			"p_ref": 0.0, "p_min": null, "wet": false, "wet_now": false}


## The way out of a rest shape (ADR 0003 item 7): per member, the vector from its rest offset
## to the nearest point of the shape's outline, which runs half a spacing outside the
## boundary members. Boundary members have fewer than 8 members within 1.5 spacings; each
## one's outward normal is the sum of the directions from its neighbours to it. Every member
## takes the nearest outline point among those its neighbours took, walking in from the
## boundary (linear in the body's size). Same result as the GPU sim gets: ParticleSim.make_body
## calls this.
static func rest_outline(rest: PackedVector2Array) -> PackedVector2Array:
	var sp := SimParams.SPACING
	var n := rest.size()
	var nbs := _rest_neighbours(rest)
	var mean := Vector2.ZERO
	for k in n:
		mean += rest[k]
	mean /= maxi(n, 1)
	# Outline point of each boundary member; -1 marks an inner member.
	var point := PackedVector2Array()
	point.resize(n)
	var best := PackedInt32Array()
	best.resize(n)
	best.fill(-1)
	var queue := PackedInt32Array()
	for k in n:
		var list: PackedInt32Array = nbs[k]
		if list.size() >= 8:
			continue
		var normal := Vector2.ZERO
		for m in list:
			normal += (rest[k] - rest[m]).normalized()
		if normal.length() < 1e-4:
			normal = rest[k] - mean
		normal = normal.normalized() if normal.length() > 1e-6 else Vector2(0.0, -1.0)
		point[k] = rest[k] + 0.5 * sp * normal
		best[k] = k
		queue.append(k)
	# Walk inward: a member takes a neighbour's outline point when it is nearer than its own.
	var head := 0
	while head < queue.size():
		var k := queue[head]
		head += 1
		var o := point[best[k]]
		for m in nbs[k]:
			if best[m] < 0 or rest[m].distance_squared_to(o) < rest[m].distance_squared_to(point[best[m]]) - 1e-6:
				best[m] = best[k]
				queue.append(m)
	var out := PackedVector2Array()
	out.resize(n)
	for k in n:
		out[k] = point[best[k]] - rest[k] if best[k] >= 0 else Vector2.ZERO
	return out


## Per member of a rest shape, the members within 1.5 spacings of it: its neighbours on the
## rest lattice, diagonals included. A member with all 8 is inside the shape.
static func _rest_neighbours(rest: PackedVector2Array) -> Array:
	var reach := 1.5 * SimParams.SPACING
	var n := rest.size()
	var cells := {}
	for k in n:
		var key := Vector2i((rest[k] / reach).floor())
		if not cells.has(key):
			cells[key] = PackedInt32Array()
		cells[key].append(k)
	var nbs := []
	for k in n:
		var list := PackedInt32Array()
		var c := Vector2i((rest[k] / reach).floor())
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				for m in cells.get(c + Vector2i(dx, dy), PackedInt32Array()):
					if m != k and rest[k].distance_squared_to(rest[m]) < reach * reach:
						list.append(m)
		nbs.append(list)
	return nbs


## The pieces of a rest shape (ADR 0004): groups of members connected through neighbours on
## the rest lattice (within 1.5 spacings, diagonals included, as rest_outline counts them).
## Returns one PackedInt32Array of indices into rest per piece, the largest first (ties: the
## piece holding the lower index first).
static func body_pieces(rest: PackedVector2Array) -> Array:
	var nbs := _rest_neighbours(rest)
	var piece_of := PackedInt32Array()
	piece_of.resize(rest.size())
	piece_of.fill(-1)
	var pieces := []
	for k in rest.size():
		if piece_of[k] >= 0:
			continue
		var piece := PackedInt32Array([k])
		piece_of[k] = pieces.size()
		var head := 0
		while head < piece.size():
			for m in nbs[piece[head]]:
				if piece_of[m] < 0:
					piece_of[m] = pieces.size()
					piece.append(m)
			head += 1
		piece.sort()
		pieces.append(piece)
	pieces.sort_custom(func(a: PackedInt32Array, b: PackedInt32Array) -> bool:
		return a.size() > b.size() or (a.size() == b.size() and a[0] < b[0]))
	return pieces


## Splits a body into one body per piece (ADR 0004; the eraser calls it on every body it cut).
## The largest piece keeps the id; each other piece takes the lowest free id and a member range
## by first fit, and the body's frame, reference pressure and wet flag, so it moves on as it
## was. Rest offsets stay as they are (the rest centroid is the live members', ADR 0002 item
## 5); every piece's outline is worked out again (rest_outline), which clears the stale flag.
## Returns the ids of the new bodies (empty when the body is in one piece).
static func split_body(state: Dictionary, id: int) -> PackedInt32Array:
	var body: PackedInt32Array = state.body
	var rest: PackedVector2Array = state.rest
	var edge: PackedVector2Array = state.edge
	var bodies: Array = state.bodies
	var members: PackedInt32Array = state.members
	var b: Dictionary = bodies[id]
	var live := PackedInt32Array()
	var shape := PackedVector2Array()
	for k in range(b.first, b.first + b.count):
		if body[members[k]] == id:
			live.append(members[k])
			shape.append(rest[members[k]])
	var pieces := body_pieces(shape)
	var made := PackedInt32Array()
	for p in pieces.size():
		var piece: PackedInt32Array = pieces[p]
		var piece_rest := PackedVector2Array()
		for k in piece:
			piece_rest.append(shape[k])
		var out := rest_outline(piece_rest)
		for j in piece.size():
			edge[live[piece[j]]] = out[j]
		if p == 0:
			# The largest piece keeps the id and the front of the range; the rest of the range is
			# free for the new pieces.
			for j in piece.size():
				members[b.first + j] = live[piece[j]]
			b.count = piece.size()
			b.live = b.count
			b.stale = false
			continue
		var new_id := 1
		while new_id < bodies.size() and bodies[new_id].count > 0:
			new_id += 1
		var first := _first_fit(bodies, piece.size())
		if new_id == bodies.size():
			bodies.append({})
		if members.size() < first + piece.size():
			members.resize(first + piece.size())
		for j in piece.size():
			var m := live[piece[j]]
			members[first + j] = m
			body[m] = new_id
		var nb := _new_body(first, piece.size(), b.centroid)
		for key in ["rot", "rest_centroid", "p_ref", "wet"]:
			nb[key] = b[key]
		bodies[new_id] = nb
		made.append(new_id)
	state.members = members
	return made


## Removes particles (the eraser) and remaps the member lists and ranges, so what is left of
## a body keeps matching its own shape. A body left with no members frees its id and range.
## A body that loses members is split into one body per piece left (split_body, ADR 0004),
## which also works its outline out again. (On the GPU the eraser marks the outline stale and
## the split follows a few frames later, ParticleSim._split_bodies.)
static func erase_particles(state: Dictionary, indices: PackedInt32Array) -> void:
	_ensure_body_keys(state)
	var n: int = state.pos.size()
	var gone := {}
	for i in indices:
		gone[i] = true
	var remap := PackedInt32Array()
	remap.resize(n)
	var keep := 0
	for i in n:
		remap[i] = -1 if gone.has(i) else keep
		keep += 0 if gone.has(i) else 1
	for key in ["pos", "vel", "material", "body", "rest", "edge", "region_rot"]:
		var old = state[key]
		old.resize(n)
		var out = old.duplicate()
		out.resize(keep)
		for i in n:
			if remap[i] >= 0:
				out[remap[i]] = old[i]
		state[key] = out
	var members := PackedInt32Array()
	var bodies: Array = state.bodies
	for id in range(1, bodies.size()):
		var b: Dictionary = bodies[id]
		var first := members.size()
		for k in range(b.first, b.first + b.count):
			var m: int = state.members[k]
			if remap[m] >= 0:
				members.append(remap[m])
		b.first = first if members.size() > first else 0
		if members.size() - first < b.count:
			b.stale = true
		b.count = members.size() - first
		b.live = b.count
	state.members = members
	for id in range(1, bodies.size()):
		if bodies[id].stale and bodies[id].count > 0:
			split_body(state, id)


static func _ensure_body_keys(state: Dictionary) -> void:
	var n: int = state.pos.size()
	if not state.has("body"):
		var body := PackedInt32Array()
		body.resize(n)
		state.body = body
	if not state.has("rest"):
		var rest := PackedVector2Array()
		rest.resize(n)
		state.rest = rest
	if not state.has("edge"):
		var edge := PackedVector2Array()
		edge.resize(n)
		state.edge = edge
	if not state.has("region_rot"):
		var region_rot := PackedVector2Array()
		region_rot.resize(n)
		state.region_rot = region_rot
	if not state.has("bodies"):
		state.bodies = [_new_body(0, 0, Vector2.ZERO)]
	if not state.has("members"):
		state.members = PackedInt32Array()


## Start of the first gap in the member list that holds `count` members, past the end if
## none does. The CPU allocates ranges this way in the GPU sim too (ADR 0002).
static func _first_fit(bodies: Array, count: int) -> int:
	var used := []
	for id in range(1, bodies.size()):
		if bodies[id].count > 0:
			used.append(Vector2i(bodies[id].first, bodies[id].count))
	used.sort()
	var at := 0
	for r in used:
		if r.x - at >= count:
			return at
		at = maxi(at, r.x + r.y)
	return at


# --- Liquid density projection grid (hydro.glslinc) --------------------------------

## Coarse grid size: HYDRO_CELL hash cells per cell along each axis.
static func hydro_size(world: Vector2) -> Vector2i:
	var g := Vector2i(ceili(world.x / SimParams.H), ceili(world.y / SimParams.H))
	var c := SimParams.HYDRO_CELL
	return Vector2i((g.x + c - 1) / c, (g.y + c - 1) / c)


static func hydro_cell_size() -> float:
	return SimParams.H * SimParams.HYDRO_CELL


## Share of a 1D tent of half-width a, centred at c, that lies inside [0, w].
static func hydro_tent_inside(c: float, a: float, w: float) -> float:
	var lo := maxf(1.0 - c / a, 0.0)
	var hi := maxf(1.0 - (w - c) / a, 0.0)
	return 1.0 - 0.5 * (lo * lo + hi * hi)


## Per coarse cell, over rest density: liquid (x), powder (y), body volume (z) and body weight
## in water (w: each body particle counts min(density, 1), ADR 0003). Each particle's tent
## weight on the four nearest cell centres (hydro_splat), over the weight at rest spacing of
## the part of the tent inside the world (hydro_density).
func _hydro_density(pred: PackedVector2Array, mat: PackedInt32Array, body: PackedInt32Array) -> PackedVector4Array:
	var size := hydro_size(world_size)
	var a := hydro_cell_size()
	var sum := PackedVector4Array()
	sum.resize(size.x * size.y)
	# Liquid mass over water's, as an excess over the liquid channel (ADR 0010): only liquids of
	# density other than 1 add to it, so with water alone mass == phi.x exactly.
	var excess := PackedFloat32Array()
	excess.resize(size.x * size.y)
	for i in pred.size():
		var channel: Vector4
		var extra := 0.0
		if body[i] != 0:
			channel = Vector4(0.0, 0.0, 1.0, minf(materials[mat[i]].density, 1.0))
		elif _class(mat[i]) == LIQUID:
			channel = Vector4(1.0, 0.0, 0.0, 0.0)
			extra = materials[mat[i]].density - 1.0
		elif _class(mat[i]) == POWDER:
			channel = Vector4(0.0, 1.0, 0.0, 0.0)
		else:
			continue
		var g := pred[i] / a - Vector2(0.5, 0.5)
		var b := Vector2i(g.floor())
		var f := g - Vector2(b)
		for dy in 2:
			for dx in 2:
				var c := b + Vector2i(dx, dy)
				if c.x < 0 or c.y < 0 or c.x >= size.x or c.y >= size.y:
					continue
				var tent := (f.x if dx == 1 else 1.0 - f.x) * (f.y if dy == 1 else 1.0 - f.y)
				sum[c.y * size.x + c.x] += channel * tent
				if extra != 0.0:
					excess[c.y * size.x + c.x] += extra * tent
	_hydro_mass.resize(sum.size())
	for c in sum.size():
		var centre := (Vector2(c % size.x, c / size.x) + Vector2(0.5, 0.5)) * a
		var inside := hydro_tent_inside(centre.x, a, world_size.x) * hydro_tent_inside(centre.y, a, world_size.y)
		var scale := SimParams.SPACING * SimParams.SPACING / (a * a * inside)
		sum[c] *= scale
		_hydro_mass[c] = sum[c].x + excess[c] * scale
		var rho := hydro_rho(_hydro_mass, sum, c, c)
		if rho != 1.0:
			# A body at its weight in the liquid that is there (hydro_level), not in water.
			sum[c].w = minf(sum[c].w / rho, sum[c].z)
	return sum


## Liquid density over water's across the face between cells c and n (c == n: in cell c): their
## liquid mass over their liquid volume, 1 with no liquid or no mass channel (ADR 0010).
## Mirror: hydro_rho in hydro.glslinc.
static func hydro_rho(mass: PackedFloat32Array, phi: PackedVector4Array, c: int, n: int) -> float:
	var x := phi[c].x + phi[n].x
	if mass.is_empty() or x <= 1e-6:
		return 1.0
	return (mass[c] + mass[n]) / x


## HYDRO_SWEEPS projected red-black SOR sweeps on p, in place (hydro_sweep).
## Each face between liquid cells weighs 1 / hydro_rho (the mass-weighted Poisson equation,
## ADR 0010), so the push over a particle's mass removes each cell's compression whatever its
## liquid; the floor's and bodies' flux stays head, as (1/rho) dp/dn = g at rest. No mass
## (hand-made cells): water everywhere.
func _hydro_solve(phi: PackedVector4Array, p: PackedFloat32Array, dt: float,
		mass := PackedFloat32Array()) -> void:
	var size := hydro_size(world_size)
	var a := hydro_cell_size()
	var offs := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	var head := SimParams.GRAVITY * a  # hydrostatic rise of p per cell of depth
	for _s in SimParams.HYDRO_SWEEPS:
		for parity in 2:
			for c in phi.size():
				var ci := Vector2i(c % size.x, c / size.x)
				if (ci.x + ci.y) % 2 != parity:
					continue
				var solid := hydro_solid(phi[c])
				var air := hydro_air(phi, ci, size)
				var sum := 0.0
				var n := 0.0
				var wall_sum := 0.0
				for off in offs:
					var nc: Vector2i = ci + off
					if nc.y >= size.y:  # the floor holds the water's weight, as a sand bed does
						if not solid and not air:
							wall_sum += head
						continue
					if nc.x < 0 or nc.y < 0 or nc.x >= size.x:
						continue
					var ni := nc.y * size.x + nc.x
					var solid_n := hydro_solid(phi[ni])
					var air_n := hydro_air(phi, nc, size)
					if solid:
						if not air_n:  # sand bed: the liquid's pressure continued hydrostatically
							sum += p[ni] - hydro_rho(mass, phi, c, ni) * head * off.y
							n += 1.0
					elif solid_n:
						if not air:
							if phi[ni].z < SimParams.HYDRO_BODY_CELL:  # porous sand bed: its p, the water's continued
								var wb := 1.0 / hydro_rho(mass, phi, c, ni)
								sum += wb * p[ni]
								n += wb
							else:  # a body: a wall holding the water's weight, dp/dn = rho g . n
								wall_sum += head * off.y
					elif air:
						if not air_n:  # ghost: liquid p extrapolated through 0 at the surface
							sum += p[ni] * (1.0 - 1.0 / _hydro_theta(hydro_level(phi[ni]), hydro_level(phi[c])))
							n += 1.0
					elif air_n:
						n += 1.0 / (hydro_rho(mass, phi, c, c) * _hydro_theta(hydro_level(phi[c]), hydro_level(phi[ni])))
					else:
						var wl := 1.0 / hydro_rho(mass, phi, c, ni)
						n += wl
						sum += wl * p[ni]
				if solid:
					p[c] = maxf(sum / n, 0.0) if n > 0.0 else 0.0
					continue
				if air:
					p[c] = sum / n if n > 0.0 else 0.0
					continue
				if n == 0.0:  # walled in by sand on every side
					p[c] = maxf(p[c], 0.0)
					continue
				# Under a full cell (water, powder and bodies), a cell with room left is pulled full (a trapped bubble).
				# Body volume counts as full room (ADR 0003), so a body is not a bubble to fill.
				# Never in the floor row: half outside the world, it reads a little short of full.
				# Nor where a body partly fills the cell (HYDRO_BODY_CELL): water keeps a contact gap from
				# it, so the cell reads short of full with no air in it. Pulled, a pinned cork's cells flipped
				# between p 0 and squeezed, and the whole pool's p with them.
				var covered := ci.y > 0 and ci.y < size.y - 1 and phi[c - size.x].x + phi[c - size.x].y * SimParams.HYDRO_POWDER_VOL + phi[c - size.x].z >= SimParams.HYDRO_FULL \
						and phi[c].z < SimParams.HYDRO_BODY_CELL
				# Compression counts body volume too, so water squeezed under or into a body is pushed out.
				var err := maxf(phi[c].x + phi[c].z - 1.0, 0.0)
				var room := minf(phi[c].x + phi[c].y * SimParams.HYDRO_POWDER_FULL + phi[c].z - 1.0, 0.0)
				if covered:
					err += room
				elif hydro_under_floater(phi, ci, size):
					# Under the bottom of a body that floats: pulled for at most HYDRO_ROOF_PULL of its room,
					# so the water rises into the gap the coarse grid leaves under it (hydro_row). Not under a
					# body still under water: the void a rising body leaves was pulled to 0 and it hung there.
					err += maxf(room, -SimParams.HYDRO_ROOF_PULL)
				var k := 1.0 - pow(1.0 - SimParams.HYDRO_K, dt * 60.0)  # share per step (hydro_k())
				var rhs := -a * a * k * err / (dt * dt)
				p[c] = maxf(lerpf(maxf(p[c], 0.0), (sum + wall_sum - rhs) / n, SimParams.HYDRO_SOR), 0.0)


## True when cell ci is air (hydro_air): neither bed nor HYDRO_AIR full of liquid. A cell that
## sand or a body partly fills and that holds some water, under a cell that isn't air, is under
## water: its room is the water's gap from the grains and the body, not air.
static func hydro_air(phi: PackedVector4Array, ci: Vector2i, size: Vector2i) -> bool:
	var c := ci.y * size.x + ci.x
	var fill := phi[c].y * SimParams.HYDRO_POWDER_VOL + phi[c].z
	var level := hydro_level(phi[c])
	if fill >= SimParams.HYDRO_SOLID or level >= SimParams.HYDRO_AIR:
		return false
	if ci.y > 0 and level >= SimParams.HYDRO_MIXED_WET and fill >= SimParams.HYDRO_MIXED_SOLID:
		return not hydro_solid(phi[c - size.x]) and hydro_level(phi[c - size.x]) < SimParams.HYDRO_AIR
	return true


## True when cell ci is under the bottom of a body that floats: HYDRO_BODY_ROOF of body in the
## cell above, less in its own, not the floor row, and going up past the cells holding body
## (HYDRO_BODY_CELL), up to the body's top however tall, the first is open-cell air
## (hydro_under_floater in hydro_solve.glsl).
static func hydro_under_floater(phi: PackedVector4Array, ci: Vector2i, size: Vector2i) -> bool:
	if ci.y < 1 or ci.y >= size.y - 1:
		return false
	var c := ci.y * size.x + ci.x
	if phi[c - size.x].z < SimParams.HYDRO_BODY_ROOF or phi[c].z >= SimParams.HYDRO_BODY_ROOF:
		return false
	for y in range(ci.y - 2, -1, -1):
		var u: Vector4 = phi[y * size.x + ci.x]
		if u.z < SimParams.HYDRO_BODY_CELL:
			return hydro_level(u) < SimParams.HYDRO_AIR and not hydro_solid(u)
	return true


## True when a cell is bed: a solid wall for the grid (hydro_solid). Sand at its packing, and
## body particles, which fill a cell as water at rest does (ADR 0003).
static func hydro_solid(phi_c: Vector4) -> bool:
	return phi_c.y * SimParams.HYDRO_POWDER_VOL + phi_c.z >= SimParams.HYDRO_SOLID


## A cell's liquid level for the air test and the free surface (hydro_level): its liquid, plus
## its body particles at their weight in water. A floating body displaces its own weight of
## water, so a cell it floats in reads as level as the water beside it. Counted by volume
## instead (or left out), a floating body raised (or lowered) the grid's surface where it sat,
## and the pressure on its sides pushed it away from (or after) wherever it went (ADR 0003).
## The weight counts in full only where the cell has at least HYDRO_AIR of liquid, so a dry
## body's cells stay air instead of reading as a column of water.
static func hydro_level(phi_c: Vector4) -> float:
	return phi_c.x + phi_c.w * minf(phi_c.x / SimParams.HYDRO_AIR, 1.0)


## Share of the way from a liquid cell to its air neighbour where phi crosses the
## surface (hydro_theta).
static func _hydro_theta(phi_f: float, phi_a: float) -> float:
	return clampf((phi_f - SimParams.HYDRO_SURFACE) / maxf(phi_f - phi_a, 1e-4), SimParams.HYDRO_THETA_MIN, 1.0)


## True when grain i rests in a pocket: on the floor, or touched below on each side by a
## grain or a wall (velocity_update.glsl cradled()).
func _cradled(i: int, pred: PackedVector2Array, mat: PackedInt32Array, nb: PackedInt32Array) -> bool:
	var sp := SimParams.SPACING
	var pt := pred[i]
	if pt.y >= world_size.y - 0.6 * sp:
		return true
	var left := pt.x <= 0.6 * sp
	var right := pt.x >= world_size.x - 0.6 * sp
	for j in nb:
		if j == i or _class(mat[j]) != POWDER:
			continue
		var d := pred[j] - pt
		if d.y > 0.1 * sp and d.length_squared() < 1.44 * sp * sp:
			left = left or d.x < -0.2 * sp
			right = right or d.x > 0.2 * sp
	return left and right


## Pressure at coarse cell c, mirrored past the grid edge (hydro_p_at).
func _hydro_p_at(c: Vector2i, phi: PackedVector4Array, p: PackedFloat32Array) -> float:
	var size := hydro_size(world_size)
	var cc := c.clamp(Vector2i.ZERO, size - Vector2i.ONE)
	var i := cc.y * size.x + cc.x
	return p[i]


func _hydro_p_sample(x: Vector2, phi: PackedVector4Array, p: PackedFloat32Array) -> float:
	var g := x / hydro_cell_size() - Vector2(0.5, 0.5)
	var b := Vector2i(g.floor())
	var f := g - Vector2(b)
	var top := lerpf(_hydro_p_at(b, phi, p), _hydro_p_at(b + Vector2i(1, 0), phi, p), f.x)
	var bottom := lerpf(_hydro_p_at(b + Vector2i(0, 1), phi, p), _hydro_p_at(b + Vector2i(1, 1), phi, p), f.x)
	return maxf(lerpf(top, bottom, f.y), 0.0)


## Position change this step from the grid pressure: -grad p * dt^2 (hydro_delta).
func _hydro_delta(x: Vector2, phi: PackedVector4Array, p: PackedFloat32Array, dt: float) -> Vector2:
	var e := 0.5 * hydro_cell_size()
	var grad := Vector2(
			_hydro_p_sample(x + Vector2(e, 0.0), phi, p) - _hydro_p_sample(x - Vector2(e, 0.0), phi, p),
			_hydro_p_sample(x + Vector2(0.0, e), phi, p) - _hydro_p_sample(x - Vector2(0.0, e), phi, p)) / (2.0 * e)
	return -grad * dt * dt


## A body particle's wet face (body_wet_face in solve_pressure.glsl): the sum of unit vectors
## toward its liquid neighbours, each weighted 1 out to 1.5 spacings and fading to 0 at H, over
## 1 + sqrt(2), what a flat face of liquid on the rest lattice gives (one neighbour straight
## on, two diagonal). So it reads 1 for a flat wet face and sqrt(2) along the diagonal at a
## corner wet on two sides, wherever the water sits within 1.5 spacings. Summed spiky kernel
## gradients over their value for that lattice read 0.55-0.64 instead: water by a body sits
## ~2-2.5 px off and not on a lattice, and the spiky gradient falls steeply over that range, so
## an 80 x 40 cork floated at 0.71 of its height instead of ~0.5 (GPU body_probe waterbig).
static func body_wet_face(d: Vector2, h: float, spacing: float) -> Vector2:
	var r := d.length()
	if r < MIN_DIST or r >= h:
		return Vector2.ZERO
	var w := clampf((h - r) / (h - 1.5 * spacing), 0.0, 1.0)
	return d / r * w / (1.0 + sqrt(2.0))


## Liquid in the grid at x, over rest: bilinear over the cells' liquid channel
## (body_liquid_fill in solve_pressure.glsl).
func _body_liquid_fill(x: Vector2, phi: PackedVector4Array) -> float:
	var size := hydro_size(world_size)
	var gc := x / hydro_cell_size() - Vector2(0.5, 0.5)
	var c0 := Vector2i(gc.floor())
	var f := gc - Vector2(c0)
	var v := PackedFloat32Array()
	for k in 4:
		var c := (c0 + Vector2i(k & 1, k >> 1)).clamp(Vector2i.ZERO, size - Vector2i.ONE)
		v.append(phi[c.y * size.x + c.x].x)
	return lerpf(lerpf(v[0], v[1], f.x), lerpf(v[2], v[3], f.x), f.y)


## Grid pressure at x for a body's surface (body_p_sample): the bilinear sample, continued
## hydrostatically below the last row of cell centres, where the sample alone stops growing.
func _body_p_sample(x: Vector2, phi: PackedVector4Array, p: PackedFloat32Array) -> float:
	var size := hydro_size(world_size)
	var y_last := (size.y - 0.5) * hydro_cell_size()
	var s := _hydro_p_sample(Vector2(x.x, minf(x.y, y_last)), phi, p)
	if s <= 0.0 or x.y <= y_last:
		return s
	# Below the last row, the head of the liquid in that row's cell (ADR 0010).
	var c := (size.y - 1) * size.x + clampi(int(x.x / hydro_cell_size()), 0, size.x - 1)
	return s + hydro_rho(_hydro_mass, phi, c, c) * SimParams.GRAVITY * (x.y - y_last)


## Position change this step of body particle i from the liquid's pressure on its wet surface
## (ADR 0003 item 4): p at the body's outline on the liquid side, over the body's reference
## pressure, pressing on its wet face (body_wet_face), over the body's mass per particle
## (density x spacing^2, water being 1). Within 1.5 spacings of the floor or a side wall, a
## particle of a body that was wet last substep also counts the floor or wall as a face of
## liquid (water seeps between them), so a light body on the floor of a pool rises, and one
## against a wall isn't pushed into it, where the wall's friction holds it.
## Under water the whole face is wet, whatever touches it: a boundary member of a body that was
## wet last substep, not touching another body, takes its outline face (its way out turned by
## the body's rotation, over half a spacing: 1 on a flat face, sqrt(2) at a corner) as wet where
## the grid holds liquid at its outline point (BODY_PORE_WET) and a pressure over 0, if that is
## larger than its liquid neighbours' face. So a cork pressed into a sand bed under water, with
## grains under it, not water particles, rises (ADR 0003 item 15). Such a face keeps the body wet.
## Also gives the body's reference pressure for the next substep (p_min, which the body pass
## moves to p_ref): the lowest p over its wet particles (INF if none) and over its bare
## boundary members (nothing but its own body within 1.5 spacings, away from the walls), each
## of which reads the grid's p at its outline point: 0 out of the water, the water's pressure in
## a void under it. Closed in by liquid, grains, other bodies, the floor and walls, a body is
## pushed only by the pressure difference across it, so deep water doesn't squeeze it past the
## correction cap. With a face out of the water it floats, and its pressure is absolute:
## referred to its lowest wet pressure instead, a cork bobbing up until only its bottom row was
## wet lost all its lift at the top of each bob, and the bob grew (ADR 0003). A bare member used
## to read 0 wherever it was, so a void in poured water beside it made a deep cork's pushes
## absolute, capped and cancelling, and it stayed on the floor (ADR 0003 item 4).
## Mirror: body_pressure_delta in solve_pressure.glsl.
func _body_pressure_delta(i: int, pred: PackedVector2Array, mat: PackedInt32Array, body: PackedInt32Array,
		edge: PackedVector2Array, b: Dictionary, nb: PackedInt32Array, phi: PackedVector4Array,
		p: PackedFloat32Array, dt: float) -> Vector2:
	var sp := SimParams.SPACING
	var g := Vector2.ZERO
	var touching := false
	var on_body := false
	for j in nb:
		if body[j] == body[i]:
			continue
		if pred[i].distance_squared_to(pred[j]) < 2.25 * sp * sp:
			touching = true
			on_body = on_body or body[j] != 0
		if _class(mat[j]) == LIQUID:
			g += body_wet_face(pred[j] - pred[i], SimParams.H, sp)
	var x := pred[i]
	var was_wet: bool = b.get("wet", false)
	var r: Vector2 = b.rot
	var e := Vector2(r.x * edge[i].x - r.y * edge[i].y, r.y * edge[i].x + r.x * edge[i].y)
	var boundary := edge[i].length() < 0.75 * sp
	var wet := g.length() > 1e-6
	var pw := _body_p_sample(x + 0.5 * sp * g.normalized(), phi, p) if wet else 0.0
	# Under water the whole face is wet, whatever touches it (between grains, or a void).
	var face := e / (0.5 * sp)
	if was_wet and boundary and not on_body and g.length() < face.length() \
			and _body_liquid_fill(x + e, phi) >= SimParams.BODY_PORE_WET:
		var pf := _body_p_sample(x + 0.5 * sp * face.normalized(), phi, p)
		if pf > 0.0:
			g = face
			pw = pf
			wet = true
	if wet:
		b.wet_now = true
	var ref := pw if wet else INF
	var at_wall := x.x < 1.5 * sp or x.y < 1.5 * sp or x.x > world_size.x - 1.5 * sp or x.y > world_size.y - 1.5 * sp
	if not touching and not at_wall and boundary:
		# A bare boundary member: the grid's p at its outline point, 0 out of the water.
		ref = minf(ref, _body_p_sample(x + e, phi, p))
	b.p_min = minf(b.p_min if b.get("p_min") != null else INF, ref)
	if was_wet:
		if x.y >= world_size.y - 1.5 * sp:
			g.y = maxf(g.y, 1.0)
			pw = maxf(pw, _body_p_sample(Vector2(x.x, world_size.y), phi, p))
		if x.x <= 1.5 * sp:
			g.x = minf(g.x, -1.0)
			pw = maxf(pw, _body_p_sample(Vector2(0.0, x.y), phi, p))
		if x.x >= world_size.x - 1.5 * sp:
			g.x = maxf(g.x, 1.0)
			pw = maxf(pw, _body_p_sample(Vector2(world_size.x, x.y), phi, p))
	if g.length() <= 1e-6:
		return Vector2.ZERO
	return -maxf(pw - b.get("p_ref", 0.0), 0.0) * g * dt * dt / (materials[mat[i]].density * sp)


## Density a wall at distance d adds (poly6 over the half-plane past it, at rest
## density), and its slope d(density)/dd. Returns Vector2(density, slope).
static func wall_density_1d(d: float, h: float, rest: float) -> Vector2:
	if d >= h:
		return Vector2.ZERO
	var s := maxf(d, 0.0) / h
	var a := asin(s)
	var q := 1.0 - s * s
	var c := 128.0 / (35.0 * PI)
	var j := (35.0 * a + 28.0 * sin(2.0 * a) + 7.0 * sin(4.0 * a) + 4.0 / 3.0 * sin(6.0 * a)
			+ 0.125 * sin(8.0 * a)) / 128.0
	return Vector2(rest * (0.5 - c * j), -rest * c / h * q * q * q * sqrt(q))


## Density from all four walls and its gradient with respect to p, as
## Vector3(density, grad.x, grad.y). Same as wall_density() in liquid.glslinc.
static func wall_density(p: Vector2, h: float, rest: float, world: Vector2) -> Vector3:
	var l := wall_density_1d(p.x, h, rest)
	var r := wall_density_1d(world.x - p.x, h, rest)
	var t := wall_density_1d(p.y, h, rest)
	var b := wall_density_1d(world.y - p.y, h, rest)
	return Vector3(l.x + r.x + t.x + b.x, l.y - r.y, t.y - b.y)


## Share of a contact's push-out that particle i takes, for rv = p_i - p_j (y down).
## The lower particle acts heavier (STACK_K), so piles hold up under load.
## Powder-powder pairs (see powder.glslinc), and pairs with a body, where rv_y is the
## height between body centroids (a grain counts at its own height).
static func stack_weight(m_i: float, m_j: float, rv_y: float) -> float:
	return m_j / (m_i * exp(clampf(SimParams.STACK_K * rv_y, -8.0, 8.0)) + m_j)


## stack_weight for a contact with a body (ADR 0002 item 11), except where one side is in a soft
## body and the other isn't (ADR 0005 item 11): there the share is by density alone, so a carrot
## set on a jelly presses it flat. With STACK_K the jelly under it took almost none of the contact
## and stood as tall as an unloaded one (body_probe squash). Two soft bodies keep STACK_K (ADR 0008
## item 2): sharing by density, the lower one gave way under the upper one, and a stack of them
## leaned over and slid apart. Mirror: body_stack_weight in powder.glslinc.
static func body_stack_weight(m_i: float, m_j: float, rv_y: float, soft_i: bool, soft_j: bool) -> float:
	return m_j / (m_i + m_j) if soft_i != soft_j else stack_weight(m_i, m_j, rv_y)


## Contacts with any particle closer than SPACING (POWDER_LIQUID_REACH x SPACING for a
## powder-liquid pair), where at least one side is a powder or a body particle of another
## body: body particles follow the powder rule. Same-body pairs are left to shape matching.
## Mass-weighted push-out, the lower side heavier by STACK_K (see stack_weight), except
## powder-liquid (the liquid yields) and body-liquid (by density only, ADR 0003); also
## static/kinetic friction on the relative sideways motion.
## Scaled by CONTACT_RELAX; summed for powders and bodies, averaged over the particles it
## touches for a liquid (see powder.glslinc). A particle that sits inside another body's
## outline is also pushed out to it (_push_out): all of it for a particle in no body, a body
## member its contact share (ADR 0003 item 11).
func _contact_delta(i: int, pos: PackedVector2Array, pred: PackedVector2Array, mat: PackedInt32Array,
		body: PackedInt32Array, edge: PackedVector2Array, bodies: Array, nb: PackedInt32Array) -> Vector2:
	var mi: Dictionary = materials[mat[i]]
	var sum := Vector2.ZERO
	var nearest_push := Vector2.ZERO  # the nearest pair's contact push-out
	var sum_bodies := Vector2.ZERO  # body member i: the part of sum from other bodies
	var soft_i := _soft(i, mat, body)
	var sum_soft := Vector2.ZERO  # soft member i: the part of sum from other soft bodies
	var fric := Vector2.ZERO
	var fric_soft := Vector2.ZERO  # soft member i: the part of fric from other soft bodies
	var n_near := 0
	var n_wet := 0
	var fric_w := 0.0
	var n_touch := 0.0
	var nearest := -1  # nearest particle of another body within a spacing
	var nearest_d := SimParams.SPACING
	for j in nb:
		var mj: Dictionary = materials[mat[j]]
		if mi["class"] != POWDER and mj["class"] != POWDER and body[i] == 0 and body[j] == 0:
			continue  # liquid-liquid: the density constraint
		var own := body[i] != 0 and body[i] == body[j]
		if own and not _self_contact(i, j, mat):
			continue  # same body: shape matching holds it together
		var rv := pred[i] - pred[j]
		var dist := rv.length()
		if dist < SimParams.H:
			n_near += 1
			if mj["class"] == LIQUID:
				n_wet += 1
		if body[j] != 0 and not own and dist < nearest_d:
			nearest = j
			nearest_d = dist
		var t_liquid: bool = mi["class"] == LIQUID
		var j_liquid: bool = mj["class"] == LIQUID
		var powder_liquid: bool = (t_liquid and mj["class"] == POWDER) or (j_liquid and mi["class"] == POWDER)
		var reach := SimParams.SPACING * (SimParams.POWDER_LIQUID_REACH if powder_liquid else 1.0)
		if dist >= reach:
			continue
		n_touch += 1.0
		var normal := pair_dir(rv, dist, i, j)
		var pen := reach - dist
		var w: float
		if powder_liquid:
			# Powder-liquid: the liquid yields (see POWDER_LIQUID_SHARE).
			w = SimParams.POWDER_LIQUID_SHARE if mi["class"] == POWDER else 1.0 - SimParams.POWDER_LIQUID_SHARE
		else:
			w = mj.density / (mi.density + mj.density)
		var w_push := w
		if mi["class"] == POWDER and mj["class"] == POWDER:
			w_push = stack_weight(mi.density, mj.density, rv.y)
		elif not t_liquid and not j_liquid:
			# A body (or a grain against one) is heavier by the height of its body's centroid
			# under the other side's, so a stack of bodies holds; friction gets the same share,
			# since a stack with mass-weighted friction swayed for good (ADR 0002).
			var yi: float = bodies[body[i]].centroid.y if body[i] != 0 else pred[i].y
			var yj: float = bodies[body[j]].centroid.y if body[j] != 0 else pred[j].y
			w_push = body_stack_weight(mi.density, mj.density, yi - yj, _soft(i, mat, body), _soft(j, mat, body))
			w = w_push
		sum += w_push * pen * normal
		var soft_pair: bool = soft_i and body[j] != 0 and not own and _soft(j, mat, body)
		if body[i] != 0 and body[j] != 0 and not own:
			sum_bodies += w_push * pen * normal
		if soft_pair:
			sum_soft += w_push * pen * normal
		if j == nearest:
			nearest_push = w_push * pen * normal
		var mu: float = minf(mi.friction, mj.friction)
		if mu > 0.0:
			var rel := (pred[i] - pos[i]) - (pred[j] - pos[j])
			var tangent := rel - rel.dot(normal) * normal
			var t_len := tangent.length()
			var f := Vector2.ZERO
			if t_len < mu * pen:
				f = -w * tangent  # static: cancel the slide
			elif t_len > 1e-6:
				f = -w * tangent * minf(0.8 * mu * pen / t_len, 1.0)  # kinetic
			fric += f
			if soft_pair:
				fric_soft += f
			fric_w += w
	# Friction is averaged over the contacts (divided by their total weight, at least 1),
	# so the correction per iteration stays below CONTACT_RELAX. An unnormalised sum
	# overshoots with many contacts and makes a settled pile wobble.
	fric /= maxf(fric_w, 1.0)
	# Wet grains slip (WET_SLIP): friction drops with the share of liquid neighbours. Bodies
	# don't get wet (ADR 0003).
	var wet := float(n_wet) / n_near if n_near > 0 and mi["class"] == POWDER else 0.0
	if mi["class"] == LIQUID:
		sum /= maxf(n_touch, 1.0)  # liquid: averaged over what it touches (powder.glslinc)
	var out := Vector2.ZERO
	var soft_near := false  # i and its nearest member of another body are both in soft bodies
	if nearest >= 0:
		soft_near = soft_i and _soft(nearest, mat, body)
		var r_near := _member_rot(nearest, mat, body, bodies)
		out = _push_out(pred[i], pred[nearest], edge[nearest], bodies[body[nearest]], r_near)
		if (soft_near or (mi["class"] == POWDER and _soft(nearest, mat, body))) \
				and not in_lattice_cell(pred[i], pred[nearest], r_near):
			# Outside the soft body: a corner's outline misfires (ADR 0008 item 1), and a grain in a
			# stretched gap of its bottom row let it dig into sand (ADR 0009).
			out = Vector2.ZERO
		if body[i] != 0 and out.dot(pred[i] - pred[nearest]) < 0.0:
			# Past the nearest member's edge row, that pair pushes inward: the outline decides
			# (powder.glslinc contact_delta).
			sum -= nearest_push
			sum_bodies -= nearest_push
			if soft_near:
				sum_soft -= nearest_push
		if body[i] != 0:
			# Body-body: each side takes its contact share, so the pair separates by the depth
			# (powder.glslinc contact_delta).
			var yj: float = bodies[body[nearest]].centroid.y
			out *= body_stack_weight(mi.density, materials[mat[nearest]].density, bodies[body[i]].centroid.y - yj,
					soft_i, _soft(nearest, mat, body))
	_body_out = (sum_bodies + out) * SimParams.CONTACT_RELAX if body[i] != 0 else Vector2.ZERO
	_body_share = (sum_soft + (out if soft_near else Vector2.ZERO) + fric_soft / maxf(fric_w, 1.0)) \
			* SimParams.CONTACT_RELAX if soft_i else Vector2.ZERO
	return (sum + fric * (1.0 - SimParams.WET_SLIP * wet) + out) * SimParams.CONTACT_RELAX


## Push-out from inside a body (ADR 0003 items 8 and 11): x is a particle, x_j its nearest
## particle of another body, e_j that member's way out of the rest shape. Turned by r, the
## member's rotation (_member_rot: its body's, or in a soft body its region's), e_j gives the outward normal N and the outline's distance along it; x is
## inside by d = |e_j| - N.(x - x_j), and if so is moved d along N, to the outline. Nothing
## for a body whose outline is stale (part of it erased). Mirror: push_out in powder.glslinc.
static func _push_out(x: Vector2, x_j: Vector2, e_j: Vector2, b: Dictionary, r: Vector2) -> Vector2:
	if b.stale or e_j.length() < 1e-6:
		return Vector2.ZERO
	var e := Vector2(r.x * e_j.x - r.y * e_j.y, r.y * e_j.x + r.x * e_j.y)
	var len := e.length()
	var normal := e / len
	var d := len - normal.dot(x - x_j)
	return d * normal if d > 0.0 else Vector2.ZERO


## Whether x lies in the lattice cell of a body member at x_j turned by r: within SOFT_CELL
## spacings of it along both of the turned lattice's axes. On a square lattice a member's cell is
## the part of the body nearest it, so a point is inside the body only if it is in the cell of
## its nearest member. Between two soft bodies, and on a grain from a soft body (ADR 0009), the
## push-out acts only there (ADR 0008 item 1): a corner member's way out is the 45-degree
## diagonal, so a point 1.7 px under a corner of the body above, 0.6 px in from its side, read
## 0.22 px inside it, though 0.7 px below its bottom face. A
## member took that push on its own and its body's shape took it back; shared over its region
## (_share_pushes_over_regions) it moved the patch, and a soft stack 2 px off centre crept sideways
## for good. Not against a rigid body: a jelly plank on two carrot pillars slid off their corners
## into the gap (test_jelly_plank_bends_over_a_gap). Mirror: in_lattice_cell in powder.glslinc.
static func in_lattice_cell(x: Vector2, x_j: Vector2, r: Vector2) -> bool:
	var q := x - x_j
	q = Vector2(r.x * q.x + r.y * q.y, -r.y * q.x + r.x * q.y)  # into j's turned frame
	return maxf(absf(q.x), absf(q.y)) < SOFT_CELL * SimParams.SPACING


## Quadratic drag of a grain toward its liquid neighbours' kernel-weighted velocity,
## scaled by how much liquid is around it (powder_liquid_drag in powder.glslinc).
func _powder_liquid_drag(i: int, pred: PackedVector2Array, vel: PackedVector2Array,
		mat: PackedInt32Array, nb: PackedInt32Array, h: float, dt: float) -> Vector2:
	if _class(mat[i]) != POWDER:
		return Vector2.ZERO
	var sum := Vector2.ZERO
	var w_sum := 0.0
	for j in nb:
		if _class(mat[j]) != LIQUID:
			continue
		var w := poly6((pred[i] - pred[j]).length_squared(), h)
		sum += (vel[j] - vel[i]) * w
		w_sum += w
	if w_sum <= 0.0:
		return Vector2.ZERO
	var rel := sum / w_sum
	var rate := SimParams.POWDER_LIQUID_DRAG * rel.length()
	return rel * ((1.0 - exp(-rate * dt)) * minf(w_sum / rest_density, 1.0))


## Linear drag of a body particle toward its liquid neighbours' kernel-weighted velocity,
## scaled by how much liquid is around it (body_liquid_drag in powder.glslinc; ADR 0003).
## Only wet particles feel it, so a body's drag grows with its wet surface while its mass
## grows with its area: without it a floating body heaved at its natural period (~0.8 s for
## an 8x6 cork) and a cork rising from the floor capsized at the surface.
func _body_liquid_drag(i: int, pred: PackedVector2Array, vel: PackedVector2Array,
		mat: PackedInt32Array, nb: PackedInt32Array, h: float, dt: float) -> Vector2:
	var sum := Vector2.ZERO
	var w_sum := 0.0
	for j in nb:
		if _class(mat[j]) != LIQUID:
			continue
		var w := poly6((pred[i] - pred[j]).length_squared(), h)
		sum += (vel[j] - vel[i]) * w
		w_sum += w
	if w_sum <= 0.0:
		return Vector2.ZERO
	return sum / w_sum * ((1.0 - exp(-SimParams.BODY_LIQUID_DRAG * dt)) * minf(w_sum / rest_density, 1.0))


## XSPH viscosity: liquids blend toward their liquid neighbours' velocity. The material
## viscosity is the blend per 1/60 s, scaled to dt.
func _xsph(i: int, pred: PackedVector2Array, vel: PackedVector2Array, mat: PackedInt32Array,
		nb: PackedInt32Array, h: float, dt: float) -> Vector2:
	if _class(mat[i]) != LIQUID:
		return Vector2.ZERO
	var visc: float = materials[mat[i]].viscosity
	var sum := Vector2.ZERO
	for j in nb:
		if _class(mat[j]) == LIQUID:
			sum += (vel[j] - vel[i]) * poly6(pred[i].distance_squared_to(pred[j]), h)
	return sum * (visc * dt * 60.0 / rest_density)
