# 0010: Liquids by density (mass-weighted PBF and grid)

Date: 2026-10-15. Status: proposed. Milestone 3b, STATUS Next item 9 ("per-material liquid density"); fixes STATUS Known issues "Liquids ignore their material density".

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
3. **Grid solve with mass-weighted coefficients** (the variable-density Poisson equation, `div((1/ρ) ∇p) = −k err / dt²`). Each face between two liquid cells weighs `1/ρ_face`, where `ρ_face = (m_c + m_n) / (x_c + x_n)`: the two cells' liquid mass over their liquid volume (1 when both are empty). This changes the row weights (`hydro_row`, worked out once per frame) but not the sweeps. Because `(1/ρ) ∇p = g` at rest, the floor and body-wall flux terms stay `head = g × a` for any liquid, and the compression and bubble right-hand side stays in volume. What changes per cell:
   - **Liquid rows:** `w[k] = 1/ρ_face`, and `n` sums the same weights. A surface face weighs `1/ρ_c` (`n += 1/(ρ_c θ)`).
   - **Bed rows:** p continued into the pores from a neighbour is `p_n − ρ_face × head × off.y`, the head of the liquid that is there.
   - **Air rows** (the ghost extrapolation): unchanged. They are an extrapolation, not a flux.

   Without this, the constant-coefficient solve would under- or over-shoot each cell by `w = 1/ρ`. The removed share of compression per substep would be 0.29 × w: 0.59 at density 0.5, 2.9 at 0.1 (which overshoots and pumps). The floor row of a heavy-liquid pool would also sit compressed by about one head.
4. **A fifth grid channel, liquid mass.** Only liquid particles with density ≠ 1 splat their excess `ρ_i − 1` into a fifth `hydro_acc` channel, so pure water does no extra atomics. `hydro_phi.glsl` writes the cell's liquid mass `m = x + excess` to a new buffer, `hydro_mass` (binding 29, `hydro.glslinc`, one float per cell). With water only, `m == x` bit for bit, so `ρ_face` is exactly 1. `hydro_phi` stays a `vec4`. Shared memory in `hydro_solve` stays at 12 B per cell: `hydro_row` reads `hydro_mass` and the neighbours' `x` from global memory, once per frame. Shader stamp v19 → v20 (the binding is added in a `.glslinc`).
5. **A body in mixed liquid:** `hydro_level` counts a body at `min(phi.w / ρ_cell, phi.z)` (`ρ_cell = m / x`), its weight in the liquid that is there. In water, `min(phi.w, phi.z) = phi.w`, as now. A floater in oil sits deeper and doesn't drift off its own dent in the surface (ADR 0003's reason for counting by weight). Not exact for a heavy body in a heavy liquid: `phi.w` is splatted clamped at 1, so it counts at `1/ρ_cell` instead of `ρ_b/ρ_cell` (Known limits). It only matters at the surface, where heavy bodies don't stay.
6. **Body buoyancy needs nothing new:** `body_pressure_delta` reads p, which now carries each liquid's weight. A cork in oil floats deeper, and one between oil and water floats at the interface. `body_p_sample`'s continuation below the last row becomes `ρ_cell × gravity × depth`, with `ρ_cell` from that row's cell. The p_ref floor stays `gravity × BODY_SURFACE_DROP` (Known limits).
7. **The bubble pull is by volume, unchanged.** A bubble is missing volume whichever liquid surrounds it, so `covered`, `room` and `HYDRO_ROOF_PULL` don't read density. Through decision 3 its pull moves each liquid by its own mass.
8. **Panel:** liquid `density` joins `PANEL_FIELDS` (curved slider, like the other densities). `CLASS_RANGES` gets liquid density **0.5–2** to start: a ratio of up to 4 against water, FleX's 4:1. It covers petrol (0.7), oil (0.9) and syrup (1.4). Both ends are probed against water, and widened or narrowed from that. The shared 0.1–10 stays for powders and bodies.
9. **Test liquid.** Layering needs two liquids, so the tests and probes need a second liquid row. CPU tests and `gpu_probe` / `water_feel_probe` add an "oil" row in memory (density 0.8, viscosity 0.1, drag 0.15, amber), as the body tests did before step 5. `materials.json` is unchanged unless the owner says otherwise (Question 1). The `main.tscn` screenshots add the same row at runtime through `MaterialTable` and `update_material`, and fill it with `_pending_fill`.

### Mixed-liquid cells, in one place
| | rule | in a cell half oil, half water |
|---|---|---|
| hydrostatic head (floor, body wall) | flux `g × a`, unchanged | same; the weights carry ρ |
| bed continuation | `ρ_face × g × a` | the pore liquid's head |
| face coefficient | `1/ρ_face`, mass over volume | 1/0.9 |
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
2. GPU shaders mirroring it, stamp v20; `particle_sim.gd` makes and binds `hydro_mass`, and `hydro_acc` grows to 5 channels.
3. `MaterialTable`: the range, the panel field, tests in `test_parameters.gd`.
4. Verify as the task lists (AGENTS.md): CPU `@quick @setup @hydro @liquids @bodies-water`; GPU `gpu_probe water` (both drop patterns, `every=47`), `water_feel_probe surface,bowl`, `body_probe watersink,waterfloat,waterbig,corkstrip,pourfloor,sandcorks`, the sand checks, `set=water.density=0.5` and `=2`, and a layering scenario (new: `water_feel_probe layers`: oil blocks then water blocks, and the reverse; the oil and water mean heights and the share of each in the other's layer, on plateaus). Timing of `hydro` and `solve` against main, back to back, `--disable-vsync`. `main.tscn` screenshots of oil on water and water under oil.

## Questions for the owner
1. **Ship oil as a toolbar material?** SPEC's v1 roster lists oil. Proposed row: density 0.8, viscosity 0.1, drag 0.15, colour `#d9a62b`. Without it, in game only the water density slider shows the change, and only through bodies: a cork rides higher on denser water. The proposal is to keep oil test-only now and add it once you've seen the screenshots.
2. **Liquid density range 0.5–2 to start?** It is widened only if both ends probe clean.
3. Sand still sinks through any liquid density (above). Fine for this slice?

## Known limits (expected)
- A heavy body in a heavy liquid counts at less than its weight in the grid's level (decision 5); it only matters at a surface.
- The p_ref floor is water's: a floater in oil sits ~`BODY_SURFACE_DROP × (1 − 0.8)` ≈ 0.5 px off.
- No interfacial tension, so a thin layer under 1 coarse cell (16 px) is resolved by PBF and the mixed-cell rule only.
- Grains ignore the liquid's density (above).
