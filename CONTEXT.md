# Cooking Sandbox

A 2D side-view particle sandbox in the spirit of OE-Cake, where the player mixes, heats and cooks materials to discover recipes. Everything that moves is a particle in one shared simulation: liquids, powders, rigid bodies and soft bodies.

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
The behaviour class where a group of particles keeps a shape by shape matching. It covers both rigid bodies and soft bodies; one group is a body.
_Avoid_: Cluster (alone, when the class is meant)

**Rigid body**:
A cluster solid at stiffness 1: keeps its shape exactly (carrot, a drawn block).
_Avoid_: Solid (ambiguous with static solid)

**Soft body**:
A cluster solid below stiffness 1: bends, wobbles and springs back (jelly), or keeps its dents if it has plasticity (dough). It is matched over regions, not as one cluster (ADR 0005), or held by pair joints if its material's soft model says so (ADR 0016).
_Avoid_: Deformable

**Jelly**:
The springy soft-body material, as in OE-Cake.

**Dough**:
The soft-body material with plasticity: it keeps dents and flattening instead of springing back (ADR 0012).

**Plasticity**:
The cluster-solid parameter (0–1, soft bodies only): the share of a member's deformation past the yield (half a spacing, in its body's frame) that its rest shape takes on per 1/60 s. 0 springs back fully (jelly); 1 keeps all of it at once. Its rest lattice can't be squeezed below 0.7 of a spacing or torn, so a hard press stays partly elastic.
_Avoid_: Memory, creep (creep is the slow drift it must not have)

**Stiffness**:
The cluster-solid parameter: the share of a body's shape error removed per 1/60 s (for a soft body, of each region's). 1 is a rigid body; lower is a soft body.

**Region**:
In a soft body, a member and the members of its body whose rest offsets lie within the material's `region` radius of its own (1.5–2.0 spacings). Each region is fitted like a small rigid body every iteration, and each member moves toward the mean of its regions' goals, so the body bends where it is loaded. Smaller regions bend more. A long or big soft body sags and slumps a lot (the noodle, ADR 0005 Known limits).
_Avoid_: Cluster (a region is not its own body)

**Soft model**:
How a soft material keeps its shape, the `soft_model` column: `regions` (regional shape matching, the default) or `joints` (pair joints). Joint jelly is the shipped row with joints (ADR 0016).

**Pair joint**:
In a soft body held by joints, a link between two members whose rest offsets lie within the region radius (the same pairs a region holds). Each iteration both ends move toward their rest vector, turned by the two ends' rotations, by equal and opposite amounts, so the body's momentum is kept and it can't creep (ADR 0016).
_Avoid_: Spring (a joint keeps direction as well as length), bond

**Gas**:
A behaviour class of light, short-lived particles moved by heat and wind (fire, smoke, steam).

**Static solid**:
Material painted into the world grid instead of being particles (steel, wood). Particles collide with it.
_Avoid_: Wall, terrain

**Parameter**:
One adjustable column of a material's row (viscosity, stickiness, density, stiffness and so on). Parameters belong to the material, not to single particles, and each has a safe range: the validator's range for that column and class, where its slider stops.
_Avoid_: Setting (config.json holds settings), property

**Stickiness**:
How strongly a material's particles hold on: cohesion to particles of the same material, adhesion to other materials and walls. A capped force, so a sticky clump still breaks under enough weight.
_Avoid_: Glue, friction (friction resists sliding; stickiness resists pulling apart)

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

**Body**:
One group of cluster-solid particles, all of one material, that shape matching holds to a rest shape. Each particle carries its body's id; particles of the same body never push on each other.
_Avoid_: Cluster (for one body), object

**Rest shape**:
How a body's particles sit when nothing deforms it, stored as each particle's rest offset. Shape matching pulls the body back toward it, moved and turned to fit where the particles are now. Plasticity edits it, and the outline follows.

**Outline**:
The edge of a body's rest shape, half a spacing outside its edge particles. A grain or water particle inside a body's outline is pushed out toward its nearest edge (the push-out).
_Avoid_: Hull, boundary (for the shape)

**Wet surface**:
The part of a body's outline that liquid touches. The liquid's pressure presses on it, which floats light bodies and lets heavy ones sink slower; a body with no wet surface feels no pressure.
_Avoid_: Submerged part

**Piece**:
A group of a body's particles that still touch each other in its rest shape (neighbours within 1.5 spacings, diagonals included) after the eraser took some. A body left in two or more pieces is split: each piece becomes its own body, the largest keeping the id (ADR 0004).
_Avoid_: Fragment, island, shard

**Body cap**:
The most bodies at once (`body_cap` in `config.json`). When every body id is in use, the body brush makes nothing.

## Player tools

**Brush**:
The tool that adds the selected material in a circle; right-click with it is the eraser. Every material goes only into free spots, so it never lands inside existing particles; held still, it adds only as fast as the last particles fall away.

**Body brush**:
The tool that draws a shape which becomes one rigid or soft body, by the material's stiffness. It paints on the rest lattice, leaves out spots that already hold particles and parts thinner than 2 particles, and makes one body per piece left. A stroke holds at most 2000 particles.

**Parameter panel**:
The in-game panel (top right) of sliders for the selected material's parameters, with its colour and reset (copy to a free slot comes later). An edit changes every particle and body of the material at once, while the sim runs (ADR 0007).
_Avoid_: Material editor, inspector

**Eraser**:
The brush's remove mode; the only thing that deletes particles besides gas lifetime. A body it leaves in pieces becomes one body per piece (ADR 0004).

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
_Avoid_: Wobble, jelly (jelly is a material)

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
Grains packed into each other that hang together in the air instead of falling, so the clump seems to defy gravity. Packed grains can't spring apart (push-outs add no speed), so they only spread slowly. A bug, unlike a clump a sticky material holds together on purpose.
_Avoid_: Sticky sand (sand has no stickiness)

**Hovering**:
Loose liquid drops held a few pixels above a liquid surface at rest instead of falling onto it, making the surface look fuzzy.
_Avoid_: Floating (keep that for solids buoyed up by liquid)

**Slosh**:
The whole body of liquid swinging from side to side, the surface tilting one way then the other. Real water does it; it is churn only if it doesn't die down.

**Density projection grid**:
The coarse grid (16 px cells) that gives liquids their pressure with depth: it measures each cell's liquid density, solves for the pressure that removes compression across the whole tank, and pushes liquid particles down its gradient before the PBF iterations (`hydro.glslinc`). Cells mostly full of sand are a bed that holds the water's weight, with the pressure carried on into its pores; the floor holds it the same way.
_Avoid_: Hydro grid (the shader names say hydro, but it isn't hydrostatic: pressure comes from compression, and from the weight of water resting on a sand bed)

## Simulation step

**Frame**:
One 1/60 s update of the simulation and one render.

**Shape matching**:
The cluster-solid rule (Müller et al. 2005): in each solver iteration, fit each body's rest shape to its particles (centre and rotation), then pull each particle toward its place in the fitted shape by the material's stiffness.

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
The script that measures how real water and sand move on the GPU, one scenario per run (`tools/water_feel_probe.gd`, list in its header): free fall, dam break, surface drift, pour, hovering, sand from a brush in the air, sand left in the air by the eraser, shafts cut into a pile, sand sinking through water, a pool in a sand bowl, and water over sand mounds.

**GPU check**:
The debug-overlay button that checks the pool and the spatial hash agree.

**Owner**:
The human who plays the game on real hardware (PC and phone) and reports bugs.
_Avoid_: User, tester
