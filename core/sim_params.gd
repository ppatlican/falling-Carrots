## Simulation constants shared by the GPU solver (gpu/particle_sim.gd, sent to the
## shaders as push constants) and the CPU reference (cpu_ref/particle_step.gd).
## Units are art pixels and seconds. The world is the 640x360 base viewport.
extends RefCounted

const WORLD_SIZE := Vector2(640, 360)
## Rest spacing between particle centres, and the contact distance between grains.
const SPACING := 2.0
## SPH kernel radius and hash cell size.
const H := 4.0
## One fixed frame time, split into substeps (config.json). Slower frames slow the sim
## down rather than destabilise it.
const DT := 1.0 / 60.0
const GRAVITY := 400.0
## Largest move per substep. Keeps fast particles from skipping past neighbours, and caps
## speed at MAX_STEP / (DT / substeps).
const MAX_STEP := 4.0

## PBF density constraint relaxation (larger = softer water). In units of
## (1/px)^2 of the normalised constraint gradient, so it scales with H.
const LAMBDA_EPS := 0.01
## Anti-clumping / surface-tension term (Macklin & Mueller 2013): k per 1/60 s step,
## scaled by dt^2 in the solver (liquid.glslinc), with
## n = 4 and dq = 0.2 h fixed in the shader and the CPU reference.
const SCORR_K := 0.02
## Powder contact stiffness per iteration: delta = relax * sum of push-outs.
const CONTACT_RELAX := 0.5
## Stack stiffening (mass scaling by height, as in Macklin et al. 2014 "Unified
## Particle Physics"): in a contact the lower particle acts exp(STACK_K * dy) times
## heavier, so piles hold their shape under load instead of crushing. Per px of dy.
## Powder-powder contacts, and contacts with a body, where dy is the height between body
## centroids (ADR 0002). Liquids get their depth pressure from the hydro grid.
const STACK_K := 0.3
## Share of a powder-liquid contact's push-out that the powder takes; the liquid takes
## the rest. Low, so water yields and can't push sand grains apart (see powder.glslinc).
const POWDER_LIQUID_SHARE := 0.1
## Contact distance of a powder-liquid pair, in spacings: water passes between grains, so a
## sand bed can drain and pack (see powder.glslinc).
const POWDER_LIQUID_REACH := 0.6
## Share of a liquid's density one powder grain counts for, its solid volume: sand under
## water packs to ~1.1 and is ~60% grain, 40% pore, so 0.6 x HYDRO_POWDER_FULL (see
## liquid.glslinc).
const LIQUID_POWDER_SHARE := 0.54
## Quadratic drag of a grain toward the liquid around it, per px/s of relative speed per
## second: grains sink through water at ~sqrt(GRAVITY / it) (see powder.glslinc).
const POWDER_LIQUID_DRAG := 0.06
## Linear drag of a body particle toward the liquid around it, per second, scaled by how much
## liquid is around it (ADR 0003): damps a floating body's heave and rocking.
## Mirror: BODY_LIQUID_DRAG in powder.glslinc.
const BODY_LIQUID_DRAG := 20.0
## How far (px) the density projection grid's free surface (p = 0) sits above the surface of
## the top water particles: a body's reference pressure is at least GRAVITY x this, so a
## floating body (its p_min is 0) floats level with the water it shows (ADR 0003 item 4).
## Mirror: BODY_SURFACE_DROP in body_match.glsl.
const BODY_SURFACE_DROP := 2.5
## Liquid fill of the grid at a wet body's outline point from which that face is under water,
## between grains or in a void, even with no water particle on it (ADR 0003 item 15). A dry
## sand bed reads 0, a saturated one under a pool 0.02-0.26.
## Mirror: BODY_PORE_WET in solve_pressure.glsl.
const BODY_PORE_WET := 0.02
## Fastest a powder grain may move away from a contact because of the push-out alone
## (px/s). 0 makes sand inelastic: overlap is still resolved, but a push-out never adds
## velocity away from a contact. At 15 the impacts of falling grains rebounded them
## upward (the "edges send particles up" bug, measured in cpu_ref), so it is now 0.
const MAX_SEPARATION := 0.0
## Share of its friction a powder grain loses when fully surrounded by liquid. Lets
## sand under water slump and settle under the water instead of trapping it.
const WET_SLIP := 0.9
## Powder sleeping (velocity_update.glsl): a grain the solver stopped that moved slower
## than this (px/s) in a step stays put with zero velocity. 0.1 px per 1/60 s step.
const SLEEP_SPEED := 6.0

