# Release Notes

## v0.2.2 — Unreal Engine Integration

The Dart space sim now drives a real-time renderer in **Unreal Engine 5.8**.

### Unreal Engine bridge
- The sim streams live world state to a drop-in UE plugin over **FlatBuffers/TCP**
  (`wire/sim.fbs`). The bridge runs **in-process** (`SimBridge`), so Unreal renders
  the very same simulation the Flutter views drive — with a Flutter desktop
  remote-control client on the shared server.
- UE `FSim*` structs are **generated from the wire schema** and drift-checked, so
  the C++ and Dart sides can't fall out of sync.

### UE plugin (`ue/AcroSimBridge`)
- A drop-in `AcroSimBridge.uplugin`: `ASpaceSimRenderer` turns the telemetry stream
  into actors, the bridge is exposed to Blueprint, and the **live sim renders in the
  editor viewport** (not just Play-In-Editor).
- Bodies are sized from their bounds (craft no longer spawn inside the planet),
  spawned actors are labelled in the World Outliner, and a `WorldScale` knob plus
  orbit-line thickness control tune the look. Compiles clean on UE 5.8.

### Telemetry & orbits
- Per-vessel telemetry gauges, a discrete event stream, and per-vessel orbit,
  trajectory, and comms-link lines.
- Celestial-body **orbit rings** stream so Unreal can draw the whole system; static
  body render descriptors carry texture, heightmap, and atmosphere data.

### Universe
- The **real Solar System** is now the only system; legacy KSP body names are gone.

### Atmosphere
- The 0.2.1 per-pixel path-length atmosphere shader was reverted to the **0.2.0
  screen-space radial halo** — it reads better. The icosphere render rewrite stays.

## v0.2.1 — The Rendering & Atmosphere Overhaul

This release rebuilds the planet renderer end to end and adds a complete game guide.

### Planet rendering
- **Adaptive icosphere planets.** Bodies are now subdivided-icosahedron 3-D spheres
  (no lat/long pole singularity), projected through the real perspective camera and
  correct from interplanetary distance down to standing on the surface.
- **No missing surface wedges.** Faces crossing the camera near plane are clipped so
  the ground fills cleanly to the frustum edge at every angle and elevation —
  verified across the full angle/altitude range by a pixel-scoring harness.
- **Performance.** Killed the low-altitude tessellation blow-up (the "<1 Mm
  slideshow"): straddle faces no longer recurse to full depth, the visible cap is
  pruned, and detail scales with distance. The cost curve is now flat and bounded.
- **No more flat-disc fallbacks.** A body is always the textured sphere.

### Atmosphere
- **Per-pixel scattering shader.** The atmosphere is now computed per pixel
  (`shaders/atmosphere.frag`): each view ray's path length through the atmosphere
  shell drives the glow, warming toward the terminator. It is **correct at every
  altitude** — a soft ring on the limb from orbit, a haze band along the local
  horizon when low, atmospheric perspective near the edge — with no gap to the
  horizon and a genuinely soft edge. Falls back to a radial-gradient halo where
  shaders aren't available.

### Camera
- A clean `SceneCamera` abstraction (orthographic MAP + perspective CRAFT views);
  perspective `range` is a surface-relative altitude that zooms smoothly to the
  ground.

### Testing
- **True-pipeline screenshot harness** that drives the real render path (real solar
  system + real landed craft + the live camera + the real surface texture) and scores
  each frame pixel-by-pixel for atmosphere connection and surface wedges. Render
  regressions are caught as numbers, not eyeballed.

### Documentation
- Deep class-level documentation on the renderer, camera, and atmosphere; full API
  docs generated with `dart doc` into `doc/api/`.
- A complete **game guide / wiki** (`wiki/`): promo overview, quickstart, a pad-to-
  orbit tutorial, and detailed mechanics pages covering flight physics, orbital
  mechanics, atmosphere & reentry, thermal, propulsion & staging, colonies & economy,
  and rendering — each with in-game screenshots.

### Earlier in 0.2.x
- Landed craft co-rotate with the planet; airspeed measured against the co-rotating
  atmosphere (no more stationary craft cooking under time-warp).
- Engine state persists across save/load; max-Q structural limits; reentry heating
  substepping; manual-flight default start with infinite fuel + 1× warp.
