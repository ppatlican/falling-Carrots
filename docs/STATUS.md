# Status

Last updated: 2026-10-17 (contact impulses between rigid bodies built and measured, ADR 0015, on a branch for the owner; earlier the same day: the creep fix, ADR 0014, and jelly on sand at low stiffness, ADR 0013). Terms follow `CONTEXT.md`. The design and the rules the code must keep are in `docs/SPEC.md`.

Resolved issues, every experiment log, the Verified table, measured pass times and the full Next history moved verbatim to `docs/status-archive.md`. Its `###` headings name each entry: grep it before trying a fix ("archive § X" below means that heading).

## Contents
- Where things stand
- What works
- Known issues (open)
- Next
- Hardware checklist (PC and phone)
- Running tests and the validator

## Where things stand
- Direction: an OE-Cake-style sandbox with rigid and soft bodies and in-game material parameters (`docs/adr/0001-oe-cake-direction.md`).
- **Current milestone: 3b (material parameters, Next item 9).** Done: the parameter panel (ADR 0007), soft-on-soft contact (ADR 0008), jelly on sand improved (ADR 0009) and fixed at low stiffness (ADR 0013, proposed; owner to play it), liquids by density and oil (ADR 0010), stickiness (ADR 0011; the owner played it on 2026-10-16). Plasticity is built (ADR 0012, proposed; owner to play it). Next: the later 3b slices.
- **Milestone 3 (cluster solids) is done** (What works, Bodies; body brush at most 2000 members a body). The owner played it on 2026-10-14: jelly feel OK, the brush cap stays, a stroke drawn into water making nothing is fine.
- **Milestone 2 (GPU liquid, powder and brush)** is code complete and runs on the PC GPU. Left: measure the cap on a phone, at the very end (owner, 2026-10-14). The owner played the sand-and-water builds on 2026-10-10 and 2026-10-12 ("looks OK").

## What works
Details and how each was verified: archive § Done (Milestone 2), § Verified, and the ADRs.
- **Materials:** rows in `data/materials.json` (sand, water, oil, carrot, jelly, cork, dough), loaded, validated and packed by `cpu_ref/material_table.gd`; validator `tools/validate_materials.gd`. Parameter panel (top right) with sliders per class, a colour picker and reset; edits upload while the sim runs. Slider ranges stop where the GPU probe found an end unsafe: density 0.1–10, liquid density 0.5–2, drag 0–5, liquid drag from 0.1, body drag from 0.5, stiffness from 0.2 (ADR 0007, 0010).
- **Pool and hash:** a fixed cap (`config.json`) with a free-list; a spatial hash; the solver runs on the cell-sorted copy (SPEC 2.1).
- **Liquids:** PBF with s_corr and XSPH, wall density, a kick cap (`LIQUID_KICK` 2), drag per second (water 0.15), 2 substeps with a 4 px move cap per substep (480 px/s top speed), a lattice brush. Depth pressure comes from the density projection grid (`hydro.glslinc`, `hydro_solve`: 16 px cells, 32 red-black SOR sweeps in one workgroup, ghost-fluid free surface). Liquids layer by density (mass-weighted PBF and grid, ADR 0010).
- **Powder:** mass-weighted contacts with friction, `STACK_K` 0.3, inelastic push-out, sleeping only when held up and cradled, a lattice brush. Under water: sand sinks and settles, water leaves sand out of its density, a bed holds ~0.4 water per grain, the grid treats a sand bed and the floor as walls that hold the water's weight.
- **Bodies:** shape-matched cluster solids (ADR 0002) that float or sink by density and keep grains and water out (ADR 0003), collide and sweep fast impacts, split under the eraser (ADR 0004), bend over regions (ADR 0005), rest on each other (ADR 0008) and on sand at any stiffness (ADR 0009, 0013), and keep their dents with plasticity (ADR 0012).
- **Stickiness:** `cohesion` and `adhesion` per material (ADR 0011): damp sand stands in columns, honey climbs walls.
- **Rendering:** 2×2 points into 640×360; liquids, then the gap over sand (`render_gap.glsl`), then powders; pore water shaded as wet sand.
- **Tools:** F3 overlay (time per pass, hash view, "GPU check"); `tools/gpu_probe.gd`, `tools/water_feel_probe.gd`, `tools/body_probe.gd` (`docs/agents/gpu-probe.md`); the game refuses to start on a stale shader import (`ComputeContext.import_is_stale`, SPEC 2.7).
- **Cost** (PC, RTX 3080 Ti, settled, 2 substeps, `--disable-vsync`, 2026-10-12): 0.62–1.14 ms a frame for 50k; mixed water and sand is the most expensive state (solve 0.7–0.8 ms), `hydro` 150–185 µs. Bodies pass ~40 µs for small bodies, ~219 µs for one 2000-member body; stickiness +60–70 µs at 50k while a material is sticky; plasticity 50–450 µs with a dough. Phone: not measured. Tables: archive § Measured numbers.

