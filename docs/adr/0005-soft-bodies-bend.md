# 0005: Soft bodies bend: shape matching over small regions

Date: 2026-10-14. Status: proposed (the owner asked for it and chose the look, 2026-10-14; not built). Milestone 3, after the body brush (step 5).

## Context
The owner, 2026-10-14, after playing the body brush: soft bodies should be "actually soft, as in bending", like OE-Cake's Elastic, with all three of:
- **drooping**: a jelly plank laid over a gap or an edge sags into it;
- **wobbling**: a jelly that lands jiggles and settles;
- **squashing**: a jelly under a carrot flattens, and springs back once the carrot is gone.

The owner also chose **floppy** as the default jelly, and bendiness **adjustable per material**.

Why the jelly can't do this today: each body is one shape-matching cluster (ADR 0002 items 7–8). Every iteration the whole body is pulled toward one rigid copy of its rest shape, so a jelly plank over a gap is always pulled back toward a straight plank. Stiffness only sets how fast it gets there. At 0.3 a 10 × 8 jelly sags 1.08 px (ADR 0002 Known limits), and a lower stiffness makes it lag and slump, not bend. Under water a soft body's pressure pushes are also made rigid on purpose (ADR 0003 item 12).

OE-Cake's Elastic, as its community wiki describes it, is a lattice whose joins keep their distance and orientation from each other, with each particle turning with the local deformation ([Spin-Charged Elastic](https://oecake.fandom.com/wiki/Spin-Charged_Elastic), [Material](https://oecake.fandom.com/wiki/Material); unofficial). That is shape matching over each particle's own neighbourhood, as in "Solid simulation with oriented particles" (Müller & Chentanez 2011) and "FastLSM: fast lattice shape matching" (Rivers & James 2007), not one cluster per body.

## Decision (proposed)
**Regional shape matching for soft bodies**
1. **A soft body (stiffness < 1) is matched over small overlapping regions, not as one cluster.** Each member i has a region: the members of its body whose rest offsets lie within the material's region radius w of its own (itself included). Each iteration, after the apply step:
   - **Fit** (per member, `body_region_fit.glsl`): the region's centroid cᵢ, rest centroid c₀ᵢ and rotation Rᵢ, exactly as ADR 0002 item 8 does for a whole body (unweighted sums, closed-form 2D polar decomposition, the previous rotation kept below ε). Written per slot.
   - **Goal** (per member, `body_region_goal.glsl`): the mean, over every region that holds i (the regions of the members within w of it: the relation is symmetric), of c_r + R_r (qᵢ − c₀_r), and the member moves toward it by the material's k (ADR 0002 item 7's formula, unchanged).

   Each region is rigid, but neighbouring regions turn by different amounts, so the body bends where it is loaded, wobbles as the regions catch up with each other, and squashes under weight, then springs back to its rest shape. Smaller regions bend more.
2. **Rigid bodies don't change.** At stiffness 1 the body pass matches the whole body as today (`body_match`), and the region column is ignored. The carrot and cork results and every rigid test keep their numbers.
3. **Regions are found at run time, not stored.** A member finds its region through the spatial hash, keeping only particles with its body id whose rest offsets are within w of its own. Both passes are per particle, so they cost the same for one big jelly as for many small ones, unlike the per-body workgroup of `body_match` (the deferred "split the body pass" is not needed for soft bodies). w is at most H (2 spacings), so the search stays in the 3 × 3 hash cells the contact loop already reads. A member stretched more than H − w from a rest neighbour drops out of that neighbour's region until it comes back: the body stretches further there, but nothing breaks. Tearing (OE-Cake's Brittle) stays deferred (SPEC §9).
4. **Folding: same-body pairs that aren't in each other's region collide.** A floppy body can fold onto itself, and same-body pairs skip contacts today (ADR 0002 item 1). Under this ADR, only pairs within w of each other in the rest shape skip them. Pairs further apart get the ordinary body contact, so a jelly folded in two lies on itself instead of passing through.

