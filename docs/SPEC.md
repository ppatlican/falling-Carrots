# Cooking Sandbox: Design Spec (v1)

Audience: Opus 5.5, who writes all the code. The owner tests on real hardware (PC and phone) and reports back. Terms follow `CONTEXT.md`; current progress and open bugs are in `docs/STATUS.md`.

## 1. Product

A 2D side-view falling-sand sandbox with cooking. Materials: powders, liquids, gases, drawn static solids, rigid-ish solids (carrots), and soft bodies (dough). Wind and heat are simulated. The player experiments, and recipe discovery is the "game". There are no goals in v1.

**Hard constraints**
- Godot 4.7.1, Forward Mobile (Vulkan) renderer, with compute through `RenderingDevice`. No Compatibility renderer and no web export.
- Fixed 16:9 landscape world, scaled to fit with letterboxing.
- Mid-range phones at 60 fps with about 50k particles. PC may go higher, so the particle cap is a config value.
- Stability beats physical accuracy everywhere.
- Adding an element must be easy, even for weaker models.

## 2. Architecture

One unified GPU particle solver (Position-Based Dynamics) plus two grids.

### 2.1 Particles
- Struct-of-arrays in storage buffers: position, previous position, velocity, material ID, temperature, lifetime, cluster ID, flags.
- Fixed pool with a hard cap and a free-list. When the pool is full, brushing stops adding particles and a UI meter shows capacity. Nothing is ever silently deleted. Gas and fire particles expire by lifetime, which frees slots.
- One spatial hash grid, rebuilt every frame (count, prefix-sum, scatter), is shared by all neighbor queries.
- Slots are stable particle IDs. The scatter step also copies each live particle's state into cell-sorted arrays, and the solver and velocity passes work only on those, so neighbors are contiguous in memory. A commit pass writes results back to the slots. (Decided in Milestone 2: neighbor reads through slot indices were about 2× slower on a settled pool.)

### 2.2 Behavior classes
Each material belongs to exactly one class. New classes are the only thing that needs shader changes.

| Class | Method |
|---|---|
| Liquid | PBF-style density constraint, plus mild viscosity (XSPH) and a surface-tension hint. The viscosity parameter covers water, oil, and batter. Walls count toward a liquid particle's density (an analytic poly6 integral over the half-plane past the wall), so liquid doesn't crowd into walls. PBF only holds liquid locally, so the pressure that grows with depth comes from a liquid density projection on a coarse grid (16 px cells, `hydro.glslinc`, after Kugelstadt et al. 2019): once per frame, liquid particles splat their density onto the grid, a projected red-black SOR solve (`HYDRO_SWEEPS`, warm-started) finds a pressure p ≥ 0 that removes `HYDRO_K` of each cell's compression (and closes bubbles inside full water), and liquid particles are pushed by −∇p·dt² before the PBF iterations. Gravity acts as usual, so liquid that lifts off falls back. With that pressure water behaves like nearly frictionless real water and sloshes for a long time, so water has a little drag (0.15 per second in `materials.json`, applied as v × exp(−drag·dt)): a slosh fades within several seconds while a fall or pour barely slows. The solver's correction may stop water but add at most `LIQUID_KICK` × gravity × dt of speed in its own direction per step, so overshoot can't launch water. |
| Powder | Frictional particle-particle contact. Flour has strong drag, low mass, and a wind-coupling coefficient. Sand is heavier and has little drag. Gameplay-first tweaks (M2): powder-powder contacts are mass-scaled by height so piles hold their volume under load (`STACK_K`); a grain's push-out never adds velocity away from a contact (`MAX_SEPARATION` 0, so impacts can't rebound grains); the powder share of a powder–liquid push-out is small so water yields (`POWDER_LIQUID_SHARE`); grains surrounded by liquid lose most of their friction so sand settles under water (`WET_SLIP`); side walls apply Coulomb friction (at most friction × how far the grain is pressed in); a grain the solver stopped that moved slower than `SLEEP_SPEED` in a step stays put (sleeping), which is what brings a pile to rest. |
| Cluster solid | Shape matching: a group of particles is pulled toward a rigid-transformed rest shape with a stiffness parameter. Carrots are stiff and dough is soft (lower stiffness, plus plastic deformation optional later). Particles within a cluster are bonded, so cutting later means severing bonds, with no redesign. |
| Gas | Light, short-lived particles. Buoyancy comes from temperature, they are pushed by wind, and they have a lifetime. This class covers fire, smoke, and steam. |
| Static | Not particles. See 2.3. |

