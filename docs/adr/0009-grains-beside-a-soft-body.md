# 0009: Grains beside a soft body

Date: 2026-10-15. Status: proposed; on main. The owner tried it on 2026-10-15: below some stiffness the jelly still worms and digs through the sand, left for later (Known limits). Fixes the owner's report of 2026-10-14 (STATUS Known issues, "Jelly on sand at low stiffness jitters and sinks into the pile").

## Context
Owner, 2026-10-14: "add 10k sand, then drop a long horizontal strip of jelly on top of it. Some tiny pieces of jelly spaz out, constantly jittering and digging through the sand", with the jelly's stiffness lowered to the panel's minimum, 0.2. Measured on the GPU before this ADR (`body_probe`, RTX 3080 Ti, `--disable-vsync`):
- `sandjelly` (a 180 × 10 stroke dropped on the pile, landing at ~300 px/s) at 0.2: the strip dug down through the pile. At the end 1779 of its 1780 members were under the sand's top beside them, 771 grains were inside its outline, and up to 311 members were over 5 px/s, the fastest at 55 px/s. In `main.tscn` with the owner's steps the strip ends at the floor under the pile, 16 jelly pixels left in view, while 0.5–0.9% of the sand pixels change every 2 frames above it.
- `sandstroke depth=0 span=280` (the same strip painted onto the pile, nothing dropped) at 0.2: a member still at 14–41 px/s at the end, so lying on sand is enough.
- `sandbits` at 0.2: a 2 × 2 piece jittered at 8–9 px/s.
- Not only at the minimum: `sandjelly` at 0.5 kept members moving at 10–12 px/s (2 runs of 2) and at 0.8 at 7.7–13 px/s (2 of 3), though STATUS had them resting. At the shipped 0.95 it rests (3–5 members under the top, 3 runs).

### What the diagnosis found
A CPU repro went red the same way: a 12 × 4 jelly at 0.2 set on a settled 28 × 10 sand bed in a 64 × 80 world, 300 frames, nothing dropped. A bottom member was at 39 px/s over the last 60 frames, and the lowest member ended 9.4 px below the bed's top (at 0.95: 0.04 px/s, 5.8 px). Parts of the contact were then switched off one at a time (`_contact_delta`):

| switched off | fastest member, px/s | lowest member below the top, px |
|---|---|---|
| nothing (0.2) | 39 | 9.4 |
| the region pull, at 0.95's strength | 0.04 | 5.8 (as at 0.95) |
| **the push-out of a grain from the soft body** | **0.76** | **5.3** |
| friction between a soft member and a grain | 17 | 15 |
| the grain's push on the soft member | 16 | 18 |
| the soft member's push on the grain | 54 | 7.9 |
| sleeping | 42 | 18 |
| stop-not-launch | 39 | 9.4 |
| the regions | 58 | 18 |

So the stiffness acts only through the region pull, and of the contact's parts the push-out from inside a body (ADR 0003 items 8 and 11) alone makes the difference. Each push-out of a grain from the soft body over the last 60 frames was then logged:

- **At rest at 0.2:** 808 push-outs, none with the grain in its nearest member's lattice cell (`in_lattice_cell`, the test ADR 0008 item 3 uses between two soft bodies). 445 came from bottom-face members with the grain 0.8 spacing to the side of the member, within the outline's half spacing below its row. The lattice stretches at low stiffness, so grains sit in the widened gaps of the bottom row. The push-out moves such a grain its whole depth and gives the member nothing back, so the member settles into the gap and the next grain is inside the outline: the jelly digs. The other 363 came from corner members' 45-degree ways out, ADR 0008's misfire.
- **At rest at 0.95:** 708, all from corner members with the grain 0.8–1 spacing to the side; at that stiffness they balance and nothing moves.
- **In a landing at 0.95** (dropped 40 px): 152 in 40 frames, 97 of them in the nearest member's cell.

Ruled out before this ADR (GPU, reverted): ADR 0008's other two rules carried over to grains. Sharing what grains do to a soft member over its region gave less sinking but more jitter (77 members up to 29 px/s); the contact shared by `STACK_K` let the strip sink through the pile. Ruled out by the CPU switches: the body's rotation instead of the region's in the push-out (16–28 px/s), skipping corner members only (13 px/s), the push-out capped at half a spacing (52 px/s), and a wider cell for grains (0.75 spacing: 9.7 px/s; at 1 spacing every push-out counts and it reads as main).

## Decision
**A grain is pushed out of a soft body only inside the lattice cell of its nearest member** (`in_lattice_cell`, `SOFT_CELL` 0.55 spacing), as ADR 0008 item 3 does between two soft bodies. A grain driven into the lattice, which the push-out exists for (ADR 0003: one in a lattice square sits 0.7 spacing from four members whose contacts cancel), is in some member's cell and is still pushed out. A grain beside the body, in a stretched gap of its bottom row or under a corner, gets the ordinary contact only. Rigid bodies, water and a soft body's own folds are unchanged.

`powder.glslinc` `contact_delta`; CPU reference `ParticleStep._contact_delta`.

