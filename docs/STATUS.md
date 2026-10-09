# Status

Last updated: 2026-10-09. Current milestone: **2 (GPU liquid + powder + brush): code complete and run on the PC GPU. Water churn is still the top problem (owner: "way too churny" in manual play); phone not yet measured.**

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
  - Height mass scaling (`STACK_K`), so deep water stays at rest density instead of being squeezed. 30k water had ~3× rest density at the floor; it is now ≈1.0 all the way down.
  - Carried-over pressure (`PRESSURE_GAIN` 0.1, `WARM_START` 0.95, pass `solve_pressure`): each liquid particle keeps its pressure between frames and is pushed down its gradient before the iterations. It passes pressure sideways, so heaps flow out and the surface levels.
  - Kick cap (`LIQUID_KICK` 2, `velocity_update.glsl`): the solver's correction may stop water but add at most 2 × gravity × dt of speed per step in its own direction, so overshoot can't launch water. Both this and carried-over pressure are needed; each alone churned at 35–140 px/s.
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
- **Water churn: still the top problem.** In manual play the owner finds the water "way too churny" (2026-10-09). Not yet confirmed whether that play was on `main` or with PR #2 applied. PR #2 (carried-over pressure + kick cap) brought the GPU probe to ~9 px/s (30k) and ~15 px/s (50k), from 37 and 60 (see Verified). If the owner was on PR #2, mean speed isn't measuring what they see: find a probe metric that matches the visible churn (for example per-particle jitter, surface motion, or speeds in the top 40 px and along the walls) before tuning against it.
  - The fix may change anything it needs to, including sand, powder contacts and the solver structure. After any change, re-run the sand checks in Verified (50k sand at rest: drift 0, surface y≈112; sand into water: sand rests on the floor).
  - What was left on the probe after PR #2:
    - The surface of 30k water can stay tilted by ~20 px across the tank, and its top 20–40 px moves at 10–40 px/s. The stack scaling still holds water up locally, so it levels slowly.
    - 10k water resting on 10k sand moves at ~11 px/s (8 before), and 10–15 grains under it creep at up to 7 px/s (0 before).
  - Cause, found 2026-10-09: with 4 Jacobi iterations the density correction overshoots and the overshoot became separating speed (the kick cap stops that). The stack scaling held deep water up by a local lift, so water didn't pass pressure sideways: heaps held up like sand, and squeezed water rose like hot air, which drove the wall jets and plumes (carried-over pressure fixes that).
  - Tried on the GPU and rejected (30k water, mean speed):
    - Symmetric neighbour windows alone: no change. Liquid stack k 0.1 or 0.05: 60–68 px/s. Capping the stack lift at gravity: 95. XSPH 0.2: 27, but more viscous. Delta relaxation 0.5: 31. From before: SCORR_K 0, LAMBDA_EPS 0.1, 16 iterations.
    - Carried-over pressure applied with the symmetric PBF form, sum (λi + λj)∇W: 100–120 px/s jitter. A large λ times ∑∇W, which is non-zero for any disordered arrangement, is noise. Hence the gradient form.
    - Hydrostatic pressure from the liquid count above each particle's column: 130 px/s in the symmetric form, 140–185 in the gradient form (spray adds depth and lifts the water under it).
    - 4 substeps of 1 iteration (dt 1/240): 100–180 px/s, spikes over 1000. PBF turns per-step position noise into velocity / dt.
    - Mirror (ghost) walls instead of the analytic wall density: no change (37).
    - Kick cap alone (with stack): 9–15 px/s, but the water heaped against both walls around an empty hole mid-tank. Kick 4: 19–27. Kick cap with stack 0.1 or 0.03: 16–53 and sloshing.
    - Carried-over pressure without the kick cap: 85–145. Without stack scaling: 11 at gain 0.1, but the floor squeezed to 1.4× (1.8× at keep 0.9). Gain 0.25: whole-body bounce at 40. Keep 0.99 or 1.0: 32–70 and sloshing.
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
1. Water churn (Known issues): first confirm whether the owner's report was on PR #2, then make the water calm in manual play. Sand may be changed if needed but must still pass its checks.
2. Re-measure GPU pass times at the settled state (the solve pass gained one pressure pass), then measure the cap on a phone (the Milestone 2 goal).
3. Milestone 3 (cluster solids): shape-matched carrot boxes colliding and floating or sinking in water and sand. Buoyancy should use the same density weighting as the sand–water contacts.
