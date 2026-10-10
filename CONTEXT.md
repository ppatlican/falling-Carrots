# Cooking Sandbox

A 2D side-view falling-sand sandbox where the player mixes, heats and cooks materials to discover recipes. Everything that moves is a particle in one shared simulation.

## Materials

**Material**:
One row of the material table: a named substance with its behaviour class and physical properties (density, friction, viscosity, drag and so on).
_Avoid_: Element, substance

**Behaviour class**:
The rule set a material moves by: liquid, powder, cluster solid, gas or static. Adding a material is data; adding a behaviour class is code.
_Avoid_: Type, kind, category

**Liquid**:
A behaviour class that keeps a constant density and flows (water, oil, batter).

**Powder**:
A behaviour class made of frictional grains that pile up (sand, flour).
_Avoid_: Granular, dust

**Cluster solid**:
A behaviour class where a group of particles keeps a shape, stiff (carrot) or soft (dough).
_Avoid_: Rigid body, soft body

**Gas**:
A behaviour class of light, short-lived particles moved by heat and wind (fire, smoke, steam).

**Static solid**:
Material painted into the world grid instead of being particles (steel, wood). Particles collide with it.
_Avoid_: Wall, terrain

**Reaction**:
A table rule that turns input materials into output materials when they touch or reach a temperature.
_Avoid_: Recipe (a recipe is what the player discovers, made of reactions)

## Particles

**Particle**:
One simulated point of a material.

**Grain**:
A particle of a powder.
_Avoid_: Sand particle (when the material doesn't matter)

**Pool**:
The fixed set of particle slots the simulation can hold; its size is the cap.

**Cap**:
The most particles the pool holds at once. When the pool is full the brush adds nothing.
_Avoid_: Limit, max particles

**Rest density**:
How tightly a material's particles sit when nothing squeezes them. A liquid well above it is squeezed.

**Pile**:
A settled heap of grains, held up by the grains under it.
_Avoid_: Heap (in docs), stack

## Player tools

**Brush**:
The tool that adds the selected material in a circle; right-click with it is the eraser. Every material goes only into free spots, so it never lands inside existing particles; held still, it adds only as fast as the last particles fall away.

**Eraser**:
The brush's remove mode; the only thing that deletes particles besides gas lifetime.

**Block fill**:
A benchmark button that adds a 10k-particle rectangle of one material.
_Avoid_: Bench block, "+10k"

## Settling behaviour

**At rest**:
A settled pile or body of liquid whose particles stay put; the target state after anything lands.
_Avoid_: Settled (when movement is still happening), calm

**Sleeping**:
A grain held at rest because it barely moved in a step while something supported it. It wakes when hit or unsupported.

**Pudding**:
A pile that has settled overall but whose grains keep moving back and forth inside it, so it wobbles.
_Avoid_: Wobble, jelly

**Churn**:
Ongoing motion inside a body of liquid that should be at rest: jitter, convection plumes or spray.
_Avoid_: Boiling (boiling is a real reaction)

**Plume**:
A coherent column of liquid rising through the bulk at rest density, part of churn.

**Squeezing**:
Particles pressed well above rest density under the weight of what sits on them.
_Avoid_: Compression (fine in prose, but squeezing is the bug name)

**Floaty**:
Liquid that falls, spreads or splashes in slow motion compared with real water: a speed cap, too much drag, or particles blown apart on spawn.
_Avoid_: Viscous (unless the liquid really is thick, like batter)

**Surface drift**:
Particles in the top layer of a liquid at rest sliding sideways along the surface, part of churn.

**Mid-air clump**:
Grains packed into each other that hang together in the air instead of falling, so the clump seems to defy gravity. Packed grains can't spring apart (push-outs add no speed), so they only spread slowly.
_Avoid_: Sticky sand (grains have no cohesion)

**Hovering**:
Loose liquid drops held a few pixels above a liquid surface at rest instead of falling onto it, making the surface look fuzzy.
_Avoid_: Floating (keep that for solids buoyed up by liquid)

**Slosh**:
The whole body of liquid swinging from side to side, the surface tilting one way then the other. Real water does it; it is churn only if it doesn't die down.

**Density projection grid**:
The coarse grid (16 px cells) that gives liquids their pressure with depth: it measures each cell's liquid density, solves for the pressure that removes compression across the whole tank, and pushes liquid particles down its gradient before the PBF iterations (`hydro.glslinc`).
_Avoid_: Hydro grid (the shader names say hydro, but it isn't hydrostatic: pressure comes only from compression)

## Simulation step

**Frame**:
One 1/60 s update of the simulation and one render.

**Substep**:
One pass of predict to velocity inside a frame, at the frame time divided by the substep count (`config.json`). Settings are per second or per 1/60 s, so the substep count changes accuracy and cost, not how materials behave.
_Avoid_: Step (when a frame and a substep differ), tick

## Verification

**CPU reference**:
The small, readable CPU version of the simulation rules that the headless tests run and the GPU shaders mirror.
_Avoid_: CPU mirror, CPU sim

**GPU probe**:
The script that fills the GPU simulation with block fills and prints settling metrics from a real window.
_Avoid_: Probe script, harness

**Water feel probe**:
The script that measures how real water moves on the GPU: free fall, dam-break front speed, surface drift, hovering, pour screenshots, and sand from a brush falling through the air (`tools/water_feel_probe.gd`).

**GPU check**:
The debug-overlay button that checks the pool and the spatial hash agree.

**Owner**:
The human who plays the game on real hardware (PC and phone) and reports bugs.
_Avoid_: User, tester
