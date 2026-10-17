# 0016: Pair-joint jelly (a timeboxed experiment)

Date: 2026-10-17. Status: proposed. A timeboxed experiment, ADR 0014's Owner's call 3: jelly as a network of pair joints (Phyzios, `docs/phyzios.md`, write-up § 9) instead of regional shape matching (ADR 0005), behind a per-material switch so the owner can compare the two.

## Context
- **The creep.** ADR 0014 (FastLSM weights, on main, 63b2106) stops a lopsided soft body creeping sideways (GPU `body_probe creep` at 0.2: 0.151 → 0.028 px/s). But loaded jellies then give more: a carrot dropped on a shipped jelly slid off in 2 of 3 runs, since the old momentum leak was holding loads up. ADR 0014 found that any momentum-exact fix inside regional shape matching sags the same way.
- **Inside out.** A soft plank (0.5 and below) wedged into a gap is crushed at the supports' corners and turns partly inside out (`droop inv`: 16-19 members with det F ≤ 0 at 0.2), and region fits at k ≈ 0.03 an iteration don't pull the patch back (archive § ADR 0013 follow-ups).
- **Phyzios** makes a jelly from pair joints, made on first touch. Each joint stores a rest vector and both ends' rest angles. Each pass moves the two ends by an equal and opposite correction toward the rest vector, carried round by both ends' turns. Momentum is exact for any network shape, so a lopsided jelly can't drift, and there is no region fit. Its constants don't port: it is sequential (Gauss-Seidel), has no dt and works in kernel radii.

## Decision
A cluster material below stiffness 1 takes a new column, `soft_model`: `"regions"` (ADR 0005, the default, and what every shipped row uses) or `"joints"`. A new row, **joint jelly** (id 7), is jelly with `"soft_model": "joints"` and its own colour, so both can be drawn side by side in `main.tscn`. Everything below is for joint materials only; a regions material runs exactly as before.

1. **The joints are the region pairs.** Two members of one soft body are joined when their rest offsets lie within the material's region radius w (`region_reach`), which is the pair relation ADR 0005 already uses for regions, skipped contacts and `keep_order`. The rest vector is q_j − q_i (rest offsets). The body brush spawns members on the rest-spacing lattice, so the pairs within w at creation are exactly the touching pairs: Phyzios' "made on first touch inside the body", made when the body is made. Every member starts at angle 0 (brush_spawn and make_body write region rotation (1, 0)), so both ends' rest angles are 0 and nothing needs storing.
2. **Each end's angle is its region's fitted rotation** (R_i from `body_region_fit`, unchanged; oriented particles, Müller & Chentanez 2011), not an angle and spin integrated per particle as Phyzios does. That reuses a pass we have. Integrated angles are the fallback if inverted patches still don't come back (Risks).
3. **The correction**, per joined pair (i, j), with both ends' rotations from the last fit:
   - R̄ = normalize(R_i + R_j), so both ends see the same frame (as `keep_order`); the body's rotation if the sum is ~0;
   - e_ij = (p_j − p_i) − R̄ (q_j − q_i): how far the pair is from its rest vector carried round;
   - |e_ij| clamped to `JOINT_MAX_ERR` (1 spacing): a symmetric clamp, since |e_ji| = |e_ij|;
   - member i moves by a Σ_j e_ij, with a = `JOINT_GAIN` · k / N(w): k = 1 − (1 − stiffness)^(dt · 60 / iterations) (ADR 0002 item 7) and N(w) the lattice neighbours within w (8 below region 2, 12 at 2).

   e_ji = −e_ij exactly in floats (a − b = −(b − a); R_i + R_j = R_j + R_i; rotating −q gives the negated result), so j moves by exactly the opposite of i's share: **momentum is exact**, whatever the network's shape or stiffness. With N(w) as the divisor, a member displaced alone among unmoved neighbours gets k of its displacement back per iteration, as a regions member does (ADR 0005 item 1), and its N neighbours share the reaction. That reaction is the difference from regions: it is what keeps momentum. `JOINT_GAIN` (1 to start) is the knob for retuning, since a momentum-exact body may sag more under load (ADR 0014).
