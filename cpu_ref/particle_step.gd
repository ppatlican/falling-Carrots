## CPU reference: simplified 2D PBD particle step (spec 2.6 steps 2-5).
## Mirrors the GPU passes in gpu/shaders/sim/ one for one, in plain readable form:
##   predict  -> gravity, step clamp, wall clamp            (predict.glsl)
##   hash     -> neighbours within H                         (hash_*.glsl, scan_*.glsl)
##   hydro    -> liquid density projection grid               (hydro_*.glsl)
##   solve    -> grid pressure push, then                   (solve_pressure.glsl)
##               per iteration: lambda, delta, apply         (solve_*.glsl)
##               liquids: PBF density constraint (liquid.glslinc)
##               powders: frictional contacts   (powder.glslinc)
##               bodies: contacts as powders (powder.glslinc), then shape
##               matching (body_match.glsl; ADR 0002)
##   velocity -> v = (pred - pos) / dt, drag, XSPH, commit   (velocity_*.glsl)
## Kernels are the 2D poly6 (density) and spiky (gradient) kernels.
## Density is normalised: rho_hat = sum(W) / rest_density, so 1.0 is rest.
extends RefCounted

const SimParams = preload("res://core/sim_params.gd")

const LIQUID := 0
const POWDER := 1
## Below this distance two particles count as coincident (see pair_dir).
const MIN_DIST := 1e-4
## Shape matching keeps a body's last rotation when |A_pq| (the length of the vector its
## angle comes from) is below this, per live member, in px^2.
const BODY_ROT_EPS := 1e-4

## World box particles are kept inside.
var world_size: Vector2
## Per material id: { "class": int, "density", "friction", "viscosity", "drag", "stiffness" }.
var materials: Dictionary
var rest_density: float


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
	var bodies: Array = state.get("bodies", [])
	var members: PackedInt32Array = state.get("members", PackedInt32Array())
	var h := SimParams.H
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

	# Density projection grid, then its push on liquids (hydro_*.glsl, solve_pressure.glsl).
	var phi := _hydro_density(pred, mat)
	_hydro_solve(phi, hydro_p, dt)
	var delta := PackedVector2Array()
	delta.resize(n)
	for i in n:
		delta[i] = _hydro_delta(pred[i], phi, hydro_p, dt).limit_length(0.5 * SimParams.SPACING) \
				if _class(mat[i]) == LIQUID else Vector2.ZERO
	for i in n:
		pred[i] = _apply_delta(i, pos[i], pred[i] + delta[i], mat[i], body[i] != 0)

	# Solver iterations: lambda, delta, apply, then shape matching.
	var lambda := PackedFloat32Array()
	lambda.resize(n)
	for _it in iterations:
		for i in n:
			lambda[i] = minf(_lambda(i, pred, mat, neighbours[i], h), 0.0) if _class(mat[i]) == LIQUID else 0.0
		for i in n:
			var d := Vector2.ZERO
			if _class(mat[i]) == LIQUID:
				d = _liquid_delta(i, pred, mat, lambda, neighbours[i], h, dt)
			d += _contact_delta(i, pos, pred, mat, body, bodies, neighbours[i])
			delta[i] = d.limit_length(0.5 * SimParams.SPACING)
		for i in n:
			pred[i] = _apply_delta(i, pos[i], pred[i] + delta[i], mat[i], body[i] != 0)
		_match_shapes(pred, mat, body, rest, bodies, members, dt, iterations)

	# Velocity update, drag, then XSPH viscosity from the raw velocities.
	var new_vel := PackedVector2Array()
	new_vel.resize(n)
	for i in n:
		var v := (pred[i] - pos[i]) / dt
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
				+ _powder_liquid_drag(i, pred, vel, mat, neighbours[i], h, dt)
	for i in n:
		vel[i] = new_vel[i]
		pos[i] = pred[i]
	state.pos = pos
	state.vel = vel
	state.hydro_p = hydro_p


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


## PBF lambda. Liquid neighbours count toward density, grains at their solid share
## (LIQUID_POWDER_SHARE, liquid.glslinc), but only liquid neighbours move, so only they
## add to the gradient sum.
func _lambda(i: int, pred: PackedVector2Array, mat: PackedInt32Array, nb: PackedInt32Array, h: float) -> float:
	var wall := wall_density(pred[i], h, rest_density, world_size)
	var density: float = poly6(0.0, h) + wall.x
	var grad_i := Vector2(wall.y, wall.z) / rest_density
	var grad_sum := 0.0
	for j in nb:
		if _class(mat[j]) == POWDER:
			var rp := pred[i] - pred[j]
			density += SimParams.LIQUID_POWDER_SHARE * poly6(rp.length_squared(), h)
			grad_i += SimParams.LIQUID_POWDER_SHARE * spiky_grad(rp, h, i, j) / rest_density
			continue
		if _class(mat[j]) != LIQUID:
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
	for j in nb:
		if _class(mat[j]) == POWDER:
			d += lambda[i] * SimParams.LIQUID_POWDER_SHARE * spiky_grad(pred[i] - pred[j], h, i, j)
			continue
		if _class(mat[j]) != LIQUID:
			continue
		var rv := pred[i] - pred[j]
		d += (lambda[i] + lambda[j] + scorr(rv.length_squared(), h, dt)) * spiky_grad(rv, h, i, j)
	return d / rest_density


