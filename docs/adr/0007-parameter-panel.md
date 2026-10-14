# 0007: The parameter panel (Milestone 3b, slice 1)

Date: 2026-10-14. Status: accepted (owner, 2026-10-14).

(0006 is reserved for Brittle and String bodies, STATUS Next item 8.)

## Context
ADR 0001 decisions 3 and 4: parameters are per material, the player edits the selected material's row while the sim runs, the row is re-packed and uploaded to the material buffer, every particle of that material changes at once, and each slider stops at the validator's range for its column, with both ends safe on the GPU. This slice builds the panel for the columns that exist today; stickiness, plasticity and per-material liquid density are later 3b slices.

What the code reads, checked before writing this:
- Every column a slider touches is read from the material buffer (binding 14) in every substep: `density` (powder and body contacts, a body's weight in the density projection grid, `solve_pressure`), `friction` (powder and body contacts, wall friction in `solve_apply`), `viscosity` (liquid XSPH), `drag` (`velocity_update`, all classes), `stiffness` (`body_match`, `body_region_goal`, `soft_material()`), `region` (`region_reach()` in `body_region_fit` and `body_region_goal`). Nothing caches them on the GPU: regions are found again every iteration from the live radius.
- One thing was cached on the CPU: each body's `soft` flag in `ParticleSim`, which decides whether the regions pass runs (ADR 0005).
- A liquid's `density` does nothing (STATUS Known issues, "Liquids ignore their material density").
- Nothing reads `wind_coupling`, `conductivity`, `heat_capacity`, `lifetime` or the temperatures yet.

## Decision
1. **Columns with sliders** (`MaterialTable.PANEL_FIELDS`), plus a colour picker for every material:
   - liquid: `viscosity`, `drag`;
   - powder: `density`, `friction`, `drag`;
   - cluster: `density`, `friction`, `drag`, `stiffness`, `region` (the region slider shows only below stiffness 1, where it is read).

   Not now: liquid `density` (does nothing yet), the heat, wind and lifetime columns (nothing reads them).
2. **Every edit applies live** to every particle and body of that material, including a stiffness edit across 1: a carrot set below 1 starts bending, a jelly set to 1 turns rigid. Bodies record their material instead of a soft flag, and `ParticleSim.update_material` keeps the set of soft materials, so the regions pass runs while any body of a soft material exists. When a material turns soft, `region_frame` is zeroed, so the new soft members' push-out uses the body's rotation until their first region fit instead of a rotation left in those slots by an earlier soft body.
3. **Ranges come from the validator.** `MaterialTable.range_of(column, class)` gives a column's range for a class: `CLASS_RANGES` (a class's narrower range for a shared column), else `CLUSTER_FIELDS` (cluster-only columns), else `NUMBER_FIELDS`. The cluster stiffness floor, which was a special check (`> 0`), is now a `CLASS_RANGES` entry. The ranges are 64-bit floats, not a `Vector2` (which rounded 0.01 under the validator's minimum). The final ranges and why each end is where it is are under Results.
4. **Runtime upload:** `MaterialTable.set_value(id, column, value)` clamps to the range and changes the row; `set_color`; `pack_row(id)` packs one 80-byte row (`pack_gpu` is built from it); `ParticleSim.update_material(table, id)` copies the row into its table bytes and sends `buffer_update` of that row on the render thread, queued before the next frame's passes. No pipeline rebuild, no sim reset.
5. **Reset** per material restores the row as loaded from `materials.json` (`MaterialTable.reset`). **Copy to a free slot waits** for a later 3b slice.
6. **Placement** (`ui/parameter_panel.gd`, a `CanvasLayer` in `main.tscn`): a 132 px panel in the top-right corner, its header the material's name and a ▾ that folds it to one line; the debug overlay stays top left, the toolbar at the bottom. The panel is GUI, so its clicks never reach `main.gd`'s `_unhandled_input` and never start a brush stroke. Sliders for density and drag move along a cubic curve (`CURVED`), so the shipped values sit a fifth to a third of the way along the track instead of at its left end; values are kept to three significant digits.
7. **Probes edit parameters the same way:** `set=<material>.<column>=<value>[,...]` and `setat=N` on `gpu_probe`, `water_feel_probe` and `body_probe` (`tools/probe_params.gd`) go through `set_value` and `update_material` while the sim runs.

## Owner's answers (2026-10-14)
- Columns: the proposed set, plus colour.
- Live edits: all live, a stiffness edit across 1 included.
- Copy to a free slot later; reset now.
- Placement: top right, foldable.
- Found while verifying, asked separately: a soft body dropped onto another soft body sinks into it (Known limits). Keep the stiffness floor at 0.2, where a single jelly is safe, record the stacking as a Known issue, and make fixing the soft-soft contact the next solver task.

## Results
GPU probe at both ends of every slider (RTX 3080 Ti, `--disable-vsync`, one run each unless noted; logs in the job's tmp, not kept). Where an end failed, the range was narrowed and the new end run again.

| column | was | now | why the end moved |
|---|---|---|---|
| density (all) | 0.01–100 | **0.1–10** | At 0.01 a jelly under a carrot stayed squashed flat after the carrot was erased (3.1 px tall against 9.7; `body_probe squash`). At 100 an 8 × 6 box dropped onto a sand bed sank through it to the floor; at 10 it rests on the bed. |
| drag (all) | 0–60 /s | **0–5** | At 60 water hung near the top of the screen, falling at ~7 px/s (main.tscn). At 10, 300–500 grains of a 50k sand fill still slid at ~30 px/s after 50 s, a plateau; at 5 and 3 the count fell steadily (31 and 23 at 41 s). |
| drag (liquid) | – | **0.1–5** | At 0 a 30k pool never came to rest: 11.2 px/s mean speed from 20 s to 40 s, with a level surface (churn, not slosh); at 0.05 still 3.1 px/s at the end; at 0.1 it decays like the shipped 0.15 (1.75 → 1.04 px/s against 0.46 → 0.23). |
| drag (cluster) | – | **0.5–5** | A jelly at stiffness 0.2 with no friction kept jiggling at drag 0–0.3 (`wobble` 7–22 px/s, `fold` 14–28 px/s at the end); at 0.5 it settles (0.4–0.5 px/s). |
| stiffness (cluster) | >0–1 | **0.2–1** | At 0.01 a jelly ended as a puddle (7.8 px tall against 18) that stayed flat after a load, and in main.tscn its members sank into a sand bed. At 0.1 it didn't spring back after a load (off 1.24 px); at 0.2 it does (off 0.39). |
| friction, viscosity, region | 0–1, 0–1, 1.5–2 | unchanged | Both ends safe. |

Checks at the final ends (water: `gpu_probe water 2400 3 gap=30 every=47`, `water_feel_probe dam`; sand: the two sand checks; bodies: `body_probe tests,watersink,waterfloat,sand,boxstack` for carrot and cork, `jelly,droop,wobble,squash,fold,waterjelly,erasejelly` for jelly). Many `body_probe` checks are tuned to the shipped values, so a FAIL there can mean "behaves differently"; what was judged is launching, exploding, freezing and settling.
- **Water** (viscosity 0, drag 0.1 / viscosity 1, drag 5): pool plateau 1.40 px/s, decaying / 0.02 px/s (shipped 0.35); dam front at 1 s 342 / 180 px (shipped 340), mean speed at 10 s 24.4 / 7.9 px/s (shipped 22.5). No spray, no wall risers. Viscosity 0 alone: 0.74 px/s.
- **Sand** (density 0.1, friction 0, drag 0 / density 10, friction 1, drag 5): 50k at rest: drift 0.000, top grains resting on grains below / 15 grains still sliding at 49 s, falling; sand into water: sand at rest on the floor under the water with pores as in the shipped run, sand 0.02 / 0.05 px/s, water 1.8 / 2.1 px/s (shipped 0.04, 2.7).
- **Carrot and cork** (density 0.1, friction 0, drag 0.5 / density 10, friction 1, drag 5): every body ends at rest or under 2 px/s; no launch (a box spawned 4 px into the floor peaks at 29–31 px/s, as shipped); 0 grains inside a box on sand; at 0.1 both float high, at 10 both sink to the floor. Frictionless offset boxes slide off a 3-stack (`stack3`, 7 px/s, one ends turned by π, which for a box is face down).
- **Jelly** (stiffness 0.2 with region 1.5, density 0.1, friction 0, drag 0.5 / with region 2, density 10, friction 1, drag 5): settles in `wobble` and `fold` (0.4–0.5 / 0.1–0.4 px/s); a frictionless jelly still slides after the carrot over it is erased (`squash`, 8.5 px/s, as shipped stiffness with friction 0: 10.4); erase splits work. Stiffness 1 with region 2: a jelly behaves as a rigid body.
- **Live upload** (`setat`): a floating cork set to density 10 at frame 600 sank to the floor by frame 780 (draft 0.57 → 6.8), so the grid re-weights live; carrots set to stiffness 0.3 at frame 120 behave as carrots made soft from the start (below).
- **main.tscn** (`C:\Users\nosed\Pictures\falling-carrots-parameter-panel\`): the panel; water drag 5 against 0.1, 56 frames after the same +10k drop; reset; three jellies on a sand bed at stiffness 0.95, then 0.2 (they drape), then 1 (rigid, region slider hidden); a colour change. A click on a slider moved the slider and drew nothing; the same click on the canvas started a stroke.
- **CPU** (`@setup`, `@quick`, `@erase`): `tests/test_parameters.gd` (one row packs as the table does; every panel column has a range holding the shipped value; edits clamp to the ranges and a table with every slider at either end validates; the cluster stiffness floor; colour and reset; the sliders reach both ends exactly; shipped values sit off the left end of a curved slider; a stiffness edit across 1 turns a material's bodies soft or rigid in `ParticleSim`), and `test_class_ranges` in `test_materials.gd`.

## Known limits
- ~~**A soft body dropped onto another soft body sinks into it**~~ Fixed by ADR 0008 (2026-10-14). Before: at the shipped jelly's 0.95 up to 156 of the dropped body's members passed inside during the landing and it didn't end on top; at 0.8, 31 stayed inside (7.7 px/s); at 0.2–0.7, 100–180 stayed inside and the pair jittered at 17–25 px/s for good. Now nothing ends inside at 0.2–0.95; below ~0.8 a tall soft stack may lean over and a fast drop may roll off (ADR 0008 Known limits). The 0.2 floor stays.
- **A heavy soft body sunk in water lets water inside its outline:** 5 water particles at density 3 (shipped stiffness), 20 at density 10 and stiffness 0.2 (`waterjelly`), against 0 shipped. Nothing launches; the jelly lies on the floor squashed.
- **The sand fill at drag 5 takes longer than 50 s to stop** (15 of 50k grains still sliding at 49 s, falling).
- Copy to a free slot, saved edits and a reset-all are not built.
