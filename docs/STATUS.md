# Status

Last updated: 2026-10-10. Current milestone: **2 (GPU liquid + powder + brush): code complete and run on the PC GPU. Water churn fixed on the GPU probe with a grid density projection (2026-10-10); waiting on the owner's manual play. Phone not yet measured.**

Terms follow `CONTEXT.md`. The design and the rules the code must keep are in `docs/SPEC.md`.

## Done (Milestone 2)
- **Material table:** `data/materials.json` holds sand (powder) and water (liquid).
  - Loaded, validated and packed into a GPU buffer by `cpu_ref/material_table.gd`.
  - Standalone validator: `tools/validate_materials.gd`.
- **Pool:** fixed cap from `config.json`, with a free-list (stack plus free count). Spawning can't exceed the cap, and nothing is deleted except by the eraser. CPU reference: `cpu_ref/particle_pool.gd`.
- **Spatial hash:** clear, count, a 3-dispatch prefix sum, then scatter.
  - The scatter copies particle state into cell order, and the solver runs on that sorted copy (SPEC 2.1).
  - Neighbour loops use each particle's hash cell, so pairs are symmetric (SPEC 2.7).
- **Liquid** (`gpu/shaders/sim/liquid.glslinc`): PBF density constraint, s_corr and XSPH viscosity, plus:
  - Wall density, so liquid doesn't crowd into the walls.
  - Density projection grid (`hydro.glslinc`, pass `hydro`, then `solve_pressure`): 16 px cells; liquid and powder particles splat their density with integer atomics, 32 red-black SOR sweeps (one dispatch each, warm-started) solve for a pressure p ≥ 0 that removes `HYDRO_K` 0.5 of each cell's compression and closes air bubbles under full water, and liquid particles are pushed by −∇p·dt² before the PBF iterations. It reaches the whole tank in one step, so deep water stays at rest density with gravity acting as usual.
  - Water drag 0.01 per step (`materials.json`), so a slosh dies within seconds.
  - Kick cap (`LIQUID_KICK` 2, `velocity_update.glsl`): the solver's correction may stop water but add at most 2 × gravity × dt of speed per step in its own direction, so overshoot can't launch water.
- **Powder** (`powder.glslinc`, `solve_apply.glsl`, `velocity_update.glsl`): mass-weighted contacts with static/kinetic friction, averaged over contacts.
  - Height mass scaling (`STACK_K` 0.3), so piles aren't crushed under load.
  - Inelastic push-out (`MAX_SEPARATION` 0): impacts don't rebound grains, which removed the upward kicks at the edges.
  - Water yields to sand (`POWDER_LIQUID_SHARE` 0.1), and wet grains slip (`WET_SLIP` 0.9), so sand sinks through water and settles under it.
  - Floor friction, and Coulomb friction on the side walls.
  - Sleeping (`SLEEP_DISTANCE` 0.1 px) brings piles to rest; it fixed the pudding.
- **Brush:**
  - Left mouse adds the selected material and right mouse erases any material.
  - Toolbar has Sand/Water, the two block fills ("+10k sand", "+10k water") and Clear.
  - Capacity meter turns red and reads FULL at the cap, and adding stops.
- **Rendering:** plain 2×2 colored points into a 640×360 texture.
- **Debug overlay (F3):**
  - GPU and CPU time per pass, averaged over 1 s, plus a TOTAL row.
  - Hash-grid view, which shades cells by particle count.
  - "GPU check" button: reads back the pool and hash once, verifies they agree, and reports the fullest cell.
- **GPU probe** (`tools/gpu_probe.gd`): fills, steps and measures the GPU sim from a real window. Usage is in its header.
- **Scenes:** `main.tscn` is the sim. The M1 smoke test is `debug/smoke_test.tscn`.

