# 0002: Data layout for cluster solids

Date: 2026-10-12. Status: accepted (the owner approved the layout, 2026-10-12). Milestone 3 steps 1–3 (this layout, shape matching in the CPU reference, and the GPU passes) are done; see "Decided by the step 3 GPU probe" for what step 3 changed and measured.

## Context
ADR 0001 makes rigid and soft bodies one behaviour class, the cluster solid, solved by shape matching (Müller et al. 2005) in the same PBD solver as liquids and powders. Shape matching needs, per body, the centre and best-fit rotation of its particles every solver iteration, and per particle, where it sits in the body's rest shape. The GPU constraints that shape the layout:
- Particles live in pool slots handed out by a free-stack, so one body's slots are scattered. The solver works in cell-sorted order (SPEC 2.1), which isn't grouped by body either.
- `mat_flags` uses bits 0–7 (material) and bit 8 (`ALIVE`); bits 9–31 are free. `hash_scatter` already copies it into `s_mat`, which every neighbour loop reads.
- Float atomics aren't portable to phone GPUs, and thousands of atomics on one address per iteration would serialise.
- Parameters are per material (ADR 0001 decision 3).

## Decision
**Per particle**
1. **Body id in `mat_flags` bits 16–31.** 0 means "not in a body"; ids run 1..`body_cap`. Bits 9–15 stay free for flags. Bits 16–31 were checked and nothing uses them. The neighbour loops get the body id from the word they already read, so same-body pairs can skip contacts (shape matching holds them together) at no extra memory cost.
2. **Rest offset: one `vec2` per slot** (`rest_offset`, cap × 8 B): the particle's position in its body's rest shape, in px, written once when the body is made. Solver passes read it through `sorted_ids` (one indirect read per particle per iteration, never per neighbour), so there is no sorted copy.
3. **The CPU reference keeps body id and rest offset as separate per-particle arrays** (`"body"`, `"rest"` in the state dictionary of `cpu_ref/particle_step.gd`), since it has no flags word. Its `"bodies"` and `"members"` mirror the GPU records and member list below.

**Per body**
4. **Member list: `body_members`** (cap × 4 B) holds slot indices. Each body owns one contiguous range of it. A member counts only while its slot is alive and carries this body's id: a slot freed by the eraser and reused by another particle is skipped, not cleaned up. The CPU allocates ranges (first-fit) when a body is made and frees a range when the body's live count reads back 0, so the GPU never allocates. (The CPU reference compacts its member list on erase instead, since its particle indices shift.)
5. **Body record: 48 B (std430), `bodies[body_cap + 1]`, record 0 unused.**

   | Field | Contents | Written by |
   |---|---|---|
   | `uvec4 info` | first member, member count, live members, flags (reserved) | body brush (first, count); body pass (live) |
   | `vec4 frame` | centroid x, y, cos θ, sin θ: the current best fit | body pass, every solver iteration |
   | `vec4 rest` | rest centroid x, y of the live members; 2 floats reserved | body pass |

   The rest centroid is recomputed from the live members' rest offsets in each pass, so erasing part of a body keeps the rest of it matching its own shape, with no bookkeeping on erase. With a rest centroid fixed at creation, the half-erased box test slid 27 px and turned over.