4. **The push.** Phyzios moves position and velocity by the same Δ. In our PBD terms that is the ordinary position correction: velocity_update makes v = (pred − pos) / dt, so moving pred by Δ adds Δ / dt to the velocity. That is Phyzios' push in per-step units, so it needs nothing new. The caps every body member already gets (`stop_not_launch`, the `BODY_KICK` separation cap, ADR 0002 item 12) still apply; at rest the joint velocities are far under the 13 px/s kick, so they don't break the momentum balance there.
5. **Break and yield.** No permanent break (Brittle stays ADR 0006). A joint acts only while both ends are in each other's 3 x 3 hash window, as a region member does (ADR 0005 item 3), so a pair stretched past roughly 1.4-2x its rest length stops pulling until it comes back. Yield is plasticity (ADR 0012): it moves rest offsets, so joints' rest vectors follow with nothing new. Phyzios' "reset the rest vector past a yield" is the same idea.
6. **Storage on the GPU: none.** Joints are found at run time from the hash, the body id and rest offsets, as regions are (ADR 0005 item 3 rejected stored lists for the same reasons). No new buffer, binding or `Params` field. `soft_model` goes into the material row's spare `info.y` (the `uvec4` holding the class has three unused uints), so the row stays 80 bytes. `common.glslinc` gains `joint_material()`, so the shader stamp goes to v25 (SPEC 2.7).
7. **In parallel without races: Jacobi accumulation, no colouring, no atomics.** The correction is added in `contact_delta` (`powder.glslinc`), in the same-body branch that already visits exactly these pairs for `keep_order`. Each thread writes only its own `scratch` (solve_delta), reading positions that only solve_apply writes and rotations the previous iteration's fit wrote. FOR_EACH_NEIGHBOUR's home-cell windows make the pair sets symmetric (SPEC 2.7), so both ends compute the negated correction from the same values. solve_delta adds it after the half-spacing clamp of the contact sum, which would otherwise cut one end's share and not the other's. solve_apply applies it. For joint members `body_region_goal` returns at once (the goals aren't used), and `body_region_fit` still runs (the rotations).
   - *Graph colouring* (SunaEngine's coloured solve, `docs/papers.md`) would give Gauss-Seidel order between colours (faster convergence, closer to Phyzios), but needs 4x the dispatches per iteration. A Jacobi sum is already momentum-exact, which is what this ADR is for. Colouring stays a later stiffness lever.
   - *Atomics* would need float atomics, which phones don't have (ADR 0002), and contended adds.
8. **Alongside everything else, unchanged:** sand, water and other bodies meet a joint member through the same contacts, push-out, `keep_order`, region-shared pushes between soft bodies (ADR 0008 item 1) and grain reach (ADR 0013) as a regions member. They all read region membership or rotations, which the fit still provides. Pressure pushes stay rigid (ADR 0003 item 12).
   - **The eraser** (ADR 0004): an erased member's joints go with it. Each piece of a split gets its own body id, so joints across the cut are dropped by the same-body test, with no bookkeeping.
9. **CPU reference mirrors it:** `ParticleStep._joint_delta` (from `_contact_delta`'s same-body branch, added after the clamp in `step()`); `_match_regions` fits but sets no goal for joint members.

## How it's judged (GPU probe; the CPU reference only checks the build)
Against FastLSM on main, RTX 3080 Ti, `--disable-vsync`, with `set=jelly.soft_model=joints` turning the probe's jelly into joints:
- `creep` at 0.2: target ≤ 0.028 px/s, ideally ~0.
- A carrot dropped on a jelly at 0.95: does it stay on? 3 runs each.
- `droop inv` at 0.5 and 0.2: do inverted members come back?
- `sandjelly` (ADR 0013) and `jellystack`, `jellydrop` (ADR 0008): no regressions.
- Stiffness 0.2, 0.95 and an awkward middle value (0.63; Phyzios testing lesson).
- Cost: TIME for `waterjelly` (one small jelly) and `softcap` (2000 members) against STATUS.
- `main.tscn` screenshots of what the owner will see.

**Kill criteria:** after a working GPU version, if the creep isn't clearly below FastLSM's, or loads hold no better, or the cost at 2000 members is over ~2x the current bodies pass, write it up as rejected and leave main's jelly path as it is.

## Results
To be filled in from the runs.

## Risks
- **The rotations still come from a fit.** If an inverted patch's fitted rotation turns with the inversion, its joints' rest vectors turn too and hold it inverted, as the goals do now. Fallback: a per-member angle integrated from the joints' torques (Phyzios' spin), which can't jump.
- **Angular momentum isn't exact.** The correction isn't along the pair's line, and fitted rotations have no spin to trade with. A body could spin itself. Measured by `creep`'s rotation and `wobble`.
- **A momentum-exact body may sag more under load** (ADR 0014). `JOINT_GAIN` is there to retune.
- **Pulls cross a body one joint per iteration** (Jacobi), as regions' do (ADR 0005 Known limits): long jellies drape as before.

## Considered and rejected
- **Stored joint lists** (fixed slots per member, cap × 8-12 × 4 B, 1.6-2.4 MB at 50k): the eraser, split and plasticity would have to keep them current. The hash already gives the pairs, and a lattice body's touching pairs at creation are its rest pairs.
- **A separate joint pass**: it reads neighbours' positions, so it would need a delta buffer and an apply pass (two more dispatches per iteration). `contact_delta` already visits the pairs, and solve_apply applies.
- **Dividing each member's sum by its own joint count** (Jacobi averaging): edge members (fewer joints) would get a different coefficient from their partners, breaking the equal and opposite rule. That is the creep's own mechanism (ADR 0014).
