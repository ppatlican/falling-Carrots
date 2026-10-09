## CPU reference: simplified 2D PBD particle step (spec 2.6 steps 2-5).
## Mirrors the GPU passes in gpu/shaders/sim/ one for one, in plain readable form:
##   predict  -> gravity, step clamp, wall clamp            (predict.glsl)
##   hash     -> neighbours within H                         (hash_*.glsl, scan_*.glsl)
##   solve    -> per iteration: lambda, delta, apply         (solve_*.glsl)
##               liquids: PBF density constraint (liquid.glslinc)
##               powders: frictional contacts   (powder.glslinc)
##   velocity -> v = (pred - pos) / dt, drag, XSPH, commit   (velocity_*.glsl)
## Kernels are the 2D poly6 (density) and spiky (gradient) kernels.
## Density is normalised: rho_hat = sum(W) / rest_density, so 1.0 is rest.
extends RefCounted

const SimParams = preload("res://core/sim_params.gd")

const LIQUID := 0
const POWDER := 1
## Below this distance two particles count as coincident (see pair_dir).
const MIN_DIST := 1e-4

## World box particles are kept inside.
var world_size: Vector2
## Per material id: { "class": int, "density", "friction", "viscosity", "drag" }.
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
static func scorr(r2: float, h: float) -> float:
	var w := poly6(r2, h) / poly6(0.04 * h * h, h)
	return -SimParams.SCORR_K * w * w * w * w


# --- Step -------------------------------------------------------------------------

## Advances particles one frame. state: "pos", "vel" (PackedVector2Array) and
## "material" (PackedInt32Array), all the same length. Modified in place.
func step(state: Dictionary, dt: float, iterations: int) -> void:
	var pos: PackedVector2Array = state.pos
	var vel: PackedVector2Array = state.vel
	var mat: PackedInt32Array = state.material
	var n := pos.size()
	var h := SimParams.H

	# Predict.
	var pred := PackedVector2Array()
	pred.resize(n)
	for i in n:
		vel[i].y += SimParams.GRAVITY * dt
		var move := (vel[i] * dt).limit_length(SimParams.MAX_STEP)
		pred[i] = _clamp_to_world(pos[i] + move, i)

	# Neighbour lists from the predicted positions (the GPU rebuilds its hash here too).
	var neighbours := _find_neighbours(pred, h)

	# Solver iterations: lambda, delta, apply.
	var lambda := PackedFloat32Array()
	lambda.resize(n)
	var delta := PackedVector2Array()
	delta.resize(n)
	for _it in iterations:
		for i in n:
			lambda[i] = _lambda(i, pred, mat, neighbours[i], h) \
					if _class(mat[i]) == LIQUID else 0.0
		for i in n:
			var d := Vector2.ZERO
			if _class(mat[i]) == LIQUID:
				d = _liquid_delta(i, pred, mat, lambda, neighbours[i], h)
			d += _contact_delta(i, pos, pred, mat, neighbours[i])
			delta[i] = d.limit_length(0.5 * SimParams.SPACING)
		for i in n:
			pred[i] = _apply_delta(i, pos[i], pred[i] + delta[i], mat[i])

	# Velocity update, drag, then XSPH viscosity from the raw velocities.
	var new_vel := PackedVector2Array()
	new_vel.resize(n)
	for i in n:
		var v := (pred[i] - pos[i]) / dt
		if _class(mat[i]) == POWDER:
			var v_pre := vel[i].limit_length(SimParams.MAX_STEP / dt)
			# Sleeping (velocity_update.glsl): a stopped grain that barely moved stays put.
			var stopped := (v - v_pre).length() > 0.5 * SimParams.GRAVITY * dt
			if stopped and pred[i].distance_to(pos[i]) < SimParams.SLEEP_DISTANCE:
				pred[i] = pos[i]
				v = Vector2.ZERO
			v = limit_separation(v, v_pre)
		vel[i] = v * (1.0 - materials[mat[i]].drag)
	for i in n:
		new_vel[i] = vel[i] + _xsph(i, pred, vel, mat, neighbours[i], h)
	for i in n:
		vel[i] = new_vel[i]
		pos[i] = pred[i]
	state.pos = pos
	state.vel = vel


## Powder push-out may stop a grain but not launch it faster than MAX_SEPARATION
## in the push direction. v_pre is the velocity the grain was predicted with.
static func limit_separation(v: Vector2, v_pre: Vector2) -> Vector2:
	var dv := v - v_pre
	var dv_len := dv.length()
	if dv_len <= 1e-6:
		return v
	var n := dv / dv_len
	var excess := v.dot(n) - maxf(SimParams.MAX_SEPARATION, v_pre.dot(n))
	return v - excess * n if excess > 0.0 else v


func _class(m: int) -> int:
	return materials[m]["class"]


## Each particle gets its own wall inset (0.5 to 0.75 spacing) so wall clamping
## can't stack particles on exactly the same point. Same as common.glslinc.
func _clamp_to_world(p: Vector2, slot: int) -> Vector2:
	var r := SimParams.SPACING * (0.5 + 0.25 * float(slot % 7) / 6.0)
	return p.clamp(Vector2(r, r), world_size - Vector2(r, r))


