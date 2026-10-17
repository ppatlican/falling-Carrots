# 0013: A soft body on sand stays on top

Date: 2026-10-17. Status: proposed; built and verified the same day (Results), on main; the owner is to play it. Fixes the STATUS known issue "Jelly on sand at low stiffness jitters and sinks into the pile" (deferred by the owner on 2026-10-15; ADR 0009 Known limits).

## Context
Owner, 2026-10-15, after ADR 0009: "below certain stiffnesses it still starts worming and digging thru sand". Where it starts, measured first (GPU `body_probe sandjelly frames=3600 set=jelly.stiffness=S`, main, RTX 3080 Ti, `--disable-vsync`, one run each; the strip is a 180 x 10 stroke dropped from y 60, landing at ~300 px/s):

| S | 0.2 | 0.3 | 0.4 | 0.5 | 0.6 | 0.7 | 0.8 | 0.9 | 0.95 |
|---|---|---|---|---|---|---|---|---|---|
| members under the sand's top | 528 | 291 | ~447 | ~466 | 596 | 500 | 391 | 236 | 108 |
| grains inside its outline | 691 | 560 | ~548 | ~473 | 471 | 392 | 294 | 233 | 191 |
| fastest member, last 60 frames (px/s) | 0.3 | 0.3 | ~1 | ~0 | 14.5 | 14.0 | 5.3 | 0.0 | 15.8 |

- **Digging starts below ~0.9** and grows as the stiffness drops; 0.9 and 0.95 sit mostly on top. A few members kept moving at 5-16 px/s at 0.6, 0.7, 0.8 and 0.95 (one run each).
- **It happens at the landing, not afterwards.** Every run is still from frame ~500 to 3600: the strip doesn't keep worming on the probe. `main.tscn` (+10k sand, then the strip at 0.2) shows it: in the frame it lands the strip pancakes, its bottom members are punched down between the grains, grains come up between them, and the strip re-expands with sand through its lower rows. At 0.95 it stops as one piece. Painted onto the pile instead (`sandstroke depth=0`, `sandbits`), it rests at every stiffness.
- On the CPU (`test_soft_jelly_rests_on_sand`, a 12 x 4 jelly set on a bed) the jelly at 0.2 also kept sinking slowly: its centroid went down 3.3 px between frames 60 and 300 (0.95: 2.2, the bed packing), ending 5.30 px below the bed's top (0.95: 1.61).

### Why
1. **Same-body pairs within the region radius don't collide** (ADR 0005 item 1): their regions hold them. At 0.2 a region pulls a member back by k = 0.03 per iteration, so in a 300 px/s landing (1.25 spacings per substep) the upper rows fell straight through the bottom row that the sand had stopped, and the strip arrived as loose members, each hitting the pile like a grain.
2. **A grain fits into a gap of a stretched bottom row.** A grain and a member touch at one spacing, so once two bottom-row members are 2 spacings apart a grain sits between them untouched, and ADR 0009 stopped the push-out acting there.