## Results (2026-10-15)
GPU (`body_probe`, RTX 3080 Ti, `--disable-vsync`; the same build's runs differ, so each count is over the runs given):

| | main | this ADR |
|---|---|---|
| `sandjelly` 0.2 | FAIL: fastest 55 px/s, 1779 of 1780 members under the sand's top | PASS ×2: 0.4–1.1 px/s, 351–499 under |
| `sandjelly` 0.5 | FAIL ×2: 10–12 px/s, 4–6 under | PASS: 0.2 px/s, 395 under |
| `sandjelly` 0.8 | FAIL 2 of 3: 7.7–13 px/s, 1–4 under | PASS ×2: 0.1–0.3 px/s, 399–478 under |
| `sandjelly` 0.95 | PASS ×3: 0–3 px/s, 3–5 under | PASS ×2: 0–1.9 px/s, 72–174 under |
| `sandbits` 0.2 / 0.5 / 0.8 / 0.95 | FAIL at 0.2 (a 2 × 2 at 9 px/s) | PASS at all four |
| `sandstroke depth=0 span=280` 0.2 | FAIL ×2: 14–41 px/s | 2 of 3 PASS; one at 7 px/s |
| `sandstroke depth=30 span=280` 0.2 | PASS | PASS ×4 |
| `sandstroke depth=0 span=280` 0.95 | FAIL ×3 (the corner member, Known limits) | FAIL ×3, the same |

- **What the owner sees** (`main.tscn`, "+10k sand", then a level jelly stroke across the pile at y 60, frames 600–1502; `C:\Users\nosed\Pictures\falling-carrots-jelly-on-sand\`, `before_*` main, `after_*` this ADR): at 0.2 the strip now stays on top of the pile and is still, 12,800–13,300 jelly pixels in view with 0.03–0.15% of them changing between frames 2 apart (the sand 0.07–0.11%). It lands thinned, though, with sand mixed into its lower rows, and its left end slides down the slope (Known limits). At 0.95 it looks as on main, the same height on the pile and settled (jelly pixels changing 0.06–0.19% at frames 900–1500; main 1.28%, 0.49%, 0.05%), with a slightly ragged bottom edge where sand shows between bottom-row members. That edge is the extra "members under the sand's top" in the table, which counts any member below the sand beside it.
- **Unchanged, as expected** (no grain beside a soft body there): `sand`, `sandlow`, the sand checks (`gpu_probe sand 3000 5 279 top`: drift 0.000, fastest grain 0.29 px/s; `water,sand 1800 2`: sand at rest), `water_feel_probe sandair,erase,shaft,sink`, and ADR 0008's soft verdict (`stack3,stack5,boxstack,jellystack,jellydrop`, `frames=1800`): at 0.95 all pass at 0.007–0.026 px/s, at 0.2 as ADR 0008's 0.2 row.
- **CPU**: `test_soft_jelly_rests_on_sand` (new, the repro above, 57 s): main 39.23 px/s and 9.38 px, this ADR 0.76 px/s and 5.30 px. `@rigid @soft @sand @setup @quick` 61/61, `@bodies-water` 6/6.

## Known limits
- **Below some stiffness a jelly on sand still worms and digs through it** (owner, 2026-10-15: "below certain stiffnesses it still starts worming and digging thru sand - but can do it later"). The threshold wasn't measured; deferred by the owner.
- **A stiff jelly sits a little lower on sand after a fast landing.** Out-of-cell push-outs during a ~300 px/s landing were what kept the shipped jelly's bottom row fully on top (a row-deep share of members under the sand's top: 72–174 against 3–5). Tried and rejected, below: letting the push act while the two close fast (a landing). It held the shipped jelly up (11 under), but made a resting one sparkle.
- **A soft jelly dropped onto sand lands with sand mixed into it.** At 0.2 the ~300 px/s landing opens the bottom rows, and grains that end in the stretched gaps aren't pushed out any more, so the strip rests thinned with sand among its lower rows (`sandjelly` 0.2: 600–700 grains inside its outline; main 771, with the strip at the floor). The speed-gated variant below kept it cleaner (14,600 jelly pixels against 12,800–13,300), but made the shipped jelly sparkle.
- **A member in a floor corner reads a speed it doesn't have** (not from this ADR: the same on main). With the stroke reaching the left wall (`sandstroke span=280`), a member at x 4–7 on the floor holds its place within 0.1 px while its velocity flips sign at 6–14 px/s every sample, so the probe's "still moving" check fails at any stiffness.
- The diagnosis said which push-outs misfire, not why grains sit in the gaps in the first place: a jelly at 0.2 stretches its lattice under its own weight on a bumpy bed (ADR 0005, regions; ADR 0008 Known limits).

## Considered and rejected
- **The push-out outside the cell only while the grain and the member close faster than a landing speed** (15 px/s along the push; also 30 and 100). At 15 px/s the shipped jelly ended with 11 members under the sand's top and 0.2 rested (233 under). But in `main.tscn` the resting 0.95 jelly kept sparkling (1.25–1.88% of its pixels changing between frames 2 apart at 1200 and 1500, main 0.05%): a member that moved toward a grain past the speed got the whole push again, which kicked it. A gate on the body's own speed would avoid that feedback, but the body record has no velocity (a new field, a shader stamp bump). It also left a jelly piece crushed into a floor corner under sand (`sandstroke depth=30` at 0.2) popping at 6–8 px/s in 3 of 10 runs (this ADR: 0 of 4).
- **The out-of-cell push scaled by the jelly's stiffness**: 0.95 as on main, but at 0.2 a fifth of the push still dug the strip through the pile (`sandjelly` 1473 members under the top, 91 px/s), and 0.5 kept moving (12.6 px/s).
- **A wider cell for grains, the body's rotation in the push-out, skipping corner members, a cap on the push**: CPU, Context.