# --- Cluster solids (ADR 0002) ------------------------------------------------------

## Shape matching (Mueller et al. 2005, rotation only), after each iteration's apply step.
## Per body: its live members (a member counts only while it carries the body's id), their
## centroid c, the rest centroid c0 of their rest offsets, A_pq = sum (p - c)(q - c0)^T and
## the rotation from it (kept when live < 2 or |A_pq| is near 0); then every live member
## moves toward its goal c + R(q - c0) by k = 1 - (1 - stiffness)^(dt * 60 / iterations),
## so stiffness is the share of the shape error removed per 1/60 s. Mirrored by the fused
## body pass, body_match.glsl (one workgroup per body).
func _match_shapes(pred: PackedVector2Array, mat: PackedInt32Array, body: PackedInt32Array,
		rest: PackedVector2Array, bodies: Array, members: PackedInt32Array, dt: float, iterations: int) -> void:
	for id in range(1, bodies.size()):
		var b: Dictionary = bodies[id]
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
		var k := 1.0 - pow(1.0 - s, dt * 60.0 / iterations)
		var rot: Vector2 = b.rot
		for m in live:
			var q := rest[m] - c0
			var goal := c + Vector2(rot.x * q.x - rot.y * q.y, rot.y * q.x + rot.x * q.y)
			pred[m] += k * (goal - pred[m])


## Makes one body of `material` from spawned positions (the body brush, Milestone 3 step 5;
## on the GPU, ParticleSim.make_body):
## appends its particles at rest, takes the lowest free body id, sets rest offsets from the
## positions (relative to their mean) and gives it a member range (first fit). Adds the body
## keys to state when missing:
##   "body": PackedInt32Array, body id per particle, 0 = none; ids 1..N
##   "rest": PackedVector2Array, rest offset per particle (px)
##   "bodies": Array, index 0 unused; per body { first, count, live, centroid,
##             rot (Vector2(cos, sin)), rest_centroid }, as the GPU's body records
##   "members": PackedInt32Array, particle indices; body b owns [first, first + count)
## Returns the body id.
static func make_body(state: Dictionary, positions: PackedVector2Array, material: int) -> int:
	_ensure_body_keys(state)
	var pos: PackedVector2Array = state.pos
	var vel: PackedVector2Array = state.vel
	var mat: PackedInt32Array = state.material
	var body: PackedInt32Array = state.body
	var rest: PackedVector2Array = state.rest
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
	for k in count:
		members[first + k] = pos.size()
		pos.append(positions[k])
		vel.append(Vector2.ZERO)
		mat.append(material)
		body.append(id)
		rest.append(positions[k] - mean)
	bodies[id] = {"first": first, "count": count, "live": count, "centroid": mean,
			"rot": Vector2(1.0, 0.0), "rest_centroid": Vector2.ZERO}
	state.pos = pos
	state.vel = vel
	state.material = mat
	state.body = body
	state.rest = rest
	state.members = members
	return id


## Removes particles (the eraser) and remaps the member lists and ranges, so what is left of
## a body keeps matching its own shape. A body left with no members frees its id and range.
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
	for key in ["pos", "vel", "material", "body", "rest"]:
		var old = state[key]
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
		b.count = members.size() - first
		b.live = b.count
	state.members = members


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
	if not state.has("bodies"):
		state.bodies = [{"first": 0, "count": 0, "live": 0, "centroid": Vector2.ZERO,
				"rot": Vector2(1.0, 0.0), "rest_centroid": Vector2.ZERO}]
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


