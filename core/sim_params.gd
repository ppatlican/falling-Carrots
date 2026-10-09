## Simulation constants shared by the GPU solver (gpu/particle_sim.gd, sent to the
## shaders as push constants) and the CPU reference (cpu_ref/particle_step.gd).
## Units are art pixels and seconds. The world is the 640x360 base viewport.
extends RefCounted

const WORLD_SIZE := Vector2(640, 360)
## Rest spacing between particle centres, and the contact distance between grains.
const SPACING := 2.0
## SPH kernel radius and hash cell size.
const H := 4.0
## One fixed step per frame. Slower frames slow the sim down rather than destabilise it.
const DT := 1.0 / 60.0
const GRAVITY := 400.0
## Largest move per step. Keeps fast particles from skipping past neighbours.
const MAX_STEP := 4.0

## PBF density constraint relaxation (larger = softer water). In units of
## (1/px)^2 of the normalised constraint gradient, so it scales with H.
const LAMBDA_EPS := 0.01
## Anti-clumping / surface-tension term (Macklin & Mueller 2013): k, with
## n = 4 and dq = 0.2 h fixed in the shader and the CPU reference.
const SCORR_K := 0.02
## Powder contact stiffness per iteration: delta = relax * sum of push-outs.
const CONTACT_RELAX := 0.5
## Stack stiffening (mass scaling by height, as in Macklin et al. 2014 "Unified
## Particle Physics"): in a contact the lower particle acts exp(STACK_K * dy) times
## heavier, so piles hold their shape under load instead of crushing. Per px of dy.
## Powder-powder contacts only (liquids get their depth pressure from the hydro grid).
const STACK_K := 0.3
## Share of a powder-liquid contact's push-out that the powder takes; the liquid takes
## the rest. Low, so water yields and can't push sand grains apart (see powder.glslinc).
const POWDER_LIQUID_SHARE := 0.1
## Fastest a powder grain may move away from a contact because of the push-out alone
## (px/s). 0 makes sand inelastic: overlap is still resolved, but a push-out never adds
## velocity away from a contact. At 15 the impacts of falling grains rebounded them
## upward (the "edges send particles up" bug, measured in cpu_ref), so it is now 0.
const MAX_SEPARATION := 0.0
## Share of its friction a powder grain loses when fully surrounded by liquid. Lets
## sand under water slump and settle under the water instead of trapping it.
const WET_SLIP := 0.9
## Powder sleeping (velocity_update.glsl): a grain the solver stopped that moved less
## than this (px) in a step stays put with zero velocity. Below gravity * DT^2.
const SLEEP_DISTANCE := 0.1

## Liquids (velocity_update.glsl): the speed the solver's correction may add in its own
## direction in one step, in units of GRAVITY * DT. Stops the solver launching water.
const LIQUID_KICK := 2.0

## Liquid density projection on a coarse grid (gpu/shaders/sim/hydro.glslinc): cell size
## in hash cells, the density (over rest) below which a cell is air, the SOR
## over-relaxation, the share of a cell's compression removed per step, the density from
## which the cell above counts as full (thin cells under full water are pulled full), and
## the red-black sweeps per frame (warm-started from the last frame). Fewer sweeps don't
## converge in deep water: 16 left 50k water moving at 6.5 px/s with a 12 px tilt
## instead of at rest (GPU probe). The sweeps are most of the pass's cost.
const HYDRO_CELL := 4
const HYDRO_AIR := 0.3
const HYDRO_SOR := 1.8
const HYDRO_K := 0.5
const HYDRO_FULL := 0.95
## Powder density over rest above which a thin cell isn't pulled full: it is sand, not air.
const HYDRO_POWDER := 0.05
const HYDRO_SWEEPS := 32

## Brush: radius in px, and the fraction of the circle's empty capacity added per frame.
const BRUSH_RADIUS := 10.0
const BRUSH_FILL := 0.3
## Benchmark fill: one press adds a block of this many particles (BENCH_COLS wide).
const BENCH_BLOCK := 10000
const BENCH_COLS := 250


static func grid_size() -> Vector2i:
	return Vector2i(ceili(WORLD_SIZE.x / H), ceili(WORLD_SIZE.y / H))


## Particles a brush stroke adds per frame.
static func brush_rate() -> int:
	return maxi(1, roundi(PI * BRUSH_RADIUS * BRUSH_RADIUS / (SPACING * SPACING) * BRUSH_FILL))