All classes collide with each other through the shared hash. That is the whole answer to "can solids interact reliably with liquids and powders": there is no coupling layer, because everything is in one solver.

Buoyancy comes from per-material density in the density-constraint and contact response, so carrots float in water and sink in oil with no special case.

### 2.3 Static solids grid
- A texture or storage buffer at art resolution (about 640×360). Each cell holds a material ID and a temperature.
- Particles collide with it through a signed-distance field, rebuilt incrementally in the cells the brush touched. Contact uses stable push-out projection, with no impulses.
- Heat conducts through cells. Reaction rules can convert a cell, for example burnable wood above its ignition temperature becomes fire, ash, and smoke. Conversion emits gas particles and changes the cell's material ID.

### 2.4 Wind and heat grid
- A coarse Eulerian grid (about 128×72) holding velocity, ambient temperature, and optionally pressure. It uses a Stam-style stable-fluids step: advect, apply forces, project (a few Jacobi iterations).
- Heat convection: hot cells apply an upward buoyancy force.
- Particles sample it for drift and drag. Hot particles write temperature into it, and it feeds back into particle temperature.
- The fan tool injects velocity. Solid cells block flow.

### 2.5 Temperature and state
- Every particle and static cell carries a temperature. Conduction runs between neighbors through the hash and the grid, with conductivity from the material table.
- Phase and state changes are threshold rules in the table: water → steam above its boiling point, flour + water → dough, and so on.