**Parameters**
5. **A new material column, `region`:** the region radius w, in spacings, from 1.5 (each member's 8 lattice neighbours: the floppiest) to 2.0 (H). It is used only by cluster materials with stiffness < 1, and the validator checks the range. Jelly's floppiness comes from `region` and `stiffness` together. Their defaults are set by the tests in "To be decided by the tests". It is a Milestone 3b slider, like stiffness. It takes the first float of the new vec4 that SPEC 2.4's planned columns add (GPU row 64 → 80 B, shader stamp bump, SPEC 2.7).

**What the regions change elsewhere**
6. **Push-out from inside a body, body–body push-out and swept contacts** (ADR 0003 items 8, 11, 14) turn a member's way out of the rest shape, e_j, by the body's rotation. For a soft body they use the region rotation Rⱼ of that member instead, so the outline bends with the body. It is read from the per-slot fit of item 1, from the iteration before.
7. **The body pass still runs for soft bodies,** for what is per body: live count, rest centroid, centroid (`STACK_K` heights, ADR 0002 item 11), p_ref (ADR 0003 item 4) and item 13's mean push between bodies. It no longer writes goals for them. The per-body rotation it keeps is the whole-body best fit, used only where nothing per member exists.
8. **Pressure pushes stay rigid for soft bodies** (ADR 0003 item 12 unchanged). Water's pressure squeezes a jelly only because the pushes are relative to its top (p_ref). A real jelly is close to incompressible, so even pressure all round shouldn't deform it. Buoyancy still moves and turns it; contacts, gravity and impacts bend it.
9. **The eraser and the split** (ADR 0004) need nothing new: regions are found from rest offsets each iteration, so a piece's regions are whatever is left within w, and its outline is worked out again as today.
10. **The CPU reference mirrors it** (`ParticleStep._match_regions`, beside `_match_shapes`), with neighbour lists from its own grid.

## To be decided by the tests
CPU tests first, small (the fewest particles and frames that separate before from after), then the same scenarios in `body_probe`:
- **Droop:** a 40 × 4 jelly plank resting on two carrot pillars 60 px apart. Today its middle sags about 1 px. Floppy should sag visibly: tens of px at the default, less at `region` 2.0 or a higher stiffness. It should rest still, not creep.
- **Wobble:** a 16 × 10 jelly dropped 100 px onto the floor. Its shape error should peak at the impact, swing a few times, and settle under 0.5 px off its sag within ~2 s, with no endless jiggle and no flying members.
- **Squash and spring back:** a 16 × 10 carrot set on a 16 × 10 jelly. The jelly flattens (its height drops by a set share), and once the carrot is erased it gets back within 0.5 px of its rest height.
- **Fold:** a long thin jelly dropped across a carrot so its ends fold down. No member ends inside the body's own outline.
- **No change:** every rigid test and probe (carrot, cork, stacks, sand, water) keeps its numbers; the existing jelly tests are re-read against the new defaults (`test_squashed_jelly_springs_back`, `test_sunk_jelly_keeps_its_shape`, `waterjelly`).
- **Defaults:** jelly's `stiffness` and `region`, picked from the droop and wobble runs and confirmed by the owner in screenshots and clips of `main.tscn` (a jelly drawn over a gap between two sand piles, one dropped, one under a carrot).
- **Cost:** `body_probe` timing for one 2000-member jelly and for 256 small ones, against today's `bodies` pass.

## Considered and rejected
- **Linear and quadratic deformation modes for the whole body** (Müller et al. 2005, β): cheap, but one bend for the whole body. A long or freehand shape can't bend in one place only.
- **Springs between neighbours** (XPBD distance bonds plus an area constraint, as SunaEngine's bonds and OE-Cake-like ports do): natural bending and tearing, but with 4 Jacobi iterations a chain of springs converges slowly, so a big jelly would sag and stretch like taffy unless iterations go up for everything, and their stiffness doesn't map onto the `stiffness` column. Regions reach a goal in one step each iteration.
- **Stored per-member region lists:** fixed neighbour slots per member (cap × 13 × 4 B ≈ 2.6 MB at 50k, more for a larger region) that the eraser and the split would have to keep current. The hash already holds the neighbours.
- **Lower stiffness on the one cluster:** lag and slump, no bending (Context).
- **MPM or FEM for soft bodies:** a second solver; the WorkBuddy review (2026-10-10) found an MPM rewrite not justified, and ADR 0001 keeps one PBD solver.

## Risks
- **Folding and inversion:** with small regions and low stiffness, a region can flip (its rotation fit turns past 90° under a hard impact). The previous-rotation fallback and the self-contacts of item 4 should hold it. The fold and wobble tests are there to catch it.
- **Outline under bending:** item 6 uses a member's own region frame, which is good for gentle bends. At a sharp fold the outline points of the two sides cross, and the push-out may push water or grains the wrong way there.
- **Cost of two per-particle passes per iteration** (fit and goal, each reading up to ~13 neighbours) across all particles, though they exit at once for anything not in a soft body: about one more `solve_delta`'s worth of work per iteration. To be measured (the cost test above).
