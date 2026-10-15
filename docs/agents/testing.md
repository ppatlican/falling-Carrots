# What to run for a change

Pick the CPU test groups and GPU probe scenarios a change can affect, run those, and say in the report which you skipped and why. How to run Godot (tmp copy, import, window) is in CLAUDE.md; how to read and time the probes is in `gpu-probe.md`.

## Two halves, two kinds of check
- **CPU tests** (`tests/`, `run_tests.gd`) run the CPU reference (`cpu_ref/`, GDScript) and the plain-GDScript helpers. A change only to a shader can move nothing there except `@setup` (shaders compile, imports newer than their includes).
- **GPU probes** (`tools/*_probe.gd`) run the shaders. A change only to `cpu_ref/` can move nothing there.
- A solver change usually edits both a `cpu_ref/` function and its mirror shader (each says `Mirror:`); take the rows for both.

## Groups
`run_tests.gd -- @soft @erase` runs every test in those groups; files and method names still work and mix with groups. `-- @soft --list` prints what would run. Tags sit at the top of each test file (`GROUPS`, `FILE_GROUPS`); the runner fails a test with no group, so tag a new test when you add it.

| group | what it covers | tests | time (one process) |
|---|---|---|---|
| `@quick` | any change, first: loading, setup, one dry scene per area (no body in water: the cheapest takes ~70 s) | 36 | ~1.5 min |
| `@setup` | materials table, config, project settings, scripts load, shaders compile, particle pool, smoke hash | 15 | ~5 s |
| `@rigid` | rigid bodies dry: on the floor, stacks, corner drop, fast drops, body-body push-out | 15 | ~3.5 min |
| `@soft` | soft bodies (ADR 0005) dry, a soft body resting on another (ADR 0008), and the sunk jelly | 7 | ~4 min |
| `@erase` | erasing part of a body, splitting into pieces (ADR 0004), outlines, the GPU split plan | 7 | ~15 s |
| `@bodies-water` | bodies in water: sinking, floating, rising, p_ref, cork in wet sand, sunk jelly | 6 | ~13 min |
| `@sand` | sand into water, a box on sand, a cork in a wet sand bed | 3 | ~2 min |
| `@liquids` | sand sinking through water, the grid on hand-made cells, two liquids layering by density (ADR 0010) | 6 | ~40 s |
| `@hydro` | density projection grid: hand-made cells, p_ref under water, cork in wet sand, liquids by density | 7 | ~2.7 min |
| `@brush` | body brush strokes (`core/body_brush.gd`) | 7 | <1 s |

The whole suite (59 tests) takes ~20 min in one process, ~14 min as two in parallel: `-- @bodies-water` in one, `-- @rigid @erase @brush @setup @liquids` and the six dry `@soft` methods in the other. `test_light_box_rises_from_the_bottom` alone takes ~4-5 min.

## Changed file → what to run