## Liquid (x) and powder (y) density over rest per coarse cell: each particle's tent
## weight on the four nearest cell centres (hydro_splat), over the weight at rest spacing
## of the part of the tent inside the world (hydro_density).
func _hydro_density(pred: PackedVector2Array, mat: PackedInt32Array) -> PackedVector2Array:
	var size := hydro_size(world_size)
	var a := hydro_cell_size()
	var sum := PackedVector2Array()
	sum.resize(size.x * size.y)
	for i in pred.size():
		if _class(mat[i]) != LIQUID and _class(mat[i]) != POWDER:
			continue
		var channel := Vector2(1.0, 0.0) if _class(mat[i]) == LIQUID else Vector2(0.0, 1.0)
		var g := pred[i] / a - Vector2(0.5, 0.5)
		var b := Vector2i(g.floor())
		var f := g - Vector2(b)
		for dy in 2:
			for dx in 2:
				var c := b + Vector2i(dx, dy)
				if c.x < 0 or c.y < 0 or c.x >= size.x or c.y >= size.y:
					continue
				sum[c.y * size.x + c.x] += channel * (f.x if dx == 1 else 1.0 - f.x) * (f.y if dy == 1 else 1.0 - f.y)
	for c in sum.size():
		var centre := (Vector2(c % size.x, c / size.x) + Vector2(0.5, 0.5)) * a
		var inside := hydro_tent_inside(centre.x, a, world_size.x) * hydro_tent_inside(centre.y, a, world_size.y)
		sum[c] *= SimParams.SPACING * SimParams.SPACING / (a * a * inside)
	return sum


## HYDRO_SWEEPS projected red-black SOR sweeps on p, in place (hydro_sweep).
func _hydro_solve(phi: PackedVector2Array, p: PackedFloat32Array, dt: float) -> void:
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
				var air := not solid and phi[c].x < SimParams.HYDRO_AIR
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
					var air_n := not solid_n and phi[ni].x < SimParams.HYDRO_AIR
					if solid:
						if not air_n:  # sand bed: the water's pressure continued hydrostatically
							sum += p[ni] - head * off.y
							n += 1.0
					elif solid_n:
						if not air:  # a wall holding the water's weight: dp/dn = rho g . n
							wall_sum += head * off.y
					elif air:
						if not air_n:  # ghost: liquid p extrapolated through 0 at the surface
							sum += p[ni] * (1.0 - 1.0 / _hydro_theta(phi[ni].x, phi[c].x))
							n += 1.0
					elif air_n:
						n += 1.0 / _hydro_theta(phi[c].x, phi[ni].x)
					else:
						n += 1.0
						sum += p[ni]
				if solid:
					p[c] = maxf(sum / n, 0.0) if n > 0.0 else 0.0
					continue
				if air:
					p[c] = sum / n if n > 0.0 else 0.0
					continue
				if n == 0.0:  # walled in by sand on every side
					p[c] = maxf(p[c], 0.0)
					continue
				# Under a full cell (water and powder), a cell with room left is pulled full (a trapped bubble).
				# Never in the floor row: half outside the world, it reads a little short of full.
				var covered := ci.y > 0 and ci.y < size.y - 1 and phi[c - size.x].x + phi[c - size.x].y * SimParams.HYDRO_POWDER_VOL >= SimParams.HYDRO_FULL
				var err := maxf(phi[c].x - 1.0, 0.0)
				if covered:
					err += minf(phi[c].x + phi[c].y * SimParams.HYDRO_POWDER_FULL - 1.0, 0.0)
				var k := 1.0 - pow(1.0 - SimParams.HYDRO_K, dt * 60.0)  # share per step (hydro_k())
				var rhs := -a * a * k * err / (dt * dt)
				p[c] = maxf(lerpf(maxf(p[c], 0.0), (sum + wall_sum - rhs) / n, SimParams.HYDRO_SOR), 0.0)


## True when a cell is sand bed: a solid wall for the grid (hydro_solid).
static func hydro_solid(phi_c: Vector2) -> bool:
	return phi_c.y * SimParams.HYDRO_POWDER_VOL >= SimParams.HYDRO_SOLID


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
func _hydro_p_at(c: Vector2i, phi: PackedVector2Array, p: PackedFloat32Array) -> float:
	var size := hydro_size(world_size)
	var cc := c.clamp(Vector2i.ZERO, size - Vector2i.ONE)
	var i := cc.y * size.x + cc.x
	return p[i]


func _hydro_p_sample(x: Vector2, phi: PackedVector2Array, p: PackedFloat32Array) -> float:
	var g := x / hydro_cell_size() - Vector2(0.5, 0.5)
	var b := Vector2i(g.floor())
	var f := g - Vector2(b)
	var top := lerpf(_hydro_p_at(b, phi, p), _hydro_p_at(b + Vector2i(1, 0), phi, p), f.x)
	var bottom := lerpf(_hydro_p_at(b + Vector2i(0, 1), phi, p), _hydro_p_at(b + Vector2i(1, 1), phi, p), f.x)
	return maxf(lerpf(top, bottom, f.y), 0.0)


