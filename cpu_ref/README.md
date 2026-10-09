# CPU reference

A small, readable CPU implementation of the core rules (spec section 6). It is the
ground truth that headless tests check, and the reference GPU shaders are compared
against. Plain GDScript, no engine nodes, so it runs under `--headless`.

| Module | Spec | Filled in by |
|---|---|---|
| `material_table.gd` | 3: table loader and validator | Milestone 2 (loader), 9 (full validator) |
| `reactions.gd` | 3, 2.6 step 7: reaction rules | Milestone 7 |
| `conduction.gd` | 2.5: heat conduction | Milestone 7 |
| `particle_step.gd` | 2.6 steps 2-5: simplified 2D particle step | Milestones 2-3 |

Milestone 1 ships these as stubs with their intended interfaces only.
