# Status

Last updated: 2026-10-09. Current milestone: **2 (GPU liquid + powder + brush): code complete, run on the PC GPU, not yet measured on a phone.**

## Done (Milestone 2)
- **Material table:** `data/materials.json` holds sand (powder) and water (liquid).
  - Loaded, validated and packed into a GPU buffer by `cpu_ref/material_table.gd`.
  - Standalone validator: `tools/validate_materials.gd`.
- **Particle pool:** fixed cap from `config.json`, with a free-list (stack plus free count).
  - Spawning can't exceed the cap, and nothing is deleted except by the eraser.
  - CPU mirror: `cpu_ref/particle_pool.gd`.
- **Spatial hash:** clear, count, a 3-dispatch prefix sum, then scatter.
  - The scatter copies particle state into cell order, and the solver runs on that sorted copy (SPEC 2.1).
- **Liquid:** PBF density constraint plus s_corr and XSPH viscosity (`gpu/shaders/sim/liquid.glslinc`).
- **Powder:** mass-weighted contacts with static/kinetic friction, plus floor friction (`powder.glslinc`). Sand sinks through water.
  - Anti-compression and anti-hop fix (owner report: sand under water crushed, top grains "jumping like grasshoppers"):
    stack stiffening between grains (`STACK_K` 0.3), a push-out speed cap (`MAX_SEPARATION`, now 0: sand is inelastic), and wet slip (`WET_SLIP` 0.9).
- **Edge, wobble and sand-in-water changes (first measured on the CPU; see the GPU fixes below):**
  - Upward kicks at the edges: falling grains rebounded at the 15 px/s cap. Cap is now 0, so corner and heap rebound is gone (max upward 14.85 → 0.00 px/s in the corner test).
  - Wobble: powder friction is averaged over contacts, not summed, so the per-iteration correction stays stable. A 200-grain heap went from 5% velocity reversals to 0.
  - Powder pressed into a side wall gets Coulomb wall friction: it cancels at most friction × how far the grain is pressed in. A fixed cut like the floor's held lightly touching grains up the walls in thin columns.
  - Water yields to sand (`POWDER_LIQUID_SHARE` 0.1): sand–water push-out goes mostly to the water.
- **GPU fixes for pudding and water (verified with the GPU probe, RTX 3080 Ti, 2026-10-09):**
  - Neighbour windows come from each particle's hash cell, not its moving position (`FOR_EACH_NEIGHBOUR(t)`), so pairs stay symmetric across iterations like the CPU's per-frame lists. No measurable change on its own; it removes a CPU/GPU difference.
  - Sand sleeping (`SLEEP_DISTANCE` 0.1 px, `velocity_update.glsl`): a grain the solver stopped that moved less than that stays put. 50k sand: RMS displacement per 60 frames 2.5 → 0.000 px from frame ~900 to 3000, surface fixed at y≈111 (was breathing between 92 and 130), wall grains 0 px/s upward.
  - Water: walls add density (`wall_density`, poly6 over the half-plane past the wall), and liquid pairs are mass-scaled by height with `STACK_K`, like sand. Deep water was squeezed to ~3× rest at the bottom and jittered at ~115 px/s; it is now at rest density (≈1.05) all the way down.
  - Sand dropped into 10k water sinks to the floor and comes to rest, with no water left inside the pile.
- **Brush:**
  - Left mouse adds the selected material and right mouse erases any material.
  - Toolbar has Sand/Water, "+10k sand", "+10k water" (benchmark fills) and Clear.
  - Capacity meter turns red and reads FULL at the cap, and adding stops.
- **Rendering:** plain 2×2 colored points into a 640×360 texture.
- **Debug overlay (F3):**
  - GPU and CPU time per pass, averaged over 1 s, plus a TOTAL row.
  - Working hash-grid view, which shades cells by particle count.
  - "GPU check" button: reads back the pool and hash once, verifies they agree, and reports the fullest cell.
- **Scenes:** `main.tscn` is now the sim. The M1 smoke test moved to `debug/smoke_test.tscn`.
- **Fixes made along the way:**
  - The M1 overlay labelled GPU times as µs, but they are nanoseconds; it now converts.
  - The test runner now fails a test file that doesn't parse (it used to skip it silently).

## Verified
| What | Where | Result |
|---|---|---|
| CPU tests (table, validator, GPU packing, free-list, CPU particle step, shaders compile, stale-import guard, scripts load) | WSL → Godot 4.7.1 console, `--headless` | 15 passed, 0 failed |
| Table validator | headless | `materials.json OK: 2 materials` |
| Sim on a real GPU: block fills, circle brush (+1440 over 60 frames, as expected), erase, cap, GPU check | PC, RTX 3080 Ti, driven by a temporary script | All OK. GPU check consistent at 20k, 21,440, 30k, 40k, 50k and 17,600 live |
| Manual play with a mouse | PC | **Not yet** (owner) |
| Phone | — | **Not yet** |