## Wall clamp. Powders pressed into a wall get friction. Floor: the sideways move is
## cut by their friction coefficient. Side walls: Coulomb, the vertical move cancelled
## is at most friction x how far the grain was pressed into the wall (solve_apply.glsl).
## Without the side-wall part, contacts push wall grains up the wall.
func _apply_delta(i: int, old: Vector2, p: Vector2, m: int) -> Vector2:
	var c := _clamp_to_world(p, i)
	if _class(m) == POWDER:
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


## PBF lambda. Every neighbour counts toward density (sand fills volume too),
## but only liquid neighbours move, so only they add to the gradient sum.
func _lambda(i: int, pred: PackedVector2Array, mat: PackedInt32Array, nb: PackedInt32Array, h: float) -> float:
	var wall := wall_density(pred[i], h, rest_density, world_size)
	var density: float = poly6(0.0, h) + wall.x
	var grad_i := Vector2(wall.y, wall.z) / rest_density
	var grad_sum := 0.0
	for j in nb:
		var rv := pred[i] - pred[j]
		density += poly6(rv.length_squared(), h)
		var g := spiky_grad(rv, h, i, j) / rest_density
		grad_i += g
		if _class(mat[j]) == LIQUID:
			grad_sum += g.length_squared()
	var c := maxf(density / rest_density - 1.0, 0.0)
	return -c / (grad_sum + grad_i.length_squared() + SimParams.LAMBDA_EPS)


func _liquid_delta(i: int, pred: PackedVector2Array, mat: PackedInt32Array, lambda: PackedFloat32Array,
		nb: PackedInt32Array, h: float) -> Vector2:
	var wall := wall_density(pred[i], h, rest_density, world_size)
	var d := lambda[i] * Vector2(wall.y, wall.z)
	for j in nb:
		var rv := pred[i] - pred[j]
		var liquid_j := _class(mat[j]) == LIQUID
		var lj := lambda[j] if liquid_j else 0.0
		# Liquid pairs are mass-scaled by height like powder stacks (liquid.glslinc).
		var share := 2.0 / (exp(clampf(SimParams.STACK_K * rv.y, -8.0, 8.0)) + 1.0) if liquid_j else 1.0
		d += share * (lambda[i] + lj + scorr(rv.length_squared(), h)) * spiky_grad(rv, h, i, j)
	return d / rest_density


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
## Powder-powder pairs only (see powder.glslinc).
static func stack_weight(m_i: float, m_j: float, rv_y: float) -> float:
	return m_j / (m_i * exp(clampf(SimParams.STACK_K * rv_y, -8.0, 8.0)) + m_j)


## Contacts with any particle closer than SPACING, where at least one side is a
## powder. Mass-weighted push-out; powders also get static/kinetic friction on the
## relative sideways motion. Scaled by CONTACT_RELAX, not averaged (see powder.glslinc).
func _contact_delta(i: int, pos: PackedVector2Array, pred: PackedVector2Array, mat: PackedInt32Array,
		nb: PackedInt32Array) -> Vector2:
	var mi: Dictionary = materials[mat[i]]
	var sum := Vector2.ZERO
	var fric := Vector2.ZERO
	var n_near := 0
	var n_wet := 0
	var fric_w := 0.0
	for j in nb:
		var mj: Dictionary = materials[mat[j]]
		if mi["class"] != POWDER and mj["class"] != POWDER:
			continue  # liquid-liquid is handled by the density constraint
		var rv := pred[i] - pred[j]
		var dist := rv.length()
		if dist < SimParams.H:
			n_near += 1
			if mj["class"] == LIQUID:
				n_wet += 1
		if dist >= SimParams.SPACING:
			continue
		var normal := pair_dir(rv, dist, i, j)
		var pen := SimParams.SPACING - dist
		var w: float
		if (mi["class"] == POWDER) != (mj["class"] == POWDER):
			# Powder-liquid: the liquid yields (see POWDER_LIQUID_SHARE).
			w = SimParams.POWDER_LIQUID_SHARE if mi["class"] == POWDER else 1.0 - SimParams.POWDER_LIQUID_SHARE
		else:
			w = mj.density / (mi.density + mj.density)
		var stack: bool = mi["class"] == POWDER and mj["class"] == POWDER
		sum += (stack_weight(mi.density, mj.density, rv.y) if stack else w) * pen * normal
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
	return (sum + fric * (1.0 - SimParams.WET_SLIP * wet)) * SimParams.CONTACT_RELAX


## XSPH viscosity: liquids blend toward their liquid neighbours' velocity.
func _xsph(i: int, pred: PackedVector2Array, vel: PackedVector2Array, mat: PackedInt32Array,
		nb: PackedInt32Array, h: float) -> Vector2:
	if _class(mat[i]) != LIQUID:
		return Vector2.ZERO
	var visc: float = materials[mat[i]].viscosity
	var sum := Vector2.ZERO
	for j in nb:
		if _class(mat[j]) == LIQUID:
			sum += (vel[j] - vel[i]) * poly6(pred[i].distance_squared_to(pred[j]), h)
	return sum * (visc / rest_density)
