# 0018: Mochi in liquid: water lies on a dough, stays out of it, and a dough floats by its density

Date: 2026-10-17. Status: **proposed, owner to play.** Owner, 2026-10-17, with a screenshot of "+10k dough" then "+10k water": "water seems to float on top of dough, along with water leaking inside it ... how does phyzios fix that and how may we implement it in the same way in our gpu?" Then: "floats on top" means the dark gap where the water hovers over the dough. A dough at 1.1 lying under water is fine. Layering by density is nice to have. Amends ADR 0017 Decision 4's liquid part and its Known limits ("in water it sinks whatever its density ... takes ~10% water into its cracks").

## Context
- **What ADR 0017 did with a liquid:** a mochi particle met water as a grain does (the powder contact at a full spacing, shared by density). In the water's PBF density and in the density projection grid it counted as a body particle (displacing share 1; body volume and weight channels). Its mochi density counted only its own material. It got no pressure push.
- **Measured before** (`body_probe doughbed`, the owner's case: "+10k dough" at frame 1, "+10k water" at frame 240, 1800 frames; `main.tscn` shots of the same):
  - Water inside the dough: 269-305 particles in six runs, all of it caught when the water lands (frames 290-360), and none of it ever leaves. In a 30 x 10 dough with two "+10k water" poured on it (`doughlayer`): 47.
  - Gap between the dough's top and the water over it: median 1.9-2.2 px, p90 2.9-3.3 px per 4 px column, centre to centre (water lies 2 px off at the rest spacing). In the shots, 59% of pixel columns had a dark pixel right over the dough's top (70% at 10 s), 2.1 px deep on average. The dough under the water never came to rest (99% of particles under 6-7 px/s).
  - A dough of any density sank.
- **Why:** with only its own material in its density, a dough has no reason to push out water caught in it, and nothing in our model expels a particle sitting in a vacancy of the lattice. The dark line is the same as the sand one (STATUS, dark strip): the grid counts the dough as bed and holds the water's bottom layer up over the dips of the dough's top. With no pressure push, a dough has no buoyancy.
- **Phyzios** (write-up § 5; task-b18/SPEC.md § 5.1, § 5.7): Mochi's density counts every neighbour, water included, and its pair rule runs on every pair with a Mochi end, so water in a crack makes the spot dense and is pushed out. Every particle, mochi included, goes through one shared pressure solve, and buoyancy comes from the Light/Dense pair swap: momentum-conserving, only where unlike kinds touch, w · coef · g.

## Decision
1. **A mochi-liquid pair takes the pair rule, push only, instead of the grain contact** (`mochi_wet_push`, `powder.glslinc` adds it to `mochi_sum` at both ends, after the clamp). For both ends it uses the mochi end's own density plus its **wet density** (mochi_w over its liquid neighbours, kept by `mochi_density`): f = 2 (ρ_m + wet_m − ρ*) KE + w KS, times the reach, at most `MOCHI_WET_MAX_PAIR` (0.5 spacing) an end per iteration.
   - A dough's top under water reads as full as its inside, so the water on it is pushed by nothing at the rest spacing and lies at its own packing. Water pressed into a dough reads dense and is pushed out as the dough closes on it.
   - Push only: with a pull, water would stick to a dough and be held in its cracks. The mochi-mochi rule keeps its own-material density, so a dry dough is exactly as before, and a wet one keeps its own surface (counting water in that density too, a dough under water lost its cohesion: `doughwater` split in two, 183 water stayed inside the bed).
2. **Water closed in by mochi trades momentum with it along gravity, the water up** (`mochi_expel`, velocity_xsph). A liquid particle's enclosure is the mochi share of its mochi-and-liquid poly6 weight, summed in `liquid_lambda`. From 0.5 to 0.9 it is a smoothstep (`MOCHI_ENCLOSED_LO`, `_HI`): water lying on a dough reads under 0.5, one particle in a crack about 1. Each pair trades `MOCHI_EXPEL` (60) × mochi_w × enclosure × g × dt of speed, each end its mass share (`liquid_pair_share`), so the pair's momentum is kept.
   - This is Phyzios' Light/Dense swap, gated on enclosure. On every pair with the heavier end above (Phyzios' trigger), it did nothing at 10 or 50 (61-68 water left inside). It also pumps water up into the bottom of a dough sinking through a pool.
   - Always up: in a dough lighter than water, water pushed down went into the dough under it (a 0.9 dough split, 28 px/s).
