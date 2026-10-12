# 0002: Data layout for cluster solids

Date: 2026-10-12. Status: proposed (Milestone 3 step 1; awaiting the owner's go-ahead).

## Context
ADR 0001 makes rigid and soft bodies one behaviour class, the cluster solid, solved by shape matching (Müller et al. 2005) in the same PBD solver as liquids and powders. Shape matching needs, per body, the centre and best-fit rotation of its particles every solver iteration, and per particle, where it sits in the body's rest shape. The GPU constraints that shape the layout:
- Particles live in pool slots handed out by a free-stack, so one body's slots are scattered. The solver works in cell-sorted order (SPEC 2.1), which isn't grouped by body either.
- `mat_flags` uses bits 0–7 (material) and bit 8 (`ALIVE`); bits 9–31 are free. `hash_scatter` already copies it into `s_mat`, which every neighbour loop reads.
- Float atomics aren't portable to phone GPUs, and thousands of atomics on one address per iteration would serialise.
- Parameters are per material (ADR 0001 decision 3).

## Decision
**Per particle**
1. **Body id in `mat_flags` bits 16–31.** 0 means "not in a body"; ids run 1..`body_cap`. Bits 9–15 stay free for flags. The neighbour loops get the body id from the word they already read, so same-body pairs can skip contacts (shape matching holds them together) at no extra memory cost.
2. **Rest offset: one `vec2` per slot** (`rest_offset`, cap × 8 B): the particle's position in its body's rest shape, in px, written once when the body is made. Solver passes read it through `sorted_ids` (one indirect read per particle per iteration, never per neighbour), so there is no sorted copy.

**Per body**
3. **Member list: `body_members`** (cap × 4 B) holds slot indices. Each body owns one contiguous range of it. A member counts only while its slot is alive and carries this body's id: a slot freed by the eraser and reused by another particle is skipped, not cleaned up. The CPU allocates ranges (first-fit) when a body is made and frees a range when the body's live count reads back 0, so the GPU never allocates.
4. **Body record: 48 B (std430), `bodies[body_cap + 1]`, record 0 unused.**

   | Field | Contents | Written by |
   |---|---|---|
   | `uvec4 info` | first member, member count, live members, flags (reserved) | body brush (first, count); reduction (live) |
   | `vec4 frame` | centroid x, y, cos θ, sin θ: the current best fit | reduction, every solver iteration |
   | `vec4 rest` | rest centroid x, y of the live members; 2 floats reserved | reduction |

   The rest centroid is recomputed from the live members' rest offsets in each reduction, so erasing part of a body keeps the rest of it matching its own shape, with no bookkeeping on erase.
5. **Reduction: one 64-thread workgroup per body** sums over its member range in shared memory (count, Σp, Σq, Σ p qᵀ, with p taken relative to last iteration's centroid to keep the sums small) and writes `info.live`, `frame` and `rest`. Deterministic and atomic-free. Dispatched up to the highest body id in use, which the CPU knows.
6. **`body_cap` in `config.json`**, default 256, range 1–65535 (16 bits). At 256 the records take 12 KB. Making a body stops when no body id or member range is free, as the brush stops when the pool is full.

Memory at the default 50k cap: 400 KB rest offsets, 200 KB member list, 12 KB records.

**Shape matching rules this layout assumes**
7. **Stiffness is the material's `stiffness` column**, not a body field: a parameter slider changes every body of that material at once. A body is one material (the body brush paints one). Stiffness s is the share of the shape error removed per 1/60 s; per solver iteration k = 1 − (1 − s)^(dt·60 / iterations), so the substep and iteration counts don't change how stiff a material is. s = 1 reaches the goal every iteration: a rigid body.
8. **Rotation only.** Goal gᵢ = c + R(qᵢ − c₀), with R from the polar decomposition of A_pq, closed form in 2D: θ = atan2(A₁₀ − A₀₁, A₀₀ + A₁₁). No linear or quadratic deformation modes (Müller's β), so no A_qq. One material per body means equal masses, so centroids are unweighted.
9. **Plasticity (Milestone 3b) edits `rest_offset`** toward the deformed shape seen in the body frame; it needs no new field.

## Considered and rejected
- **A separate body-id buffer** (plus a sorted copy): 400 KB and another copy in `hash_scatter`, when 16 bits of `mat_flags` are free.
- **Stiffness or other parameters per body or per particle**: ADR 0001 decision 3.
- **A fixed slab of members per body** (body b at b × max): simplest addressing, but it either caps a body's size (2048 members is 90 × 90 px) or wastes memory (256 bodies × 5000 × 4 B = 5 MB).
- **Atomic sums over all particles**: needs float atomics (not on phones) or fixed point, and serialises thousands of adds on one address per iteration.
- **A rest centroid fixed when the body is made**: erasing members would shift the goal shape and drag or spin what is left.

## Not decided here
- How the body brush turns a drawn shape into members (rest-spacing lattice fill, one body per stroke) and what happens when a stroke is larger than the free pool.
- Body–liquid coupling (Milestone 3 step 4): body particles in the density projection grid and in water's PBF density.
- Cutting (SPEC 2.2): splitting a member range into two bodies with new ids fits this layout but isn't designed.
