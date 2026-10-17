## Agent skills

### Issue tracker

GitHub Issues in this repo, via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default labels: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.

### Subagents

When a task needs a subagent, delegate it through `/grok-cc:rescue` (the Grok CLI worker) or DeepSeek instead of spawning a Claude subagent. DeepSeek runs through the DeepSeek Harness CLI (`dsh`, installed globally): `echo "<task>" | dsh headless -` from the repo root prints the answer on stdout and its reasoning on stderr. It is a full agent that can edit files: start review or research tasks with "Read-only task: do not edit any files", and run edit tasks in a worktree.

## Project docs

- `CONTEXT.md`: the glossary. Use CONTEXT.md's terms.
- `docs/adr/`: decisions. `0001-oe-cake-direction.md` sets the direction (OE-Cake-style, rigid and soft bodies as cluster solids, per-material parameters the player adjusts) and lists what in the code still works against it.
- `docs/SPEC.md`: what we're building and the rules the code must keep, including the GPU plumbing rules in 2.7. Read 2.7 before touching a shader.
- `docs/STATUS.md`: what works, open bugs with what was already tried, and what's next. Read its Known issues before tuning the solver. Resolved issues, experiment logs, the Verified table and pass times are in `docs/status-archive.md` (grep its headings).
- `docs/papers.md`: reference papers and code, grouped by symptom. Before changing solver, boundary, sand, MPM or fluid-rendering behaviour, read only the matching section; cite what you used.
- `docs/phyzios.md`: how Phyzios (OE-Cake's successor, reverse-engineered by the owner) handles each of our open symptoms, with a pointer to the full write-up. Read the matching row before changing a material rule, the soft bodies, sand, stickiness or drag. Ideas only: no code or files from the game.
- `docs/agents/gpu-probe.md`: read before running or reading the GPU probe, comparing variants, timing passes, or taking screenshots.
- `.workbuddy-ai/memory/` (untracked, main checkout only): notes from another AI tool the owner used, with decisions made there (for example, an MPM rewrite was judged not justified). Read them before solver or architecture decisions. WorkBuddy no longer works on this codebase (owner, 2026-10-14), and its spikes were deleted.

## Finishing a task
- Before saying a task is done, bring the main checkout (`/mnt/c/Users/nosed/documents/falling-carrots`) up to date with the finished work, so the owner can open it in Godot. Commit the work on its branch and push it. Then merge that branch into `main` (fast-forward when possible), push `main`, and check out `main` in the main checkout.
- The main checkout holds uncommitted files from the owner (`.workbuddy-ai/`, `project.godot` edits). Never stash, reset, clean or overwrite them. If the checkout would touch one of them, stop and ask the owner.
- In the final report, give the main checkout's branch and commit.

## Working on the sim

### Liquids
- Depth pressure comes from the density projection grid (`gpu/shaders/sim/hydro.glslinc`); PBF only fixes local spacing. Tune liquids through the `HYDRO_*` constants and water `drag` in `data/materials.json`. `docs/status-archive.md` (Water churn) lists the local fixes the grid replaced (liquid stack scaling, per-particle carried pressure) and why they churned.

### Verifying a change on the GPU
- A solver change is fixed only once the GPU probe shows it (`tools/gpu_probe.gd`; arguments in its header, how to read it in `docs/agents/gpu-probe.md`). Fixes that passed the CPU reference have done nothing on the GPU before.
- A change to what the owner sees is fixed only once screenshots of `main.tscn` show it (recipe in `docs/agents/gpu-probe.md`). The probe's mean speed once read 9 px/s while the owner saw water shooting up.
- Run Godot from a copy of the repo under the job tmp or scratchpad. Running in the repo rewrites `project.godot` and `.godot/`, and a headless `--import` drops lines from `project.godot`. A fresh copy needs one `--headless --import` before the probe. After editing a `.glslinc`, delete `.godot/imported/*.glsl-*` in the copy before importing.
- The GPU probe needs a real window: the Windows console exe without `--headless`, `/mnt/c/Users/nosed/Desktop/Godot_v4.7.1-stable_win64.exe/Godot_v4.7.1-stable_win64_console.exe --path '<windows path>' --script res://tools/gpu_probe.gd -- <args>`. A WSL path works as `\\wsl.localhost\kali-linux\home\...`.
- In a worktree session, a guard rejects shell commands it can't verify: what it rejects and what passes is in `docs/agents/gpu-probe.md` (Worktree shell guard).

### Running tests
- Before running anything, pick what the change can affect from `docs/agents/testing.md`: changed file → CPU test groups and GPU probe scenarios. Name what you skipped and why in the report.
- CPU tests: `--headless --script res://tests/run_tests.gd -- @quick @soft test_bodies.gd <method>` runs those groups, files and methods (`--list` prints them without running). Each test runs in its own child process at below normal priority, up to `-j N` at once (default 4 here; `-j 1` for one process); never run a test suite and a GPU probe at the same time, or more than ~4 Godot processes in all: more made the owner's PC hang. `@quick` (~30 s) suits any change; the full suite takes ~3 min, so run it before the final commit whenever the change reaches the CPU reference.
- GPU probes: pass `--disable-vsync` (a third faster, same results).

### GDScript pitfalls seen here
- `var x := untyped_call()` fails to parse when the value has no static type. Write `var x: float = ...`.
- Overriding `_process` on a `SceneTree` script must match the parent signature, `-> bool`.
- In a probe, call `sim.shutdown()` before `quit()`, or Godot reports leaked RIDs.
