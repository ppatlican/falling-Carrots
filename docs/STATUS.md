# Status

Last updated: 2026-10-09. Current milestone: **1 (Project and tooling): code complete, not yet verified on hardware.**

## Done (Milestone 1)
- Project settings: Mobile renderer, Vulkan on Windows, no OpenGL fallback, 640×360 base viewport letterboxed (`stretch/aspect=keep`), nearest-neighbor filtering. Input actions `draw`, `erase`, `grab`, `pause`, `clear`, `toggle_debug` (F3).
- `config.json` (`particle_cap` 50000, `solver_iterations` 4), loaded and clamped by `core/game_config.gd`.
- `gpu/compute_context.gd`: main-device compute wrapper (see SPEC 2.7).
- Compute smoke test (`main.tscn`): two passes over 50k elements drawn to the screen through `Texture2DRD`, plus an async readback compared against a CPU hash mirror.
- Debug overlay (F3): FPS, frame time, per-pass CPU/GPU µs, particle count against the cap. The hash grid, wind and temperature toggles are wired up but show "n/a".
- Error screen when no RenderingDevice is available or a shader fails to compile.
- `cpu_ref/` stubs and a headless test runner: `tests/run_tests.gd`.

## Verified
| What | Where | Result |
|---|---|---|
| Headless tests (config, input map, renderer settings, shaders compile, hash mirror, placeholder) | WSL → Godot 4.7.1 console, `--headless` | 8 passed, 0 failed |
| Broken shader is caught | headless | test fails with the compiler error |
| Smoke scene runs windowed | PC, via MCP | **Not verified**: the game launched, but the MCP runtime tools failed auth (see known issues) |
| Anything on real hardware | PC / phone | **Not yet** |

Run tests: `Godot_v4.7.1-stable_win64_console.exe --headless --path <project> --script res://tests/run_tests.gd`

## Measured numbers
None yet. Fill in from the overlay after a hardware run:

| Device | GPU (from `[compute] device` log line) | Particles | Frame ms | smoke_fill GPU µs | smoke_draw GPU µs | Readback |
|---|---|---|---|---|---|---|
| PC | | 0 (smoke test: 50k elements) | | | | |
| Phone | | 0 (smoke test: 50k elements) | | | | |

## Hardware checklist (PC and phone)
1. A moving orange wave in a 16:9 letterboxed view. A frozen image means compute isn't running.
2. Overlay shows "smoke readback OK: 50000/50000 values match".
3. GPU µs columns show numbers, not `-`. A `-` means timestamps aren't working.
4. F3 toggles the overlay, and Space pauses the wave.
5. Log has the `[compute] device ...` line, with no leaked-RID warnings on quit.
6. Phone: forcing the Compatibility renderer shows the error screen, not a crash.

## Known issues
- **MCP runtime tools fail** with "registry entry ... has no token path; relaunch the editor". Suspected (unconfirmed) cause: the headless test runs also start the MCP addon's runtime autoload, which overwrites the registry entry. Relaunch the editor. If it recurs, the test runner should keep that autoload from starting.
- **Stale editor state:** the editor that was open during Milestone 1 still holds the old project settings (main scene `node_2d.tscn`) and keeps re-saving `node_2d.tscn`, which is deleted from git. Close and reopen the editor before saving there, and delete the stray `node_2d.tscn`.
- `config.json` is not auto-exported: the Android preset needs `*.json` in its non-resource include filter.
- Overlay pass-timing columns use a proportional font, so alignment is approximate.

## Next: Milestone 2 (GPU liquid + powder + brush)
Particle pool and free-list, spatial hash (count, prefix-sum, scatter), PBF liquid, powder friction, and a brush using `draw`/`erase`. Sand and water should interact. **Measure the particle cap on a phone.** That measurement proves the performance budget, and its numbers go in the table above.
