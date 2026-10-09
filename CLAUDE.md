## Agent skills

### Issue tracker

GitHub Issues in this repo, via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default labels: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.

## Project docs

- `CONTEXT.md`: the glossary. Use its terms (grain, pile, block fill, churn, pudding, sleeping, CPU reference, GPU probe).
- `docs/SPEC.md`: what we're building and the rules the code must keep, including the GPU plumbing rules in 2.7. Read 2.7 before touching a shader.
- `docs/STATUS.md`: what works, what's verified, open bugs with everything already tried, and what's next. Read Known issues before tuning the solver.

## Working on the sim

### Verifying a change on the GPU
- A solver change is fixed only once the GPU probe shows it (`tools/gpu_probe.gd`; usage in its header). Fixes that passed the CPU reference have done nothing on the GPU before.
- Run Godot from a copy of the repo under the job tmp or scratchpad. Running in the repo rewrites `project.godot` and `.godot/`, and a headless `--import` drops lines from `project.godot`. A fresh copy needs one `--headless --import` before the probe.
- The GPU probe needs a real window: the Windows console exe without `--headless`, `/mnt/c/Users/nosed/Desktop/Godot_v4.7.1-stable_win64.exe/Godot_v4.7.1-stable_win64_console.exe --path '<windows path>' --script res://tools/gpu_probe.gd -- <args>`. A WSL path works as `\\wsl.localhost\kali-linux\home\...`.
- In a worktree session, a guard rejects shell commands it can't parse: a variable as the command (`$G`), `for` loops, `bash script.sh`, `timeout`, and any text containing `.git` (such as `tar --exclude=.git`). Write each Godot call as one literal command, and copy the repo with `cp -r` over an explicit list of top-level entries.

### Reading the GPU probe
- In the grid, high speed (S) with mean vy (V) near 0 is jitter; matching S and V across a region is flow. N≈100 per cell is water at rest density; sand packs to ≈130–150.
- To tell energy being pumped in from slow dissipation, start the material at rest (`spawn_y` 279 for 10k) and run 1800+ frames. A plateau means something injects energy.
- Default mode drops all blocks at y=8 in consecutive frames (overlapping). The baseline numbers in STATUS were taken this way, so keep it for before/after comparisons.
- With sleeping, anything that makes grains cling (walls, friction) becomes permanent. After changing contact or friction rules, run with `top` and check that the highest grains sit on grains below them.

### GDScript pitfalls seen here
- `var x := untyped_call()` fails to parse when the value has no static type. Write `var x: float = ...`.
- Overriding `_process` on a `SceneTree` script must match the parent signature, `-> bool`.
- In a probe, call `sim.shutdown()` before `quit()`, or Godot reports leaked RIDs.
