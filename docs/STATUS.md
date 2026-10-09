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
- **Compression under load.** With 4 iterations, deep water is about 1.5× compressed on average and up to about 5× in the floor row. Sand under a water column is about 3× compressed. This costs solver time (more neighbors) and will matter for buoyancy in M3. Options: more iterations or substeps, boundary density at walls, or a unilateral density constraint for powders.
- **Water looks noisy** as plain 2×2 points, with dark gaps and some spray when blocks land. Metaball rendering is M5.
- The fixed 1/60 s step per frame means a slow device runs the sim in slow motion rather than unstably. That's intended.
- **MCP runtime tools fail** with "registry entry ... has no token path; relaunch the editor". Suspected cause: headless test runs also start the MCP addon's runtime autoload. If it recurs, the test runner should keep that autoload from starting.
- **Stale editor state:** delete the stray `node_2d.tscn` in the main checkout, and reopen the editor before saving.
- **Shader includes:** after editing a `.glslinc`, reimport the `.glsl` files (SPEC 2.7). `test_shaders.gd` catches a stale import.
- `config.json` and `data/materials.json` are not auto-exported. The Android preset needs `*.json` in its non-resource include filter.
- No keyboard shortcuts for materials (the toolbar only), so input stays inside the action layer.

## Next: Milestone 3 (cluster solids)
Shape-matched carrot boxes colliding and floating or sinking in water and sand. Start by deciding how to handle the compression above, because buoyancy depends on it.
