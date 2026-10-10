# GPU probe, timing and screenshots

How to measure the GPU sim: run the probe, read it, time passes, and capture what the owner sees. Arguments and output fields are listed in the header of `tools/gpu_probe.gd`; this file covers how to use them.

## Running variants
- One tmp copy per variant (`$CLAUDE_JOB_DIR/tmp/wc/<name>`), each imported once. Several probes run fine in parallel as separate windows; a 2400-frame run takes a few minutes.
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
- **Sand checks after any contact, friction or liquid change:** 50k sand at rest (`sand 3000 5 279 top`: drift 0.000, top grains resting on grains below, no wall grains rising), and sand into water (`water,sand 1800 2`: sand at rest on the floor, no water inside the pile). With sleeping, anything that makes grains cling becomes permanent; the `top` list shows whether the highest grains sit on grains below.

## Timing passes
- The probe prints `TIME <pass> gpu_us=` averages from frame 600 on. The overlay's numbers are 1 s averages.
- The GPU downclocks at vsync'd 165 fps, so per-pass times swing 2–3× between runs (predict read 8 µs in one run and 24 µs in another). Time variants solo, back to back in one command, and compare the per-frame totals. Any other Godot window running at the same time invalidates the numbers.

## Screenshots and clips
The probe draws nothing visible. To see what the owner sees, run `main.tscn` from a throwaway `SceneTree` script in the tmp copy:
- In `_initialize`: `main = load("res://main.tscn").instantiate(); root.add_child(main)`.
- In `_process`: wait for `main._running`. Set `main._pending_fill = main._table.id_of("water")` every 30th frame to press "+10k" like the owner. At chosen frames, save `root.get_texture().get_image().save_png(<windows path>)`.
- To quit: set `main._running = false`, then `main._sim.shutdown()`, then `quit()`. Otherwise `main.gd` runs one more frame on a freed sim and logs a script error.
- `ffmpeg -framerate 30 -pattern_type glob -i 'clip/c*.png'` turns frames into an mp4 or gif. To put a number on visible churn, measure the share of water pixels that change between frames 2 apart (PIL `ImageChops.difference`, pixels over 40). PR #2 measured 13.7%; the density projection grid 0.1%.
- The owner's before and after images and clips are in `C:\Users\nosed\Pictures\falling-carrots-water50k\`.