3. **A mochi particle where the grid holds liquid takes the grid's pressure push over its density, as a liquid does** (solve_pressure; ADR 0010's mass weighting). A dough floats, hangs or sinks by its density. The push is gated on the grid's liquid fill at the particle (`MOCHI_WET_FILL` 0.05, a smoothstep), because inside a dry bed the grid continues the pressure hydrostatically with no water in it, and that push would hold a dry dough up. A proportional gate (fill / HYDRO_AIR) gave the parts of a 0.9 lump different lifts: it stretched to 54 px tall and tore.
   - A mochi particle still counts as a body particle in the water's density and the grid (ADR 0017), so water doesn't fill a dough.
   - **Amended by ADR 0019 (2026-10-17):** the push is at most 1.25 gravities over the particle's density a step. Clamped only like a liquid's (half a spacing, ~36 g), the push that removes the water's compression held a "+10k dough" dropped on "+10k water" up on its wet bottom rows like a lid: it bounced and burst open for ~20 s.
4. **The dark-line drawing covers dough as it covers sand** (`render_gap.glsl`): background pixels between a liquid particle and the mochi particle right under it (gap up to 4 px) are painted in the liquid's colour. The pass also runs where the grid's body fill reaches 0.02. Drawing only.
5. **Where the values live:** a mochi particle's wet density is in `rest_offset.x` of its slot. A liquid particle's enclosure sums are in `rest_offset.xy`, stamped with the frame in `.z` and written only when it has a mochi neighbour. Written for every liquid in every iteration, that store took 50k water's solve from 538 to 565 µs. Only body members use `rest_offset` otherwise, and neither class is ever one. No new buffer, binding or `Params` field. `common.glslinc` is unchanged, so no stamp bump. Constants: `SimParams.MOCHI_WET_MAX_PAIR`, `MOCHI_ENCLOSED_LO`, `_HI`, `MOCHI_EXPEL`, `MOCHI_WET_FILL`. The CPU mirror is `ParticleStep.mochi_wet_push_size`, `_mochi_wet_push`, `mochi_enclosed` and `_mochi_expel`, plus the mochi branches of `_lambda`, `_mochi_density`, `_contact_delta` and the grid push.

## What was borrowed from Phyzios, and what wasn't
- **Borrowed:** the pair rule on mochi-liquid pairs, with the liquid counted in the mochi's density for that pair; a momentum-conserving trade along gravity where unlike kinds touch (Light/Dense); one pressure acting on the dough as on the liquid, so buoyancy goes by density.
- **Not borrowed:**
  - The liquid in the mochi-mochi density: a wet dough fell apart.
  - The pull on liquid pairs: water would stick and be held in cracks.
  - Light/Dense on every unlike pair: it did nothing here, so it is gated on enclosure and always lifts the liquid.
  - Its coefficient (10) and Gauss-Seidel order.
  - Mochi in the PBF density solve: its `lambda` slot holds the mochi density, so that needs a second lambda per particle, and the grid push gives the buoyancy.
- No code or file from the game.

## Results (2026-10-17)
GPU, RTX 3080 Ti, `--disable-vsync`, the shipped dough row (1.1) unless set. "Before" is the branch before this ADR, the same day.

| check | before | after |
|---|---|---|
| `doughbed` water inside the dough (owner's case, of 10k) | 269-305 (6 runs) | 5-13 (8 runs) |
| `doughbed` gap, dough top to water over it (median / p90) | 1.9-2.2 / 2.9-3.3 px | 1.46-1.64 / 2.05-2.12 px |
| `doughbed` dough at rest (99% of particles) | under 6-7 px/s | under 0.07-0.72 px/s |
| `doughlayer` (30 x 10 dough on the floor, 20k water poured on it) water inside | 47 | 1-4 |
| `doughwater` (16 x 10 dropped into the pool) water inside | 9 | 0-1 |
| `main.tscn` shots, columns with a dark pixel over the dough's top, 20 s (10 s) | 59% (70%), 2.1 px deep | 44% with the sim alone; 24% (31%), 0.6 px with the drawing too (sand's floor was 24-27%) |
| shots, blue pixels 6+ px under the dough's top | 1948 | 0-160 (2 runs) |
| density 0.9 | sinks (ADR 0017) | dropped: floats at the surface (lowest dough 15 px under it); on the floor under poured water: rises to the surface (centre 239 against a surface at 235), in 3-4 pieces |
| density 1.0 | sinks | dropped: sinks slowly and hangs (20 px over the floor at 10 s); on the floor: stays there |
| density 1.1 | sinks | sinks to the floor and rests |
| cost, `doughbed` frame (10k dough + 10k water), solo, alternating | 1042, 1062 µs | 1084, 1103 µs (+~40: velocity +20-30 for the trade, render +10 for the gap pass) |

- **Slider ends** in water (`doughwater,doughlayer,doughbed`):
  - Density 10: all pass, at rest.
  - Density 0.1: dropped, it floats (bobbing at ~10 px/s). On the floor, it rises and floats in 3 pieces. A 10k bed of it under 10k water turns over (the dough rises through the water) and is still churning at 30 s: 99% of particles under 58 px/s, a few up to 360. Before the mass share of item 2, this end flew apart at over 1000 px/s.
  - Cohesion 0: it falls apart as it does dry (7 pieces), with 16 water among the pieces.
  - Friction 0 with drag 5 and viscosity 1: it sinks slowly (drag 5), and nothing launches.
