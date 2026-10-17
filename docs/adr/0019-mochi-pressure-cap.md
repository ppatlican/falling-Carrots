# 0019: Dough landing on water: the grid's push on wet dough is capped at its buoyancy

Date: 2026-10-17. Status: **proposed, owner to play.** Owner, 2026-10-17: "dough in water: 1. add 10k dough. 2. add 10k water. 3. add 10k dough. watch as it bounces and twitches, jumps around. can we fix that?" Amends ADR 0018 Decision 3.

## Context
- **The scene** (`body_probe doughsandwich`: "+10k dough" at frame 1, "+10k water" at 240, "+10k dough" at 480, as `main.tscn` fills them; 2400 frames). The second dough falls ~220 px and lands on the water at ~300 px/s as a slab nearly wall to wall.
- **Measured before** (two runs the same day; four earlier runs agree): the slab lies on the water like a lid, bounces there, and the water bursts up through it again and again. Calm (the second dough's 99th percentile under 15 px/s and under 50 water particles over 100 px/s from then on) only 18.7-21.2 s after the fill. Over the 21 s after the fill: the second dough's 99th percentile speed 59-60 px/s on average, its centre's |vy| 5.8 px/s, 13.5 water particles alone in the air. In `main.tscn` shots, 10.7% of the dough and water pixels change between frames 2 apart from 8.7 s to 18.7 s after the fill.
- **Why** (each by turning one thing off, GPU):
  - Since ADR 0018 a wet mochi particle takes the grid's push over its density, clamped like a liquid's at half a spacing a step: ~36 gravities. That push removes the water's compression. The water squeezed under the landed slab pushed the slab's wet bottom rows up by up to that much, and they held the whole slab up over the water. Without the grid push (ADR 0017's dough) the slab sinks through and is calm ~6 s after landing, but then a dough sinks whatever its density.
  - The lid is unstable (a heavy layer over a light one). The water broke through it in bursts for ~20 s: air pockets, strands thrown up.
  - The trade of ADR 0018 Decision 2 throws water coming up through a dough into the air. With it off, 1.3 water particles in the air against 14, and the dough no calmer.
- **The dough's own jitter at the end is not this.** Two "+10k dough" with no water (`doughtwice`) leave the lower one shaking in place for good (0.28 px a frame, 99th percentile 13 px/s) under the upper one's weight. One alone rests (0.77 px/s). It is ADR 0017's limit (the pair rule at its Jacobi limit), and it reads the same with this change.

## Decision
- **The grid's push on a mochi particle is at most `MOCHI_PRESSURE_MAX` (1.25) gravities (g dt²) over its density a step** (`solve_pressure.glsl`; CPU `ParticleStep.mochi_pressure_push`). At rest the push that holds water up is one gravity, so a dough still gets 1 / density of it: it floats, hangs or sinks by its density as in ADR 0018. The push that removes the water's compression is cut to that, so it can't hold a dough up on its wet rows.
- **Amended by ADR 0021 (2026-10-17):** dough round a pocket of liquid caught inside a dough bed (the liquid share of the 3 x 3 grid cells round it under 0.2-0.45) takes no push at all.
- Nothing else changes: a dry dough never takes the push (ADR 0018's fill gate), and every other class takes its old path. No new buffer, binding or `Params` field; `common.glslinc` is unchanged.

## Results (2026-10-17)
GPU, RTX 3080 Ti, `--disable-vsync`, the shipped dough row (1.1) unless set. "Before" is the branch before this ADR, the same day.

| check | before | after |
|---|---|---|
| `doughsandwich` calm after the second "+10k dough" | 18.7, 21.2 s | 10.5, 11.3 s |
| second dough's 99th percentile speed, mean over the 21 s after it | 59.4, 60.2 px/s (55-62 in four earlier runs) | 29.2, 31.9 px/s (26-32 in three earlier runs) |
| its centre's \|vy\|, mean | 5.8, 5.8 px/s (4.9-7.3) | 3.6, 4.0 (2.9-3.5) |
| water alone in the air, mean | 13.5 (13.6-14.9) | 26.3, 26.6 |
| water inside the dough at 40 s | 314, 345 (300-560) | 467, 705 (700-1090) |
| `main.tscn` shots, pixels changing between frames 2 apart, 1.3-8.7 s / 8.7-18.7 s after the fill | 11.5% / 10.7% | 14.2% / 3.4% |
| shots, air pockets under the top (6 x 6 dark blocks, mean px), same windows | 16.9k / 13.9k | 25.6k / 2.2k |
| `doughbed` water inside, gap median / p90, rest (99%) | 5-13, 1.46-1.64 / 2.05-2.12 px (ADR 0018) | 6, 13; 1.52-1.61 / 2.08-2.10 px; 0.06-0.09 px/s |
| `doughlayer`, `doughwater` | 0-4 inside; one piece, at rest | 0 inside; one piece in 2 of 2 runs (6 of 6 with the same cap), 0.8-1.8 px/s |
| density 0.9 | dropped: floats (lowest 294.6); from the floor: rises to the surface (240.4 against 235.0) | 295.1; 238.6 against 235.1, in 4 pieces (ADR 0018: 3-4) |
| density 1.0 | dropped: hangs (lowest 324 at 10 s); on the floor: stays | lowest 340 at 10 s; stays |
| density 0.1 / 10 | as ADR 0018 | 0.1: floats at rest (0.51 px/s), the 10k bed under water still turns over (99% under 61 px/s at 30 s; ADR 0018: 58). 10: all pass but `doughwater` split in 1 of 2 runs (before: 1 of 3) |
| cost, `doughbed` frame, solo back to back | 1094 µs | 1060 µs |

- **The landing is now one splash, not 20 s of bouncing.** The slab sinks through the water in ~4 s and the water ends on top, calm by ~11 s. That splash is harder than before while it lasts: more water thrown up, more air pockets for a few seconds, and more water left in the dough's top as specks (above).
- **Dry dough unchanged:** `doughslump` 109.8 x 26.6 px (before 109.3 x 26.6), `doughmerge` the same, `doughtwice` the same jitter. The push is only reached where the grid holds liquid at a mochi particle.
- **Not run:** the shipped materials' body scenarios and the sand checks (only the mochi branch of `solve_pressure` changed); the full CPU suite.
- **CPU** (`@quick @mochi`, 61 pass; `@setup @mochi` with the new test, 34 pass):
  - New `test_wet_pressure_push_is_capped`: the push at rest is unchanged at 1.1 and 0.9, and a half-spacing push is cut to the cap.
  - `test_water_in_a_dough_rises_out` still passes, but the water rises less far: from y 25 to 17.3 against the dough's top at 18.8 (before: to 12.0 against 18.3).

## Known limits
- **The landing still splashes for ~4 s:** spray and air pockets while the dough plunges through the water, and more water left in its top afterwards (470-1090 of 10k against 300-560).
- **A dough bed under another dough jitters in place** (99th percentile ~10 px/s with water, 13 dry, 0.06-0.28 px a frame), as before. Halving the pair rule's step, or scaling it by the busier end's neighbour count, cut the jitter by a third to a half but flattened a lump (`doughslump` 129-163 px wide against 107-113). A coloured solve is still the lever (ADR 0017 Known limits).

## Owner's call
- **Play:** "+10k dough", "+10k water", "+10k dough", as reported. Also "+10k dough" then "+10k water" (as ADR 0018), and dough blobs dropped into a pool at density 0.9, 1.0 and 1.1 (floats, hangs, sinks).
- **Keep or revert:** `git revert` this ADR's code commit brings back ADR 0018's push.

## Considered and rejected
- **A higher cap:** 2 gravities, calm at 10.7-13.2 s with 27-33 water in the air; 3, calm at 13.8-27 s with 36-37 in the air.
- **No grid push on dough** (ADR 0017): calm ~6 s after landing, but a dough sinks whatever its density.
- **Stopping the trade once the water rises at 30 or 100 px/s** (its own speed or past the dough): 2-5 water in the air, but a dough dropped into a pool tore on the floor in 8 of 15 runs (0 of 15 without), around water it no longer pushed out.
- **Counting air near a water particle as not closed in** (so water at a dough's open top isn't traded up): 20-21 water in the air, about the same.
- **A lower enclosure threshold (0.35)** to clear the specks: 266-795 water inside, 30-31 in the air.
- **The trade off:** 2.5 in the air, but no calmer, and water caught in a dough stays.
