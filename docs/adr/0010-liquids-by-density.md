# 0010: Liquids by density (mass-weighted PBF and grid)

Date: 2026-10-15. Status: accepted (owner, 2026-10-15; answers below). Milestone 3b, STATUS Next item 9 ("per-material liquid density"); fixes STATUS Known issues "Liquids ignore their material density".

## Context
ADR 0001 and SPEC 2.2 say buoyancy comes from each material's density. For liquids the code doesn't do that yet. What it does today (read before writing this):
- **PBF** (`liquid.glslinc`, `ParticleStep._lambda`, `_liquid_delta`). `params.rest_density` is the poly6 kernel sum at rest spacing, so it normalises a number density. It isn't a physical density. Each pair is corrected by `(λ_i + λ_j + scorr) ∇W`, the same on both sides, as if all liquid particles had the same mass. A pair with unequal masses moved equal and opposite distances would add momentum, by `(m_i − m_j) Δx`.
- **Grid push** (`solve_pressure.glsl`, `hydro_delta`). Every liquid particle moves `−∇p dt²`: the acceleration of a liquid with density 1.
- **Grid solve** (`hydro_solve.glsl` `hydro_row`, `ParticleStep._hydro_solve`). It solves `Σ (p_n − p) = −a² k err / dt²` with constant coefficients, which assumes the push above. The floor and body-wall flux terms and the bed's hydrostatic continuation use `head = gravity × a`, which is water's weight.
- **Body level** (`hydro_level`). A body counts at its weight in water, `min(density, 1)` (ADR 0003).
- **Body push** (`body_pressure_delta`). It is p over the body's density, so it already follows whatever p the grid gives. `body_p_sample` continues p below the last row of cells by `gravity × depth`. The p_ref floor is `gravity × BODY_SURFACE_DROP` (`body_match.glsl`).
- **Already reads a liquid's density:** body–liquid contacts share their push-out by `ρ_j / (ρ_i + ρ_j)` (`powder.glslinc`). **Doesn't read it:** grain–liquid contacts use the fixed `POWDER_LIQUID_SHARE` 0.1, and grains get no push from the grid.

So with water alone nothing is wrong. Oil on water, or a liquid density slider, would do nothing except change the body–liquid contact split.

### FleX 2014, 7.1.1 (read for this ADR)
"The density constraint formulation of [Macklin and Müller 2013] treats fluid particles as having equal mass, but by using the mass weighted version of position-based dynamics (Eq. 4) we can simulate fluids and rigid bodies with differing densities." The denominator of λ is precomputed "assum[ing] that neighboring particles have the same mass". For immiscible multi-phase liquids, "fluid particles of different phases [...] contribute to each other's density estimation"; their Rayleigh–Taylor scene uses a density ratio of 4:1. Here every liquid particle has the same volume (the rest-spacing lattice), so its mass is its material's density. The density constraint stays a volume (number-density) constraint, and the mass enters only through how a correction is split and how a pressure accelerates a particle. That is also Solenthaler and Pajarola 2008: density is mass times number density.