## Liquids (velocity_update.glsl): the speed the solver's correction may add in its own
## direction in one step, in units of GRAVITY * DT. Stops the solver launching water.
const LIQUID_KICK := 2.0
## Body particles (cluster solids, ADR 0002): the same cap, in units of GRAVITY * DT. A box
## spawned into the floor or pushed out of another body may leave at most this much faster.
## Shape matching still moves the particles; only the speed it leaves them is capped.
## Mirror: BODY_KICK in velocity_update.glsl.
const BODY_KICK := 4.0
## Swept contacts between bodies (ADR 0003 item 14), in spacings: the deepest a member may
## already be inside another body's outline at the start of a substep and still count as coming
## from outside, and the least it must go further in that substep. Slower approaches are left to
## the contacts and push-out (without the least depth a 5-box stack leaned and never rested).
## Mirror: SWEEP_DEPTH in body_sweep.glsl.
const SWEEP_DEPTH := 0.25

## Liquid density projection on a coarse grid (gpu/shaders/sim/hydro.glslinc): cell size
## in hash cells, the density (over rest) below which a cell is air, the SOR
## over-relaxation, the share of a cell's compression removed per 1/60 s, the density from
## which the cell above counts as full (thin cells under full water are pulled full), and
## the red-black sweeps per frame (warm-started from the last frame). Fewer sweeps don't
## converge in deep water: 16 left 50k water moving at 6.5 px/s with a 12 px tilt
## instead of at rest (GPU probe). All sweeps run in one workgroup (hydro_solve.glsl).
## Mirror: HYDRO_SWEEPS in hydro.glslinc.
const HYDRO_CELL := 4
const HYDRO_AIR := 0.3
const HYDRO_SOR := 1.8
const HYDRO_K := 0.5
const HYDRO_FULL := 0.95
## Share of a cell one unit of powder density fills (sand packs to ~1.4x the water's rest
## density). Powder counts toward a cell being full, so a gap next to sinking sand closes.
const HYDRO_POWDER_VOL := 0.7
## A cell whose powder fills at least this share (powder * HYDRO_POWDER_VOL) is sand bed: a
## wall that holds the water's weight (dp/dn = rho g . n), with the water's pressure
## continued hydrostatically into its pores.
const HYDRO_SOLID := 0.5
## Share of a cell one unit of powder density fills when the grid checks a cell for room
## left (an air bubble to pull closed): sand under water packs to only ~1.1 and water can't
## get into its pores, so such a cell is full. With HYDRO_POWDER_VOL every cell at a sand
## surface looked ~3% short and sucked water in: a pool over sand mounds circulated over
## the peaks (water_feel_probe mounds).
const HYDRO_POWDER_FULL := 0.9
## Body volume from which a cell is a body's for the grid: it isn't pulled full (water keeps a
## contact gap from a body, so the cell reads short of full though it holds no air), and as
## bed it is a wall to the water beside it, not porous sand. Mirror: hydro_solve.glsl.
const HYDRO_BODY_CELL := 0.05
## A cell short of HYDRO_AIR that holds at least HYDRO_MIXED_WET of liquid and HYDRO_MIXED_SOLID
## of bed fill (sand or body) is under water, not air, when the cell above isn't air: its room
## is the water's gap from the grains and the body. Mirror: hydro_air in hydro_solve.glsl.
const HYDRO_MIXED_WET := 0.02
const HYDRO_MIXED_SOLID := 0.1
## Free surface (ghost fluid): liquid density over rest at the surface, and the smallest
## share of a cell the surface may sit from a liquid cell's centre.
const HYDRO_SURFACE := 0.5
const HYDRO_THETA_MIN := 0.1
const HYDRO_SWEEPS := 32

## Brush: radius in px, and the fraction of the circle's empty capacity added per frame.
const BRUSH_RADIUS := 10.0
const BRUSH_FILL := 0.3
## Body brush (core/body_brush.gd): the most members one stroke may paint. The body pass costs
## ~0.09 µs a frame per member of the largest body (ADR 0002), so 2000 is ~180 µs, until the
## pass is split so several workgroups share a body.
const BODY_BRUSH_MAX := 2000
## Benchmark fill: one press adds a block of this many particles (BENCH_COLS wide).
const BENCH_BLOCK := 10000
const BENCH_COLS := 250


static func grid_size() -> Vector2i:
	return Vector2i(ceili(WORLD_SIZE.x / H), ceili(WORLD_SIZE.y / H))


## Particles a brush stroke adds per frame.
static func brush_rate() -> int:
	return maxi(1, roundi(PI * BRUSH_RADIUS * BRUSH_RADIUS / (SPACING * SPACING) * BRUSH_FILL))
