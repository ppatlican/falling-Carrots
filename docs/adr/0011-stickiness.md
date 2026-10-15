# 0011: Stickiness, cohesion and adhesion (Milestone 3b)

Date: 2026-10-15. Status: proposed. Built on the owner's go-ahead (2026-10-15: "authorised - go ahead" to the next 3b slice); the owner hasn't played it yet.

## Context
ADR 0001 decision 5 and SPEC 2.2: stickiness is two material columns, `cohesion` (pull between touching particles of one material) and `adhesion` (pull toward other materials and walls), both capped forces so a sticky clump still breaks under enough weight. SPEC's examples: thick sticky liquids (honey), damp clumping sand, jelly that holds together, honey on a wall, batter on a carrot. With sleeping, anything that makes grains cling risks permanent mid-air clumps, so powder cohesion must pass `erase` and `shaft` (SPEC 2.2, risks table).

What the code had: contacts (`powder.glslinc`) only push apart, the liquid density constraint only pushes apart (C >= 0), and the material row had three free floats in `Material.more` (ADR 0005).

## Decision
1. **Columns.** `cohesion` and `adhesion`, 0 to 1, on every row (`NUMBER_FIELDS`), with sliders for liquids, powders and bodies (`PANEL_FIELDS`). Packed into `Material.more.y` and `.z` (offsets 68, 72), so the row stays 80 bytes. The shipped materials all have 0.
2. **A pair's coefficient** (`stick_k`): its cohesion when both are one material (two bodies of one material too), else the larger adhesion of the two, so honey sticks to a carrot whatever the carrot's. Members of one body skip each other (their shape holds them).
3. **Applied as speed in the velocity pass**, like a force: `velocity_xsph.glsl` adds `stick_velocity` (`stick.glslinc`) after drag and XSPH; the CPU reference adds `_stick_pull * dt + _stick_damp + _stick_drag` in `step()`. Three parts:
   - **Pull:** STICK_G (4) x gravity x the coefficient x `stick_shape`, split as the pair's contact is (`contact_share`: by STACK_K between grains and with bodies, POWDER_LIQUID_SHARE between a grain and a liquid, else by density). `stick_shape` is 0 while the pair touches, full at STICK_FULL (0.15) spacings past touching, 0 again from STICK_REACH (0.4), short of a lattice diagonal. A wall pulls a particle within STICK_WALL (0.75) spacings of it by its adhesion, full while touching (`stick_hold`). A particle's summed pull is at most STICK_CAP (6) x gravity.
   - **Damping:** a sticky pair touching or within the band that is moving apart loses that speed, up to what its pull could take away in a step, split as the contact. It never presses a pair.
   - **Slip:** a wall's pull never reaches the solver's wall friction (predict clamps a particle to the wall first), so a grain or body particle a wall pulls gets Coulomb friction from it here, against its speed along the wall and the gravity the next step adds. A liquid has no friction: it is dragged toward the velocity of what it sticks to that isn't liquid, and along walls, at STICK_DRAG (30) per second x the coefficient, so it creeps down a wall instead of sliding off.