## Options
**A. Mass-weighted PBF plus mass-weighted grid** (STATUS's suggestion). Physical: buoyancy is `−∇p/ρ_i + g`, so light liquid rises through heavy, every liquid still falls at g, and bodies and sand see the pressure of the liquid that is actually there.

**B. SunaBox: equal masses, per-material gravity** (`docs/papers.md`, SunaEngine). Cheap: one material read in `predict`, no PBF change. Rejected:
- Everything stops falling at g. A liquid at density 0.5 would pour in slow motion, and the density slider would read as a "fall speed" slider.
- The grid would still need a per-cell weight, `head = g_cell × a`, at the floor and in the bed.
- Bodies and grains weigh contacts by real density (`powder.glslinc`), so liquids would be the one class out of step. A cork's buoyancy in oil would come from oil's lighter gravity, not its lighter weight.
- papers.md already calls it "a cheap stand-in [...] no layering by real density".

**Option A, decided below.**

## Decision
Each liquid particle's mass is its material's `density` (water 1). Every rule below reduces exactly to today's code when every liquid has density 1: each factor is 1.0, exactly, in floating point. So pure water behaves as it does now.

1. **PBF, mass-weighted split** (FleX Eq. 4). λ is computed as now, from the volume constraint, with no material read. In `liquid_delta`, each liquid neighbour pair's term is scaled by i's mass share of the pair, `2 ρ_j / (ρ_i + ρ_j)` (that is, `2 w_i / (w_i + w_j)` with `w = 1/ρ`). Both sides of the pair then change momentum by the same amount in opposite directions, and the pair's total separation is the same as two water particles'. The light side moves at most 2× what it moves today, whatever the ratio. The other terms are unchanged:
   - Walls, grains and body particles don't move with the constraint, so the liquid takes all of their term, as now.
   - `scorr` is part of the pair term, so it is split the same way.

   Cost: one float from the neighbour's material row, which `s_class(j)` already reads, plus a divide, per liquid neighbour. That is the only new per-neighbour code. Fallback if it costs too much: the per-particle form (λ divided by `w_i`, and the sum times `w_i`: momentum is still kept, with no per-neighbour read). Its light side gets `w_i/w_j` of its neighbour's λ, which is unbounded, so the slider's range would need narrowing.
2. **Grid push over the particle's mass:** `hydro_delta(x) / ρ_i` in `solve_pressure` (one material read per liquid particle).
3. **Grid solve with mass-weighted coefficients** (the variable-density Poisson equation, `div((1/ρ) ∇p) = −k err / dt²`). Each face between two liquid cells weighs `1/ρ_face`. `ρ_face` is the two cells' liquid density where they are equal (exactly 1 for water), else their mean weighted by each cell's level (`hydro_level`), so a face to a cell holding little liquid takes the other's density (`hydro_face_rho`). *Changed in the implementation:* it was first the two cells' liquid mass over their liquid volume, read from global memory per face in `hydro_row`; that cost the single-workgroup solve ~40 µs for pure water and ~100 µs with oil (Results). This changes the row weights (`hydro_row`, worked out once per frame) but not the sweeps. Because `(1/ρ) ∇p = g` at rest, the floor and body-wall flux terms stay `head = g × a` for any liquid, and the compression and bubble right-hand side stays in volume. What changes per cell:
   - **Liquid rows:** `w[k] = 1/ρ_face`, and `n` sums the same weights. A surface face weighs `1/ρ_c` (`n += 1/(ρ_c θ)`).
   - **Bed rows:** p continued into the pores from a neighbour is `p_n − ρ_face × head × off.y`, the head of the liquid that is there.
   - **Air rows** (the ghost extrapolation): unchanged. They are an extrapolation, not a flux.

   Without this, the constant-coefficient solve would under- or over-shoot each cell by `w = 1/ρ`. The removed share of compression per substep would be 0.29 × w: 0.59 at density 0.5, 2.9 at 0.1 (which overshoots and pumps). The floor row of a heavy-liquid pool would also sit compressed by about one head.
4. **A fifth grid channel, liquid mass, and a cell density.** Only liquid particles with density ≠ 1 splat their excess `ρ_i − 1` into a fifth `hydro_acc` channel, so pure water does no extra atomics. `hydro_phi.glsl` (one thread per cell) works out the cell's liquid density, mass `x + excess` over volume `x`, into a new buffer, `hydro_rho` (binding 29, `hydro.glslinc`, one float per cell). It is exactly 1 where mass equals volume (water alone: `excess` is 0, so they match bit for bit) or there is no liquid; that is a test on the inputs, since Vulkan's division needn't round exactly and 0.9999999 would change water (`hydro_rho_of`). `hydro_phi` stays a `vec4`. `hydro_solve` loads `hydro_rho` once per cell into shared memory (`s_rho`) with the rest of the cell, so `hydro_row` reads only shared memory. That is 16 B per cell, so `HYDRO_MAX_CELLS` goes from 1024 to 960 to stay under the 16 KB Vulkan minimum (the world's grid is 920 cells). Every other factor is guarded the same way: the pair share is 1 between equal densities, and the push is divided only when ρ ≠ 1. Shader stamp v19 → v20 (the binding is added in a `.glslinc`, and `common.glslinc`'s binding comment changes).
5. **A body in mixed liquid:** `hydro_level` counts a body at `min(phi.w / ρ_cell, phi.z)` (`hydro_phi` does it where `ρ_cell` ≠ 1), its weight in the liquid that is there. In water, `min(phi.w, phi.z) = phi.w`, as now. A floater in oil sits deeper and doesn't drift off its own dent in the surface (ADR 0003's reason for counting by weight). Not exact for a heavy body in a heavy liquid: `phi.w` is splatted clamped at 1, so it counts at `1/ρ_cell` instead of `ρ_b/ρ_cell` (Known limits). It only matters at the surface, where heavy bodies don't stay.
6. **Body buoyancy needs nothing new:** `body_pressure_delta` reads p, which now carries each liquid's weight. A cork in oil floats deeper, and one between oil and water floats at the interface. `body_p_sample`'s continuation below the last row becomes `ρ_cell × gravity × depth`, with `ρ_cell` from that row's cell. The p_ref floor stays `gravity × BODY_SURFACE_DROP` (Known limits).
7. **The bubble pull is by volume, unchanged.** A bubble is missing volume whichever liquid surrounds it, so `covered`, `room` and `HYDRO_ROOF_PULL` don't read density. Through decision 3 its pull moves each liquid by its own mass.
8. **Panel:** liquid `density` joins `PANEL_FIELDS` (curved slider, like the other densities). `CLASS_RANGES` gets liquid density **0.5–2** to start: a ratio of up to 4 against water, FleX's 4:1. It covers petrol (0.7), oil (0.9) and syrup (1.4). Both ends are probed against water, and widened or narrowed from that. The shared 0.1–10 stays for powders and bodies.
9. **Oil ships** (owner, 2026-10-15): a toolbar material, row 5 of `materials.json` (density 0.8, viscosity 0.1, drag 0.15, `#b5b82e`, olive; first `#d9a62b`, which drew oil the same as sand). The tests and probes use it as the second liquid (`gpu_probe oil,water`).

