# What to run for a change

Pick the CPU test groups and GPU probe scenarios a change can affect, run those, and say in the report which you skipped and why. How to run Godot (tmp copy, import, window) is in CLAUDE.md; how to read and time the probes is in `gpu-probe.md`.

## Two halves, two kinds of check
- **CPU tests** (`tests/`, `run_tests.gd`) run the CPU reference (`cpu_ref/`, GDScript) and the plain-GDScript helpers. A change only to a shader can move nothing there except `@setup` (shaders compile, imports newer than their includes).
- **GPU probes** (`tools/*_probe.gd`) run the shaders. A change only to `cpu_ref/` can move nothing there.
- A solver change usually edits both a `cpu_ref/` function and its mirror shader (each says `Mirror:`); take the rows for both.

## Groups
`run_tests.gd -- @soft @erase` runs every test in those groups; files and method names still work and mix with groups. `-- @soft --list` prints what would run. Tags sit at the top of each test file (`GROUPS`, `FILE_GROUPS`); the runner fails a test with no group, so tag a new test when you add it.

| group | what it covers | tests | time (parallel runner, 10 processes) |
|---|---|---|---|
| `@quick` | any change, first: loading, setup, one dry scene per area (no body in water) | 50 | 21 s |
| `@setup` | materials table, config, project settings, scripts load, shaders compile, stale shader imports refused, particle pool, smoke hash | 25 | 5 s |
| `@rigid` | rigid bodies dry: on the floor, stacks, corner drop, fast drops, body-body push-out | 14 | 32 s |
| `@soft` | soft bodies (ADR 0005) dry, a soft body resting on another (ADR 0008), and the sunk jelly | 8 | 32 s |
| `@erase` | erasing part of a body, splitting into pieces (ADR 0004), outlines, the GPU split plan | 7 | 2 s |
| `@bodies-water` | bodies in water: sinking, floating, rising, p_ref, cork in wet sand, sunk jelly | 6 | 94 s |
| `@sand` | sand into water, a box on sand, a cork in a wet sand bed | 4 | 22 s |
| `@liquids` | sand sinking through water, the grid on hand-made cells, two liquids layering by density, also from a mixed start (ADR 0010) | 8 | 11 s |
| `@hydro` | density projection grid: hand-made cells, p_ref under water, cork in wet sand, liquids by density | 9 | 22 s |
| `@brush` | body brush strokes (`core/body_brush.gd`) | 7 | 2 s |
| `@stick` | stickiness (ADR 0011): hanging from the ceiling, tearing, sticky clumps falling freely, a damp column, a liquid and a body sticking | 9 | 4 s |
| `@plastic` | plasticity (ADR 0012): a dent and a drop kept, no creep at rest, a soft dough on sand, plasticity 0 changes nothing, the split's rest readback | 6 | ~100 s |

