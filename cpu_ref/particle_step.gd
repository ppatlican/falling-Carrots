## CPU reference: simplified 2D PBD particle step (spec 2.6 steps 2-5).
## Mirrors the GPU passes in gpu/shaders/sim/ one for one, in plain readable form:
##   predict  -> gravity, step clamp, wall clamp            (predict.glsl)
##   hash     -> neighbours within H                         (hash_*.glsl, scan_*.glsl)
##   hydro    -> liquid density projection grid               (hydro_*.glsl)
##   solve    -> grid pressure push, then                   (solve_pressure.glsl)
##               per iteration: lambda, delta, apply         (solve_*.glsl)
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
## SCORR_K is per 1/60 s step and scales with dt^2 (a position push standing in for a force).
static func scorr(r2: float, h: float, dt: float) -> float:
	var w := poly6(r2, h) / poly6(0.04 * h * h, h)
	return -SimParams.SCORR_K * pow(dt * 60.0, 2.0) * w * w * w * w


# --- Step -------------------------------------------------------------------------

## Advances particles one frame. state: "pos", "vel" (PackedVector2Array) and
## "material" (PackedInt32Array), all the same length, and optionally "hydro_p"
## (PackedFloat32Array, the density projection grid's pressure from the last frame;
## added at 0 if missing). Modified in place.
func step(state: Dictionary, dt: float, iterations: int) -> void:
	var pos: PackedVector2Array = state.pos
	var vel: PackedVector2Array = state.vel
	var mat: PackedInt32Array = state.material
	var n := pos.size()
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
		pred[i] = _clamp_to_world(pos[i] + move, i)

	# Neighbour lists from the predicted positions (the GPU rebuilds its hash here too).
	var neighbours := _find_neighbours(pred, h)

	# Density projection grid, then its push on liquids (hydro_*.glsl, solve_pressure.glsl).
	var phi := _hydro_density(pred, mat)
	_hydro_solve(phi, hydro_p, dt)
	var delta := PackedVector2Array()
	delta.resize(n)
	for i in n:
		if _class(mat[i]) != LIQUID:
			delta[i] = Vector2.ZERO
			continue
		var d := _hydro_delta(pred[i], phi, hydro_p, dt)
		if not _hydro_submerged(pred[i], phi):
			d *= hydro_support(_density(i, pred, neighbours[i], h))
		delta[i] = d.limit_length(0.5 * SimParams.SPACING)
	for i in n:
		pred[i] = _apply_delta(i, pos[i], pred[i] + delta[i], mat[i])

	# Solver iterations: lambda, delta, apply.
	var lambda := PackedFloat32Array()
	lambda.resize(n)
	for _it in iterations:
		for i in n:
			lambda[i] = minf(_lambda(i, pred, mat, neighbours[i], h), 0.0) if _class(mat[i]) == LIQUID else 0.0
		for i in n:
			var d := Vector2.ZERO
			if _class(mat[i]) == LIQUID:
				d = _liquid_delta(i, pred, mat, lambda, neighbours[i], h, dt)
			d += _contact_delta(i, pos, pred, mat, neighbours[i])
			delta[i] = d.limit_length(0.5 * SimParams.SPACING)
		for i in n:
			pred[i] = _apply_delta(i, pos[i], pred[i] + delta[i], mat[i])

	# Velocity update, drag, then XSPH viscosity from the raw velocities.
	var new_vel := PackedVector2Array()
	new_vel.resize(n)
	for i in n:
		var v := (pred[i] - pos[i]) / dt
		var v_pre := vel[i].limit_length(SimParams.MAX_STEP / dt)
		if _class(mat[i]) == POWDER:
			# Sleeping (velocity_update.glsl): a stopped grain that barely moved stays put.
			var stopped := (v - v_pre).length() > 0.5 * SimParams.GRAVITY * dt
			if stopped and pred[i].distance_to(pos[i]) < SimParams.SLEEP_SPEED * dt:
				pred[i] = pos[i]
				v = Vector2.ZERO
			v = limit_separation(v, v_pre, SimParams.MAX_SEPARATION, 0.0)
		else:
			v = limit_separation(v, v_pre, 0.0, SimParams.LIQUID_KICK * SimParams.GRAVITY * dt)
		vel[i] = v * exp(-materials[mat[i]].drag * dt)
	for i in n:
		new_vel[i] = vel[i] + _xsph(i, pred, vel, mat, neighbours[i], h, dt)
	for i in n:
		vel[i] = new_vel[i]
		pos[i] = pred[i]
	state.pos = pos
	state.vel = vel
	state.hydro_p = hydro_p


## The solver's correction may stop a particle but leave it at most
## max(sep, its speed along the correction before the solver) + kick in that direction.
## Powders: sep MAX_SEPARATION, kick 0. Liquids: sep 0, kick LIQUID_KICK * GRAVITY * dt.
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
	var c := density / rest_density - 1.0
	return -c / (grad_sum + grad_i.length_squared() + SimParams.LAMBDA_EPS)