4. **Free when nothing is sticky.** `Params.sticky` (the push constants' last 4 bytes, now 128, the portable limit) is 1 while any material has cohesion or adhesion (`ParticleSim._sticky_materials`, kept by `update_material`); otherwise `velocity_xsph` skips the loop and the CPU step skips it too (`has_stickiness`). Shader stamp v21.
5. **One neighbour loop on the GPU** for all three parts (three loops cost ~+110 to 140 us a frame at 50k, one ~+60 to 70). The CPU keeps three functions.
6. **Probes:** `water_feel_probe erase` and `shaft` print `floating`, still grains in clumps (flood fill over 2 px cells) touching no wall, floor or ceiling. `stuck` counts any still grain with nothing below, which a sticky overhang has on purpose.

## What was tried, and why it changed
All CPU unless marked; the tests named are in `tests/test_stickiness.gd`.
- **Pull split by mass** (momentum kept), while the pull still acted on touching pairs: a sticky 6 x 6 clump let go in mid-air rose to the ceiling. The pull pressed touching grains together and their contact pushed them apart again mostly upward (STACK_K), so every press-and-push lifted the clump. Split as the contact, it fell (`test_a_sticky_clump_in_mid_air_falls`, then red with the mass split: top grain at y 16.9). With the final pull (nothing while touching) the mass split passes every test but the one checking the split itself; the contact's split stays, as every GPU check ran with it.
- **Pull full while touching** (to raise friction, as damp sand's water bridges do): at one substep a sticky pile squeezed to ~3/4 of its height; at 2 substeps a sticky 10k block dropped in `main.tscn` fell at a quarter of a dry one's speed and set as a lace of sand arched in the air. On the CPU a 30 x 20 block fell 12 px in 30 frames against 46 (`test_a_sticky_block_falls_freely`). Even split as the contact, pressing leaked lift.
- **Pull 0 while touching, no damping:** a row hung under another (the ceiling test) fell ~0.2 px before its pull took hold and was too fast to stop by the end of the band; nothing hung but the row touching the ceiling. The damping catches it (`test_sticky_sand_holds_to_the_ceiling`).
- **Sleeping:** discounting the pull from "held up" (velocity_update's sleep test) looked necessary while the pull pressed touching grains, and its upward part, if discounted, slept a whole hanging block that should have torn. With the final pull (nothing while touching) no test or probe changes either way, so the sleep test is unchanged: `erase` and `shaft` at cohesion 1 end with 0 floating grains.
- **Side walls for bodies:** the slip acts per member and only cancels that member's own slide, so a carrot pulled to a side wall slid (13 px in 30 frames). Left as a known limit; a body sticks to the ceiling and to other things.
- At one substep the lagged pull is half as stiff against the contacts and a damp column slumped; the tests step as the game does (2 substeps).

## Results
CPU (`@stick`, 9 tests, ~13 s): a pair is pulled as its contact pushes it; two rows of sand hang from the ceiling at cohesion and adhesion 1 and fall without; a 16-row block hung there tears and falls; a sticky clump and a sticky 30 x 20 block fall as dry ones; a hex-packed 6 x 14 column stands at cohesion 1 (base 11 px) where dry sand slumps to a 51 px base; water at adhesion 1 creeps down a wall at <0.4 of plain water's fall; a carrot at adhesion 1 hangs from the ceiling. Columns by cohesion (base px, started 11): 0 → 51, 0.25 → 28, 0.5 → 11, 1 → 11; a resting sticky block isn't squeezed (mean y 31.19 against 31.18 dry).

GPU (RTX 3080 Ti, `--disable-vsync`; screenshots in `C:\Users\nosed\Pictures\falling-carrots-stickiness\` and the feel probe's `user://feel_shaft_*`):
- **Mid-air clumps:** `erase 1500` at sand cohesion 1 (and cohesion + adhesion 1): 0 stuck, 0 floating from the end of erasing to 25 s. `shaft 1500`: 0 floating; at cohesion 1 the cut opens (268 empty cells at 9 s) and its 55-row walls cave in at ~12 s (39 empty cells at rest, dry 250): more than the capped pull holds. The brushed damp pile stands taller and steeper than a dry one, with fresh strokes sticking out sideways.
- **Sand checks:** 50k sand at rest at cohesion and adhesion 1: positions still (0.002 px per sample), the top layer stuck to the ceiling. Sand into water at 1 (`water,sand 1800 2`): sand at rest ~8 px higher than dry (mean y 322 against 330; it doesn't spread flat), overall motion as shipped (0.51 against 0.45 px per sample; the water's read speed, 3.8 against 2.5 px/s, includes the queued pull of the sticky sand).
- **A +10k sand block** at cohesion 1 falls as the dry one and lands as a slab with steep, rounded sides (`sand_coh1_*`, `sand_dry_*`).
- **Water** (30k, `gap=30`, plateau from frame 1200): shipped tilt 0.0, rough 0.17, rms 0.29 px; cohesion 0.5: tilt 0.1, rough 0.5, rms 0.07; cohesion and adhesion 1: level (tilt 0.2, rough 1.1) in two runs of three, at rest (rms 0.02-0.04), ~280 particles stuck on the walls above the surface. Honey (water at viscosity, cohesion and adhesion 1): climbs both walls as a meniscus, then levels and is still by 400 frames, where plain water still sloshes (`honey_*`, `water_plain_*`).
- **Bodies** (`body_probe tests,watersink,waterfloat,sand,boxstack`, carrot and cork at cohesion and adhesion 1; `jelly,droop,wobble,squash,fold,waterjelly,erasejelly,jellystack`, jelly at 1): positions, shapes, rotations, stacking and "nothing inside" as shipped; a box spawned into the floor launches slower (25.5 against 30.8 px/s); the cork floats a little deeper (draft 0.57 against 0.53). The FAILs are rest speeds, which read the queued pull (below).
- **Cost** (velocity pass, per frame, 50k at rest, from frame 1800): sand 74 → 135 us at cohesion 1, water 51 → 119 us; nothing while no material is sticky.

## Known limits
- **Stored velocity holds next step's pull.** A grain hung by stickiness, or a member pulled to the floor, reads ~3 to 13 px/s in `vel` while it doesn't move, so the probes' speeds for sticky materials overstate motion; read `rms_disp_per_sample` and positions. Nothing in the game reads it.
- **At adhesion 1, splash sticks to the walls.** One water run of three kept a lump high on a side wall (surface rough 27, tilt 8.4) for good; the pool under it was at rest.
- **A body doesn't stick to a side wall** (each member's slip only holds its own weight). It sticks to the ceiling, to grains and liquids, and to other sticky bodies.
- **Tall damp cuts cave in.** A pull per pair is capped, so a sand wall over ~15-20 rows tears and slumps; a lower one stands. That is the cap working, but the owner may want more strength at cohesion 1 (STICK_G).
- **Honey looks streaky** as 2 x 2 points (aligned gaps), like water but more so; metaball rendering is M5.
- **Breaking is a strength cap, not a stretch limit with memory:** a torn pair re-sticks as soon as it touches again.

## Owner's call
- Play: sand at cohesion 0.5 and 1 (pile, column, the eraser), water as honey (viscosity, cohesion and adhesion up), sand or water with adhesion against the walls.
- Is cohesion 1 strong enough, or should damp sand hold taller walls (STICK_G)?
- Should a body stick to a side wall (needs a per-body slip, not per member)?