### 2.6 Per-frame pipeline
1. Apply input: brush, fan, heat, and drag writes. The circle brush places every material only on free spots of a rest-spacing lattice, so new particles never land inside existing ones (packed sand, which can't spring apart, hung in the air).

Steps 2–5 run `substeps` times per frame (`config.json`, default 2) with dt = 1/60 ÷ substeps. A move is capped at `MAX_STEP` (4 px, one kernel radius) per substep, so the top speed is `MAX_STEP` ÷ dt: 240 px/s at 1 substep, which held falling and spreading water to slow motion; 480 px/s at 2. Per-step quantities are written per second or per 1/60 s (drag, sleeping speed, XSPH), so the substep count changes accuracy and cost but not the materials.

2. Predict positions (gravity, wind force, buoyancy).
3. Rebuild the spatial hash.
4. Solver iterations (about 3–4): density constraints, contacts, cluster shape matching, and static-SDF collision.
5. Update velocities (powder sleeping and the push-out speed cap happen here) and apply viscosity and friction.
6. Heat step: particle and cell conduction, then the wind grid step.
7. Reaction pass: apply table rules and spawn or despawn particles.
8. Render.

### 2.7 GPU plumbing rules (verified against the Godot 4.7 class reference in Milestone 1)
- Use the **main** `RenderingDevice` (`RenderingServer.get_rendering_device()`), never a local one. Local devices can't share data with rendering, and particle buffers must feed it (`Texture2DRD` only works with main-device textures).
- Make every device call on the render thread through `RenderingServer.call_on_render_thread()`. Record compute lists each frame and never `submit()`/`sync()` (those are local-device only).
- Each pass is its own compute list followed by `capture_timestamp()`, because timestamps can't be captured inside a list that already has dispatches. The engine inserts barriers between lists. Dependent dispatches inside one pass use `compute_list_add_barrier()`.
- Shaders are `.glsl` files (`#[compute]`, `#version 450`) loaded via `RDShaderFile.get_spirv()`. Check both `base_error` and `compile_error_compute` and fail loudly with an on-screen error.
- Use 64-thread 1D workgroups. Check `LIMIT_MAX_COMPUTE_WORKGROUP_SIZE_X`, `_INVOCATIONS` and `_COUNT_X` at startup against the dispatch needed for `particle_cap`. There is no limit constant for maximum storage buffer size.
- GPU readback is always `buffer_get_data_async()`. `buffer_get_data()` stalls the GPU. Readback is debug-only, with one exception: a 16-byte pool counter is read back every frame for the capacity meter (it lags 1–2 frames; the GPU enforces the cap on its own).
- GPU timestamps (`get_captured_timestamp_gpu_time`) are **nanoseconds** (checked in the Vulkan driver source). The overlay shows microseconds.
- Shared GLSL goes in `.glslinc` files pulled in with `#include "name.glslinc"` (relative path; verified to compile in 4.7.1). Godot does **not** re-import a `.glsl` when only an included file changes, and touching the file doesn't help (it compares content hashes). Reimport from the editor, or delete `.godot/imported/*.glsl-*`. `test_shaders.gd` fails on a stale import. Because of that, every sim `.glsl` carries a stamp comment with the `Params` size and a version (currently `Params 108 B, v9`) on the line above `#include "common.glslinc"`; a comment on the include line itself is a syntax error. Whenever `common.glslinc` changes, bump that version in every `.glsl`, so a merge or pull changes each shader's content and Godot reimports all of them. Without it, merging an include change gives "push constant ... not present" errors. After editing any shader locally, delete `.godot/imported/<name>*` and run `--headless --import`.
- All sim kernels share one binding layout (`gpu/shaders/sim/common.glslinc`, bindings 0–19; the density projection grid adds 20–22 in `hydro.glslinc`) and get the same full uniform set; the engine ignores bindings a shader doesn't use (checked in `uniform_set_create`). Push constants must match the pipeline's size exactly, so every kernel reads the shared `Params` block (108 bytes, under the 128-byte portable limit).
- Neighbour loops (`FOR_EACH_NEIGHBOUR(t)`) search the 3×3 cells around the cell particle `t` was hashed into this frame, never around its current solved position. Particles are stored by their hash cell, so this keeps every pair symmetric across solver iterations, as the CPU reference's once-per-frame neighbour lists are.
- Every solver change lands in both the shaders and `cpu_ref/particle_step.gd`. The headless tests only run the CPU reference.
- No RenderingDevice (Compatibility renderer, headless, no Vulkan) means an error screen, not a fallback. `fallback_to_opengl3` is off, and Windows uses Vulkan, not D3D12.
- Tunables (`particle_cap`, `solver_iterations`) live in `res://config.json`. Export presets must include `*.json` in the non-resource filter.

## 3. Material system (extensibility)

**One data file**, `data/materials.json` (`{"materials": [row, ...]}`), with a hard cap of 64 materials. The `id` (0–63) is the GPU table index. One row per material:

`id, name, class, color (HTML string; texture_id later), density, friction, viscosity, drag, wind_coupling, stiffness (clusters), conductivity, heat_capacity, ignition_temp, boil_temp, melt_temp (number or null), lifetime (gas), tags`

**Reactions** go in a separate rule list. Each rule has:
- a trigger: contact between two materials, or a temperature threshold
- inputs
- outputs
- a probability or rate
- an optional heat delta

**Mandatory deliverables for extensibility:**
- A load step that uploads the table to a GPU buffer, so adding a row needs no shader edits.
- A validator test for table integrity: duplicate IDs, unknown classes, missing textures, cap overflow, and reactions that reference missing materials.
- `ADDING_ELEMENTS.md`: a copy-paste row template, a checklist, and worked examples (a new liquid, a new powder, a new burnable solid).
- Shaders kept short, commented, and modular, with no clever tricks. One behavior class per file where possible.

**v1 roster:** sand, flour, water, oil, batter, carrot box, dough, steel, a flammable solid (wood), fire, smoke, steam, and a heat source.

**Initial reactions:** flour + water → dough; fire + wood → burning, then ash and smoke; heat on water → steam; heat on dough → cooked, then burnt (state and color change); oil + heat → hotter conduction (frying). Heat transfers by conduction.

## 4. Rendering

Layered compositing at art resolution, with a low-res art buffer upscaled using nearest-neighbor filtering.

- **Static solids and chunky powders:** pixel-art textures sampled by world position, plus per-material noise. They look much finer than Sandboxels because the visual grid is far smaller than the sim cells.
- **Liquids:** render particle density into an offscreen texture, blur it, then threshold it for smooth metaball blobs with a glossy edge (Liquid-Webtoy style). Tint and alpha come from the material.
- **Flour:** drawn as very small, soft, semi-transparent specks, additive-ish haze that thickens where it accumulates. When airborne or blown it should read finer than sand.
- **Fire:** additive, glowing particles with a color ramp by temperature and lifetime (white-yellow, orange, red, dark), flicker, and a bloom halo.
- **Smoke and steam:** soft, alpha-blended, noisy puffs that grow and fade as they rise. Steam is light and smoke is dark.
- **Carrots:** orange pixel-art cluster visuals in v1, rendered per particle with a shared texture, plus a visible edge.

## 5. Input and tools (v1)

Palette, brush (size slider; left-click to draw and **right-click to erase**), fan/blow, heat and cool, drag/grab (solids and dough), pause, clear. No spawners, no cutting, no save/load, and no undo.

Input is routed through an abstraction layer (actions such as `draw`, `erase`, and `grab`), so touch support (eraser toggle, two-finger tap) can be added later without touching the sim. No touch UI work is needed in v1.

## 6. Testing

- **CPU reference:** a small, readable implementation of the core rules (the table loader, reactions, conduction, and a simplified 2D particle step). Headless tests cover the material validator, reaction outcomes, and conservation and sanity properties such as a cluster staying intact.
- **GPU:** on the PC, agents verify solver changes with the GPU probe (`tools/gpu_probe.gd`, which needs a real window) before calling them fixed: CPU-only results have been wrong on the GPU before. The owner verifies manual play and phones, and reports screenshots, frame times, and a description of any bug.
- Add a debug overlay: particle count and cap, frame time per pass, and a toggle for the hash grid, the wind field, and the temperature visualization.

## 7. Milestones (riskiest first)

1. **Project and tooling:** Godot project with the Forward Mobile renderer, the `RenderingDevice` compute plumbing (verified, see 2.7), the debug overlay, and the CPU reference scaffold.
2. **GPU liquid + powder + brush:** the particle pool, spatial hash, PBF liquid, and powder friction. Sand and water interact. Measure the cap on a phone. This milestone proves the performance budget.
3. **Cluster solids:** shape-matched carrot boxes colliding and floating or sinking in water, sand, and flour. This proves cross-material coupling, which is the main risk.
4. **Static solids grid:** steel brush, SDF collision, and the eraser.
5. **Metaball and flour rendering,** with pixel-art textures.
6. **Wind and heat grid:** the fan tool, convection, and gas particles (smoke and steam).
7. **Temperature and reactions:** conduction, fire, burning solids, boiling, and the table-driven reaction pass.
8. **Cooking:** dough (soft cluster), batter, frying, and cooked/burnt states.
9. **Polish and extensibility:** `ADDING_ELEMENTS.md`, validator tests, and balancing.

## 8. Risks and mitigations

| Risk | Mitigation |
|---|---|
| The particle budget doesn't fit on mid-range phones | Milestone 2 measures it first. The cap is configurable, and the solver iteration count is tunable. |
| Cross-material jitter or tunneling | Stability first: small time steps, clamped velocities, and position-based projection. Soft stiffness before hard stiffness. |
| Deep piles and deep liquid with only ~4 Jacobi iterations: soft solves squeeze them, stiff solves overshoot and churn | Powders: height mass scaling (`STACK_K`) for support, sleeping to bring them to rest. Liquids: the grid density projection carries depth pressure across the whole tank in one step, plus the `LIQUID_KICK` cap. Local fixes for liquids (stack scaling, per-particle carried pressure) churned and are gone (see STATUS). Check settling with the GPU probe after any stiffness change. |
| Cluster solids tunnel through thin static walls | Minimum wall thickness, plus substeps for fast objects. |
| Compute shader differences across mobile GPUs | Use conservative GLSL features, test on at least two devices, and keep shaders small. |
| Wind grid instability | A small time step, a clamped velocity, and a fixed Jacobi iteration count. |
| Weaker models breaking shaders when adding elements | Keep additions in the data table and use the validator. New behavior classes are Opus-only work. |

## 9. Deferred (not v1)
Cutting and fracture, save/load and undo, touch UI, portrait layout, spawners, goals and recipes as a game loop, jelly and other soft bodies, web export, and phase changes beyond the starter reactions.