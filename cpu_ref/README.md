# CPU reference

A small, readable CPU implementation of the core rules (spec section 6). It is the
ground truth that headless tests check, and the reference GPU shaders are compared
against. Plain GDScript, no engine nodes, so it runs under `--headless`. `particle_step.gd`'s
neighbour loops read per-substep caches instead of material rows, and skip the density grid in a
dry step, for speed only: what they compute is unchanged (`docs/agents/testing.md`, Speed of the
CPU reference).

| Module | Spec | Filled in by |
|---|---|---|
| `material_table.gd` | 3: table loader, validator, GPU packing | Milestone 2 (texture and reaction checks: 5, 7, 9) |
| `particle_pool.gd` | 2.1: free-list rules the brush shaders follow | Milestone 2 |
| `particle_step.gd` | 2.6 steps 2-5: PBD step mirroring gpu/shaders/sim | Milestone 2 (rigid and soft bodies: 3; stickiness and per-material liquid density: 3b) |
| `reactions.gd` | 3, 2.6 step 7: reaction rules | Milestone 7 (stub) |
| `conduction.gd` | 2.5: heat conduction | Milestone 7 (stub) |
