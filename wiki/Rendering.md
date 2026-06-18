# Rendering & Camera

ACRO renders the Solar System at **1 : 1 scale** and lets you zoom continuously from
a craft on the runway out past the Moon — the planet a true 3-D sphere the whole way,
with a soft atmosphere on its limb. This page explains how that works. It's deeper
than you need to play, but it's the system that makes the scale feel real.

![Earth's atmosphere on the limb from orbit](images/atmosphere_limb.png)

## One camera abstraction, two projections

Everything that draws goes through a single `SceneCamera`, which owns the
metres→pixels mapping. Two implementations:

- **Orthographic** — the strategic MAP view. Parallel rays, constant scale, never
  culls. Good for seeing a whole orbit as a clean conic.
- **Perspective** — the 3-D CRAFT / flight view. A real eye pulled back from the
  focus, with a perspective divide (distant things shrink, near things grow) and a
  near plane. Its `range` is measured from the focused body's *surface*, so it reads
  as an altitude that shrinks to near zero — you keep zooming smoothly all the way
  down to the ground.

Swapping the camera swaps the whole look with nothing else changing, because the
presenter and painter only ever ask the camera to project points.

## The planet: an adaptive icosphere

A body is drawn as a **subdivided icosahedron** — 20 triangular faces recursively
split into four until each leaf is small on screen. An icosphere is used instead of a
latitude/longitude grid because lat/long has a **pole singularity** (looking straight
down at a pole collapses the mesh into a pinwheel); an icosphere has near-uniform
triangles and no poles. Every vertex is projected through the real perspective camera,
so the sphere is correct from any distance — including an eye at the surface, where the
silhouette becomes the projected horizon arc rather than a circle.

To stay fast, only the **visible cap** is tessellated (faces past the horizon are
pruned), detail scales with how close you are, and faces that cross the camera's near
plane are clipped so the ground fills cleanly to the frustum edge with no gaps.

![Standing near the surface, looking at the horizon](images/surface_horizon.png)

## The surface texture

Each body wears an **equirectangular surface map** (real planetary imagery). The mesh
samples it by each vertex's latitude/longitude, with care taken at the texture's
antimeridian seam and poles so the map doesn't tear. Lighting is a per-vertex Lambert
shade against the real Sun direction, so the day side is bright, the night side dark,
and the terminator falls where it should.

## The atmosphere: per-pixel scattering

The soft glow on a planet's limb is computed **per pixel** by a fragment shader. For
each pixel it casts the view ray and measures how far that ray travels through the
atmosphere shell before it hits the surface — long paths (a ray grazing the limb)
glow brightly, short paths (looking straight down) barely at all. Because it's a true
3-D ray test, the atmosphere is correct at **every altitude**: a soft ring on the limb
from orbit, a haze band along your local horizon when low, and atmospheric perspective
tinting the surface near the edge. It warms toward the terminator and fades on the
night side.

This replaced earlier screen-space tricks that worked from orbit but couldn't place
the haze on a surface-level horizon — only per-pixel ray marching is right everywhere.

![The full lit Earth with atmosphere and an orbiter](images/orbiter_over_earth.png)

## Why 1 : 1 scale holds together

Distances span metres to hundreds of millions of kilometres. Physics runs in a
floating-origin frame (coordinates kept small and local) while a precise integer-
lattice vector type carries the absolute position; the renderer projects from the same
data. That's why you can zoom from the surface to interplanetary distance without the
world tearing — the precision is never spent on a giant absolute coordinate.

## Verifying the renderer

The renderer is held to its two hardest requirements — a soft, gap-free atmosphere and
no missing surface wedges — by a **true-pipeline screenshot harness** that drives the
real render path at dozens of camera angles, elevations, and altitudes and scores each
frame pixel-by-pixel. Render bugs are caught as numbers and PNGs, not eyeballed.