### Mixed-liquid cells, in one place
| | rule | in a cell half oil, half water |
|---|---|---|
| hydrostatic head (floor, body wall) | flux `g × a`, unchanged | same; the weights carry ρ |
| bed continuation | `ρ_face × g × a` | the pore liquid's head |
| face coefficient | `1/ρ_face`, level-weighted mean of the two cells | 1/0.9 |
| bubble pull, compression | volume, unchanged | unchanged |
| push on a particle | `−∇p / ρ_i` | oil up by 1.125 g, water by 0.9 g: they separate |
| body level, body push | weight in the cell's liquid; p | from the mixed p |

### What doesn't change, and why
- **Grains in a liquid.** The powder–liquid split stays at `POWDER_LIQUID_SHARE`, and the grid doesn't push grains. So sand (1.6) sinks through any liquid, even one at 2 (Known limits). Making it follow the liquid's density is a powder-rule change of its own (ADR 0001: constants stay global until a material breaks them).
- **XSPH and liquid drag on bodies and grains** blend velocities without mass weights. An oil–water shear exchanges a little momentum unevenly. That damps; it can't inject energy.
- **Immiscibility.** As in FleX, phases count toward each other's density, and nothing but buoyancy keeps them apart: there is no interfacial tension. A mixed pour separates as it settles; it doesn't stay emulsified.
- **`LIQUID_KICK`** (2 g dt a step) allows the strongest buoyant pull in range: density 0.5 in water rises at a net g.

## Plan
1. CPU reference (`ParticleStep`: `_liquid_delta`, the `_hydro_delta` call site, `_hydro_density` with the mass channel, `_hydro_solve`, `hydro_level`, `_body_p_sample`) and tests in `tests/test_hydro_grid.gd` or a new `test_liquid_density.gd` (`@liquids @hydro`):
   - oil poured under water ends as a layer on top, and water poured under oil ends underneath (red on main);
   - an oil-only pool settles like water (surface, floor density);
   - a cork floats deeper in oil than in water;
   - pure water's numbers match main to the bit on a fixed scene.
