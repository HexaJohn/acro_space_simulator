# Voxel Terrain — Full-Planet LOD (phase 4)

**Status:** design, awaiting go-ahead. **Scope:** replace the single chunk under the
craft with cubed-sphere terrain over the whole body, voxel resolution degrading with
camera distance.

Today `TerrainNodes` meshes exactly ONE axis-aligned box at the sub-camera surface
point (`chunkSizeM = 6000`, `resolution = 48`, only below `maxAltitudeM = 60000`) and
re-anchors when the focus drifts >0.4 chunk. Everything below is the step from that to
a planet.

---

## 0. Constraints (verified, do not violate)

These are the ones that actually shape the design:

1. **No `sampler3D` / texture arrays / compute shaders** on this pin. The density field
   stays CPU-side (`TerrainField` already is).
2. **No isolates on web** — `compute()` runs on the main thread there. Any meshing
   scheduler MUST be behind an interface with a native (isolate) and a web
   (time-sliced main thread) implementation. Do not call `compute()` directly.
3. **GPU write discipline** (learned the hard way, see `flutter-scene-backend` memory):
   never mutate in-flight buffers. Build fresh geometry and swap; retire replaced
   meshes by WALL CLOCK (~400 ms), not frame counts. Touch the GPU once per painted
   frame, never inside `SceneView`'s repaint ticker.
4. **Depth**: near plane is adaptive (`d/20`). Terrain far chunks must not depend on
   fine depth precision at range — see §6.
5. **DDD**: field/meshing math in `domain/terrain/` with zero Flutter imports; all
   GPU/`ui.Image` work in `infrastructure/`.

## 1. Chunk addressing — cubed sphere + quadtree

Replace the single body-fixed box with a **cubed sphere**: 6 root faces, each a
quadtree. A chunk is identified by `(face, level, u, v)`.

- Chunk shell: mesh only the voxel band that can contain the isosurface —
  `[groundRadius - amplitude - margin, groundRadius + amplitude + margin]` — not a
  solid box to the core. At high levels this band is thin; that is what keeps the
  voxel count bounded.
- Keep the mesh in the **body-fixed frame** (as today) so terrain co-rotates and the
  landed-craft co-rotation fix keeps working.
- Voxel grid per chunk stays fixed (e.g. 32³ or the current 48³). **Resolution is
  constant per chunk; LOD comes from chunk SIZE**, which is what "degrade with
  distance" means here. This is the key simplification — do not try to vary grid
  resolution within a chunk.

## 2. LOD selection

Split a chunk when its projected size exceeds a screen-space budget:

```
splitIf: camera.radiusPx(chunkCentreRel, chunkHalfSizeM) > kSplitPx   // ~200 px
mergeIf: ... < kSplitPx / 2.2                                          // hysteresis
```

Use the existing `SceneCamera.radiusPx` — it is the same apparent-size machinery the
rail culls use, so LOD and culling agree. **Hysteresis is mandatory**: a bare threshold
thrashes split/merge on the frame boundary and every flip is a remesh + GPU upload.

Enforce a **2:1 balance** (restricted quadtree): no chunk may neighbour one more than
one level apart. This bounds the seam cases to a single class and is a precondition
for §3.

## 3. Seams (the hard part)

Surface Nets across an LOD boundary leaves **cracks** — the two sides sample the field
at different rates and their vertices do not meet.

- **First cut: skirts.** Extend a downward apron one voxel deep around each chunk's
  perimeter. It hides cracks, costs almost nothing, and needs no change to the mesher.
  Standard practice, and it does not block anything later. **Recommended.**
- **Later, if skirts show:** Transvoxel (Lengyel tables, transvoxel.org) gives true
  crack-free transitions. Note this is a **real cost**: Transvoxel is defined over
  Marching Cubes, and `surface_nets.dart` is Naive Surface Nets — adopting it means a
  second mesher, not a tweak. Do not start here.

Do not attempt "just snap boundary vertices" — it fails on the 2:1 diagonal cases and
you will chase it for days.

## 4. Streaming + budget

- **Async meshing** behind `TerrainMeshScheduler` (native: isolate; web: time-sliced).
  `TerrainField` is deterministic and seed-driven, so a chunk can be meshed off-thread
  from `(face, level, u, v, seed)` alone — no shared mutable state. Verify this stays
  true; determinism is what makes the isolate path safe.
- **Budget the uploads**, not the meshing: cap N chunk swaps per painted frame (start
  N=2) so a fast descent cannot stall a frame. A backlog is fine; a hitch is not.
- **LRU eviction** with a cap (start ~256 live chunks). Evict by "not visible + oldest".
- flutter_scene master ships `MeshData` isolate-transfer + dirty-range uploads; worth a
  look before hand-rolling the transfer.

## 5. Handoff to the sphere

The textured sphere (`BodyNodes`) currently renders behind the single chunk. With
full-planet terrain the two overlap everywhere, so:

- Terrain covers the body out to the coarsest useful level; the sphere stays as the
  far/fallback representation.
- **Blend, do not pop**: fade the sphere out only where terrain chunks are resident, or
  keep the sphere strictly inside the terrain's minimum ground radius so it can never
  poke through. The second is cheaper and less fragile — prefer it.
- `maxAltitudeM = 60000` goes away as a hard gate; it becomes "coarsest level only".

## 6. Risks

- **Voxel count.** This is the whole ballgame. One 48³ chunk today → potentially
  thousands. The thin-shell band (§1) plus level caps are what keep it finite. Measure
  before widening any constant.
- **Depth at range.** Coarse far chunks sit at planetary distance where the quantum is
  metres-to-tens-of-metres; keep the sphere handoff (§5) well inside that so a fight is
  impossible.
- **Float32.** Chunk centres are rebased through the floating origin already; keep all
  chunk math in doubles until the final `relToScene` cast.
- **Web.** No isolates. If the web build cannot hold frame rate, gate full-planet LOD
  to native and keep the single chunk on web.

## 7. Phasing

| Phase | Deliverable | Gate |
|---|---|---|
| 4a | Cubed-sphere addressing + quadtree + LOD select + 2:1 balance. Fixed ring of chunks around the sub-camera point, still synchronous. | Unit tests on addressing/neighbour/balance. No renderer change visible beyond more ground. |
| 4b | Skirts. | Visual: no cracks at a level boundary. |
| 4c | Async scheduler + upload budget + LRU. | No frame hitch on a fast descent. |
| 4d | Full-planet coverage + sphere handoff. | Orbit → landing with no pop. |

Each phase ships independently. **4a is the one to start.**

## 8. Tests

Domain (no Flutter): cubed-sphere face/uv round-trip; neighbour lookup across face
seams (the corner cases are where this breaks); 2:1 balance invariant after random
split/merge sequences; chunk-centre → ground-radius agreement with `TerrainField`;
determinism (same key → identical mesh).

Render: extend `test/screenshots/` — per the `sphere-render-debugging` memory, LOOK at
it, do not reason about it.
