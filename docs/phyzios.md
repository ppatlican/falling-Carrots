# Phyzios: how OE-Cake's successor does it

Phyzios Studio (Prometech) is OE-Cake's successor, the feel ADR 0001 aims for. The owner reverse-engineered its
particle engine (Phyzios Studio Pro CE 1.4.18) outside this repo. The full write-up, with the math for every rule:
`C:\Users\nosed\WorkBuddy AI\2026-10-14-07-26-29\phyzios-analysis\FALLING-CARROTS-IDEAS.md` (it cites `task-b18/SPEC.md`
in the same folder, which was checked against the engine over 86 scenes). This page is the short version, grouped by
our symptoms.

**Rules.**
- Ideas and math only. Nothing from the decompiled game or its files goes into this repo, and we don't set out to
  clone Phyzios as a whole (owner, 2026-10-17: falling-carrots stays on the GPU; no restart).
- Phyzios constants don't port. It is sequential (pairs walked in order, Gauss-Seidel), has no dt (everything per
  step) and works in kernel radii (h = 1, spacing 0.75 h; ours h = 4 px). Retune, then prove it on the CPU reference
  and the GPU probe, as AGENTS.md requires.
- Before borrowing a rule, read its section in the full write-up.

## The four differences that matter
1. **Sequential vs parallel.** Later pairs see earlier pairs' results within a step. Depth pressure, stable stacks and
   snap come largely from that ordering. Our GPU Jacobi can't, which is why we have the density projection grid:
   **don't remove the grid on the strength of Phyzios.** The nearest GPU equivalent is a coloured solve
   (`docs/papers.md`, SunaEngine coloured solve).
2. **No dt.** Gravity 0.001 h/step², speed cap 0.5 h/step. Convert by dimensionless numbers; a per-step fraction c is
   `1 − (1 − c)^(steps/s)` per second.
3. **One kernel for everything:** `w ≈ 1 − |r|/h` (a linear hat), `n` the unit pair normal, density `Σw`. Every
   material rule below is written on `w` and `n`; borrow the kernel with the rule or rescale.
4. **Corrections move position and velocity by the same Δ** ("push"). Not pure PBD, not pure force. A big part of the
   snappy-but-stable feel. In our PBD terms: a position correction that also keeps its velocity.

## By symptom