## Verified
| What | Where | Result |
|---|---|---|
| CPU tests (table, validator, GPU packing, free-list, CPU particle step, shaders compile, stale-import guard, scripts load) | WSL → Godot 4.7.1 console, `--headless` | 15 passed, 0 failed |
| Table validator | headless | `materials.json OK: 2 materials` |
| Block fills, circle brush (+1440 over 60 frames, as expected), erase, cap, GPU check | PC, RTX 3080 Ti, scripted | All OK. GPU check consistent at 20k, 21,440, 30k, 40k, 50k and 17,600 live |
| 50k sand at rest | PC, GPU probe, 3000 frames | RMS drift per 60 frames 2.5 → 0.000 px from frame ~900; surface fixed at y≈111 (was 92–130); wall grains 0 px/s upward |
| 10k sand dropped into 10k water | PC, GPU probe | Sand sinks to the floor and rests there; no water inside the pile |
| Deep water, 30k (3 blocks at y=8) | PC, GPU probe | Mean speed 37 → 9 px/s (steady to 4800 frames); fastest riser 200–330 → 30–48 px/s; wall particles rising 150–330 → 20–45 px/s; floor at rest density |
| Deep water, 50k | PC, GPU probe | Mean speed 57–67 → 14–15 px/s; wall particles rising 200–350 → 33–48 px/s |
| 10k water started at rest, 25 s | PC, GPU probe | 3.8 px/s (was 4.1), fastest 27 px/s (was 46) |
| 50k sand at rest, and 10k sand into 10k water, after the water fix | PC, GPU probe | Sand unchanged: drift 0.000 px, surface y 112; sand rests on the floor under the water |
| Water churn fix (density projection grid, water drag 0.01), 50k water dropped as five +10k presses 30 frames apart | PC, GPU probe, 2400 frames, plateau from frame 1200 | Mean speed 15.2 → 0.08 px/s; top 20 px 30 → 0.06 px/s; surface tilt 17 → 0.4 px, roughness 5.6 → 0.5 px; spray 41 → 0.7 drops; floor at rest density. Game capture: water pixels changing within 2 frames 13.7% → 0.1% |
| Same fix, 50k and 30k water dropped in consecutive frames | PC, GPU probe | 50k: 15 → 0.06 px/s, all particles still. 30k: 0.11 px/s (sloshed at 19–22 px/s without drag) |
| Same fix, 50k sand at rest; 10k sand into 10k water | PC, GPU probe | Sand unchanged: drift 0.000 px, top grains at y≈105 resting on 7–9 grains, no wall grains rising. Sand rests on the floor (0.01 px/s); the water over it moves at 5.2 px/s (was ~11) |
| Same fix, CPU tests | headless | 15 passed, 0 failed |
| Manual play with a mouse | PC | Owner on PR #2 (2026-10-10): "way too churny", 50k water shooting up. The fix above is **not yet** played |
| Phone | — | **Not yet** |

Run tests: `Godot_v4.7.1-stable_win64_console.exe --headless --path <project> --script res://tests/run_tests.gd`
Run validator: `... --headless --path <project> --script res://tools/validate_materials.gd`

## Measured numbers (GPU µs per pass, 1 s average)
`solver_iterations` 4, cap 50k. The first four rows were **measured before the 2026-10-09 solver changes** (wall density, sleeping); re-measure the settled state.

| Device | Particles | FPS | predict | hash | solve | velocity | render | TOTAL GPU |
|---|---|---|---|---|---|---|---|---|
| PC RTX 3080 Ti | 20k (falling blocks) | 165 (vsync) | 5 | 10 | 45 | 5 | 7 | ~72 |
| PC RTX 3080 Ti | 30k water, settled | 165 | 9 | 28 | 826 | 143 | 65 | ~1070 |
| PC RTX 3080 Ti | 50k (30k sand + 20k water), settling | 164 | 9 | 26 | 1253 | 161 | 45 | ~1495 |
| PC RTX 3080 Ti | 20k (10k sand, then 10k water on top), 15 s | 165 | 8 | 24 | 637 | 57 | 12 | ~738 |
| PC RTX 3080 Ti, 2026-10-10, probe `TIME`, back to back | 50k water, PR #2 (before the grid) | 165 | 17 | 38 | 873 | 124 | 24 | ~1075 |
| PC RTX 3080 Ti, 2026-10-10, probe `TIME`, back to back | 50k water, density projection grid (adds `hydro` 395) | 165 | 12 | 27 | 807 | 45 | 16 | ~1300 |
| Phone | | | | | | | | |

Solve dominates once particles are settled and packed, so measure the settled state. The 2026-10-10 rows are averaged from frame 600 while the water settles. Clocks swing 2–3× between runs at vsync'd 165 fps, so compare totals measured back to back (see `docs/agents/gpu-probe.md`).

## Hardware checklist (PC and phone)
1. Drawing with left mouse/tap adds the selected material; right mouse erases any material.
2. Sand sinks under water, and water spreads out and goes calm.
3. "+10k" buttons add a block. The meter turns red and reads FULL at the cap, and drawing then adds nothing.
4. "GPU check" in the overlay prints `GPU check OK ...`. A FAILED line is a bug: send it.
5. The overlay GPU column shows numbers, not `-`.
6. The log has no errors, and no leaked-RID warnings on quit.

