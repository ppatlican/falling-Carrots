# 0021: Pops in a dough dropped through a liquid: no grid lift for dough round a pocket

Date: 2026-10-17. Status: **proposed, owner to play.** Owner, 2026-10-17, after ADR 0020: the black gaps are "way better but the pops still happen", in "+10k oil" then "+10k dough", and with water too. Amends ADR 0018 Decision 3 (and ADR 0019's cap on it). An option that stops the pops outright, at a cost to "+10k dough", "+10k water", "+10k dough", is the owner's call (below).

## Context
- **What a pop is** (`main.tscn` shots of "+10k oil" then "+10k dough" 4 s later, every 2 frames, UI hidden; `C:\Users\nosed\Pictures\falling-carrots-dough-pops\base_oil_whole.gif`, `base_oil_pop_zoom.gif`): the dough lands on the oil at ~300 px/s, throws most of it up the walls in a splash for ~2-3 s, and settles on the floor with 1500-2000 oil particles caught in it, in pockets and lakes. Over the next ~15 s a pocket now and then empties within ~10 frames: a void opens at its centre and grows outward, pressing the oil into a thin rim on the dough walls; the dough round it doesn't move in. The void then rises through the dough and tears out through the oil over it as dark streaks, throwing dough and oil. Water does the same. The handoff's guess (liquid caught at the landing bursting out) is right; what the eye catches is the void it leaves.
- **Measured before** (main at d26ba8b, the same day; `body_probe doughfall` with the new pop lines, below): dough faster than 30 px/s, summed over the samples from 5 to 20 s after the drop, with oil 1.4k-15.6k (6 runs, mean 9.1k), 13 seconds over 1000 (bursts) in the 6; with water 0.4k-25.3k (6 runs, mean 12.6k), 14 bursts. Holes (empty 4 x 4 px blocks over and in the dough, summed): 113-627.
- **Why: two steps, each found by switching one term off on the GPU** (`doughfall liquid=oil`, 3 runs each; the same sums):
  1. **The dough round a pocket turns over.** The grid's push on wet dough (ADR 0018 Decision 3) off: 85-1468, 0-1 bursts. That push lifts every mochi particle where the grid holds any liquid (fill gate 0 to 0.05) by about the liquid's density over the dough's, so dough round a pocket deep in a bed is nearly weightless under the dry dough over it, which keeps its full weight: light under heavy, and it turns over in bursts, throwing dough. Off, though, a dough sinks whatever its density (ADR 0019 rejected it).
  2. **The pocket empties into a void.** The grid corrects compression in every cell, counting mochi volume as a body's (ADR 0017). Where dough slumps onto a pocket, its cell reads over full, and the push drives the pocket's liquid out from its centre faster than the dough can close in (mochi has no pressure of its own to fill a void). With mochi left out of that count: holes 2-23, 0 bursts.
  - Not the cause: the expel trade (ADR 0018 Decision 2) off gave more motion (20.9k-56.5k) and kept 1500-1800 oil inside; oil's buoyancy (`set=oil.density=1`, 2.6k-18.7k) and water pop alike; a slower landing (`drop_y=288`, 1.7k-7.0k) caught just as much (1480-1790 at 2 s); ADR 0020's pull beside mochi off still popped (0.8k-33.1k) and brought its band of air back; the grid's push on liquid in cells with mochi off made the liquid churn (220k-254k).

## Decision
- **A mochi particle takes the grid's push only where liquid is round it at the scale of 3 x 3 grid cells (48 px)** (step 1): the push of ADR 0018, capped by ADR 0019, is also scaled by a smoothstep of the liquid share of the liquid and mochi volume in those cells, from `MOCHI_SHARE_LO` 0.2 to `MOCHI_SHARE_HI` 0.45 (`hydro_liquid_share`, `hydro_mochi_open` in `hydro.glslinc`, used by `solve_pressure.glsl`; CPU `ParticleStep._hydro_liquid_share`, `mochi_share_gate`). A dough dropped into a pool or lying under one reads mostly liquid round it (a 16 x 10 lump in water: 0.93) and keeps the whole push, so it floats, hangs or sinks by its density as before. Dough round a pocket inside a dough bed reads mostly mochi (0.03) and takes none.
- **Step 2 is not changed here** (the owner's call, below): every version of it measured left "+10k dough", "+10k water", "+10k dough" (ADR 0019) bouncing in more runs than the unchanged build.
- The share uses the grid's liquid fill (`hydro_phi.x`) and ADR 0020's mochi volume (`hydro_mochi`), both already bound. No new buffer, binding or `Params` field; `common.glslinc` unchanged. A dry dough never took the push, and every other class takes its old path.
- **Probe:** `doughfall` prints `POP` lines every 60 frames (liquid rising over 60 px/s under the dough's top or within 3 spacings over it, dough over 30 px/s, empty 4 x 4 px blocks from 3 spacings over the dough's top to the floor, each summed over the last 60 frames' samples) and their sums in its result line: from 4 s after the drop, then from 5 s (the landing's splash throws dough to ~5 s), the seconds from 5 s with over 1000 fast dough (bursts), holes. `drop_y=` sets the dough's bottom row.

## Results (2026-10-17)
GPU, RTX 3080 Ti, `--disable-vsync`, shipped rows. "Before" is main at d26ba8b, the same day. The pop sums and the sandwich are chaotic, so each build ran many times (this build's numbers pool the tuning copy and the final copy, the same code).

| check | before | after |
|---|---|---|
| `doughfall liquid=oil`, dough over 30 px/s summed 5-20 s after the drop | 1.4k-15.6k, mean 9.1k (6 runs) | 0.3k-5.4k, mean 2.0k (12 runs) |
| the same, bursts (seconds over 1000) | 13 in 6 runs (0-3 a run) | 8 in 12 runs (0-3 a run, 7 runs none) |
| `doughfall` (water), the same sum; bursts | 0.4k-25.3k, mean 12.6k; 14 in 6 runs | 1.1k-4.9k, mean 3.0k; 6 in 6 runs |
| holes over 5-20 s (oil) | 113, 136, 627 | 21-949, mean 342 (6 runs): **not fewer** |
| liquid left inside at 30 s, oil / water | 472-1165 / 612-1369 | 487-1259 / 685-968 |
| `main.tscn` shots, oil then dough: pixels changing between shots 10 frames apart, 5-10 s / 10-20 s after the drop | 25.5-39.4% / 8.8-13.4% (3 runs) | 23.7-27.0% / 9.5-17.3% (3 runs) |
| shots, frames at 10-20 s with a hole of 100+ px under the surface (of 61) | 3, 3, 1 | 10, 1, 5 |
| ADR 0020: shots, oil then dough at 30 s, columns with 3+ px of air / deepest | 0.5-1.4% / 3-5 px (3 runs) | 0.9-1.7% / 5-7 px (3 runs; ADR 0020: 0.5-0.9%, 4-7) |
| ADR 0020: probe `doughfall`, columns over 3 px at 30 s | 0-3% (9 runs) | 0-5% (18 runs; one 5%) |
| ADR 0020: dough then oil at 30 s | (ADR 0020: 0.6% / 3 px) | 0.2% / 6 px |
| ADR 0018: dough then water, dark columns over the dough at 10 s / 20 s | (ADR 0020: 22-23% / 20-22%) | 22% / 21% |
| ADR 0018: `doughbed` water inside, gap median, rest (99%) | (ADR 0020: 11, 20; 1.56-1.60 px; 0.55-0.58 px/s) | 7, 10; 1.40-1.44 px; 0.47-0.53 px/s |
| density 0.9 (`doughwater`, `doughlayer`) | (ADR 0019: floats, lowest 295.1; from the floor rises to 238.6 against a surface at 235.1) | floats, lowest 294.8-295.3; rises to 240.1-244.1, its top 233.0-237.1 against 235.0-235.1 |
| density 1.0 | (ADR 0019: hangs, lowest 340 at 10 s; on the floor stays) | hangs, lowest 340.6-343.4; stays |
| density 1.1 | sinks, rests | sinks, rests |
| ADR 0019: `doughsandwich`, calm within 15 s / end rms under 0.2 px / bouncing (rms near 1 px or more) | 4 / 3 / 2 of 9 (calm 8.0-24.7 s) | 7 / 6 / 1 of 9 (calm 5.5-28.7 s) |
| `doughwater` (16 x 10 into the pool): one piece / at rest | 5 / 4 of 5 | 5 / 3 of 5 (the other two 17-21 px/s at 10 s; before, 42) |
| dry dough: `doughslump`, `doughmerge` | 109.3 x 26.6 px (ADR 0019); one piece | 109.3 x 26.6 px; one piece |

- **The pops are rarer and weaker, not gone.** The dough no longer turns over round its pockets: fast dough falls 4-5x with oil and with water, and the bursts by half or more. But a pocket still empties into a void now and then (in one of 3 shot runs at 13.8 s, `fix_oil_leftover_pop.gif`), and the holes read no fewer: that is step 2, unchanged.
- **Variants of step 1 not taken** (`doughfall liquid=oil`, 3 runs; `doughwater,doughlayer` at 0.9 and 1.0):
  - The share over the particle's own 2 x 2 cells (bilinear), 0.25-0.5: 0.9k-4.7k, but a 0.9 dough sank to the floor and stayed there (a lump's own cells read mostly mochi).
  - The 3 x 3 share at 0.4-0.7: 0.2k-0.8k, no bursts, but a 0.9 dough on the floor under water stayed down (351.7 against 238.6). At 0.3-0.55: 0.5k-14.1k, no better than 0.2-0.45.
  - The whole dough under a pool lifted evenly (the gate also on where any cell over it in its column is liquid): 8.6k-22.7k, more pops.
  - The same share gate on the liquid's own push: 1.3k-5.7k, more liquid left inside.
- **CPU** (`@mochi @quick @hydro @liquids`, 69 pass): new `test_mochi_lifted_in_open_water_not_round_a_pocket` (hand-made cells: the share round a lump in water 0.93, gate 1; round a pocket in a dough bed 0.03, gate 0). `test_water_in_a_dough_rises_out` still passes (from y 25.0 to 15.7 against the dough's top at 18.9). Not run: `@bodies-water` and the full suite (owner, 2026-10-17: only the cheap tests a change can break; with no mochi the share is 1 and the gate 1, so every other class takes its old path), the sand checks and the body scenarios (no mochi).

## Owner's call: also stop the pockets emptying (step 2)
- **What it is:** mochi left out of the grid's compression where dough closes the cell in, by the same share gate (`hydro_solve.glsl`: `err = max(own.x + own.z - hydro_mochi[c] * (1 - hydro_mochi_open(ci)) - 1, 0)`; CPU the same line in `_hydro_solve`). Mochi still counts as room, so a dough isn't a bubble to fill.
- **What it does** (with this ADR's change; `option_K_oil_whole.gif` against `fix_oil_whole.gif` and `base_oil_whole.gif`):
  - `doughfall liquid=oil`: fast dough 0.4k-1.3k, **no bursts in 6 runs**, holes 4-78; water 1.7k-2.3k, 1 burst in 3 runs, holes 47-110. Shots: no frame at 10-20 s with a 100+ px hole in 3 runs (biggest 34-62 px); ADR 0020's gap at 30 s 0.5-0.9%, deepest 4-6 px; dough then oil 1.1%; dough then water 21% dark at 20 s.
  - Density 0.9 / 1.0 / 1.1, `doughbed`, `doughwater` (5 of 5 one piece and at rest), `doughslump`, `doughmerge`: all as above.
  - **The cost:** `doughsandwich` calm within 15 s in 3 of 9 runs, end rms under 0.2 px in 2, and 4 of 9 bouncing for good (calm 23-32 s, rms 0.9-2.35 px), against 4 / 3 / 2 of 9 unchanged: ADR 0019's kill criterion fails. Liquid left inside: oil 839-1062 (this build 487-1259).
  - Left out everywhere instead (no gate): no holes (2-77) but the sandwich worse (calm 16.3-22.8 s in 3 runs, rms 0.19-1.22). Only where the share is under 0.08-0.2: holes back to 110-332, and still 1 of 4 sandwiches bouncing.
- To take it, add that line; the sandwich would then need its own fix (the water between the two doughs reads as closed in and is no longer squeezed out).

## Known limits
- **A pocket of liquid in a dough still empties into a void now and then** (step 2, above): the void rises and bursts out of the dough's top, weaker than before (the dough round it no longer turns over). A dough has no pressure of its own to close a void.
- **A dough under a deep pool is lifted only near its top**, as before (ADR 0018 Known limits): dough with dough all round it at 48 px takes no lift, so a wide 0.9 slab on the floor rises by its edges and top first.
- ADR 0020's gap at 30 s reads 0.9-1.7% of columns over 3 px against 0.5-1.4% unchanged the same day (deepest 5-7 px against 3-5), and one of 18 probe runs read 5% of 4 px columns over 3 px (unchanged: up to 3% in 9): within its spread or a little over.
- Still as before: liquid caught in a dough dropped through a pool (490-1260 of 10k stay); the landing's ~3 s splash.

## Owner's call
- **Play:** "+10k oil" then "+10k dough", and "+10k water" then "+10k dough": fewer and weaker pops after the splash, an occasional one left. Also "+10k dough", "+10k water", "+10k dough" (ADR 0019; it settles a little sooner now), and dough blobs dropped into a pool at density 0.9, 1.0 and 1.1 (floats, hangs, sinks). Gifs and shots: `C:\Users\nosed\Pictures\falling-carrots-dough-pops\` (`base_*` before, `fix_*` this change, `option_K_*` with step 2 as well).
- **Step 2** (above): say so if the remaining pops matter more than the sandwich settling.
- **Keep or revert:** `git revert` this ADR's code commit brings back ADR 0018/0019's push on all wet dough.

## Considered and rejected
- **No grid push on dough** (ADR 0017's dough, the switch-off that found step 1): no pops from turning over, but a dough sinks whatever its density.
- **The whole dough under a pool lifted evenly; the share over the particle's own cells; a 0.4-0.7 window; the share gate on the liquid's push too:** above.
- **ADR 0020's pull beside mochi off:** still pops, and its band of air back.
- **The expel trade off:** more motion, and the liquid stays inside.
- **A slower landing:** the same catch.
- **Mochi out of the compression, everywhere or gated:** the owner's call above; it fails ADR 0019's check as it stands.