| changed | CPU groups | GPU probes (scenarios) |
|---|---|---|
| `docs/`, `*.md`, ADRs | nothing | nothing |
| a test file | the tests you changed | — |
| `tests/run_tests.gd`, `test_case.gd` | `-- --list`, then `@quick` | — |
| `tools/*_probe.gd` | — | the scenarios you changed, once |
| `data/materials.json` | `@setup`, plus the groups of the material's class: water or oil `@liquids @hydro @bodies-water`, sand `@sand`, carrot or cork `@rigid @bodies-water`, jelly `@soft` | that material's scenarios at both ends of the parameter's range (ADR 0001, `gpu-probe.md`) |
| `config.json` | `@setup` (CPU tests fix substeps and iterations themselves) | the scenarios the setting touches |
| `core/sim_params.gd` | by constant: `HYDRO_*` `@hydro @liquids @bodies-water`; `BODY_*`, `STACK_K` `@rigid @soft @bodies-water`; powder constants `@sand @liquids`; `SPACING`, `H`, `DT`, `GRAVITY`, `MAX_STEP` the full suite | as the matching shader rows |
| `core/body_brush.gd` | `@brush` | `main.tscn` screenshots of a stroke |
| `core/game_config.gd`, `debug/`, `project.godot` | `@setup` | — |
| `cpu_ref/material_table.gd`, `particle_pool.gd` | `@setup` | — |
| … a range (`NUMBER_FIELDS`, `CLASS_RANGES`, `CLUSTER_FIELDS`) or `PANEL_FIELDS` | `@setup` | the scenarios of each class the column has a slider for, at the new end (`set=`, `gpu-probe.md`; the list ADR 0007 used is in its Results) |
| `tools/probe_params.gd` | — | any one probe with `set=` |
| `cpu_ref/reactions.gd`, `conduction.gd` | none exist yet | — |
| `cpu_ref/particle_step.gd`, `_match_shapes`, `make_body`, `_member_rot` | `@rigid @soft @erase @bodies-water` | — |
| … `_match_regions`, `_find_regions`, `_soft`, `_region_reach`, `_self_contact`, `_share_pushes_over_regions` | `@soft` | — |
| … `rest_outline`, `body_pieces`, `split_body`, `erase_particles`, `_first_fit` | `@erase @brush @rigid` | — |
| … `_sweep_bodies`, `_contact_delta`, `_push_out`, `in_lattice_cell`, `stack_weight`, `body_stack_weight`, `stop_not_launch`, `limit_separation` | `@rigid @soft @sand @bodies-water` | — |
| … `_hydro_*`, `hydro_*`, `_cradled` | `@hydro @liquids @bodies-water` | — |
| … `_body_pressure_delta`, `_body_p_sample`, `_body_liquid_fill`, `body_wet_face`, `_body_liquid_drag`, `_project_body_pushes` | `@bodies-water` | — |
| … `_lambda`, `_liquid_delta`, `liquid_pair_share`, `_xsph`, `scorr`, `wall_density*` | `@liquids @bodies-water` | — |
| … `_powder_liquid_drag`, powder sleeping | `@sand @liquids` | — |
| … `step()`, `_find_neighbours`, `_apply_delta`, `_clamp_to_world` | the full suite | — |
| `gpu/shaders/sim/body_match`, `body_project` | `@setup` | `body_probe tests,boxdrop,boxhigh,plank,boxside,boxstack,waterjelly`; `body_project` also `corkstrip` and the `solve_pressure` row |
| … `body_region_fit`, `body_region_goal` | `@setup` | `body_probe jelly,droop,wobble,squash,erasejelly,waterjelly` |
| … `body_split` | `@setup` | `body_probe erasemid,erasejelly,erasebridge,erasedrag,reuse` |
| … `body_sweep` | `@setup` | `body_probe boxhigh,plank,boxside,boxstack,sand` |
| … `brush_*` | `@setup` | `body_probe erase,erasemid,reuse`; `gpu_probe water 600`; `main.tscn` screenshots of the brush |
| … `hydro.glslinc`, `hydro_*` | `@setup` | `gpu_probe water 2400 3 gap=30 every=47`; `gpu_probe oil,water 4800 2 every=47` (layering, ADR 0010); `water_feel_probe surface`, `bowl`; `body_probe watersink,waterfloat,pourfloor,sandcorks`; the sand checks |
| … `liquid.glslinc`, `solve_lambda`, `solve_delta`, `solve_apply` | `@setup` | `gpu_probe water` (both drop patterns); `gpu_probe oil,water 4800 2 every=47`; `water_feel_probe fall,dam,surface`; `body_probe watersink,waterfloat`; `body_probe jellystack,jellydrop` and `stack3,stack5,boxstack set=carrot.stiffness=0.5 frames=1800` (the soft verdict, ADR 0008) |
| … `solve_pressure` | `@setup` | `body_probe watersink,waterjelly,waterfloat,waterdeep,pourfloor,sandcorks,corkstrip` |
| … `powder.glslinc` | `@setup` | the sand checks; `water_feel_probe sandair,erase,shaft,sink`; `body_probe sand,sandlow`; `body_probe jellystack,jellydrop` and `stack3,stack5,boxstack set=carrot.stiffness=0.5 frames=1800` (the soft verdict, ADR 0008) |
| … `predict`, `velocity_*`, `hash_*`, `scan_*` | `@setup` | the sand checks, `gpu_probe water`, `body_probe tests` |
| … `common.glslinc` | `@setup` (packing) | every probe whose pass reads what changed |
| … `render*` | `@setup` | `main.tscn` screenshots only |
| `gpu/shaders/smoke/`, `gpu/smoke_*` | `@setup` | `debug/smoke_test.tscn` |
| `gpu/particle_sim.gd` | `@setup @erase` | the scenarios of the passes or readbacks changed |
| `gpu/compute_context.gd` | `@setup` | any one probe |
| `main.gd`, `main.tscn`, `ui/` | `@setup` | `main.tscn` screenshots |

The sand checks are the two runs in `gpu-probe.md`, Reading the output (50k sand at rest; sand into water).

## Keeping a new test short
Cost is particles × frames × world area: the CPU step runs the density grid over the whole world every substep, water or not, so a dry 192-particle scene steps at ~95 ms a frame in a 160 x 100 world and ~220 ms in 160 x 420. Use the smallest world and the fewest particles and frames that still go red on the broken code (revert the fix in a tmp copy and run the test there). A body that should hit at speed can start close to its target with that speed (`_drop_fast` in `test_bodies.gd`): a carrot's drag (0.6/s) makes a 330 px fall land at 387 px/s, and one started 20 px above at 378 px/s lands at 386.5. The fast-drop tests did this and went from 95–140 s to 15–25 s each, with the same numbers on the shipped code and on the two broken variants they were checked against.