## Known issues
- **Water churn: fixed on the probe (2026-10-10), waiting on manual play.** The owner played PR #2 and found 50k water shooting up and churning. Screenshots then showed the surface 60–70 px higher at one wall, spray, and dark gaps opening and closing near the top.
  - Cause: PBF with 4 Jacobi iterations can't build pressure that grows with depth, and both workarounds churned. Liquid stack scaling lifts every squeezed pair, so water held slopes like a sand pile and boiled at the surface. Without it 50k water squeezed to 2.5× rest density at the floor. A per-particle pressure strong enough to hold the floor sloshed (keep 0.99: tilt swinging ±70 px; gain 0.3: 38 px/s).
  - Fix: a grid density projection (`hydro.glslinc`, see Done) replaces both, and water got drag 0.01 because the now nearly frictionless water sloshed for 40+ s after a big drop (the tank's fundamental mode, 4.7 s period).
  - Tried this session and rejected (50k water, GPU probe):
    - The uncommitted velocity projection from the main checkout (`projection_*.glsl`, MAC grid, 40 Jacobi sweeps after XSPH): tilt 79 px, roughness 18 px. It cancels divergence, not density error, so it doesn't hold water up.
    - 12 iterations: 13 px/s, tilt 24. Without liquid stack at 12 iterations: 19 px/s.
    - A grid pressure built from the weight of the liquid above (div grad p = div(φg)): water became weightless as a body and bounced to the ceiling. Capped fill bounced the same way; converged solves (128 sweeps, 16 px cells) didn't help. Pressure must come only from compression.
    - Density gather per coarse cell: ~900 µs (920 threads, each looping over ~300 particles); replaced by a particle splat with integer atomics.
    - The whole SOR solve in one workgroup in shared memory: 3× slower than one dispatch per sweep.
    - 8 or 16 sweeps: 50k left at 6.5–14 px/s.
    - Thin cells pulled full only when all four neighbours are full: 30k water kept bubbles next to each other. Counting cells part-filled with sand as bubbles pulled water into the sand bed (9 px/s over sand).
  - Left over:
    - Water over sand moves at ~5 px/s along the sand slope. The grid counts sand only to skip the bubble pull; it doesn't treat sand as solid.
    - Cost: the new pass adds ~200–300 µs at 50k on the 3080 Ti, mostly the 64 small SOR dispatches; not measured on a phone.
    - Probe timings are noisy (the GPU downclocks at vsync'd 165 fps); compare totals within one session, back to back.
  - The probe gained surface metrics, `gap=`, `every=` and pass timing; how to use them is in `docs/agents/gpu-probe.md`.
- **Sleeping trade-off:** a grain sliding slower than ~6 px/s on a slope stops, so piles freeze instead of creeping.
  - The churn can't be removed by softening contacts instead: averaged contacts or CONTACT_RELAX 0.15 stopped it but crushed the 50k pile (centroid y 244 → 302–342).
  - Also not the churn's cause: friction, iterations up to 32, CONTACT_RELAX 0.25, dt 1/120, MAX_SEPARATION 15.
- **Sand under water still somewhat compressed** (measured before the 2026-10-09 changes, 10k sand under 10k water, particles per 4×4 cell, rest is 4):
  - Sand averages 5.2 (max 8). The floor row averages 7.5.
  - About 20 grains were still sinking fast.
  - Rejected: stiffening sand–water pairs (water ended up under the sand); `STACK_K` 0.7 (the pile trapped water and churned).
- **Water looks noisy** as plain 2×2 points, with dark gaps and some spray when blocks land. Metaball rendering is M5.
- The fixed 1/60 s step per frame means a slow device runs the sim in slow motion rather than unstably. That's intended.
- **MCP runtime tools fail** with "registry entry ... has no token path; relaunch the editor". Suspected cause: headless test runs also start the MCP addon's runtime autoload. If it recurs, the test runner should keep that autoload from starting.
- **Stale editor state:** delete the stray `node_2d.tscn` in the main checkout, and reopen the editor before saving.
- `config.json` and `data/materials.json` are not auto-exported. The Android preset needs `*.json` in its non-resource include filter.
- No keyboard shortcuts for materials (the toolbar only), so input stays inside the action layer.

## Next
1. Owner plays the fix (50k water via "+10k water", and sand into water). If the water now looks too still or too thick when pouring, lower water drag (0.005) before touching the grid.
2. Re-measure GPU pass times at the settled state, then measure the cap on a phone (the Milestone 2 goal). The `hydro` pass is new and is mostly dispatch overhead (64 SOR dispatches).
3. Milestone 3 (cluster solids): shape-matched carrot boxes colliding and floating or sinking in water and sand. The density projection grid is a natural place for buoyancy and for solids displacing water.