- **Dry dough unchanged:** every changed line is reached only with a liquid within reach. `doughslump`, `doughmerge`, `doughcut`, `doughdrip`, `doughcarrot`, `doughsticks`, `doughwrap`, `doughsand` and `doughsandlow` all pass, and their values stay within the unchanged build's run-to-run spread. The mochi scenarios aren't deterministic: two unchanged runs read `doughslump` 109.3 x 26.6 and 113.2 x 24.6 px, `doughsand` 3 and 5 pieces, and one unchanged `doughcarrot` FAILed on speed (7.8 px/s).
- **Shipped materials** (`body_probe tests,sand,boxdrop,boxhigh,jellystack,jellydrop,carrotjelly,waterjelly,watersink,waterfloat,squash,wobble,droop,creep,erasejelly` against the unchanged build): 17 of 21 lines are identical (every dry body scenario). `sand`, `waterjelly`, `watersink` and `waterfloat` move within run-to-run noise and pass, as in ADR 0017. The sand checks (`gpu_probe sand 3000 5 279 top`, `water,sand 1800 2`): at rest on both (mean 0.00 and 0.03 px/s), no wall grains rising. 50k water's frame: 989 µs unchanged, 972 µs changed, back to back.
- **CPU** (`@setup @quick @mochi @stick @liquids`, 70 pass):
  - New `test_wet_pair_rule`: no push at a flat water face, a push when pressed in, no pull, the clamp, enclosure.
  - New `test_water_in_a_dough_rises_out`: one water particle in a 14 x 6 dough under a pool rises from y 25 to 12, over the dough's top at 18. With `MOCHI_EXPEL` 0 it stays at 25 and the test fails.
  - Not run: `@hydro @bodies-water @sand @rigid @soft @erase @plastic` and the full suite (owner, 2026-10-17: only the cheap tests a change can break). The CPU changes are mochi branches, or sums `_lambda` keeps beside its own, so every other class takes its old path. The GPU checks above cover the shaders.

## Known limits
- **A few water particles still end up inside** a "+10k dough" bed hit by "+10k water" (5-13 of 10k, all caught at the landing). A water particle at a wall inside the dough's edge column can stay.
- **The dough's top under water is rougher** (single particles stand up where the trade pushed the dough down around water rising out).
- **A dough of density 1.0 sinks slowly**, since its top is out of the grid's liquid fill at first. A 0.9 dough rising from the floor breaks into a few pieces at the surface.
- **A very light dough (0.1) under a big pool turns over for a long time** (Results).
- **A dough bed on the floor under water is buoyant only where the grid holds liquid** (its top cells). Its deep part bears its full weight, as a dough sealed to the floor would.
- **The gap is drawn over, not closed.** The sim leaves 1-3 px of air over the dips of the dough's top (44% of columns before the drawing), held by the grid as over sand. **Amended by ADR 0020 (2026-10-17):** the grid now pulls room beside mochi full, as in open water, so the sim closes it (shots at 10 s: 22-23% of columns dark, from 34-36%), and the air a dough leaves sinking through a pool (the owner's oil over dough, pockets up to ~20 px at the walls) with it.
- Not checked: oil and dough (oil is a liquid, so it takes the same rules), dough and sand under water, the eraser in a wet dough, phones.

## Owner's call
- **Play:** "+10k dough", then "+10k water" (no specks, no dark line). Drop dough blobs into a pool at density 0.9, 1.0 and 1.1 (floats, hangs, sinks).
- **Keep or revert:** `git revert` this ADR's code commit brings back ADR 0017's dough in water.

## Considered and rejected
- **The liquid in the mochi-mochi density** (Phyzios' density over all neighbours, one sum): a wet dough loses its cohesion. `doughwater` split in two, and 183 water stayed in the bed.
- **A stronger mochi-liquid push** (twice f): 99% of the dough at 3-4.5 px/s at rest, for little less water inside. **A wider clamp** (1 spacing): 44 water inside, against 28-34 at 0.5.
- **No liquid drag on mochi:** 84 water inside (the dough's top didn't move with the landing water).
- **Light/Dense on every pair with the heavier end above** (10, 50): 61-68 water inside; it also pumps water into the bottom of a sinking dough.
- **The trade over each end's own mass:** a 0.1 dough flew apart. **Down for a liquid heavier than the dough:** a 0.9 dough split.
- **Buoyancy proportional to the grid's liquid fill:** a light lump tore. **Ungated:** a dry dough bed would be held up by the grid's pressure.
- **Only the drawing** (as for sand): the water inside and the sinking would stay.
