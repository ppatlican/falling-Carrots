# 0014: A soft body's region goals keep its momentum (the creep)

Date: 2026-10-17. Status: proposed, **owner's call**. Built and measured (branch `fastlsm-region-fit`, commit 03d2e51), not merged: it fixes the creep, but loaded soft bodies give more (Results). Follows ADR 0013 Known limits and the STATUS known issue "A lopsided soft body creeps sideways on its own" (ADR 0008 Known limits).

## Context
The creep was measured on the CPU only (ADR 0008: 0.047 px/s; ADR 0013: 0.20 px/s, FastLSM weighting 0.14, not kept). Measured on the GPU first (`body_probe creep`, new: a 16 x 10 jelly let go turned 30 deg on the floor, 1800 frames, the centroid's sideways speed from frame 600; RTX 3080 Ti, `--disable-vsync`; each line two runs, identical):

| stiffness 0.2 | creep (px/s) | with no friction (`jelly.friction=0`) | fastest member at the end |
|---|---|---|---|
| before ADR 0013 (0d18f25) | 0.046 | 1.71 | 0.05 px/s |
| main (ADR 0013) | 0.151 | 1.84 | 0.2-0.7 px/s |
| main + FastLSM weights (this ADR) | **0.028** | **0.057** | 0.04 px/s |

At 0.5 and 0.95 it doesn't creep on any build (≤ 0.007 px/s; the jelly stays on its corner).

### Why
- **The drive is the region goals, not friction.** With no floor friction the jelly glides at a steady 1.7-1.8 px/s, every member together; friction 0.6 holds most of it back. ADR 0013's `keep_order` triples what gets past friction (the jelly rests more tilted and taller, more strained), not the drive itself.
- **Each region's goal keeps momentum, the mean over regions doesn't.** A member moves toward the mean of the goals of the n_i regions holding it. Summed over a body, that is k Σ_r Σ_{i∈r} (goal_r(i) - p_i) / n_i, which is 0 only when every member of a region has the same n_i. Edge members belong to fewer regions (4 at a corner, 6 on an edge, 9 inside at region 1.5), so they count for more, and a body strained unevenly pushes itself sideways. FastLSM (`docs/papers.md`) weights each member by 1 / n_i in the region fits (centroids and A_pq); then the sum is exactly 0 about each weighted centroid.
- **ADR 0013's CPU try measured with friction**, where the CPU creeps little anyway (0.014-0.028 px/s in a 600-frame test). Without friction the CPU shows it as the GPU does: main 2.34 px/s, FastLSM 0.061 (`test_lopsided_soft_jelly_does_not_creep`, on the branch).

## What was built (branch `fastlsm-region-fit`)
1. `body_region_fit.glsl`: member j counts with weight 1 / n_j in the region's centroid, rest centroid and A_pq; the rotation is kept when |A_pq| is under `BODY_ROT_EPS` times the weights' sum. n_j comes from `body_push.z`: `body_push` became a `vec4`, and `solve_delta` writes the region size `contact_delta` already counts (`region_n`). The fit runs after `solve_delta` in every iteration, so the count is this iteration's. A nested count in the fit instead cost 5.5 ms a frame for a 2000-member jelly; through `body_push` the regions pass reads 562 µs (main 575).
2. CPU mirror in `_match_regions` (weight 1 / `_regions[m].size()`).
3. Shader stamp v24 (`common.glslinc` changed); every reader of `body_push` takes `.xy`.
4. `test_lopsided_soft_jelly_does_not_creep` (@soft, no friction, 300 frames, under 0.3 px/s; 21 s).

## Results (2026-10-17)
Kept as ADR 0013 needs:
- **Sand** (`sandjelly`): on top at every stiffness; at 0.2 52 / 10 / 6 / 12 members under the sand's top over four runs (main 24 / 22 / 38, ADR 0013 40), 311-362 grains inside (main 340-358); 0.4-0.95: 4 / 1 / 0 / 0 under. Nothing moving.
- **Shipped jelly (0.95)**: `jelly,droop,wobble,squash,fold,erasejelly,waterjelly,sandstroke,sandbits,sand,sandlow` all pass; `droop` 3.55 px, `wobble` 10 swings, `fold` 3.01 px, no water inside.
- **Soft verdict at 0.5 and 0.8**: all standing, nothing inside; `boxstack` at 0.5 stands (main flips a box). Dough on sand as main or cleaner.
- **CPU**: `@soft @plastic @setup` pass (40 tests).

**What changed for the worse: a loaded soft body gives more.**
- `squash` (a carrot set on a 16 x 10 jelly at 0.95): 15-17% flatter (main 9%, deterministic), springs back within 0.11 px. Dough at 0.95 under a carrot: 25% flatter, keeps a 2.08 px dent (main 11%, 1.56).
- `main.tscn`, a carrot dropped 60 px onto a 0.95 jelly (`C:\Users\nosed\Pictures\falling-carrots-fastlsm\`, `before` main, `after` this ADR): on main it stays on top (3 of 3 runs); here the jelly leans and the carrot slides off in 2 of 3.
- `stack3` at 0.2: the top box tips over in 3 of 3 runs (main stands, 3 of 3; ADR 0013 counted that as a gain).
- `stack5` at 0.8: a bottom-row member's velocity flips in place (0.18-1.14 px/s while no member moves over 0.003 px in 60 frames); invisible, but it fails the probe's 1 px/s mark in one run of three.

**Why it softens: the old momentum leak was holding loads up.** A second momentum-exact variant, which keeps the unweighted fits and takes each body's mean goal move off its members (CPU only), sags the same: a 12 x 8 jelly under a 12 x 8 carrot at 0.95 stands 11.95 px tall (FastLSM 11.88, main 12.28; `test_jelly_squashes_under_a_carrot_and_springs_back`), and it kills the creep too (0.033 px/s with no friction). So in a squashed body the unweighted goals push it up against its load, as they push a lopsided one sideways; any fix of the creep inside regional shape matching takes that away.

## Owner's call
1. **Keep the creep** (0.15 px/s at 0.2 on the GPU, none from 0.5 up) and leave regional shape matching as it is; or
2. **Merge the branch** and accept softer loaded jellies (a carrot on a shipped jelly sags ~1 px more and may slide off its dent), maybe with the shipped jelly stiffer to make up for it (a tuning pass over `squash`, `stack3`, `jellystack`, the drop in `main.tscn`); or
3. **Pair joints instead of regions** (Phyzios, `docs/phyzios.md` § 9): every correction equal and opposite at a pair's two ends, so momentum is exact by construction and the stiffness is tuned with no leak to lose; no region fit to turn inside out (ADR 0013 Known limits, `droop`); joints break past a stretch. It replaces ADR 0005's regions, so its own ADR and a timeboxed CPU experiment first. Not started.

## Considered and rejected
- **The nested region count in the fit** (no new storage): 5.5 ms a frame for a 2000-member jelly.
- **The goals' sum over a constant region size** (keeps unweighted fits, momentum exact; not built): edge members would move at 4/9 to 6/9 of an inner member's rate, softer than either variant above.