6. **`body_cap` in `config.json`**, default 256, range 1–65535 (16 bits), read by `GameConfig` with the same clamping and error messages as the other keys. At 256 the records take 12 KB. Making a body stops when no body id or member range is free, as the brush stops when the pool is full. Step 3 put four fields in the spare 20 bytes of `Params` (now 124 B): `body_count` and `body_max_id` (the highest id in use, which sets the body pass's workgroup count), `body_first` (the new body's member range, for the body brush) and `iterations` (for the stiffness formula in item 7). The body bindings are 23–26 in `common.glslinc` (`rest_offset`, `body_members`, `bodies`, and `body_spawn`, the body brush's input).

Memory at the default 50k cap: 400 KB rest offsets, 200 KB member list, 12 KB records.

**Shape matching**
7. **Stiffness is the material's `stiffness` column**, not a body field: a parameter slider changes every body of that material at once. A body is one material (the body brush paints one). Stiffness s is the share of the shape error removed per 1/60 s. Matching runs after every solver iteration's apply step with k = 1 − (1 − s)^(dt·60 / iterations), so the substep and iteration counts don't change how stiff a material is. s = 1 reaches the goal every iteration: a rigid body. The material validator rejects cluster materials with stiffness ≤ 0: same-body pairs skip contacts, so a body at 0 would collapse onto one point.
8. **Rotation only.** Goal gᵢ = c + R(qᵢ − c₀), with R from the polar decomposition of A_pq = Σ(pᵢ − c)(qᵢ − c₀)ᵀ, closed form in 2D: θ = atan2(A₁₀ − A₀₁, A₀₀ + A₁₁). The live rest centroid c₀ is subtracted in both A_pq and the goal. If live < 2 or |A_pq| < ε (the length of (A₀₀ + A₁₁, A₁₀ − A₀₁); ε = 1e-4 px² per live member), the previous rotation is kept. No linear or quadratic deformation modes (Müller's β), so no A_qq. One material per body means equal masses, so centroids are unweighted.
9. **Plasticity (Milestone 3b) edits `rest_offset`** toward the deformed shape seen in the body frame; it needs no new field.

**Contacts, walls and velocity**
10. **Body particles follow the powder contact rule** against grains and against particles of other bodies (push-out within one spacing, static/kinetic friction, `CONTACT_RELAX`). Same-body pairs skip contacts. Body–liquid pairs do nothing until step 4.
11. **`STACK_K` for bodies, by the height between body centroids** (a grain counts at its own height): in a body–body or body–grain contact the lower side acts exp(`STACK_K`·dy) times heavier, as in FleX's stack mass scaling for rigids. Unlike powder–powder contacts, friction takes the same share as the push-out. The 3-box stack test decided it (below). On the GPU, the contact loop reads the neighbour's body record for body pairs: one read per neighbour pair with a body, from a 12 KB table.
12. **Separation cap: `BODY_KICK` 4**, in units of gravity × dt, as `LIQUID_KICK`. The solver's correction (contacts, walls, shape matching) may stop a body particle but leave it at most `BODY_KICK`·g·dt faster in its own direction per step. It applies per particle; positions are not capped, only the speed they leave. Body particles never sleep.
13. **Wall inset:** body particles use a fixed 0.5-spacing inset in `clamp_to_world` (GPU; its callers are predict, solve_apply and brush_spawn) and `_clamp_to_world` (CPU), not the 0.5–0.75 per-slot spread other particles get, which would tilt a body resting on a wall. They get the powder wall friction.
14. **No move cap for tunnelling.** Bodies are at least 2 particles thick (a body-brush rule). A move cap of 0.5·H per substep would be 240 px/s, and STATUS records that a 240 px/s cap made water fall in slow motion.

**GPU passes (step 3)**
15. **One fused body pass per solver iteration**, after `solve_apply` (`body_match.glsl`, its own compute list named `bodies` so its time shows in the overlay): one 128-thread workgroup per body up to the highest id in use, early exit when the member count is 0 (128, not 64: see "Decided by the step 3 GPU probe"). The workgroup sums over its member range in shared memory (count, Σp, Σq, Σ p qᵀ, with p taken relative to last iteration's centroid to keep the sums small), waits at a barrier, writes `info.live`, `frame` and `rest`, then writes its own members' `s_pred` directly at t = `cell_start[particle_cell[slot]] + particle_rank[slot]`. Each body's members are touched only by its own workgroup, so this is safe without atomics.
16. **Making a body on the GPU (step 3):** `ParticleSim.make_body(positions, material)` picks the lowest free id and a member range by first fit (`ParticleStep._first_fit`, the CPU reference's allocator), and queues the body. The next frame spawns it with brush op `BRUSH_BODY` instead of that frame's brush: `brush_spawn` pops a slot per particle as for a block, takes its position and rest offset from `body_spawn`, writes the body id into `mat_flags` and the slot into the member range; `brush_finalize` writes the record (first, count, live, the frame at the spawn centroid). One body per frame. After any erase while bodies exist, the CPU reads the records back (async, only the ids in use) and frees the ids and ranges of bodies whose live count is 0, ignoring readbacks older than the body. A freed record is zeroed before its id can be reused. Body particles spawn clamped to the world with their 0.5-spacing inset; the CPU reference leaves them where they are until the next predict, and the spawned-into-the-floor test came out the same (below).

**Body brush (step 5)**
17. The body brush refuses spots that are already occupied, so a body never has holes in its lattice, and makes bodies at least 2 particles thick. Rest offsets come from the spawned positions.

## Decided by the step 2 tests (CPU reference, `tests/test_bodies.gd`, 2026-10-12)
- **Separation cap: the per-particle version shipped.** With it, the squashed jelly springs back: its 5.02 px error is under 10% in 10 frames, and at 2 s it is within 0.10 px of an unsquashed jelly at rest. The box dropped on a corner tips 33° and lands flat, and a box spawned 4 px into the floor rises at most 30.8 px/s. Since these tests didn't conflict, the fallback (capping only the change in the body's centroid velocity) wasn't needed. Without the cap the box spawned into the floor launched at 284 px/s; the jelly (12 frames, 0.12 px) and the tipping box (33°) were no different, so the cap costs neither.
- **`STACK_K` by body-centroid height shipped**, since the stack failed without it. With plain mass weighting, the 3-box stack (each box 2 px right of the one below) leaned 0.024 rad at rest (limit 0.02), an aligned 5-box stack closed to 1.45 px between boxes (limit 0.8 spacing, 1.6 px), and an offset 5-box stack fell over. With `STACK_K` on the push-out only, the 3-box stack swayed for good (top box up to 9 px/s); removing the kick cap didn't change that, so it was the mismatch between the push-out's and friction's shares. With friction at the same share: 3-box stack 1.94 px, |θ| ≤ 0.0033 rad, at rest; aligned 5-box stack 1.92 px, at rest. Weighting by each particle's own height instead of the body centroid also came to rest but leaned 0.012 rad.

## Decided by the step 3 GPU probe (`tools/body_probe.gd`, RTX 3080 Ti, 2026-10-12)
- **The GPU matches the CPU reference on all seven `test_bodies` scenarios**, by the same thresholds: rigid box on the floor 0.0002 px, no rotation, at rest; squashed jelly under 10% in 10 frames (CPU 10), 0.109 px from the control at 2 s (CPU 0.097), sag 1.089 px (CPU 1.080); 3-box stack 1.942 px at rest (CPU 1.942), 1.433 px over the run (CPU 1.416), |θ| 0.0033 rad (CPU 0.0033); 5-box stack 1.923 px (CPU 1.923); half-erased box 30 live members read back from its record, no drift or turn; box spawned into the floor 30.82 px/s up (CPU 30.82); corner drop turns 33.1° and lands flat (CPU 33.1°). A body erased whole is freed after the readback, and the next body gets its id and member range (`body_probe reuse`). The probe spawns one body per frame, so a stack's upper boxes start a few frames late.
- **128 threads per body workgroup, not 64.** One workgroup walks the whole body, and each member's loads depend on each other (member → slot → hash cell → sorted index → position), so the pass's time grows with the largest body. Bodies pass per frame (2 substeps × 4 iterations, `--disable-vsync`), 64 / 128 / 256 threads: 256 boxes of 48 particles 37 / 38–44 / 43 µs; one 5000-particle body 773 / 436–462 / 286 µs; one of 10 000, 1582 / 797–886 / 467 µs (128: two runs). 128 is the Vulkan minimum (as `hydro_solve`, SPEC 2.7); 256 isn't guaranteed on phones. With no bodies, the eight empty `bodies` lists cost 1.5–1.7 µs a frame.
- **Bodies rest on sand:** an 8 × 6 box placed 2 px above a packed bed (wall to wall, so it doesn't slump) rests on it with no grain inside, its lowest particle at most 1.07 px below the bed's top (seven boxes along the bed, `body_probe sandrow`). On the CPU reference's bed, still a flat lattice, it rests at −0.005 rad.
- **Nothing else changed for liquids and powders:** 50k sand at rest and sand into water (`gpu_probe`) settle as on main the same day. The body rules cost the contact loop 20–70 µs a frame (3–10% of the solve) in sand into water, nothing in sand at rest.

## Known limits until later steps
- Water passes into and fills bodies until step 4 (body particles in the density projection grid and in water's PBF density).
- A body erased in two stays one body until cutting exists: its halves stay linked across the gap.
- A 5-box stack offset 2 px per box still drops its top box (CPU, landing from 1 px gaps).
- **A big body is slow:** the fused pass costs ~0.09 µs per member of the largest body per frame (436–462 µs for one 5000-particle body, 200 × 100 px), on a 3080 Ti. Until the body brush (step 5) caps a body's size, or the pass is split so several workgroups share a body (a reduction pass plus a goal pass per iteration, rejected below on dispatch count before this was measured), a large body costs more than the whole liquid solve.
- **Grains get into a body on a fast impact**, on the CPU reference and the GPU alike: a body's lattice spacing is the contact distance, and a grain pushed in at the centre of a lattice square is pushed equally by four body particles, so it stays. An 8 × 6 box dropped 72 px onto a sand bed (~200 px/s) ends with 7 grains inside on the CPU; dropped 100 px on the GPU, 16; from 37 px, 1 grain on the CPU. Placed on the bed, none get in (`body_probe sandlow`, `sandrow`).
- **A small body on sand tilts with the grains under it:** the seven boxes placed on the packed bed came to rest at −0.21 to 0.17 rad, four of them within 0.03. An 8 × 6 box is 7 grains wide, so one grain's bump (2 px) under one end tilts it 0.14 rad. Bigger bodies span more grains and sit flatter.
- A soft body sags under its own weight: at rest each particle off the floor sits about g·dt² / (1 − (1 − s)^(dt·60)) below its goal per substep, and the floor-held bottom row balances them all. A 10×8 jelly at stiffness 0.3 sits 1.08 px off its rest shape; taller or softer bodies sag more. That is jelly-like, but it bounds the low end of the stiffness slider (Milestone 3b).

## Considered and rejected
- **A separate body-id buffer** (plus a sorted copy): 400 KB and another copy in `hash_scatter`, when 16 bits of `mat_flags` are free.
- **Stiffness or other parameters per body or per particle**: ADR 0001 decision 3.
- **A fixed slab of members per body** (body b at b × max): simplest addressing, but it either caps a body's size (2048 members is 90 × 90 px) or wastes memory (256 bodies × 5000 × 4 B = 5 MB).
- **Atomic sums over all particles**: needs float atomics (not on phones) or fixed point, and serialises thousands of adds on one address per iteration.
- **A rest centroid fixed when the body is made**: erasing members shifts the goal shape and drags or spins what is left (measured above).
- **Separate reduction and goal passes**: two dispatches per iteration instead of one; the fused pass needs no intermediate buffer. Measured in step 3, the fused pass is slow for big bodies (see Known limits), so this is open again; it is the owner's call.

## Not decided here
- How the body brush turns a drawn shape into members (rest-spacing lattice fill, one body per stroke) and what happens when a stroke is larger than the free pool.
- Body–liquid coupling (step 4): body particles in the density projection grid and in water's PBF density.
- Whether body particles count as support (cradling) for sleeping grains. Today only grains and walls do, so sand on a box may keep creeping.
- Cutting (SPEC 2.2): splitting a member range into two bodies with new ids fits this layout but isn't designed.