func _liquid_delta(i: int, pred: PackedVector2Array, mat: PackedInt32Array, lambda: PackedFloat32Array,
		nb: PackedInt32Array, h: float, dt: float) -> Vector2:
	var wall := wall_density(pred[i], h, rest_density, world_size)
	var d := lambda[i] * Vector2(wall.y, wall.z)
	for j in nb:
		var rv := pred[i] - pred[j]
		var lj := lambda[j] if _class(mat[j]) == LIQUID else 0.0
		d += (lambda[i] + lj + scorr(rv.length_squared(), h, dt)) * spiky_grad(rv, h, i, j)
	return d / rest_density


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
	for _s in SimParams.HYDRO_SWEEPS:
		for parity in 2:
			for c in phi.size():
				var ci := Vector2i(c % size.x, c / size.x)
				if (ci.x + ci.y) % 2 != parity:
					continue
				if phi[c].x < SimParams.HYDRO_AIR:
					p[c] = 0.0
					continue
				var sum := 0.0
				var n := 0.0
				for off in offs:
					var nc: Vector2i = ci + off
					if nc.x < 0 or nc.y < 0 or nc.x >= size.x or nc.y >= size.y:
						continue
					var ni := nc.y * size.x + nc.x
					n += 1.0
					sum += 0.0 if phi[ni].x < SimParams.HYDRO_AIR else p[ni]
				# Thin cells are pulled full only under full water and without powder (a trapped bubble).
				var covered := ci.y > 0 and phi[c - size.x].x >= SimParams.HYDRO_FULL and phi[c].y < SimParams.HYDRO_POWDER
				var err := phi[c].x - 1.0 if covered else maxf(phi[c].x - 1.0, 0.0)
				var k := 1.0 - pow(1.0 - SimParams.HYDRO_K, dt * 60.0)  # share per step (hydro_k())
				var rhs := -a * a * k * err / (dt * dt)
				p[c] = maxf(lerpf(p[c], (sum - rhs) / n, SimParams.HYDRO_SOR), 0.0)


## Pressure at coarse cell c, mirrored past the grid edge (hydro_p_at).
func _hydro_p_at(c: Vector2i, phi: PackedVector2Array, p: PackedFloat32Array) -> float:
	var size := hydro_size(world_size)
	var cc := c.clamp(Vector2i.ZERO, size - Vector2i.ONE)
	var i := cc.y * size.x + cc.x
	return 0.0 if phi[i].x < SimParams.HYDRO_AIR else p[i]


func _hydro_p_sample(x: Vector2, phi: PackedVector2Array, p: PackedFloat32Array) -> float:
	var g := x / hydro_cell_size() - Vector2(0.5, 0.5)
	var b := Vector2i(g.floor())
	var f := g - Vector2(b)
	var top := lerpf(_hydro_p_at(b, phi, p), _hydro_p_at(b + Vector2i(1, 0), phi, p), f.x)
	var bottom := lerpf(_hydro_p_at(b + Vector2i(0, 1), phi, p), _hydro_p_at(b + Vector2i(1, 1), phi, p), f.x)
	return lerpf(top, bottom, f.y)


## Bilinear liquid density over rest at x (hydro_phi_sample).
func _hydro_phi_sample(x: Vector2, phi: PackedVector2Array) -> float:
	var size := hydro_size(world_size)
	var g := x / hydro_cell_size() - Vector2(0.5, 0.5)
	var b := Vector2i(g.floor())
	var f := g - Vector2(b)
	var at := func(c: Vector2i) -> float:
		var cc := c.clamp(Vector2i.ZERO, size - Vector2i.ONE)
		return phi[cc.y * size.x + cc.x].x
	var top := lerpf(at.call(b), at.call(b + Vector2i(1, 0)), f.x)
	var bottom := lerpf(at.call(b + Vector2i(0, 1)), at.call(b + Vector2i(1, 1)), f.x)
	return lerpf(top, bottom, f.y)


## Under full water: takes all of the grid's push (hydro_submerged).
func _hydro_submerged(x: Vector2, phi: PackedVector2Array) -> bool:
	return _hydro_phi_sample(x - Vector2(0.0, 0.5 * hydro_cell_size()), phi) >= SimParams.HYDRO_FULL


## Share of the grid's push a liquid particle near the surface takes, from its density
## over rest (hydro_support).
static func hydro_support(density: float) -> float:
	return lerpf(SimParams.HYDRO_LONE_MIN, 1.0, smoothstep(SimParams.HYDRO_LONE_LO, SimParams.HYDRO_LONE_HI, density))


## Density over rest at i: itself, its neighbours and the walls (liquid_density).
func _density(i: int, pred: PackedVector2Array, nb: PackedInt32Array, h: float) -> float:
	var density: float = poly6(0.0, h) + wall_density(pred[i], h, rest_density, world_size).x
	for j in nb:
		density += poly6((pred[i] - pred[j]).length_squared(), h)
	return density / rest_density


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