### What was tried (one change at a time; GPU `sandjelly` at 0.2 and 0.95 and `main.tscn` shots unless noted)
- **FastLSM weighting** (each member's share in a region fit is 1 over the number of regions holding it, `docs/papers.md`; CPU): the region goals then keep the body's momentum (a tilted jelly at 0.2 crept 0.14 px/s instead of 0.20), but on sand nothing changed (set on a bed: lowest member 6.62 px below the top, was 5.30; dropped: 10.30, was 9.67). Not kept; the creep stays open.
- **What grains do to a soft member shared over its region** (ADR 0008 item 1 carried to grains; push, push and friction, with and without FastLSM; CPU and GPU): members jittered at 41-52 px/s (CPU) and 25 px/s (GPU, 0.3-0.8% of the jelly's pixels changing between frames 2 apart), as ADR 0009 found.
- **Grain-member contacts shared by `STACK_K`** (CPU): 49 px/s. A grain beside the bottom row and below the jelly's centroid counts as heavier and wedges the member down into the bed.
- **A distance floor between members of a region** (0.8 spacing, no other change): 78 members under, 439 grains inside, still a ragged bottom.
- **A wider grain-member contact alone** (1.25 spacings): 8 under, 494 grains inside; the strip lands thinned with sand in it.
- **Both, with the floor at 0.8**: the cleanest on sand (1 member under, 315 grains, the jelly's pixels still), but it holds a soft jelly taller at rest, and two 16 x 10 jellies at 0.5 then leaned 0.159 rad and slid apart (`jellystack`, `jellydrop`, two runs, identical; main stands at 0.004 rad). At 0.9 spacing, a member at 14 px/s at 0.95. At 0.6, the jellies at 0.5 stood but leaned 0.27-0.30 rad.
- **A push only along the pair's rest direction once they come closer along it than a share of their rest distance** (the rule below), each member turning the rest direction by its own region rotation: at 0.5 of the rest distance 35 under, 486 grains, a ragged bottom; at 0.7 as clean as the floor at 0.8, but at 0.2 the members where two soft bodies touch flickered at 22-40 px/s (`jellystack`, `stack3`, `stack5`, two runs), the two ends of a pair pushing along different directions. With the mean of the two rotations, still 30-33 px/s at 0.2 with half the shortfall each; with a quarter each, at rest (Decision).

## Decision
For a soft body (stiffness < 1), in `contact_delta` (`powder.glslinc`; CPU `ParticleStep._contact_delta`):
1. **A grain and a member of a soft body touch at `SOFT_GRAIN_REACH` = 1.25 spacings** (a spacing for every other pair; 0.6 for a grain and a liquid). A gap in a stretched bottom row has to open to 2.5 spacings before a grain fits. The stickiness pull uses the same distance (`touch_distance`, `stick.glslinc`; `ParticleStep._touch_distance`), so a sticky jelly on sticky sand is pulled to where its contact pushes.
2. **Members of one region keep their order** (`keep_order`; `ParticleStep._keep_order`): for a same-body pair within the region radius, n is their rest direction q_t - q_j turned by the normalized sum of their two region rotations, so both ends see the same n and the pair's pushes cancel. When they are closer along n than `SOFT_ORDER` = 0.7 of their rest distance, each is pushed apart along n by `SOFT_ORDER_PUSH` = 0.25 of the shortfall (into the contact sum, so `CONTACT_RELAX` and the half-spacing clamp apply). A soft jelly squashed at rest isn't touched; a landing one's upper rows can't fall through its bottom row.

Rigid bodies, liquids and grains among themselves are unchanged. The shader stamp goes to v23 in every `.glsl` (SPEC 2.7), because Godot doesn't re-import `solve_delta.glsl` or `body_sweep.glsl` when only `powder.glslinc` changes.

## Results (2026-10-17)
GPU (`body_probe`, RTX 3080 Ti, `--disable-vsync`; main is the build before this ADR):

| `sandjelly` (1200 frames) | 0.2 | 0.3 | 0.4 | 0.5 | 0.6 | 0.7 | 0.8 | 0.9 | 0.95 |
|---|---|---|---|---|---|---|---|---|---|
| members under the sand's top (main: Context) | 40 | 5 | 19 | 4 | 15 | 1 | 9 | 13 | 1 |
| grains inside its outline | 361 | 274 | 251 | 246 | 208 | 146 | 160 | 131 | 29 |
| fastest member, last 60 frames (px/s) | 0.2 | 0.1 | 0.1 | 0.1 | 0.1 | 0.0 | 0.1 | 0.0 | 0.0 |

"Grains inside" fits the whole strip as one rigid outline, so it counts sand under a bent strip too; the screenshots are the better judge.
- **What the owner sees** (`main.tscn`, "+10k sand", the stiffness set from the panel, a level jelly stroke at y 60 across the pile; `C:\Users\nosed\Pictures\falling-carrots-jelly-on-sand-2\`, `before_*` main, `after_*` this ADR): at 0.2 the strip lands and stays on top of the pile as one band (18,150 jelly pixels in view; main 14,180 with sand through its lower rows), a few short drips along its bottom edge; 0.02-0.09% of its pixels change between frames 2 apart from frame 900 (main 0.51-0.71%). At 0.95 as main, a little stiller (0.00-0.02%; main 0.24-0.32%).
- **Jelly on the floor, jelly on jelly, dough** (same folder, frame 1200, the toolbar hidden, dough drawn blue to tell it from sand): a jelly at 0.2 on the floor rests a little thicker and no longer flickers (1.25-1.50% of its pixels changing on main, 0-0.38% here); a jelly dropped onto another at 0.5 and at 0.2 rests on it as on main; dough (0.8) dropped on the pile sits on it as a clean band, where on main sand mixed into its lower edge; dough on the floor as main.
- **At the shipped jelly** (0.95: `jelly,droop,wobble,squash,fold,erasejelly,waterjelly,sandstroke,sandbits,sand,sandlow`): all pass and read as on main (`squash` 9% flatter, `droop` 3.62 px, `wobble` 10 swings, `fold` 2.99 px closest, `waterjelly` no water inside, no grain inside a box on sand).
- **Soft verdict** (ADR 0008, `stack3,stack5,boxstack,jellystack,jellydrop frames=1800`, carrot and jelly at S): at 0.5 and 0.8 as main (all standing, under 0.07 px/s; `boxstack` at 0.5 flips a box on main too). At 0.2 `stack3` and `stack5` now stand (main: they tip over) at 0.26 / 1.45 px/s, `jellystack` and `jellydrop` lean 0.22 rad and rest (0.34 px/s; main 0.38 px/s standing, and `jellydrop` 0.35-17.9 px/s over three runs). `boxstack` at 0.2 (a box dropped 330 px onto three soft boxes) varies run to run on both: 40 and 1 members inside at 31 and 17 px/s here, 12 inside at 3.9 px/s on main (one run); ADR 0008 has it falling over at 0.2.
- **Dough** (`set=jelly.plasticity=1`, S 0.2, 0.8, 0.95; `squash,wobble,sandjelly,waterjelly,jellystack,jellydrop,erasejelly,fold`): on sand far fewer members under the top (27 / 13 / 1, main 571 / 454 / 126) and none moving (main 13.7 and 10.9 px/s at 0.8 and 0.95); the rest as main, rest offsets settled (moved under 0.5 px over the last 120 frames).
- **CPU**: `@soft @sand @setup` and `@stick` pass. `test_soft_jelly_rests_on_sand` now sits 3.12 px below the bed's top (main 5.30) but takes until ~480 frames to settle (3.87 px/s at 300; main at rest by 360), so the test runs 540 frames and its depth limit is 2 spacings (main fails it). The full suite and `@rigid @bodies-water @plastic` weren't run (owner, 2026-10-17: skip slow CPU tests where the GPU probe covers the change; nothing here acts on a pair without a soft member).

## Known limits
- **At 0.2 two checks that already failed on main read worse in one run each; repeated, they don't** (2026-10-17, archive § ADR 0013 follow-ups). `droop`: the plank falls through the gap on both builds and its ends end anywhere from 6 to 57 px out in 300 frames (main 0d18f25: 23-33), so one run each can't tell them apart. What happens is a wedge, not a slide: from 0.5 down the plank sags into the gap, the bottom-row member on each pillar's inner corner is crushed (local area 5% of rest by frame 15) and turns inside out, and regional shape matching at k ≈ 0.03 an iteration doesn't pull an inverted patch back (16-19 members stay inside out at 0.2), so the pile keeps fighting itself and tumbles the carrots for 30 s. `keep_order` delays the first inversion (frame 20, main frame 10). Capping its push on pairs that have passed each other calmed one batch of three runs and not the next, so it wasn't kept; pair joints would have no fit to invert (ADR 0014, Owner's call 3). `waterjelly` (dough at 0.2): at most 4-8 water particles in the outline at a sample here and 10-15 on main, none more than a spacing in and 0-3 at the end: water lying in the dented edge of a squished dough, which the rigid-fit outline box counts. `boxstack` at 0.2 falls over on both builds in every run (40 / 22 / 1 / 6 members inside at a sample here, 2 / 3 / 61 / 15 on main): not worse.
- **A soft jelly on sand settles more slowly on the CPU** (above); the GPU strip is at rest by frame ~500 either way.
- **The bottom edge of a 0.2 strip on sand has a few short drips**; sand doesn't run through it, but it isn't as clean as 0.95.
- **A lopsided soft body still creeps sideways, faster than before** (STATUS): on the GPU a tilted 16 x 10 jelly at 0.2 slides 0.15 px/s here, 0.046 on main 0d18f25, since it rests more strained. FastLSM weighting changed nothing on sand and cut the creep only by a third on the CPU (0.20 to 0.14 px/s), but that was measured with friction; on the GPU it cuts it to 0.028 px/s. It wasn't merged because loaded jellies then give more: ADR 0014.

## Considered and rejected
In Context, What was tried. Also: **pair joints** (Phyzios, `docs/phyzios.md`): not needed once the two rules above held; they would replace regional shape matching (ADR 0005), so that would be its own ADR and the owner's call.