Run tests: `Godot_v4.7.1-stable_win64_console.exe --headless --path <project> --script res://tests/run_tests.gd`
Run validator: `... --headless --path <project> --script res://tools/validate_materials.gd`

## Measured numbers (GPU µs per pass, 1 s average)
`solver_iterations` 4, cap 50k. The PC rows come from the automated run, not settled long-term.

| Device | Particles | FPS | predict | hash | solve | velocity | render | TOTAL GPU |
|---|---|---|---|---|---|---|---|---|
| PC RTX 3080 Ti | 20k (falling blocks) | 165 (vsync) | 5 | 10 | 45 | 5 | 7 | ~72 |
| PC RTX 3080 Ti | 30k water, settled | 165 | 9 | 28 | 826 | 143 | 65 | ~1070 |
| PC RTX 3080 Ti | 50k (30k sand + 20k water), settling | 164 | 9 | 26 | 1253 | 161 | 45 | ~1495 |
| PC RTX 3080 Ti | 20k (10k sand, then 10k water on top), 15 s, after the compression fix | 165 | 8 | 24 | 637 | 57 | 12 | ~738 |
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
- **Deep water still churns (GPU, measured 2026-10-09, improved, not fixed).** GPU probe, water dropped as 10k blocks from the top:
  | | before | now |
  |---|---|---|
  | 30k, mean speed after 15–30 s | 85 px/s | 30–36 px/s |
  | 30k, moving grains in the bottom 40 px | ~11,400 | ~2,900 |
  | 50k, mean speed | 93 px/s | 57–67 px/s |
  | 10k from rest, mean speed after 28 s | 7.5 px/s | 5.1 px/s |
  - Wall grains still reach 200–350 px/s upward at 30k and 50k. Coherent plumes rise mid-tank at rest density, about 240 px/s (the MAX_STEP cap).
  - At rest density, 50k water fills ~312 of the 360 px world, so it touches the top edge. That is the real volume, not a bug.
  - Likely cause: the liquid `STACK_K` scaling is not momentum-conserving. It lifts in proportion to the pressure itself, not its gradient, so pressure from the flow drives convection. Without it the water is squeezed instead (30k: 89 px/s).
  - Tried and rejected: liquid stack k 0.1 and 0.05 (bigger waves, 60–68 px/s), capping the lift at gravity (95 px/s), XSPH 0.2 (27 px/s, more viscous), delta relaxation 0.5 (31 px/s).
  - A real fix probably needs pressure that carries over between frames (warm-started λ) or more effective iterations, rather than stack scaling.
- **Sand sleeping trade-off:** a grain sliding slower than ~6 px/s on a slope stops, so heaps freeze instead of creeping. Averaged contacts or CONTACT_RELAX 0.15 also stopped the churn, but crushed the 50k pile (centroid y 244 → 302–342).
- **Compression under load (mostly fixed).** Measured with 10k sand under 10k water, in particles per 4×4 cell (rest is 4):
  - Sand: 9.9 → 5.2 on average (max 17 → 8).
  - Floor row: 13.6 → 7.5.
  - Water: about 4.4, both before and after.
  - Fast sand grains: none moving upward any more (was 15 or more). About 20 sinking ones remain.
  - Solve pass: 1192 → 637 µs.
  - Tried and rejected:
    - Stiffening sand–water pairs too: water ended up under the sand.
    - `STACK_K` 0.7: the pile was so stiff it trapped water inside it and churned.
- **Water looks noisy** as plain 2×2 points, with dark gaps and some spray when blocks land. Metaball rendering is M5.
- The fixed 1/60 s step per frame means a slow device runs the sim in slow motion rather than unstably. That's intended.
- **MCP runtime tools fail** with "registry entry ... has no token path; relaunch the editor". Suspected cause: headless test runs also start the MCP addon's runtime autoload. If it recurs, the test runner should keep that autoload from starting.
- **Stale editor state:** delete the stray `node_2d.tscn` in the main checkout, and reopen the editor before saving.
- **Shader includes:** after editing a `.glslinc`, reimport the `.glsl` files (SPEC 2.7). `test_shaders.gd` catches a stale import.
- `config.json` and `data/materials.json` are not auto-exported. The Android preset needs `*.json` in its non-resource include filter.
- No keyboard shortcuts for materials (the toolbar only), so input stays inside the action layer.

## Next: Milestone 3 (cluster solids)
Shape-matched carrot boxes colliding and floating or sinking in water and sand. Buoyancy should use the same density weighting as the sand–water contacts. The deep-water floor row is still somewhat compressed.