2. GPU shaders mirroring it, stamp v20; `particle_sim.gd` makes and binds `hydro_rho`, and `hydro_acc` grows to 5 channels.
3. `MaterialTable`: the range, the panel field, tests in `test_parameters.gd`.
4. Verify as the task lists (AGENTS.md): CPU `@quick @setup @hydro @liquids @bodies-water`; GPU `gpu_probe water` (both drop patterns, `every=47`), `water_feel_probe surface,bowl`, `body_probe watersink,waterfloat,waterbig,corkstrip,pourfloor,sandcorks`, the sand checks, `set=water.density=0.5` and `=2`, and a layering scenario (new: `water_feel_probe layers`: oil blocks then water blocks, and the reverse; the oil and water mean heights and the share of each in the other's layer, on plateaus). Timing of `hydro` and `solve` against main, back to back, `--disable-vsync`. `main.tscn` screenshots of oil on water and water under oil.

## Owner's answers (2026-10-15)
1. Oil: a toolbar material now.
2. The liquid density range: the implementer's call (0.5–2, from the probes; Results).
3. Sand sinking through any liquid density: fine for now. Why it does: a grain feels no grid pressure; it meets liquid only through contacts, split by the fixed `POWDER_LIQUID_SHARE`, so its buoyancy doesn't depend on the liquid. Changing that touches the sand-under-water tuning (pore water, mounds, the sand bowl), a slice of its own.

## Results
RTX 3080 Ti, `--disable-vsync`, against main (562732d) in its own tmp copy, back to back. Logs in the job's tmp, not kept.

**CPU** (`tests/test_liquid_density.gd`, `@liquids @hydro`; the grid test also `@quick`): oil on the floor under as much water (14 × 5 blocks each in a 32 × 40 box, 420 frames) ends 5.2 px higher on average than the water (−8.3 on main, as poured: red there). Water set to 2 poured onto oil ends 14 px under it (−8.3 on main). A pool of one liquid at 0.5 or 2 gets the grid's p of water's times its density, within 2%. Pure water: a 252-particle scene with water, a sand bed and a cork, 120 frames, gives positions identical to main's to 9 decimals (MD5 of every position). Groups `@quick @setup @hydro @liquids` (50) and `@bodies-water` (6) pass.

**Layering** (`gpu_probe oil,water 4800 2 every=47`: +10k oil, then +10k water poured onto it 4 s later):
| | oil mean y | water mean y | mean speed, last samples |
|---|---|---|---|
| main | 296.5 | 298.4 (mixed in blobs) | — |
| oil 0.8 under water | **266.2** | **328.6** (two full layers) | 0.11 px/s by 80 s |
| oil 2 poured onto water (`set=oil.density=2`) | 328.7 | 266.1 | 0.08 px/s |
| 4:1, oil 0.5 under water 2 | 266.1 | 328.7 | 0.21 px/s |
| 4:1, oil 2 poured onto water 0.5 | 328.7 | 266.1 | 0.17 px/s |

A layered pool rocks for ~40 s after the pour. The oil–water interface sloshes as an internal wave: its restoring force is only Δρ/ρ of gravity, so it is ~√5 slower than the surface's slosh. The mean speed swings 1–17 px/s with a ~5–6 s period, halving every ~7 s, and decays to under 0.3 px/s (from ~40 s at 4:1, ~55 s at 0.8:1). Judged on the plateaus, it is a slosh and not churn: it dies down every time, with no spray (`spray=0`) and a flat surface (rough 0.05–0.22). In `main.tscn` the water poured onto oil is still separating out of it at 15 s and fully layered by 60 s.

**Pure water**, on plateaus (frames ≥ 1200), main → branch:
- `gpu_probe water 2400 3 every=47`: mean speed 1.19 → 1.17–1.21 px/s, tilt, roughness, spray 0, floor density 0.99, centroid the same.
- With `gap=30`: 0.38 → 0.38–0.41 px/s.
- `water_feel_probe`:
  - `fall`: identical to every printed digit.
  - `surface`: top layer 0.44 → 0.39 px/s.
  - `dam`: 22 → 18.5 px/s at 10 s (mid-slosh; ADR 0007's shipped run read 22.5).
  - `bowl`: bulk 23.1 → 22.3, 2334 → 2358 in the bed, 0 pockets.
- Sand checks: 50k dry sand at rest (drift 0.000, nothing moving) and sand into water at rest (0.03 px/s on both).

**Bodies** (`body_probe watersink,waterfloat,waterbig,corkstrip,pourfloor,sandcorks`): all pass, as on main; `waterbig` gap 2.1 → 2.2 px, `corkstrip` gap 0.5 → 0.5, `sandcorks` 10 of 10. End speeds are noisy on main too: `pourfloor`, five runs each, 0.77–3.24 px/s on main (one FAIL of its 3 px/s check) and 1.0–2.4 on the branch after the restructure below. GPU runs aren't deterministic even on main: the hash scatter's atomics reorder neighbours.

**The slider at both ends** (`set=water.density=`):
- A water pool at 0.5 or 2 flows exactly as at 1: mean speed 0.40 / 0.38 against 0.41 px/s (gap=30), and 1.24 / 1.23 against 1.21 px/s (default drops), with the same tilt, roughness, floor density and centroid. A pool of one liquid has the same accelerations whatever its density.
- What changes is what floats in it:
  - at 2 the carrot (1.2) floats (lowest particle 72 px up an 80 px pool), the cork rides at draft 0.19 (0.25 expected), and 10 of 10 sandcorks rise;
  - at 0.8 the cork's draft is 0.67 (0.52 in water);
  - at 0.5 the cork (also 0.5) is neutrally buoyant and wanders under the surface, the carrot lies on the floor, and 1 of 10 sandcorks floats.
- No launches or explosions at either end; the FAILs at the ends are checks tuned to shipped water. The range stays **0.5–2**.

**Timing** (`gpu_probe water 3000 5 from=1800`, and `oil,water 3000 3 from=1800`; the hydro pass split per dispatch in a diagnostic copy; main and branch alternated):
| µs per frame | main | first build | final |
|---|---|---|---|
| `hydro_solve`, water | 160–185 | 226 | 169–181 |
| `hydro_solve`, oil on water | 147–149 | 246 | 142 |
| `hydro_splat`, water | 21–33 | 26 | 27 |
| `hydro_splat`, oil on water | 17–18 | 35 | 34 |
| `solve` pass, water | 520–545 | 529–565 | 521–559 |

The first build read each face's liquid mass and volume from global memory in `hydro_row`, inside the one-workgroup solve, where nothing hides a load's latency: +40 µs for pure water, +97 with oil. Moving the cell density into `hydro_phi` and shared memory (decision 4) leaves about +10 µs in `hydro_solve` for pure water, nothing with oil, and +6 µs (water) to +16 µs (oil) in the splat: the material read per liquid particle, and the oil's extra atomics. The `solve` pass (PBF) is unchanged within noise.

**`main.tscn`** (`C:\Users\nosed\Pictures\falling-carrots-liquid-density\`, frames 60–3600 after the first click):
- `before_*`: main, 2 × +10k oil, then 2 × +10k water: oil and water stay in big interleaved blobs.
- `after_oil-oil-water-water_*`: the same clicks on the branch: oil ends as a flat layer over the water.
- `after_water-water-oil-oil_oil2.0_*`: oil set to 2, poured onto water: it sinks under it.
- `after_panel_*`: the same, with oil selected: the panel's new density slider at its top end, 2.0.

### Mixed starts, and the owner's "they just mix" (2026-10-15)
Owner, after playing main at fb90ccf: "oil does not float above water; they just mix." Every check above started from two thick layers (and the CPU blocks test only got about halfway, +5.2 of +11 px), so this looked like a fine mix separating weakly. It wasn't that.

**Cause: stale shader imports in the owner's checkout.** All 30 `.glsl` files in the main checkout had SPIR-V imported from an older version of the file (the source md5 Godot recorded at import differs from the file on disk; most were imported 2026-10-14, before this ADR). Godot re-imports only when the editor or `--import` runs, so a game started otherwise ran shaders that ignore a liquid's density. With the owner's `.godot` copied into a tmp copy and not re-imported, `water_feel_probe layers mix=alt` (+10k oil, water, oil, water, 30 frames apart) stays mixed: oil_above 0.44, top 0.52, the oil's mean 16 px *under* the water's, every 8 px band 46–61% oil, at rest by 40 s. With fresh imports the same clicks layer (below). `main.tscn` shows the same (`C:\Users\nosed\Pictures\falling-carrots-oil-mixed\`: `before_stale-imports_alt_*`, `after_fresh-imports_alt_*`). Fix: `ComputeContext.load_spirv` refuses a shader whose source md5 differs from its import's (`import_is_stale`), so the game shows "Shaders are out of date: open the project in the Godot editor once..." instead of running old shaders (`guard_stale-imports_error.png`). Exports carry no `.glsl` source and skip the check.

**Mixed starts with fresh imports** (`water_feel_probe layers 4800 every=47`, new; `top` = per 20 px column, the share of oil among its highest particles, 1 layered, ~0.5 mixed):
| start | 10 s | 20 s | plateau | oil left on the floor |
|---|---|---|---|---|
| `mix=alt`: +10k oil, water, oil, water | top 0.63 | 0.80 | 1.000 from ~38 s, gap 124.9 of 125.4 px | 1% of the bottom band |
| `mix=rows`: 64 rows of 318, alternating 2 px rows | 0.70 | 0.97 | 0.970 from ~20 s, gap 59.8 of 63.8 | ~300 particles (24% of the bottom 8 px band) |
| `mix=pour pour_y=150`: 3.3k oil brushed onto 20k water | 0.92 | 1.00 | 1.000 from ~25 s | none |
| `mix=pourwater pour_y=150`: 3.3k water brushed onto 20k oil | 0.87 | 0.95 | 0.995 from ~30 s | ~100 (8% of the bottom band) |

The circle brush draws nothing inside a pool (a spot taken by a particle is skipped), so a pour is from above the surface.

**Suspects checked on the CPU** (an oil/water checkerboard on the rest lattice, 14 × 30, judged at rest after 15 s): main reaches gap 24.7 of 30 px with 0.96 of the oil above the water's mean; the oil layer is pure and the rest is 8 oil particles on the floor.
- (a) XSPH across liquids: off entirely, 23.6 against 23.1 px (in an 80 px world, below). Not the cause.
- (b) buoyancy from the 16 px grid: the push over mass in the bulk is 1.04–1.12 g on oil and 0.92–1.05 g on water, so a mixed cell does separate.
- scorr off: 23.4 against 23.1. Not the cause.
- (d) the grid's push near the floor: what holds the floor film. `_hydro_p_sample` clamps p below the last row of cells, so the push fades over the bottom half cell: 0.79 g on oil and 0.70 g on water in the bottom 4 px. Both are under their weight, the floor carries the rest, and oil there never rises. In an 80 px CPU world (last cell centre 8 px above the floor) the push reaches 0 at the floor and 14 oil stayed down; the game's 360 px puts the last cell centre at the floor, as the new CPU test does (72 px).
  - p continued hydrostatically below the last row for every liquid: the film is gone (1.00 of the oil above, gap 26.4), but water's own push in the bottom band goes 0.70 → 1.00 g, which changes pure water. Not shipped; the owner decides (Known limits).
  - The same continuation only for the excess term, `(1/ρ_i − 1)`, which keeps water exact: floor oil gets 0.89 g, still under its weight, and stays.
- (c) the mass-weighted pair split wasn't isolated: with the grid's push working, mixed starts separate.

CPU `test_mixed_oil_and_water_separate` (`@liquids @hydro`): a 14 × 20 checkerboard in a 32 × 72 box, 480 frames, gap > 14 of 20 px and > 0.85 of the oil above the water's mean. Red with oil's density set to 1 (gap 0.0, 0.51 above).

Nothing in the solver changed, so pure water, bodies, sand and the pass times are as above: `cpu_ref/` and every shader are byte-identical to main.

## Known limits
- **A layered pool rocks for ~40–55 s** after a pour (the interface's slow internal wave, above), and water poured onto oil takes ~30–60 s to fully separate out of it.
- **A thin dark line along the interface** in `main.tscn`: pixels no point covers, like the dark specks in open water (M5's renderer).
- **A heavy body in a heavy liquid** counts at less than its weight in the grid's level (decision 5). It only matters at a surface.
- **The p_ref floor is water's:** a floater in oil sits ~`BODY_SURFACE_DROP × (1 − 0.8)` ≈ 0.5 px off.
- **An oil film on the floor from a fine mix:** 0.5–3% of the oil (100–300 particles of 10k) stays on the floor under the water (Results, Mixed starts). The grid's push fades over the bottom few pixels (`_hydro_p_sample` clamps below the last row), so the floor carries part of every liquid's weight there and oil gets no net lift. Continuing p hydrostatically past the floor clears it, but changes pure water's floor push (0.70 → 1.00 g in the bottom 4 px); the owner's call.
- **Shaders are checked against their imports only where the `.glsl` is on disk.** An include (`.glslinc`) changed without the stamp bump (SPEC 2.7) still isn't caught at runtime; `test_shaders.gd` catches it.
- **No interfacial tension:** a layer thinner than a coarse cell (16 px) is held by PBF and the mixed-cell rule only.
- **Grains ignore the liquid's density** (above): sand sinks through liquid at 2.
- **`HYDRO_MAX_CELLS` is 960**, so a bigger world than 640 × 360 needs fewer cells or a larger workgroup memory.
