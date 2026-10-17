# 0020: Air beside a dough: the grid pulls it full, as in open water

Date: 2026-10-17. Status: **proposed, owner to play.** Owner, 2026-10-17, with a screenshot of "+10k oil" then "+10k dough": the oil sits over the dough with a dark band of air between them, widest at the left edge but along the background too, ~10-20 px in places, not the 1-3 px line of ADR 0018. Amends ADR 0003's rule that a cell a body partly fills is never pulled full, for mochi only, and ADR 0018's Known limits ("the gap is drawn over, not closed").

## Context
- **Measured before** (main at 5549919, the same day). `main.tscn` shots with the toolbar, panel and overlay hidden, so the screen edges count; per world-pixel column, the run of dark pixels right over the dough's top with liquid over it (`gap.py` in the shots folder):
  - "+10k oil", then "+10k dough" 4 s later, at 30 s (3 runs): a dark pixel over the dough in 27-31% of columns, 2.7-8.4% with 3 px or more, the deepest 12-21 px, in pockets at the side walls and over dips of the dough's top. At 10 s: 31-45%, up to 30 px.
  - "+10k dough", then "+10k oil" (1 run), 30 s: 29%, 7.8% with 3+ px, 15 px deep; 57% of the left 40 columns and 62% of the right ones are dark: a wedge of air in each wall corner over the dough, as the owner saw.
  - Water does the same: "+10k water" then "+10k dough" (2 runs), 30 s: 22-25%, 1.9-3.3%, a 24 px pocket at the left wall in one run. "+10k dough" then "+10k water" (ADR 0018's case), 10 s: 34-36%, 7.5-13.3%; 20 s: 23-25%. Oil is somewhat worse, not different.
  - `body_probe doughfall liquid=oil` (new): over 3 px in 14% and 0% of 4 px columns at 30 s (2 runs, chaotic); `doughbed liquid=oil`: 37% at 10 s, 2-3% from 20 s.
- **Why:** the density projection grid pulls a cell with room left full only under a full cell, and never where body volume reaches `HYDRO_BODY_CELL` (0.05): water keeps a contact gap from a body, so such a cell reads short of full with no air in it, and pulled, a pinned cork's cells flipped between p 0 and squeezed (ADR 0003, body_probe sandcorks). Mochi counts as body volume in the grid (ADR 0017), so no cell next to a dough was ever pulled. The air a dough leaves sinking through a pool, and the thin air over the dips of its top, stayed, and the grid's hydrostatic push held the liquid over it up like a lid, as over sand (STATUS, dark strip).
  - Found by turning the rule off on the GPU: with every cell pullable, oil then dough closed to 0.9-2.2% with 3+ px at 20-30 s (2 runs) and dough then oil to 0% over 3 px from 10 s on in the probe.
  - Since ADR 0018 liquid lies on a dough at its own packing, with no contact gap, so ADR 0003's reason doesn't hold for mochi.
- **Checked and ruled out** (the handoff's ideas): no term assumes the liquid's density is 1. The grid's floor and body walls give one head of water's flux under faces weighted 1 / rho, which is the head of any liquid; the PBF constraint is a volume constraint; the mochi-liquid pair push is a position push, the same for oil and water. The gap shows with the dough laid first, not only when it falls through, and at both walls, so it isn't the screen edges.

## Decision
- **A cell that is a body's only through its mochi is pulled full like any cell** (`hydro_solve.glsl`, `ParticleStep._hydro_solve`): the `HYDRO_BODY_CELL` test counts body volume minus mochi volume. Bodies keep ADR 0003's rule.
- The grid keeps each cell's mochi volume: `hydro_splat` adds mochi particles to a sixth channel of `hydro_acc` (`HYDRO_MOCHI_CHANNEL`, 24 bytes a cell), `hydro_phi` writes it to a new buffer `hydro_mochi` (binding 32, a float a cell), `hydro_solve` reads it. CPU: `_hydro_mochi`, filled by `_hydro_density`, passed to `_hydro_solve`. No `Params` field; `common.glslinc` unchanged.
- A dry dough never reaches it: with no liquid its cells are air, and air rows return before the pull.

## Results (2026-10-17)
GPU, RTX 3080 Ti, `--disable-vsync`, shipped rows. "Before" is main at 5549919, the same day.

| check | before | after |
|---|---|---|
| shots, "+10k oil" then "+10k dough", 30 s: columns dark over the dough / with 3+ px / deepest | 27-31% / 2.7-8.4% / 12-21 px (3 runs) | 19-21% / 0.5-0.9% / 4-7 px (3 runs) |
| the same, 20 s | 23-28% / 2.7-4.4% / 6-20 px | 18-23% / 0.8-1.4% / 3-7 px |
| shots, "+10k dough" then "+10k oil", 30 s | 29% / 7.8% / 15 px; wall corners 57-62% dark | 21% / 0.6% / 3 px; 20-30% |
| shots, "+10k water" then "+10k dough", 30 s | 22-25% / 1.9-3.3% / 13-24 px (2 runs) | 22% / 0.6% / 8 px (1 run) |
| shots, "+10k dough" then "+10k water" (ADR 0018's check), 10 s / 20 s, dark columns | 34-36% / 23-25% | 22-23% / 20-22% (2 runs) |
| `doughbed liquid=oil`, columns with a gap over 3 px at 10 s / 30 s | 37% / 3% | 0% / 0% (2 runs) |
| `doughfall liquid=oil`, gap at 30 s (median / p90 / max) | 1.65 / 4.50 / 13.3 px; 1.48 / 2.09 / 2.27 | 1.51 / 2.12 / 2.70; 1.54 / 2.11 / 3.13 |
| `doughbed` (water) inside, gap median / p90, rest (99%) | 5, 5; 1.54-1.56 / 2.07-2.12 px; 0.08-0.25 px/s | 11, 20; 1.56-1.60 / 2.07-2.12 px; 0.55-0.58 px/s, plus 1-2 loose specks |
| `doughsandwich` (ADR 0019), calm after the second dough | 7.8-14.3 s, mean 10.8 (5 runs) | 9.8-18.3 s, mean 13.7 (5 runs) |
| its second dough over the last 600 frames: rms displacement per sample | 0.05-0.10 px | 0.18-0.22 px (ADR 0019's PASS needs < 0.2: 2 of 5 pass) |
| its water inside at 40 s / spray, mean | 431-1158 / 27-30 | 278-592 / 16-20 |
| its shots: pixels changing between frames 2 apart, 8.7-18.7 s / 22-32 s after the fill | 5.8-10.6% / 2.2-3.5% (2 runs) | 6.0-13.1% / 2.9-4.2% |
| its shots at 39 s: columns with 3+ px / deepest | 3.0-17.0% / 17-19 px | 1.6-3.1% / 6-10 px |
| `doughlayer`, `doughwater` | (ADR 0019) | 0 inside, one piece, at rest |
| `waterfloat`, `waterbig`, `watersink` | | pass: drafts 0.51, 0.50, the gap under waterbig 2.4 px |
| cost, `doughbed` solo back to back: hydro pass / frame | 158, 162 / 978, 1008 µs | 172, 165 / 1036, 969 µs |

- **What's left in the shots** is single dark pixels at the density of the speckle inside open water (the 2x2 point floor, ~20-24% of columns, as ADR 0018 found for sand).
- **Liquid caught inside a dough dropped through a pool is unchanged** (oil 751-998, before 745-1010 of 10k): that is the drop itself, not this.
- **CPU** (`@setup @hydro @liquids @mochi`, 45 pass): new `test_room_beside_mochi_is_pulled_beside_a_body_not` (hand-made cells: room under full water beside mochi is pulled, p falls more than a quarter head under the open water's; beside a body it reads the open water's). Not run: `@bodies-water` and the full suite (owner, 2026-10-17: only the cheap tests a change can break; with no mochi the mochi volume is 0 and every cell takes its old path), the sand checks (no mochi), dry dough scenarios (never reached).

## Known limits
- **"+10k dough", "+10k water", "+10k dough" settles a little later** (mean 13.7 s against 10.8) and the second dough's end jitter is 2-3x larger (0.18-0.22 px per 10 frames against 0.05-0.10; ADR 0019's dry jitter is 0.28 px a frame), so ADR 0019's check fails in 3 of 5 runs. The water lying on the dough's top is now pulled onto it, the gap ADR 0018 drew over. The shots move within the unchanged build's spread. In return the dough keeps half the water it did and throws less spray.
- **"+10k dough" then "+10k water" keeps 11-20 water inside** against 5 the same day (ADR 0018: 5-13), and one or two dough particles come loose.
- The owner's screenshot isn't on disk; the scenes were matched by the steps reported.

## Owner's call
- **Play:** "+10k oil" then "+10k dough", and the other way round (no dark band, no wedges at the walls); the same with water. Also "+10k dough", "+10k water", "+10k dough" (ADR 0019): one splash, then calm.
- **Keep or revert:** `git revert` this ADR's code commit brings back the pocket and the band.

## Considered and rejected
- **Pulled only past a slack of 0.08 of a cell** (room at rest beside a dough read up to 0.06 before, and the full pull holds it at ~0): the gap stayed (oil then dough at 30 s: 5.0-7.5% with 3+ px, up to 30 px; water 40 px), and `doughsandwich` was no calmer (calm 8.5-26.2 s, rms 0.05-0.21 and one 2.2 burst, 6 runs). The room under the lid is that 0.06.
- **That slack and at most 0.02 a step:** `doughsandwich` as before (calm 9.0-15.2 s, rms 0.06-0.15), but the gap stayed (2.3-13.4% with 3+ px at 30 s). A weak pull can't bring a lid down that the grid's pressure holds up.
- **Pulling beside bodies too** (the test that found it): ADR 0003's cork in a corner under sand.
- **A wider `GAP_MAX` in `render_gap.glsl`:** hides it, the air stays.
