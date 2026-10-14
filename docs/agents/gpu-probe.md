# GPU probe, timing and screenshots

How to measure the GPU sim: run the probe, read it, time passes, and capture what the owner sees. Arguments and output fields are listed in the header of `tools/gpu_probe.gd`; this file covers how to use them. For how water and sand move in the owner's scenes (fall, dam, surface, pour, sandair, erase, shaft, sink, bowl, mounds, hover), use `tools/water_feel_probe.gd`; for rigid and soft bodies (the `tests/test_bodies.gd` scenarios on the GPU, a box on sand, and timing loads with big and many bodies), use `tools/body_probe.gd`. Their scenarios and outputs are in their headers, and they run the same way.

## Running variants
- One tmp copy per variant (`$CLAUDE_JOB_DIR/tmp/wc/<name>`), each imported once. Up to two probes can run in parallel as separate windows (see Timing passes); a 2400-frame run takes a few minutes.
- Compare variants on **plateaus**: the mean of every sample from frame 1200 on, never a single sample. Run-to-run noise on mean speed is about ±3 px/s. A small script that averages the `SURF` and `f=` lines per log pays for itself after the second variant.
- Use both drop patterns for liquids:
  - Default (blocks in consecutive frames): the STATUS baseline.
  - `gap=30`: blocks 30 frames apart, the pace of the owner clicking "+10k". It leaves more air and motion than the default. The owner's churn reports come from this pattern.
- Pass `every=47` for liquids. The default sample interval of 60 frames can stay in phase with a 1 s bounce, so a body flying to the ceiling and back read as a steady 73 px/s.

## Reading the output
- **`SURF` line** (last material): this is what the owner sees. Mean speed alone missed it: PR #2 measured 9 px/s while the owner saw water shooting up.
  - `tilt`: left quarter minus right quarter of the surface height. A tilt that holds its sign means the water is holding a slope, so something supports it locally like a sand pile. A tilt that swings sign is a slosh.
  - `rough`: surface RMS about its straight-line fit. `spray`: particles more than 6 px above their column's surface.
  - `top_v`: mean speed in the 20 px below the surface. `floor_rho`: density in the bottom 20 px over rest (1.0 = rest; above 1.2 is squeezing).
- **Grid dump** (every 5th sample): high speed (S) with mean vy (V) near 0 is jitter; matching S and V across a region is flow. N≈100 per 20 px cell is water at rest density, and sand packs to ≈130–150. Low N inside water (25–65) is a trapped air bubble.
- **Slosh vs churn:** a tilt swinging at the tank's fundamental period, 2L/√(g·depth) (≈4.7 s for 30k water), is a slosh: physical, and damped by water drag. Churn is motion that never dies down.
- **Energy injection:** start the material at rest (`spawn_y` 279 for 10k) and run 1800+ frames. A plateau means something injects energy.
- **Any new or adjusted parameter** (ADR 0001): run the scenario it affects at both ends of the parameter's safe range, and the sand checks below.
- **Sand checks after any contact, friction or liquid change:** 50k sand at rest (`sand 3000 5 279 top`: drift 0.000, top grains resting on grains below, no wall grains rising), and sand into water (`water,sand 1800 2`: sand at rest on the floor, no water inside the pile). With sleeping, anything that makes grains cling becomes permanent; the `top` list shows whether the highest grains sit on grains below.

## How long runs take, and keeping them short
Measured on the owner's PC (CPU tests 2026-10-14, probes 2026-10-13):
- **CPU tests are the slow part.** The CPU reference is plain GDScript, and each test prints its wall time. Body-in-water tests take 70–320 s each (~500–900 particles × 90–420 frames); dry body scenes 3–60 s; the rest under 2 s. The full suite takes ~19 min in one process, ~13 min as two in parallel (`-- @bodies-water` in one, the other groups in the other; the times here come from two runs side by side, while seven at once made each ~1.5× slower). Run the groups `testing.md` gives for the change, starting with `@quick` (~1.5 min). How to keep a new test short is at the end of `testing.md`.
- **A probe scenario is short; batches and repeats add up.** `body_probe sandcorks` (2400 frames, 30k particles, read back every 10 frames) takes 33 s at vsync, 22 s with `--disable-vsync` and the same result: the sim steps one frame per drawn frame, so vsync's 165 fps cap is the limit, not the readback (reading back every 60 frames instead: 32 s). Pass `--disable-vsync` (before `--path`) for behaviour runs too; the step is a fixed 1/60 s, so results don't change. Startup and the first `--import` of a copy add ~10–60 s.
- **Fewer runs, not faster runs, save the most.** A noisy result (several bodies, sand piles) needs 2–4 runs to judge, but run the scenarios a change can't affect once, or not at all. Chain a whole batch in one call (`body_probe a,b,c`): one startup.

## Timing passes
- The probe prints `TIME <pass> gpu_us=` averages from frame 600 on. The overlay's numbers are 1 s averages.
- The GPU downclocks at vsync'd 165 fps, so per-pass times swing 2–3× between runs (predict read 8 µs in one run and 24 µs in another), and frame totals drift toward the same ~2 ms whatever the work. Time with `--disable-vsync` (before `--path`): the GPU runs at full clock and passes the change didn't touch read the same between variants. Pass `from=1800` with 3000 frames to time the settled state. Time variants solo, back to back in one command, and compare the per-frame totals (the probe prints `TIME total`). Any other Godot window running at the same time invalidates the numbers.
- Behaviour runs: at most 2 windows at once. Six in parallel maxed out the owner's CPU, took ~5× longer each, and windows stopped resolving GPU work partway (`Tried capturing more timestamps than the configured maximum`, samples stopping at ~39 s).

## Screenshots and clips
The probe draws nothing visible. To see what the owner sees, run `main.tscn` from a throwaway `SceneTree` script in the tmp copy:
- In `_initialize`: `main = load("res://main.tscn").instantiate(); root.add_child(main)`.
- In `_process`: wait for `main._running`. Set `main._pending_fill = main._table.id_of("water")` every 30th frame to press "+10k" like the owner. At chosen frames, save `root.get_texture().get_image().save_png(<windows path>)`.
- To quit: set `main._running = false`, then `main._sim.shutdown()`, then `quit()`. Otherwise `main.gd` runs one more frame on a freed sim and logs a script error.
- `ffmpeg -framerate 30 -pattern_type glob -i 'clip/c*.png'` turns frames into an mp4 or gif. To put a number on visible churn, measure the share of water pixels that change between frames 2 apart (PIL `ImageChops.difference`, pixels over 40). PR #2 measured 13.7%; the density projection grid 0.1%.
- The owner's before and after images and clips are in `C:\Users\nosed\Pictures\falling-carrots-water50k\`.
