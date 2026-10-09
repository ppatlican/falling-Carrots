# Status

Last updated: 2026-10-09. Current milestone: **2 (GPU liquid + powder + brush): code complete and run on the PC GPU. Deep-water churn is open; phone not yet measured.**

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
  - Height mass scaling (`STACK_K`), so deep water stays at rest density instead of being squeezed. 30k water had ~3× rest density at the floor; it is now ≈1.05 all the way down.
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
| Deep water | PC, GPU probe | Improved, not fixed: see Known issues |
| Manual play with a mouse | PC | **Not yet** (owner) |
| Phone | — | **Not yet** |

Run tests: `Godot_v4.7.1-stable_win64_console.exe --headless --path <project> --script res://tests/run_tests.gd`
Run validator: `... --headless --path <project> --script res://tools/validate_materials.gd`

## Measured numbers (GPU µs per pass, 1 s average)
`solver_iterations` 4, cap 50k. **Measured before the 2026-10-09 solver changes** (wall density, sleeping); re-measure the settled state.

| Device | Particles | FPS | predict | hash | solve | velocity | render | TOTAL GPU |
|---|---|---|---|---|---|---|---|---|
| PC RTX 3080 Ti | 20k (falling blocks) | 165 (vsync) | 5 | 10 | 45 | 5 | 7 | ~72 |
| PC RTX 3080 Ti | 30k water, settled | 165 | 9 | 28 | 826 | 143 | 65 | ~1070 |
| PC RTX 3080 Ti | 50k (30k sand + 20k water), settling | 164 | 9 | 26 | 1253 | 161 | 45 | ~1495 |
| PC RTX 3080 Ti | 20k (10k sand, then 10k water on top), 15 s | 165 | 8 | 24 | 637 | 57 | 12 | ~738 |
| Phone | | | | | | | | |

Solve dominates once particles are settled and packed, so measure the settled state.

## Hardware checklist (PC and phone)
1. Drawing with left mouse/tap adds the selected material; right mouse erases any material.
2. Sand sinks under water, and water spreads out and goes calm.
3. "+10k" buttons add a block. The meter turns red and reads FULL at the cap, and drawing then adds nothing.
4. "GPU check" in the overlay prints `GPU check OK ...`. A FAILED line is a bug: send it.
5. The overlay GPU column shows numbers, not `-`.
6. The log has no errors, and no leaked-RID warnings on quit.

## Known issues
- **Deep-water churn (open, the next fix).** GPU probe, water dropped as 10k block fills from the top:
  | | before 2026-10-09 | now |
  |---|---|---|
  | 30k, mean speed after 15–30 s | 85 px/s | 30–36 px/s (plateau, not decaying) |
  | 30k, moving grains in the bottom 40 px | ~11,400 | ~2,900 |
  | 50k, mean speed | 93 px/s | 57–67 px/s |
  | 10k started at rest, mean speed after 28 s | 7.5 px/s | 5.1 px/s |
  - Wall particles still reach 200–350 px/s upward at 30k and 50k. Plumes rise mid-tank at about 240 px/s (the MAX_STEP cap).
  - At rest density, 50k water fills ~312 of the 360 px world, so touching the top edge is correct. Study deep water at 30k.
  - Likely cause: liquid `STACK_K` scaling isn't momentum-conserving. It lifts in proportion to pressure, not its gradient, so pressure from the flow drives convection. Without it the water is squeezed instead (30k: 89 px/s).
  - Tried on the GPU and rejected:
    - Symmetric neighbour windows alone: no change.
    - Liquid stack k 0.1 or 0.05: bigger waves, 60–68 px/s.
    - Capping the stack lift at gravity: 95 px/s.
    - XSPH 0.2: 27 px/s, but more viscous.
    - Delta relaxation 0.5: 31 px/s.
    - From before: SCORR_K 0, LAMBDA_EPS 0.1, 16 iterations.
  - Likely direction: pressure that carries over between frames (warm-started λ) or more effective iterations, in place of stack scaling for liquids.
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
1. Deep-water churn (Known issues).
2. Re-measure GPU pass times at the settled state, then measure the cap on a phone (the Milestone 2 goal).
3. Milestone 3 (cluster solids): shape-matched carrot boxes colliding and floating or sinking in water and sand. Buoyancy should use the same density weighting as the sand–water contacts.
