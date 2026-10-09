# CPU reference

A small, readable CPU implementation of the core rules (spec section 6). It is the
ground truth that headless tests check, and the reference GPU shaders are compared
against. Plain GDScript, no engine nodes, so it runs under `--headless`.

| Module | Spec | Filled in by |
|---|---|---|
| `material_table.gd` | 3: table loader, validator, GPU packing | Milestone 2 (texture and reaction checks: 5, 7, 9) |
| `particle_pool.gd` | 2.1: free-list rules the brush shaders follow | Milestone 2 |
| `particle_step.gd` | 2.6 steps 2-5: PBD step mirroring gpu/shaders/sim | Milestone 2 (clusters: 3) |
| `reactions.gd` | 3, 2.6 step 7: reaction rules | Milestone 7 (stub) |
| `conduction.gd` | 2.5: heat conduction | Milestone 7 (stub) |
