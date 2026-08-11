# Engine vs Project Split — acro → flintlock

**Status:** ON HOLD — slice 1 (sim-math via flintlock_engine path dep, 937f2a2) was
**reverted 2026-08-10**: the four domain/shared files are vendored back into this repo
(flintlock's current versions, keeping its ScaledTransform fixes; Vector3 docs restored
to acro's Z-up convention) and the path dependency is removed. Reason: avoid the
cross-repo coupling/bloat for now. This doc remains the analysis if the split resumes.
**Method:** static read of the whole repo (196 Dart
files + shaders) by four parallel investigators. Nothing built or run — verdicts are
from code + imports, not runtime.

**Target engine:** `flintlock` (F:\GitHub\flintlock) — a Flutter game engine on the
**same** flutter_scene / Flutter GPU stack + identical pins (its TOOLCHAIN.md cites this
repo as the proven-good combo). flintlock already has: an **ECS**
(archetype/entity/query/system/world/command_buffer), a **level editor**
(gizmo/inspector/outliner/picking/serialize), **cross-platform input + IO**
(pointer-lock, project_fs), **audio**, a **nav grid**, and a **terrain module**
(cube-sphere heightfield + Perlin + erosion + rivers + biome color).

---

## The one caveat that shapes everything

**Paradigm mismatch.** acro is strict **DDD/CLEAN** (aggregates, repositories, use-cases);
flintlock is **ECS**. So "engine-worthy" below means *the capability/algorithm is
engine-general* — re-homed as flintlock components + systems — **not** that acro's class
layout drops in unchanged. Two consequences:

- **Do NOT port acro's `Vector3`/`Quaternion`.** They duplicate `vector_math`, which
  flintlock already uses. Port what is built *on top* of them (below).
- The repository/aggregate/use-case files are the *most* structurally incompatible; their
  value is the algorithm inside, not the interface.

**The seam.** Every render-side file reaches space concepts through exactly one type:
`application/snapshot/world_snapshot.dart` (+ the `SceneCamera` interface). An engine
extraction keeps `SceneCamera` + a generic scene-diff feed and drops `WorldSnapshot`.
The 3D renderer is already one level removed from orbital mechanics — it only ever sees
resolved positions/quaternions — which is why so much of it extracts cleanly.

---

## Tier 1 — clean engine extractions (low coupling, high value)

Ranked by value to flintlock. These are the ones to actually lift.

| # | What | Files | Coupling | Why it matters to flintlock |
|---|---|---|---|---|
| 1 | **Large-world precision kit** | `domain/shared/precise_vector3.dart`, `scaled_transform.dart`, `reference_frame.dart` | imports only `vector3.dart`; "space" is doc prose + a `FrameKind` enum | Integer-lattice floating-origin position + integer-exact rigid transform. flintlock has **no** large-world type. Highest-value, cleanest cut. |
| 2 | **Floating-origin renderer** | `flutter_scene/coord_convert.dart` (`FloatingOrigin`, `kRenderScale`) | only the two math value types | Rebase-in-doubles → cast-to-f32 → m-to-km. flintlock has no floating-origin renderer. Pairs with #1. |
| 3 | **Rigid-body dynamics core** | `domain/dynamics/*` (`Integrator`+RK4+symplectic, `StateVector`, `GeneralizedForce`, `ForceContributor`/`ForceModel`, `MassProperties`) | none — 6-DOF, orbit-free; open force-composition seam | Drop-in physics core as a flintlock system. (`gravity_force`/`jet_force`/`structural_service` are the space contributors — leave those.) |
| 4 | **Custom shader pipeline** | `hook/build.dart` + `shaders/acro.shaderbundle.json` + `depth_materials.dart` + the std140 `setUniformBlockFromFloats` convention | none (pure stack code) | flintlock has no custom-shader pipeline and is on the *same* flutter_gpu stack. `depth_materials.dart`'s sticky depth-compare-op discipline is hard-won GPU hygiene. |
| 5 | **Camera abstraction** | `presenters/camera_view.dart` (`SceneCamera`, `CameraOrbit`, `OrthoCamera`), `perspective_camera.dart`, `flutter_scene/scene_camera_adapter.dart` | math types only; adaptive near=`d/20` + far tuning are planetary but parameterizable | Complete planetary-scale-capable camera behind one projection interface. flintlock's editor camera is not planetary. |
| 6 | **Deterministic lockstep netcode** | `multiplayer/*` (`Session`/`Player` authority, sealed `Command`/`CommandBatch`), `usecases/apply_commands.dart`, `authoritative_simulation.dart`, `client_simulation.dart`, `adapters/network/loopback_channel.dart` | payload types space-typed; *architecture* generic | Textbook predict/reconcile/replay + ownership validation + documented determinism contract. Extract by parametrizing command + snapshot types. |
| 7 | **Length-prefixed frame transport** | `infrastructure/bridge/frame_protocol.dart` | imports only `dart:typed_data` | uint32-LE framing + incremental `FrameParser` (reassembles across TCP segments, rejects oversize). Reusable IPC for any external renderer/netcode. Lift as-is. |
| 8 | **Infra primitives** | `ports/event_bus.dart` + `adapters/events/in_memory_event_bus.dart` (`drainRecent`), `simulation/epoch.dart`, `dynamics` covered in #3, `shared/units.dart` | event bus typed to a generic `DomainEvent` base | Small, generic, useful. `drainRecent` (fold a tick's events into a frame) is a nice idiom. |

## Tier 2 — extract with a seam (generic mechanism, space-flavored today)

Real reusable machinery, but currently reads a space type. Split at the noted seam.

| What | Files | The gem | The seam to cut |
|---|---|---|---|
| **Polyline rendering** | `flutter_scene/line_nodes.dart` | Copy-on-write fresh-geometry-per-frame, retire-by-wallclock, screen-space densify + Catmull-Rom — engineered around GLES buffer-in-flight tearing | Feed it "a list of world polylines"; leave orbit/trajectory/SOI content behind |
| **Instanced billboards / sprites** | `flutter_scene/ring_nodes.dart` (`_RockField`), `star_bloom_nodes.dart`, `exhaust_nodes.dart` | Hardware-instanced field + `BillboardGeometry` far field + the **1 MiB transient-arena instance ceiling**; depth-*tested* additive glow (occlusion with no post pass); throttle-driven emitter (floating-origin-safe) | "swarm of instances", "occludable glow at a point", "emitter on a moving node" |
| **Out-of-process render bridge** | `infrastructure/bridge/{sim_bridge,sim_bridge_io,sim_socket_server}.dart` | Fixed-tick server broadcasting opaque byte world-frames to N clients, ingesting opaque command-frames back; robust connect/drop; `descriptorEveryTicks` sticky-resend bandwidth trick | byte-in/byte-out `SimBridge` interface; leave the FlatBuffer/space codec as the plug-in |
| **Compute offload** | `ports/compute_port.dart` | Isolate/FFI/Rust boundary for heavy numeric work — keep the generic `integrate(state, forces, mass, dt)` | Drop the Kepler `propagate(Orbit)` methods, or generalize to a `PropagationStep` |
| **Scene reconciliation** | `flutter_scene/scene_render_view.dart`, the diff pattern in `scene_sync.dart` | Static-init gating, per-vsync frame-coalescing guard, `Transform.flip` chirality fix; id-keyed persistent nodes with diff create/remove | the widget host pattern is reusable; `scene_sync`'s orchestration body reaches celestial concepts throughout — take the pattern, not the file |
| **Shader gems** | `shaders/terrain.frag` (cascade PCF/PCSS shadow port + `terrain_nodes._packShadow` uniform packing), `atmosphere.frag`, `ring.frag` | Self-contained given their uniform blocks; the shadow-map packing against a custom `ShadowInfo` block is the reusable part | atmosphere/ring are portable to any *planetary* engine as-is |
| **Small utilities** | `scene_textures.dart` (lazy GPU-texture cache w/ retry), `sphere_geometry_util.dart` (Z-up UV sphere), `terrain/terrain_textures.dart` (procedural tiles + mip-chain) | near-zero coupling | — |

## Tier 3 — project-specific (stays in acro)

Everything else. Confirmed space/KSP-only, no hidden engine gem:

- **Orbital + universe:** `domain/orbits/*`, `domain/universe/*` (Kepler, SOI, ephemeris, real solar system, celestial bodies, atmosphere model).
- **Vessels + flight:** `domain/vessel/*`, `vehicles/*`, `parts/*` (rigid-body assembler baking placed rocket parts), `flight/*`, `aerodynamics/*`.
- **Environment physics:** `thermal/*`, `weather/*`, `radiation/*`, `lifesupport/*`.
- **Base-building genre logic:** `colony/*` (Cities-Skylines RCI), `mining/*`, `agriculture/*`, `megastructure/*`, `power/*`, `comms/*` (LOS relay graph).
- **Autonomy = KSP autopilot, NOT general AI.** The biggest domain module (13 files), but it is quaternion attitude control + Hohmann/plane-change planning + docking guidance — every file binds `Vessel`/orbital frames. **Nothing** flintlock's `zombie_ai` would share.
- **The space orchestration:** `usecases/advance_simulation_tick.dart` (~45 hard-imported domain services, hardcoded phase order, rails-vs-physics mode select), `world_snapshot.dart` payload types, `game_state_codec.dart`, `adapters/wire/*` FlatBuffers schema.
- **Screens:** all of `infrastructure/flutter/screens/*`.

**Generic *patterns* present but not worth porting** (small + space-welded): `science/TechTree`
(prereq-graph unlock), `contracts/*` (quest/objective board), `economy/Treasury` (funds
ledger), and the tile-grid/footprint-placement core buried in the 6963-line
`city_builder_screen.dart`. If flintlock ever wants generic progression/quest/economy or a
tile-placement editor, re-implement these fresh — do not port the space-coupled versions.
`elements/*` is a real periodic table but purpose-built for crustal-abundance ore veins,
not generic crafting.

---

## Terrain — a special case worth its own decision

Both repos have "terrain" and the names collide, but the machinery does **not** — they are
the **far and near halves of one planet system**, not competing implementations:

| | flintlock | acro |
|---|---|---|
| Representation | cube-sphere **heightfield** (1 scalar/direction, 2.5D) | **voxel signed-density** isosurface (full 3D) |
| Caves/overhangs/dig | impossible | representable by design |
| Meshing | fixed grid triangulation | **Naive Surface Nets** (variable topology) |
| Scope | whole planet, one bake | one 125 m-voxel chunk under the camera |
| LOD | none (and no plan) | none yet — `terrain-lod.md` plans it |
| Erosion / rivers / biome color | **yes** (thermal + hydraulic droplet + flow-accumulation) | none |
| Authoring | gizmo feature-stamps + spline rivers | seed-only procedural |
| Shading | baked per-vertex color, no textures/shadows | triplanar textures + cascaded shadows |

**Density is a superset of heightfield** (acro already emulates a heightfield inside its
field as `|p| - (radius + height(dir))`), so voxel is the strictly-more-general
representation — but naively replacing flintlock's grid with voxels throws away its
erosion, rivers, stamps, and cheap bounded whole-planet mesh.

**Clean extractions from acro (verified pure):** `domain/terrain/surface_nets.dart`
(imports only `dart:math`/`dart:typed_data`; header: "Knows nothing about spheres,
planets, LOD") and `noise3.dart` (no imports). `terrain_field.dart` extracts as a
general spherical-heightfield density adapter.

**Two actionable consequences for [terrain-lod.md](terrain-lod.md):**
1. **Borrow, don't re-derive.** flintlock already solved cube→sphere face projection
   (`_faceBases`/`direction()`) and cross-face seam reconciliation (`buildSeamGroups`/
   `stitchSeams`). acro's plan §8 lists exactly those as tests-to-write. Lift the helpers.
2. **Consider sharing the sculpt.** flintlock's erosion/rivers/stamps all operate on a
   heightfield, so they can run as a bake producing the `direction → height` function that
   acro's `TerrainField` samples. flintlock sculpts + erodes; acro's density meshes it up
   close (Surface Nets) while flintlock's grid meshes it far. Unifies both without
   discarding either.
3. **Pick one noise basis.** They disagree today — flintlock Perlin/gradient, acro value/hash.

---

## Recommended next steps (in order)

1. **Extract Tier-1 #1 + #2 together** (large-world precision + floating origin) into a
   shared package. Cleanest cut, immediately unlocks planetary scale in flintlock.
2. **Extract Tier-1 #3 + #4** (dynamics core + shader pipeline) — both zero-coupling.
3. **Decide the terrain unification** (heightfield-far + voxel-near) before building
   `terrain-lod.md` — it changes that plan's phase 4a.
4. Netcode (#6), bridge (#7), and the Tier-2 seams are worth doing only when flintlock
   actually needs multiplayer / an external renderer / orbit-line-style rendering.

**Not yet decided (needs your call):** whether the shared code lives as a **new package**
both repos depend on, or is **copied** into flintlock. A package keeps them in sync but
couples release cadence; a copy diverges but frees each. Given both are pre-1.0 and
personal, a copy is probably right for now — revisit if the shared surface grows.