Times above are with 10 processes. The default is now 4 at below normal priority (more made the owner's PC hang, 2026-10-16): the whole suite (87 tests) takes ~3.2 min (190 s), `@bodies-water` 100 s; earlier it took ~20 min in one process. The runner runs each selected test in its own child process, up to `-j N` at once (default a quarter of the logical cores, 1 to 4, each below normal priority so the desktop comes first; `-j 1` runs them one after another in one process, as before). Don't run a test suite and a GPU probe at the same time. It runs them longest first by the times the last run took (`user://test_durations.json`), and prints each test's lines as one block when it ends; a test that hits a script error fails (in one process it used to pass, since GDScript carries on). So a group takes about as long as its slowest test: the full suite's is `test_light_box_rises_from_the_bottom`, ~80 s alone and ~135 s beside nine others (~7 min before the speed-up below).

**Speed of the CPU reference (2026-10-16).** Made ~2-5x faster without changing what it computes: all 81 tests print exactly the numbers they printed before (checked against a run of the code before). What was changed, so later edits keep it: per-substep caches of each particle's class, density, friction, region reach and soft flag (`_cache_particles`) instead of a material row lookup per neighbour pair; kernel constants worked out once (`_poly6_k`, `_spiky_k`, `_w6`); `_lambda`'s kernel values per pair kept for `_liquid_delta` in the same iteration (`_pair_g`, `_pair_w`); no `_contact_delta` call for a liquid particle with only liquid neighbours (it returns exactly zero); neighbour and region lists from a flat counting-sort grid, in the same order as before; `_hydro_solve`'s per-cell tests worked out once per solve instead of in each of its 32 sweeps; and no density projection grid in a dry step (no liquid, no wet body), where its pressure pushes nothing. Keep sums in the same order when editing these loops: floats added in another order give other last digits, and the printed numbers stop matching.

## Changed file → what to run

| changed | CPU groups | GPU probes (scenarios) |
|---|---|---|
| `docs/`, `*.md`, ADRs | nothing | nothing |
| a test file | the tests you changed | — |
| `tests/run_tests.gd`, `test_case.gd` | `-- --list`, then `@quick` | — |
| `tools/*_probe.gd` | — | the scenarios you changed, once |
| `data/materials.json` | `@setup`, plus the groups of the material's class: water or oil `@liquids @hydro @bodies-water`, sand `@sand`, carrot or cork `@rigid @bodies-water`, jelly `@soft` (and `test_joint_jelly_does_not_creep`: jelly is on pair joints), dough `@soft @plastic` (the plasticity tests put jelly on regions, as dough is) | that material's scenarios at both ends of the parameter's range (ADR 0001, `gpu-probe.md`) |
| `config.json` | `@setup` (CPU tests fix substeps and iterations themselves) | the scenarios the setting touches |
| `core/sim_params.gd` | by constant: `HYDRO_*` `@hydro @liquids @bodies-water`; `BODY_*`, `STACK_K` `@rigid @soft @bodies-water`; powder constants `@sand @liquids`; `STICK_*` `@stick`; `SPACING`, `H`, `DT`, `GRAVITY`, `MAX_STEP` the full suite | as the matching shader rows |
| `core/body_brush.gd` | `@brush` | `main.tscn` screenshots of a stroke |
| `core/game_config.gd`, `debug/`, `project.godot` | `@setup` | — |
| `cpu_ref/material_table.gd`, `particle_pool.gd` | `@setup` | — |
| … a range (`NUMBER_FIELDS`, `CLASS_RANGES`, `CLUSTER_FIELDS`) or `PANEL_FIELDS` | `@setup` | the scenarios of each class the column has a slider for, at the new end (`set=`, `gpu-probe.md`; the list ADR 0007 used is in its Results) |
| `tools/probe_params.gd` | — | any one probe with `set=` |
| `cpu_ref/reactions.gd`, `conduction.gd` | none exist yet | — |
| `cpu_ref/particle_step.gd`, `_match_shapes`, `make_body`, `_member_rot` | `@rigid @soft @erase @bodies-water` | — |
| … `_match_regions`, `_find_regions`, `_soft`, `_region_reach`, `_self_contact`, `_share_pushes_over_regions` | `@soft @plastic` | — |
| … `_joint_error`, `_joint_share`, `lattice_joints` (pair joints, ADR 0016; only joint materials run them) | `test_joint_jelly_does_not_creep`, `@setup` | — |
| … `_plastic_flow`, `_plastic_room`, `_plastic_outline` | `@plastic` | — |
| … `rest_outline`, `body_pieces`, `split_body`, `erase_particles`, `_first_fit` | `@erase @brush @rigid` | — |
| … `_contact_impulses`, `_impact_pair`, `_held_in_pair` (ADR 0015) | `@rigid @soft @sand @bodies-water` | — |
| … `_sweep_bodies`, `_contact_delta`, `_push_out`, `in_lattice_cell`, `stack_weight`, `body_stack_weight`, `stop_not_launch`, `limit_separation` | `@rigid @soft @sand @bodies-water` | — |
| … `_hydro_*`, `hydro_*`, `_cradled` | `@hydro @liquids @bodies-water` | — |
| … `_body_pressure_delta`, `_body_p_sample`, `_body_liquid_fill`, `body_wet_face`, `_body_liquid_drag`, `_project_body_pushes` | `@bodies-water` | — |
| … `_lambda`, `_liquid_delta`, `liquid_pair_share`, `_xsph`, `scorr`, `wall_density*` | `@liquids @bodies-water` | — |
| … `has_stickiness`, `_stick_*`, `stick_shape`, `stick_hold`, `_contact_share`, `_touch_distance` | `@stick` (the shipped table has no stickiness, so nothing else runs them) | — |
| … `_powder_liquid_drag`, powder sleeping | `@sand @liquids` | — |
| … `step()`, `_find_neighbours`, `_apply_delta`, `_clamp_to_world` | the full suite | — |
| `gpu/shaders/sim/body_match`, `body_project` | `@setup` | `body_probe tests,boxdrop,boxhigh,plank,boxside,boxstack,waterjelly`; `body_project` also `corkstrip` and the `solve_pressure` row |
| … `body_region_fit`, `body_region_goal` | `@setup` | `body_probe jelly,droop,wobble,squash,erasejelly,waterjelly` (the shipped jelly is on pair joints, ADR 0016) and again with `set=jelly.soft_model=regions` (dough's model), plus `creep` and `droop inv` at 0.2 and `carrotjelly drop_dx=0,2,4` (each its own run) |
| … `body_split` | `@setup` | `body_probe erasemid,erasejelly,erasebridge,erasedrag,reuse` |
| … `body_plastic`, `body_outline`, `body_rest`, `plastic.glslinc` | `@setup` | `body_probe squash,wobble,sandjelly,waterjelly,jellystack,jellydrop,erasejelly,fold,softcap set=jelly.stiffness=S,jelly.plasticity=P,jelly.soft_model=regions` at P 0 and 1 and S 0.2, 0.8, 0.95; read the PLASTIC lines (ADR 0012 Results); `main.tscn` shots of dough |
| … `body_sweep` | `@setup` | `body_probe boxhigh,plank,boxside,boxstack,sand` |
| … `body_impulse*`, `impulse.glslinc` (ADR 0015) | `@setup` | `body_probe boxtilt,boxoff,boxhigh,boxdrop,plank,boxside,boxstack,stack3,stack5,jellydrop vtrace`; TIME with `many,big`; `main.tscn` shots of a tilted and an off-centre drop |
| … `brush_*` | `@setup` | `body_probe erase,erasemid,reuse`; `gpu_probe water 600`; `main.tscn` screenshots of the brush |
| … `hydro.glslinc`, `hydro_*` | `@setup` | `gpu_probe water 2400 3 gap=30 every=47`; `gpu_probe oil,water 4800 2 every=47` (layering, ADR 0010); `water_feel_probe layers 4800 every=47` with `mix=rows`, `mix=alt` and `mix=pourwater pour_y=150` (mixed starts); `water_feel_probe surface`, `bowl`; `body_probe watersink,waterfloat,pourfloor,sandcorks`; the sand checks |
| … `liquid.glslinc`, `solve_lambda`, `solve_delta`, `solve_apply` | `@setup` | `gpu_probe water` (both drop patterns); `gpu_probe oil,water 4800 2 every=47`; `water_feel_probe layers 4800 every=47 mix=rows`; `water_feel_probe fall,dam,surface`; `body_probe watersink,waterfloat`; `body_probe jellystack,jellydrop` and `stack3,stack5,boxstack set=carrot.stiffness=0.5 frames=1800` (the soft verdict, ADR 0008) |
| … `solve_pressure` | `@setup` | `body_probe watersink,waterjelly,waterfloat,waterdeep,pourfloor,sandcorks,corkstrip` |
| … `powder.glslinc` | `@setup` | the sand checks; `water_feel_probe sandair,erase,shaft,sink`; `body_probe sand,sandlow`; `body_probe jellystack,jellydrop` and `stack3,stack5,boxstack set=carrot.stiffness=0.5 frames=1800` (the soft verdict, ADR 0008) |
| … `predict`, `velocity_*`, `hash_*`, `scan_*` | `@setup` | the sand checks, `gpu_probe water`, `body_probe tests` |
| … `stick.glslinc` (stickiness, ADR 0011) | `@setup` | with the sticky columns set (`set=sand.cohesion=1,...`): `water_feel_probe erase,shaft 1500` (`floating` 0), the sand checks, `gpu_probe water 2400 3 gap=30 every=47`, `body_probe tests,boxstack` and `jelly,squash,fold`; `main.tscn` shots of a +10k sand drop; ADR 0011 Results lists the full set |
| … `common.glslinc` | `@setup` (packing) | every probe whose pass reads what changed |
| … `render*` | `@setup` | `main.tscn` screenshots only |
| `gpu/shaders/smoke/`, `gpu/smoke_*` | `@setup` | `debug/smoke_test.tscn` |
| `gpu/particle_sim.gd` | `@setup @erase` | the scenarios of the passes or readbacks changed |
| `gpu/compute_context.gd` | `@setup` | any one probe |
| `main.gd`, `main.tscn`, `ui/` | `@setup` | `main.tscn` screenshots |

The sand checks are the two runs in `gpu-probe.md`, Reading the output (50k sand at rest; sand into water).

## Keeping a new test short
Cost is particles × frames, plus world area once there is liquid: with any liquid (or a wet body) the CPU step runs the density grid over the whole world every substep, so keep a wet test's world small; a dry step skips the grid. Use the smallest world and the fewest particles and frames that still go red on the broken code (revert the fix in a tmp copy and run the test there). A body that should hit at speed can start close to its target with that speed (`_drop_fast` in `test_bodies.gd`): a carrot's drag (0.6/s) makes a 330 px fall land at 387 px/s, and one started 20 px above at 378 px/s lands at 386.5. The fast-drop tests did this and went from 95–140 s to 15–25 s each, with the same numbers on the shipped code and on the two broken variants they were checked against.
