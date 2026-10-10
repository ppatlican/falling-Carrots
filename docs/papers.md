# Reference papers & code

Read only the section for the problem at hand. Fetch one paper section at a time; cite what you used.

## Solver basics (substeps, dt scaling, s_corr, stiffness)
- **Small Steps in Physics Simulation** (Macklin et al. 2019): https://matthias-research.github.io/pages/publications/smallsteps.pdf
  Substeps beat iterations; deep PBF tank coming fully to rest; how constants scale with dt. **Read first.**
- **Position Based Fluids** (Macklin & Müller 2013): https://mmacklin.com/pbf_sig_preprint.pdf
  Base algorithm. s_corr (k≈0.1, n=4, Δq 0.1–0.3h), XSPH c≈0.01, vorticity confinement. Notes s_corr depends on time step.
- **XPBD** (Macklin, Müller, Chentanez 2016): https://matthias-research.github.io/pages/publications/XPBD.pdf
  Compliance makes stiffness independent of substep/iteration count. Use for s_corr, contacts, grid pressure stiffness.

## Boundaries & rest (floor creep, resting jitter, walls)
- **Unified Particle Physics for Real-Time Applications (FleX)** (Macklin et al. 2014): https://mmacklin.com/uppfrta_preprint.pdf
  Pre-stabilization (4.4), sleeping (4.5), stack mass scaling (5.2, basis of STACK_K), friction (6.1), sand–water coupling/buoyancy (7.1, also M3 carrots). **Read first.**
- **Versatile Rigid-Fluid Coupling for Incompressible SPH** (Akinci et al. 2012): https://cg.informatik.uni-freiburg.de/publications/2012_SIGGRAPH_rigidFluidCoupling.pdf
  Boundary particles that fix density deficit at walls/floor; relevant for M4 static solids.

## Sand (piles freezing, sand under water)
- **Drucker-Prager Elastoplasticity for Sand Animation** (Klár et al. 2016): https://math.ucdavis.edu/~jteran/papers/KGPSJT16.pdf
  Correct angle of repose; piles creep instead of freezing.
- **Multi-species simulation of porous sand and water mixtures** (Tampubolon et al. 2017): https://math.ucdavis.edu/~jteran/papers/PGKFTJM17.pdf
  Two-grid momentum exchange, wetness-dependent cohesion. Reference for water-over-sand drift.

## MPM (only if switching water from PBF; see gpu/mpm_water.gd spike)
- **nialltl MPM guide**: https://nialltl.neocities.org/articles/mpm_guide and repo https://github.com/nialltl/incremental_mpm
  Practical real-time 2D MLS-MPM (~40k particles): volume re-estimation, Tait EOS, wall handling. **Read first if going MPM.**
- **MLS-MPM** (Hu et al. 2018): https://yzhu.io/publication/mpmmls2018siggraph/paper.pdf
  The method; section 4 "From MPM to MLS-MPM".
- **taichi_mpm** (incl. 88-line mls-mpm88-explained.cpp): https://github.com/yuanming-hu/taichi_mpm
  Smallest complete reference to diff shaders against.
- **WebGPU-Ocean**: https://github.com/matsuoka-601/WebGPU-Ocean
  GPU MLS-MPM at 100k+ particles, fixed-point atomic P2G (same trick as our grid splat).

## Rendering (M5: speckle, loose edges)
- **A simple Method for creating 2D Metaballs** (John Wigg, Godot): https://john-wigg.dev/2DMetaballs/
  Gradient sprites into a viewport, then threshold shader. Closest to the M5 plan; MIT.
- **Screen Space Fluid Rendering with Curvature Flow** (van der Laan et al. 2009): https://wstahw.win.tue.nl/edu/2IV06/andrei/particle_rendering/provided/p91-van_der_laan.pdf
  Splat → smooth → threshold/shade.

## Readable code & talks
- **Ten Minute Physics** (Matthias Müller): https://matthias-research.github.io/pages/tenMinutePhysics/index.html
  Short demos: XPBD (#09), spatial hash (#11), GPU sim (#16), FLIP water (#18).
- **SebLague/Fluid-Sim**: https://github.com/SebLague/Fluid-Sim
  Readable GPU particle fluid; compare hash/kernel/pressure choices.
- **Noita GDC 2019** (Petri Purho): https://youtu.be/prXuyMCgbTc
  How a shipped falling-sand game handles materials and only simulates active regions.
