# 0001: An OE-Cake-style particle sandbox, with rigid and soft bodies and adjustable materials

Date: 2026-10-11. Status: accepted (owner's direction).

## Context
The owner wants the sim to feel like OE-Cake (Prometech, 2009): everything is particles, liquids, rigid bodies and jelly-like soft bodies push on each other, and the player can tune how a material behaves. The owner asked for:
- rigid bodies and soft bodies as first-class things the player makes;
- material parameters the player can adjust, such as viscosity and stickiness.

The project is already a unified particle solver (SPEC 2.2), which is OE-Cake's core idea, so the direction holds. This ADR records what in the code and docs worked against it, and what was decided.

## Decision
1. **One PBD solver stays.** Liquids and powders stay on grid-projected PBF (the density projection grid). Rigid and soft bodies are cluster solids in the same solver, sharing the particle pool, the spatial hash and the grids. This settles the two-tier question from the WorkBuddy notes (2026-10-10): with MPM rejected, both of its tiers are PBD, so there is no coupling layer to design.
2. **Rigid and soft bodies are one behaviour class, the cluster solid**, solved by shape matching (Müller et al. 2005). Stiffness 1 is a rigid body; lower stiffness is a soft body (jelly); plasticity (dough) makes a soft body keep its dents. A shape the player draws becomes a body, as in OE-Cake. Soft bodies and jelly move from Deferred into v1 (Milestone 3).
3. **Parameters are per material, not per particle.** The player edits a material's row in a parameter panel while the sim runs; the change is re-packed and uploaded to the material buffer (64 rows, 64 bytes each today), and every particle of that material changes at once. To get a variant, the player copies a material into a free slot (the table holds 64). Per-particle parameters were rejected: they cost memory and a material read per neighbour in every solver loop, and a brush paints one material anyway.
4. **Every adjustable parameter has a safe range**, the validator's range for that column. The panel's sliders stop at it, and both ends of each range are checked on the GPU probe. Stability beats accuracy (SPEC 1) still holds: a slider that can launch or explode particles is a bug in its range, not a feature.
5. **Stickiness is a new pair of columns:** `cohesion` (pull between touching particles of the same material) and `adhesion` (pull toward other materials and walls). Both are capped forces, so a sticky clump still breaks under enough weight.

## What worked against it, and how each is handled
| Was | Now |
|---|---|
| `CONTEXT.md` said to avoid "rigid body", "soft body", "jelly" and "sticky sand (grains have no cohesion)" | Rigid body, soft body, jelly, stickiness and parameter panel are glossary terms |
| SPEC 9 deferred jelly and other soft bodies | Soft bodies are in Milestone 3 |
| SPEC 5 had no way to change a material in game, and the brush only paints particles or static cells | A parameter panel and drawn bodies are v1 tools; the parameters work is Milestone 3b |
| SPEC 2.2 said buoyancy comes from per-material density for every class. In the code only powders use it: liquids use one global `rest_density`, and the density projection grid uses water's weight | Known gap in SPEC and STATUS. Liquids of different density (oil on water) need mass-weighted PBF (FleX 2014, section 7.1) and per-material weight in the grid before they ship |
| Viscosity is an XSPH blend capped at 1.0, which only averages neighbour velocities | Enough for water and oil; thick liquids (honey, batter) may need a stronger viscosity model. Measure before promising a full range |
| Solver constants tuned for sand and water (`STACK_K`, `WET_SLIP`, `POWDER_LIQUID_SHARE`, `LIQUID_KICK`, `HYDRO_POWDER_VOL` and `HYDRO_POWDER_FULL`, which assume sand's packing) | They stay global and are not exposed. When a new material or a slider extreme breaks one of their assumptions, the range is narrowed or the constant becomes a column; no material-specific branches in shaders |
| Sleeping freezes any grain that clings, so cohesion on powders risks permanent mid-air clumps | Cohesion on powders must pass the `erase` and `shaft` probe scenarios; the cap on the cohesion force is what lets clumps break |
| The density projection grid sees only liquid and powder | Cluster particles must count as displacement in the grid, or water fills bodies and boats don't float (Milestone 3). Done: ADR 0003 items 1–3 |
| The GPU material row is 64 bytes: three float vec4s full, and three unused slots in the integer `info` vec4 | New float columns grow the row by a vec4 (to 80 bytes) rather than bit-casting floats into `info`, and need a shader stamp bump (SPEC 2.7) |

## Not decided
- Shaking or tilting the container (OE-Cake's signature tool). Turning gravity is cheap since gravity is a shader parameter. Moving the walls needs moving boundaries in the wall density, the static grid and the density projection grid. Deferred until the owner asks.
- Whether panel edits persist. v1 has no save/load, so edits last the session, with a reset per material.
- A cutting tool stays deferred (SPEC §9). The eraser splitting a body it leaves in pieces was decided for Milestone 3 by ADR 0004 (owner, 2026-10-13); a cutting tool would reuse that split. (This used to say clusters are bonded; the layout ADR 0002 chose has no bonds, a piece is found from which members touch.)