## Known issues (open)
Read the entry and its archive section before tuning the solver: most obvious fixes were already tried.
- **A lopsided soft body creeps sideways on its own** (GPU `body_probe creep`, a tilted jelly at stiffness 0.2: 0.15 px/s, 0.046 before ADR 0013; none from 0.5 up). Cause: each member takes the plain mean of its regions' goals, so edge members count for more and the goals don't keep the body's momentum. FastLSM weights fix it (0.028 px/s), on main since 2026-10-17 for the owner to play: loaded soft bodies give more (a carrot dropped on a shipped jelly slid off in 2 of 3 runs), since the leak was holding loads up. Keep or revert (`git revert 63b2106`): ADR 0014. → archive § Lopsided soft body creeps sideways.
- **A body dropped onto another stops at a corner hit instead of spinning** (owner, 2026-10-17: "a noticeable slowdown"). The sweep's re-firing is fixed (sweep once, on main; owner: "it's better"), but contacts still take a corner hit's speed: boxtilt lies flat 8 frames after the touch (a rigid box: ~3), bodies rebound 5-6 px/s off each other. Fix built, not merged: contact impulses between rigid bodies (ADR 0015, branch `contact-impulses`): flat in 4 frames keeping ~40% of its speed, rebounds 0-1 px/s, nothing dips in; a corner landing is thrown sideways (57 px/s) and it costs ~0.1 ms a frame while bodies exist. Owner to play it and decide. A tilted carrot on the bare floor doesn't freeze. → archive § A body dropped onto another freezes at the hit.
- **Dark strip: the air between settled sand and water is still in the sim.** The drawing covers it (`render_gap.glsl`; the owner looked on 2026-10-14: the strip is gone). Tried: the grid push scaled by support below, box and ray occupancy tests, a particle-scale ghost-fluid pull, a smaller powder-liquid contact distance (0.9 × spacing closes most of it, at ~+30% water in a mounds bed: the owner's call). → archive § Dark strip between settled sand and water; Next item 1.
- **A wide floater is "a bit finicky"** (owner, 2026-10-15, after ADR 0003 item 18). Not looked into: ask before tuning it. A floater keeps ~1–3 px of air under it. → archive § Wide floater over a thin layer of air; ADR 0003 Known limits.
- **Liquids by density, left over:** a layered pool rocks for ~40–55 s; a thin dark line along the interface; from a fine mix 0.5–3% of the oil stays as a film on the floor (the measured fix changes pure water's floor push, so it waits for the owner); grains ignore a liquid's density, so sand sinks through liquid at 2 (owner: fine for now; a powder-rule change). → ADR 0010 Known limits; archive § Liquids ignore their material density.
- **Stickiness limits (ADR 0011 Known limits):** a sticky particle's stored velocity holds the next step's pull, so the probes' speeds overstate motion for sticky materials (read `rms_disp_per_sample`); at adhesion 1 splash can stay stuck high on a wall; a body doesn't stick to a side wall; a damp sand wall over ~15–20 rows tears.
- **Water over sand, left over:** a loop (≤6 px/s) in each bottom corner where a mound's toe meets the wall, an eddy over the V between two mounds (1.4–4.1 px/s), ~500 of 10k sunk grains creeping over 0.5 px/s. Tried for the corner loop: counting sand toward compression (brought the bowl loop back). → archive § Sand bowl, § Sand mounds, § Screen edges.
- **Body limits** (ADR 0002, 0003, 0005, 0008, 0012 and 0013 Known limits): a soft plank (0.5 and below) wedged into a gap is crushed at the supports' corners and turns partly inside out, which regional shape matching doesn't undo (at 0.2 it keeps tumbling the carrots; archive § ADR 0013 follow-ups); big bodies are slow (the fused pass grows with the largest body; the split pass isn't scheduled, the 2000 brush cap stays: owner, 2026-10-14); a sunk body slides on a film of water; a big floater heaves with the pool; a long body takes ~15 s to rise; a cork buried under enough sand stays down; the push-out misfires at a rigid body's corners; a dough squeezes instead of spreading.
- `config.json` and `data/materials.json` are not auto-exported. The Android preset needs `*.json` in its non-resource include filter.
- Also open, moved to the archive (§ Known issues moved from STATUS): MCP runtime tools failing after headless runs, a headless `--import` in the main checkout dropping two `project.godot` lines (`git checkout project.godot`), sand under water somewhat compressed, the sleeping trade-off (slow grains on a slope stop), the top 20 px of 50k water at ~1.2 px/s, water drawn as plain 2×2 points (metaballs are M5), slow devices running in slow motion (intended), no keyboard shortcuts for materials, a sinking sand slab holding together ~1 s, the water brush pouring ~4× slower than before the lattice brush, gravity at 400 px/s² (a ~9 m tank; the owner's call).

## Next
Item numbers match the full history (archive § Next); items 1, 2, 5 and 7 are done.
- **9. Milestone 3b (material parameters).** Probe both ends of every slider; run `erase` and `shaft` on any powder cohesion. Next: the later 3b slices: copy to a free slot. The owner is to play plasticity and keep or drop the dough row (ADR 0012, Owner's call). The owner is to play contact impulses between rigid bodies (ADR 0015, branch `contact-impulses`: merge or keep main), jelly on sand at low stiffness (ADR 0013), and the creep fix now on main (ADR 0014, Owner's call: keep it with softer loaded jellies, revert it and keep the creep, or a pair-joint experiment). Owner may look at: oil in play (the interface rocking for ~40 s after a pour, separation taking ~30–60 s), and whether grains should follow a liquid's density (sand floating on a heavy liquid; a powder-rule change, ADR 0010). Open from ADR 0011: whether bodies should stick to side walls. Leads from Phyzios for several open issues (pair-joint jelly, never-sleeping sand, drag by density deficit): `docs/phyzios.md`, best candidates at the end; none started.
- **8. Soft bodies, later, only if asked:** stiffer long jellies (a coarse level of regions, or more region passes per material like OE-Cake's `elasticIteration`), then ADR 0006 (Brittle, String).
- **6. Measure the cap on a phone** (the Milestone 2 goal). Owner, 2026-10-14: phone tests come at the very end. First add `*.json` to the Android preset's non-resource include filter. If over budget: `substeps` 1, fewer SOR sweeps, lower cap.
- **4. Tune from the owner's 2026-10-10 play:** slosh too long → water drag 0.3 per second; the weak water brush and the ~1 s sand slab (Known issues).
- **3. Owner plays the sand bowl, mounds and floor fixes** (on main, 0830973 to 5d7b550): pure water with bare screen edges, sand mounds under a deep pool, a pool in a sand bowl, sand dropped into water; decide on the side effects listed in archive § Sand bowl, § Sand mounds, § Screen edges.
- **1. If the owner wants the sim itself to close the dark strip:** a smaller powder-liquid contact distance (0.9 × spacing: strip 17-20% at 60 s, `mounds` calm), which puts ~30% more water in a mounds bed.

## Hardware checklist (PC and phone)
1. Drawing with left mouse/tap adds the selected material; right mouse erases any material.
2. Sand sinks under water, and water spreads out and goes calm.
3. "+10k" buttons add a block. The meter turns red and reads FULL at the cap, and drawing then adds nothing.
4. "GPU check" in the overlay prints `GPU check OK ...`. A FAILED line is a bug: send it.
5. The overlay GPU column shows numbers, not `-`.
6. The log has no errors, and no leaked-RID warnings on quit.

## Running tests and the validator
Run tests: `Godot_v4.7.1-stable_win64_console.exe --headless --path <project> --script res://tests/run_tests.gd -- @quick` (groups and what to run for a change: `docs/agents/testing.md`)
Run validator: `... --headless --path <project> --script res://tools/validate_materials.gd`