| our symptom (STATUS / ADR) | what Phyzios does instead | write-up § |
|---|---|---|
| Jelly on sand worms and digs; lopsided soft body creeps sideways (**tried: ADR 0016**, joint jelly) | Jelly is a network of **pair joints** made on first touch, each storing a rest vector and both ends' rest angles; every correction is equal and opposite at the two ends, so momentum is exact and creep can't happen. No region goals to fight the grain contacts; sand meets jelly through the plain powder pair rule | 9 |
| Dough (ADR 0012), if the rest lattice gives trouble | **Mochi:** no rest shape at all. `f = (ρi + ρj − 2ρ0)·ke + w·ks`, pull halved: pulls only while sparser than rest, breaks at one kernel radius, re-forms on contact. Or joints whose rest vector resets past a yield | 5, 9 |
| Stickiness limits (ADR 0011): press-and-push, caps, tall damp cuts tearing | Cohesion driven by **density deficit** is self-limiting (a clump can't push itself up) and needs no cap or "touching" zone; taller walls = raise `ke`. No wall adhesion at all | 5 |
| Sleeping trade-off; piles freeze; mid-air clumps | Sand never sleeps. Velocity-only contacts: a spring past rest spacing, damping **only on approach**, and friction that matches relative velocity scaled by overlap (`c = w·kf`). A pile at rest has no relative velocity, so friction holds it without freezing; overlaps spring apart slowly with no rebounds | 4 |
| Water floaty; slosh too long (Next 4: drag 0.3/s?) | No global drag on water. Air drag (and wind) only where `ρ < ρ0`, scaled by the deficit: bulk sloshes freely, spray and flour dust are blown about. Impacts lose energy only through approach-only damping | 13, 2 |
| Churn, surface drift | Pressure repels only (`p ≥ 0`), soft (kp 0.05); damping only on approaching pairs; hard speed cap. Check whether we damp separating pairs (XSPH does) or ever pull | 2 |
| Hovering drops; honey meniscus; noisy surface | Surface tension with a curvature term (divergence of a colour-field gradient), iterated 5× | 6 |
| Honey flows like wet sand (XSPH capped at 1) | Micropolar viscosity: per-particle spin; damp only the relative velocity a shared rotation doesn't explain, put the rest into spin. Thick and still folds and coils. Costs one float per particle | 7 |
| Edge chaos at screen walls | Wall = one ghost neighbour on the wall plane (adds density); push-back is linear, thresholded (only past 0.25 h overlap) and capped at the speed cap. No wall friction | 3 |
| Oil/water layering rocks or churns (ADR 0010) | Equal masses everywhere. Light/Dense are flags: a momentum-conserving swap only between unlike neighbours (`v_a ∓= g·w·coef`, other end opposite). A settled layer feels nothing, so it rests | 2b |
| Rigid stacks jitter; a body spawned into the floor launches | Bodies pinned exactly to their frame every step; contacts are impulses **divided by the body's contact count**; rotation from atan2 of the 2×2 covariance (exact in 2D, no polar iteration). The impulses between rigid bodies are on main (ADR 0015) | 12 |
| Eraser splits, future cutting/brittle (ADR 0004, 0006) | Union-find over contacts plus joints with weight > 0. Break thresholds vary per pair by a cheap index hash, so cracks come out irregular with no RNG | 12, 10 |
| Weak water brush | Pour = a row at rest spacing every `spacing/speed` steps: a lattice brush in time, never overlaps itself | 15 |
| Snow, packable flour | A weak spring toward exactly rest spacing in both directions | 8 |
| Reactions (`cpu_ref/reactions.gd`) | Packed fuel can't burn (density gate); growth into a neighbour only while sparse ("dough rises"); steam as flags on water, not new particles | 11 |
| CPU reference and GPU disagree | Float store points change results after a few hundred steps: mirror grouping and precision, not just the formula. Use a per-particle hash RNG (index + step), not shared state | 16, 17 |
| Dense pile acts as if it has fewer contacts | Phyzios caps its neighbour scan (7 + 16 records) and silently drops contacts below ~0.45 h spacing: check our hash's per-cell caps | 1 |

## Testing lessons from the reverse engineering
- Default parameters hide bugs. Spec errors turned up only at awkward values (gravity ×1.13, spacing 0.35, radius
  0.52). We probe both slider ends (ADR 0001); also probe an awkward **middle** value.

## Best candidates, in order (2026-10-17)
1. ~~Pair-joint jelly~~: done as a timeboxed experiment (ADR 0016, 2026-10-17), and it passed its kill criteria: creep 0.001 px/s (FastLSM 0.028), loads hold better (a carrot dropped 60 px stays on up to 4 px off centre; regions only dead centre), a soft plank at 0.2 ends with 7 members inside out against 12-25, and it's cheaper than regions. The owner judged joints better (2026-10-17): jelly is to switch to them, dough after a plasticity check. What carried over and what didn't: the equal and opposite correction with Phyzios' half-each rotation of the rest vector, yes. Integrated angles and spin, no: each member's angle is the best rotation of its own joints, refitted every iteration, which keeps angular momentum exact as well. Gauss-Seidel order, no: a Jacobi sum is already momentum-exact; a coloured solve would raise the stiffness ceiling (from ~0.9 up the slider does nothing). Phyzios' constants didn't port: the share is k / 2 per joint, capped at 1 / N.
2. Never-sleeping sand contacts on the CPU reference, then see whether `SLEEP_SPEED` can drop.
3. Drag by density deficit, as an alternative to raising water drag to 0.3/s (the owner's call on feel).

Each would be an ADR. 2 and 3 aren't started.