## Position change this step from the grid pressure: -grad p * dt^2 (hydro_delta).
func _hydro_delta(x: Vector2, phi: PackedVector2Array, p: PackedFloat32Array, dt: float) -> Vector2:
	var e := 0.5 * hydro_cell_size()
	var grad := Vector2(
			_hydro_p_sample(x + Vector2(e, 0.0), phi, p) - _hydro_p_sample(x - Vector2(e, 0.0), phi, p),
			_hydro_p_sample(x + Vector2(0.0, e), phi, p) - _hydro_p_sample(x - Vector2(0.0, e), phi, p)) / (2.0 * e)
	return -grad * dt * dt


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


## Contacts with any particle closer than SPACING (POWDER_LIQUID_REACH x SPACING for a
## powder-liquid pair), where at least one side is a powder or the two are in different
## bodies: body particles follow the powder rule. Same-body pairs are left to shape matching;
## body-liquid pairs wait for Milestone 3 step 4. Mass-weighted push-out, the lower side
## heavier by STACK_K (see stack_weight); also static/kinetic friction on the relative
## sideways motion.
## Scaled by CONTACT_RELAX; summed for powders and bodies, averaged over the grains it touches
## for a liquid (see powder.glslinc).
func _contact_delta(i: int, pos: PackedVector2Array, pred: PackedVector2Array, mat: PackedInt32Array,
		body: PackedInt32Array, bodies: Array, nb: PackedInt32Array) -> Vector2:
	var mi: Dictionary = materials[mat[i]]
	var sum := Vector2.ZERO
	var fric := Vector2.ZERO
	var n_near := 0
	var n_wet := 0
	var fric_w := 0.0
	var n_touch := 0.0
	for j in nb:
		var mj: Dictionary = materials[mat[j]]
		if mi["class"] != POWDER and mj["class"] != POWDER and (body[i] == 0 or body[j] == 0):
			continue  # liquid-liquid is handled by the density constraint; body-liquid not yet
		if body[i] != 0 and body[i] == body[j]:
			continue  # same body: shape matching holds it together
		var rv := pred[i] - pred[j]
		var dist := rv.length()
		if dist < SimParams.H:
			n_near += 1
			if mj["class"] == LIQUID:
				n_wet += 1
		var mixed: bool = mi["class"] == LIQUID or mj["class"] == LIQUID
		var reach := SimParams.SPACING * (SimParams.POWDER_LIQUID_REACH if mixed else 1.0)
		if dist >= reach:
			continue
		n_touch += 1.0
		var normal := pair_dir(rv, dist, i, j)
		var pen := reach - dist
		var w: float
		if mixed:
			# Powder-liquid: the liquid yields (see POWDER_LIQUID_SHARE).
			w = SimParams.POWDER_LIQUID_SHARE if mi["class"] == POWDER else 1.0 - SimParams.POWDER_LIQUID_SHARE
		else:
			w = mj.density / (mi.density + mj.density)
		var w_push := w
		if mi["class"] == POWDER and mj["class"] == POWDER:
			w_push = stack_weight(mi.density, mj.density, rv.y)
		elif not mixed:
			# A body (or a grain against one) is heavier by the height of its body's centroid
			# under the other side's, so a stack of bodies holds; friction gets the same share,
			# since a stack with mass-weighted friction swayed for good (ADR 0002).
			var yi: float = bodies[body[i]].centroid.y if body[i] != 0 else pred[i].y
			var yj: float = bodies[body[j]].centroid.y if body[j] != 0 else pred[j].y
			w_push = stack_weight(mi.density, mj.density, yi - yj)
			w = w_push
		sum += w_push * pen * normal
		var mu: float = minf(mi.friction, mj.friction)
		if mu > 0.0:
			var rel := (pred[i] - pos[i]) - (pred[j] - pos[j])
			var tangent := rel - rel.dot(normal) * normal
			var t_len := tangent.length()
			if t_len < mu * pen:
				fric -= w * tangent  # static: cancel the slide
			elif t_len > 1e-6:
				fric -= w * tangent * minf(0.8 * mu * pen / t_len, 1.0)  # kinetic
			fric_w += w
	# Friction is averaged over the contacts (divided by their total weight, at least 1),
	# so the correction per iteration stays below CONTACT_RELAX. An unnormalised sum
	# overshoots with many contacts and makes a settled pile wobble.
	fric /= maxf(fric_w, 1.0)
	# Wet grains slip (WET_SLIP): friction drops with the share of liquid neighbours.
	var wet := float(n_wet) / n_near if n_near > 0 else 0.0
	if mi["class"] == LIQUID:
		sum /= maxf(n_touch, 1.0)  # liquid: averaged over the grains it touches (powder.glslinc)
	return (sum + fric * (1.0 - SimParams.WET_SLIP * wet)) * SimParams.CONTACT_RELAX


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
