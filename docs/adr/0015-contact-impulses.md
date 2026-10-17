# 0015: Contact impulses between rigid bodies (a corner hit turns into spin)

Date: 2026-10-17. Status: accepted. The owner played it (2026-10-17: "looks ok. merge."), side effects included: a corner-landing carrot is thrown sideways, and it costs ~0.1 ms a frame while bodies exist. On main since 2026-10-17. Follows the STATUS known issue "A body dropped onto another freezes at the hit" (status-archive § A body dropped onto another freezes at the hit) and ADR 0003 item 14 (swept contacts) and its Known limits ("the sweep rewinds a whole move and not a spin").

## Context
Since the sweep fires once per hit (2026-10-17, on main), a carrot landing on another no longer stops dead, but the contacts still take a corner hit's speed instead of turning it into spin: `boxtilt` (a 16 x 10 carrot turned 30 deg, a corner hits at ~280 px/s) goes 150, 75, 66, 54 ... px/s after the touch and lies flat 9 frames later, where a rigid box keeps ~40% of its speed and slams flat in ~3. Contacts in PBD are position corrections spread over the body by shape matching: they stop the members that touch, and the body only learns to turn from those members' share of the fit.

Phyzios (OE-Cake's successor; `docs/phyzios.md`, rigid stacks row; full write-up § 12) solves contacts between bodies as rigid-body impulses, `J = vn / (D0 + D1)` with `D = (c^2 / moment + 1 / mass) * cnt`, c = r x n, divided by each body's contact count so a body touching in 16 places gets one impulse's worth, then pins every member to the body frame.

### The floor
A carrot turned 30 deg dropped onto the bare floor (`body_probe floortilt`, new) doesn't freeze: on 77f2ea5 its corner hits at 251 px/s, then 111, 62, 23 px/s, and it lies flat 3 frames later (spin up to 12 rad/s). The floor is a position clamp before shape matching, and that gives a corner hit about the right spin. What it does wrong is smaller: members end up to 4 px under the floor line after shape matching, and the body hops back up at ~37 px/s, tipping 0.1 rad past flat before it settles. The floor/wall impulse (`D_b = (2c^2 / I + 1 / M) cnt` in Phyzios) is left out; this ADR doesn't change `floortilt` (same trace to the digit).

## Decision (the experiment)
1. **An impulse solve between rigid bodies every substep**, after the hash and before the swept contacts (`impulse.glslinc`, `body_impulse_geo`, `_count`, `body_impulse`, `_apply`; `ParticleStep._contact_impulses`). It acts on the velocity predict moved with (gravity in) and predicts the members' positions again from it: the same as solving before predict, but with this substep's neighbour lists.
   - Pairs: a member of a rigid body (stiffness 1) and a member of another rigid body within a kernel radius at their predicted positions, closing faster than `SWEEP_DEPTH` spacings a substep (60 px/s at 2 substeps, the sweep's line) and by more than their gap allows this substep. n from the start positions, closing speed vn, gap = distance - spacing.
   - Per body (one workgroup per body, as `body_project`): mass M = members x density, moment I = density x sum (|r|^2 + spacing^2 / 6) about the start centroid, cnt = its pairs.
   - Per pair: J = (vn - max(gap, 0) / dt) / (D_a + D_b), D = (c^2 / I + 1 / M) cnt, c = r x n. **Speculative**: only the approach that would overlap this substep is taken out, so there's no rewind, and nothing is pushed apart (the push-out still does that). Inelastic.
   - Friction (ours; Phyzios has none between bodies): a tangential impulse that stops the slide at the contact, at most friction x J (the lower friction of the two, as the contacts).
   - Applied to the whole body: v_i += dV + dw x r_i. Shape matching keeps it rigid (our stand-in for Phyzios's pin). Each pair is found from both ends with the same J, so momentum is exact.
   - **A resting body pushed down is held** (`fixed_in_pair`): if every member of a body started the substep slower than an impact, and a pair's impulse on it points at least 30 deg below level, its D counts as 0 and it takes nothing from that pair; what it rests on takes it. Without it, a carrot resting on the floor took half of every hit, went into the floor at 30-60 px/s and came back up, and one dropped onto it (`boxhigh`) dipped 2 px in and tilted 0.16 rad. It stands in for Phyzios's sequential order with floor impulses, where the floor stops the lower body before the upper one's impulse is worked out. At 60 deg the lattice's diagonal pairs (35-45 deg off vertical) still pushed it down at 14-26 px/s.
   - **Jacobi, 3 passes** (`SimParams.IMPULSE_PASSES`): the pairs are found again each pass from the velocities the last left. Diagonal pairs share each body's count with the straight ones, so one pass takes out only part of the approach.
2. **Scope**: rigid bodies only, impacts only. Resting contact stays on today's contacts, push-out and `stop_not_launch`, so stacks and ADR 0008 are as tuned (`stack3`, `stack5` identical to the digit). Soft bodies (jellies, a carrot set soft) and the floor and walls take no part.
3. **The sweep-once sweep stays as a backstop.** Turned off between two rigid bodies, every scenario below gave exactly the same numbers: it no longer fires between them. It costs nothing to keep (the pass runs anyway for soft bodies).

## Results (2026-10-17, RTX 3080 Ti, `--disable-vsync`, back to back with 77f2ea5; the drops are deterministic, one run each; the 3-pass build with and without the sweep between rigid bodies gave identical numbers)

| scenario | 77f2ea5 (sweep once) | ADR 0015 |
|---|---|---|
| `boxtilt` vy after the touch, frames to flat | 150, 75, 66, 54, 48 ... px/s; flat (< 0.05 rad) 8 frames after; spin up to 5.8 rad/s | 91, 96, 100, 86, then 0 px/s; flat 4 frames after; spin 7 rad/s; **slides sideways at 57 px/s**, braked by friction over ~15 frames (moves ~11 px) |
| `boxoff` (new; 10 of 16 columns over the edge) | 78, 58, 46, 36, 31 px/s, spin rising to 6 rad/s over 4 frames | 59, 64, 69 ... px/s, spin 9 rad/s in a frame; on the floor ~4 frames sooner (`main.tscn`) |
| `floortilt` (new) | flat 3 frames after the corner hit, hops back at 37 px/s | the same, to the digit |
| `boxhigh` (flat, ~390 px/s) | 132, 19, 0 px/s; 0 inside (0.12 px); tilt 0.025 rad; rebound 0.0 | 135, 11, 1 px/s; 0 inside (0.17 px); tilt 0.032; rebound 0.0 |
| `boxdrop` | 94, 24, 0 px/s; rebound 0.0 | 72, 6, 0 px/s; rebound 0.0 |
| `plank` (tunnelling through 2 rows) | 6 members in, 1.35 px, 1 sample; tilt 0.070 | none in (0.00 px); tilt 0.027 |
| `boxside` (rebound) | 5.3 px/s, tilt 0.061 | **1.0 px/s**, tilt 0.003 |
| `boxstack` (rebound, tilt) | 6.0 px/s, 8 in (1.34 px), 0.059 rad | **0.4 px/s**, none in, 0.014 rad; lower boxes 0.002 (same) |
| `stack3`, `stack5`, `jellydrop`, `floortilt` | | identical |
| `sand` | passes, lowest particle 301.9 | passes, 301.2-302.7 over runs (the pile, not this: one body has no pairs) |
| `tests`, `sandcorks` (10/10), `watersink`, `waterfloat`, `many`, `big` | pass | pass |

Every `body_probe` check passes. `main.tscn` (a carrot dropped 150 px onto another, turned 30 deg / 20 px off centre): the tilted one lies flat by ~2 frames after the touch where 77f2ea5 takes ~6, and the overhanging one tips off and is on the floor ~4 frames sooner (`C:\Users\nosed\Pictures\falling-carrots-impulses\`).

**Cost** (TIME, solo, back to back): the new `impulse` pass reads 92-98 µs a frame with small bodies (`many`: 256 boxes; `boxstack`) and 139 µs with one 2000-member body (`big`); the other passes are as before within noise. It's mostly the dispatches (1 + 3 x 3 a substep, two of each three over the whole pool), and is paid whenever any body exists; none without bodies. Two passes would save about a third, but left `boxside` rebounding at 4.5 px/s (3 passes: 1.0) and `boxhigh` dipping 0.64 px in, rebound 0.8 px/s.

**CPU**: `test_corner_hit_on_a_box_turns_into_spin` (new, @rigid): 77f2ea5 60.6 px/s a frame after the touch and flat 8 frames later (fails), this ADR 115 px/s and 4 frames. `@setup @rigid @soft @sand @bodies-water` pass.

## Owner's call (decided 2026-10-17: option 1, merged)
1. **Merge it**: corner hits spin and keep their speed, bodies don't bounce off each other, at ~0.1 ms a frame while bodies exist. A carrot landing on a corner is thrown sideways (57 px/s in `boxtilt`) and slides ~11 px before friction stops it: what a rigid box with a gripping corner does, but more than before (12 px/s).
2. **Keep main** (the sweep once): corner hits slow, 5-6 px/s rebounds, no extra cost.
3. Later, if the cost matters on a phone: one indirect dispatch skipping the passes while nothing is closing fast.

## Known limits
- The held rule assumes a resting body is resting on something. A body at the top of a throw (slow everywhere) hit from above would be held in mid-air for that substep.
- The floor and walls aren't in the solve (The floor, above).
- Contacts between a rigid and a soft body, and between soft bodies, are as before.

## Considered and rejected
- **No hold for resting bodies** (Phyzios's impulse alone, Jacobi): the lower box takes half of every hit and the floor clamp throws it back (`boxhigh` 28 members in, tilt 0.16 rad, lower box -33 px/s).
- **Hold at 60 deg below level**: diagonal pairs got through (`boxdrop` rebound 2.7 px/s).
- **2 or 4 passes**: 2 above (with the 60 deg hold it also left `boxhigh` 6 members in, tilt 0.08); 4 (measured with the 60 deg hold) changed `boxhigh` and `boxside` little over 3 (tilt 0.023 to 0.011 rad, rebound 8.9 to 7.1 px/s) at a third more dispatches.
- **Dropping the sweep between rigid bodies**: identical numbers, nothing saved.
