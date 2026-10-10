## Agent skills

### Issue tracker

GitHub Issues in this repo, via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default labels: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.

## Project docs

- `CONTEXT.md`: the glossary. Use its terms (grain, pile, block fill, churn, slosh, squeezing, pudding, sleeping, density projection grid, CPU reference, GPU probe).
- `docs/SPEC.md`: what we're building and the rules the code must keep, including the GPU plumbing rules in 2.7. Read 2.7 before touching a shader.
- `docs/STATUS.md`: what works, what's verified, open bugs with everything already tried, and what's next. Read Known issues before tuning the solver.
- `docs/agents/gpu-probe.md`: read before running or reading the GPU probe, comparing variants, timing passes, or taking screenshots.
- `.workbuddy-ai/memory/` (untracked, main checkout only): notes from another AI tool the owner uses, with decisions made there (for example, an MPM rewrite was judged not justified). Read them before solver or architecture decisions. Its uncommitted experiments may also sit in the main checkout; treat them as read-only.

## Working on the sim

### Liquids
- Depth pressure comes from the density projection grid (`gpu/shaders/sim/hydro.glslinc`); PBF only fixes local spacing. Tune liquids through the `HYDRO_*` constants and water `drag` in `data/materials.json`. STATUS lists the local fixes the grid replaced (liquid stack scaling, per-particle carried pressure) and why they churned.

### Verifying a change on the GPU
- A solver change is fixed only once the GPU probe shows it (`tools/gpu_probe.gd`; arguments in its header, how to read it in `docs/agents/gpu-probe.md`). Fixes that passed the CPU reference have done nothing on the GPU before.
- A change to what the owner sees is fixed only once screenshots of `main.tscn` show it (recipe in `docs/agents/gpu-probe.md`). The probe's mean speed once read 9 px/s while the owner saw water shooting up.
- Run Godot from a copy of the repo under the job tmp or scratchpad. Running in the repo rewrites `project.godot` and `.godot/`, and a headless `--import` drops lines from `project.godot`. A fresh copy needs one `--headless --import` before the probe. After editing a `.glslinc`, delete `.godot/imported/*.glsl-*` in the copy before importing.
- The GPU probe needs a real window: the Windows console exe without `--headless`, `/mnt/c/Users/nosed/Desktop/Godot_v4.7.1-stable_win64.exe/Godot_v4.7.1-stable_win64_console.exe --path '<windows path>' --script res://tools/gpu_probe.gd -- <args>`. A WSL path works as `\\wsl.localhost\kali-linux\home\...`.
- In a worktree session, a guard rejects shell commands it can't verify. Rejected so far:
  - a variable as the command (`$G`), or a variable holding a path that `sed` or another tool acts on;
  - `for` loops, `bash script.sh`, `timeout`, `sleep` followed by other commands, and commands that read stdin;
  - any text containing `.git` (such as `tar --exclude=.git`), `git -C .`, `cd` into the main checkout before `git`, and a heredoc whose text contains the word git;
  - several heredocs writing files in one command.

  What passes: one literal Godot call per command (chained with `;` or `&&`); `cp -r` over an explicit list of top-level entries; the Write tool for new or rewritten files; one `python3 - <<'EOF'` per command for multi-file edits; `until <check>; do sleep 5; done` to wait. To read a file from another branch, use `git show <ref>:<path> > <tmp file>` from the worktree.

### GDScript pitfalls seen here
- `var x := untyped_call()` fails to parse when the value has no static type. Write `var x: float = ...`.
- Overriding `_process` on a `SceneTree` script must match the parent signature, `-> bool`.
- In a probe, call `sim.shutdown()` before `quit()`, or Godot reports leaked RIDs.
