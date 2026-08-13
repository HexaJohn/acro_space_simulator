# Voxel Terrain — Full-Planet LOD (phase 4)

**Status:** 4a + 4b + 4c landed (see §7); 4d outstanding. **Scope:** replace the single chunk
under the craft with cubed-sphere terrain over the whole body, voxel resolution
degrading with camera distance.

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
| 4a ✅ | Cubed-sphere addressing + quadtree + LOD select + 2:1 balance. Fixed ring of chunks around the sub-camera point, still synchronous. | Unit tests on addressing/neighbour/balance. No renderer change visible beyond more ground. |
| 4b ✅ | Skirts. | Visual gate accepted on the positive half only — see below. |
| 4c ✅ | Async scheduler + upload budget. | No frame hitch on a fast descent. |
| 4d | Full-planet coverage + sphere handoff. | Orbit → landing with no pop. |

Each phase ships independently. **4d is the one to start.**

### What 4c shipped

Two independent fixes, either of which alone would have moved the needle;
together they took a Moon chunk from 108–335 ms ON the render thread to ~12–20
ms OFF it (debug JIT; release is faster still).

- **Column-cached meshing** (`cell_mesher.dart`). The base relief is a height
  field — density along a radial is `r - (radius + h(dir))` and `h` depends only
  on direction — so `h` is evaluated once per lateral column instead of once per
  voxel (~50× fewer field evaluations for a 24×24×~50 chunk; the erosion fBm +
  ridged blend + crater walk in `h` is where all the time was). The same lattice
  replaces the old 17×17 band probe, and vertex normals on unedited ground come
  from the height-field tangent cross product (zero field evaluations) instead
  of six-tap density differences. Edited columns (`TerrainEdits.at` per column,
  resolved once) keep the exact per-voxel compose + density-gradient normals —
  the 3D CSG cannot be column-collapsed.
- **`TerrainMeshScheduler`** (`mesh_scheduler.dart` + `_isolate`/`_sync`
  bindings via conditional import, per §0.2). Native meshes each chunk with
  `Isolate.run` (the field is plain seed-driven data, so the closure copy is
  cheap and the determinism test in `mesh_scheduler_test.dart` gates it); web
  gets the inline scheduler. `TerrainNodes` submits nearest-first up to
  `meshBudgetPerFrame` jobs IN FLIGHT, and turns results into nodes under
  `uploadBudgetPerFrame` per painted frame — the upload is now the only
  streaming work on the render thread. No cancellation: in-flight results are
  dropped by a generation check (body switch, geometry knob, new edit all bump
  it), and chunks that mesh to nothing are remembered per generation so they
  are not resubmitted every frame. `ext.acro.terrain?asyncMeshing=false` is the
  A/B back to inline meshing.

LRU eviction was NOT built: the resident cap + nearest-first truncation from 4a
already bounds residency, and chunks outside `wanted` are retired immediately —
there is nothing left to age out. Revisit only if re-mesh churn at the horizon
ever shows up in practice.

### What 4b shipped, and what its gate actually covers

`_addSkirt` in `cell_mesher.dart` is verified geometrically: the apron closes
every open edge among surface vertices, hangs inward by its depth, and that depth
out-reaches how far the ground moves over one COARSE voxel (the 2:1 bound) at
levels 5/7/9. Depth defaults to 2.5 voxels, not the §3 "one voxel" — 2:1 balance
means the neighbour's voxels are twice ours, so one of ours cannot span the worst
case. Cost is ~28% more triangles (128.6k vs 100.3k on a 50-chunk ring).

A nadir capture at 100 km (50 chunks, levels 5–6) shows continuous terrain with
no cracks. The negative control — same framing, `skirtVoxels=0` — was **not**
shot, so what is established is "skirts do not break anything", not "skirts fix
the cracks". That was accepted deliberately, not overlooked: cracks had not been
observed as a problem in the first place, and the geometric tests bound the case
the apron exists to cover.

If cracks ever DO show, run the A/B before touching the mesher —
`ext.acro.terrain?skirtVoxels=0` toggles it live (resident chunks re-mesh on the
change), so it is two commands. Only reach for Transvoxel (§3) after seeing a
crack that a deeper skirt cannot hide.

### What 4a actually shipped

`domain/terrain/cubed_sphere.dart` (addressing), `terrain_lod.dart` (hysteretic
quadtree + `enforceBalance` + `isBeyondHorizon`), `cell_mesher.dart` (thin-shell
`(s, t, r)` mesher), and a `Map<ChunkKey, _ResidentChunk>` in `TerrainNodes`.

Two notes for whoever picks up 4b:

- **Seam neighbours are derived, not stepped.** Stepping one cell in `(s, t)` and
  re-projecting lands exactly ON a cell boundary near face corners (at `n=4`, a
  corner cell projects to `t' = 0.5`). The transform is instead read off the face
  bases, giving coordinates that are exactly `±1` and `±a`. Do not "simplify" it
  back.
- **Two pre-existing blockers found while verifying.** The adaptive near plane is
  `(range + bodyRadius)/20`, so a BODY focus clips everything within ~87 km on the
  Moon and terrain is invisible at any altitude — only vessel focus works. And on
  macOS the app is sandboxed, so `ext.acro.screenshot` can only write under
  `~/Library/Containers/com.example.acroSpaceSimulator/Data`.

## 8. Tests

Domain (no Flutter): cubed-sphere face/uv round-trip; neighbour lookup across face
seams (the corner cases are where this breaks); 2:1 balance invariant after random
split/merge sequences; chunk-centre → ground-radius agreement with `TerrainField`;
determinism (same key → identical mesh).

Render: extend `test/screenshots/` — per the `sphere-render-debugging` memory, LOOK at
it, do not reason about it.
