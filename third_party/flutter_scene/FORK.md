# flutter_scene — vendored fork

Upstream: https://github.com/bdero/flutter_scene, `packages/flutter_scene` at
commit `d3ebfb6a589b475e08b3acce43a71ce8c5f0b72f` (2026-06-30, pub 0.18.1+).
Vendored 2026-09-05 as a path dependency so the renderer's per-draw and
per-frame costs can be fixed at the source (the pin was already a git ref,
so nothing changed for pub except the URL). `example/`, `test/` and
`screenshots/` are not carried; `resolution: workspace` was dropped because
the package no longer lives in the upstream pub workspace.

Upstream fixes must be merged by hand. Keep this list current — one line per
patch, newest last — so a future pin bump knows what to re-apply.

## Binding persistence (the premise of the encoder patches)

The encoder patches below rely on a `gpu.RenderPass` keeping its bindings
across `draw()` calls until `clearBindings()`. Verified 2026-09-05 against
the pinned flutter_gpu
(`C:/Users/johnj/fvm/versions/84af28a0646eb00c06b5556be0d28e5e32cdf1c7/bin/cache/pkg/flutter_gpu/lib/src/render_pass.dart`):

- The Dart `RenderPass` tracks which vertex slots are bound in
  `_boundVertexSlotsMask` / `_maxBoundVertexSlot` (L349–L354). They are set by
  `bindVertexBuffer` (L435–L455, the mask at L445) and reset **only** by
  `clearBindings` (L529–L533). `draw` (L648) and `drawIndexed` (L678)
  validate the mask (`_validateVertexBindings`, L692) and record the draw
  without touching it, so a second `draw` after one `bindVertexBuffer` is
  valid by construction: the Dart side is written for bindings that outlive a
  draw.
- Uniform and texture binds (`bindUniform` L470, `bindTexture` L482) go
  straight to the native pass with no per-draw bookkeeping, and
  `clearBindings` (`_clearBindings`, native) is the only reset the API offers;
  a separate reset entry point only makes sense when a draw does not reset.
  (The native `flutter::gpu::RenderPass` keeps the vertex/index buffer and
  the uniform and texture binding maps as members that `Draw()` copies into
  each command and `ClearBindings()` empties — the engine source is not in
  the SDK cache, so this is stated from the engine tree rather than a local
  line reference.)
- The vendored WebGL2 backend (`lib/src/gpu/web/render_pass.dart` L635–L647)
  states the same contract in its `clearBindings` comment: per-draw resource
  bindings persist and only the pipeline survives a clear; its vertex
  attribute, uniform and texture state is plain GL state that outlives a
  `drawElements`.

`bindPipeline` is likewise not undone by `clearBindings` on any backend; the
encoders already relied on that.

## Patches

- `lib/src/gpu/render_pass_compat.dart` — the `(pass as dynamic)` try/catch
  shims call the pinned flutter_gpu signatures directly (`bindVertexBuffer(v,
  slot:)`, `bindIndexBuffer(v, type)`, `draw(n, instanceCount:)`,
  `drawIndexed(n, instanceCount:)`; the web and stub backends match). Saves a
  dynamic member lookup and argument boxing on ~6 calls per draw. Helper names
  and parameters unchanged.
- `lib/src/geometry/geometry.dart` — `Geometry.isIndexed` and
  `Geometry.bindsUnskinnedFrameInfo` (true for `UnskinnedGeometry` and its
  subclasses, which do not override `bind`) let the encoders split the
  unskinned bind into `bindGeometryBuffers` (per draw) and the camera block;
  `emplaceUnskinnedFrameInfo` + `UnskinnedFrameInfo` emplace the 19-float
  block once per pass and rebind its view (one native call, only after a
  clear). `bindUnskinnedFrameInfo` and `bind()` keep their old behaviour for
  the depth prepass, object filter, skinned and billboard paths. Saves one
  Float32List, one emplace and one slot lookup per draw.
- `lib/src/scene_encoder.dart` — opaque draws sort by (pipeline, material,
  depth) and run-bind: consecutive draws with the same pipeline, material and
  LOD fade skip `clearBindings`, `material.bind` and the camera block and
  bind only their streams, index buffer and instance transform (a run breaks
  at an indexed/non-indexed boundary and for non-separable geometry;
  translucent draws keep the per-draw path). Winding and primitive type are
  set only when they change. `SceneFrameStats` (exported) counts colour
  draws, material binds and packed instances. For the 127k-building colony
  (7 materials, one pipeline) this removes ~30 native calls and ~40
  allocations from all but 7 opaque draws per frame.
- `lib/src/render/shadow_encoder.dart` — `clearBindings` only when the
  pipeline changes, at an indexed boundary, or for a skinned caster; the
  light-space block is emplaced once per cascade and bound once per clear;
  winding/primitive set on change; counts shadow draws and packed instances.
- `lib/src/render/shadow_pass.dart`, `lib/src/render/scene_pass.dart`,
  `lib/src/scene.dart`, `lib/scene.dart` — `Scene.lastFrameStats`
  (`SceneFrameStats`: colour/shadow draw counts, packed instances, material
  binds, BVH rebuilds, pre-pass/BVH/shadow/colour milliseconds) accumulated
  per frame and published at the end of `renderViews`. `bvhRebuilds` stays 0
  until `RenderScene.lastRebuildWasFull` exists (owned by the culling-
  structure patch).
- `lib/src/material/material.dart` — `Material.uniformSlot(name)` caches
  `UniformSlot`s per fragment shader (dropped when the shader changes) for the
  built-in materials and app subclasses.
- `lib/src/material/engine_lighting.dart` — every `SamplerOptions` is a
  static final (was ~8 allocations per lit draw); `slotOf(shader, name)`
  caches slots per shader in an `Expando`. Sampler settings unchanged.
- `lib/src/material/physically_based_material.dart` — one `Float32List(164)`
  FragInfo per material, zeroed and refilled in place; cached slots;
  `baseColorSampler` (null = the repeat default) so a subclass can pick
  trilinear/anisotropic albedo filtering without binding `base_color_texture`
  twice per draw (the app's `_CitySurfaceMaterial` switches to it separately).
- `lib/src/material/unlit_material.dart` — one FragInfo list per material,
  static repeat sampler, cached slots.
