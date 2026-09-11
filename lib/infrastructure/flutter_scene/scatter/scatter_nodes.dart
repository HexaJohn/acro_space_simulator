// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;

import '../../../adapters/presenters/camera_view.dart';
import '../../../application/snapshot/world_snapshot.dart';
import '../../../domain/colony/city/road_elevation.dart';
import '../../../domain/scatter/prop_catalog.dart';
import '../../../domain/scatter/prop_model.dart';
import '../../../domain/scatter/scatter_instance.dart';
import '../../../domain/scatter/scatter_layer.dart';
import '../../../domain/scatter/scatter_mask.dart';
import '../../../domain/scatter/scatter_placement.dart';
import '../../../domain/scatter/scatter_scheduler.dart';
import '../../../domain/shared/quaternion.dart';
import '../../../domain/shared/vector3.dart';
import '../../../domain/terrain/cubed_sphere.dart';
import '../../../domain/terrain/terrain_brush.dart';
import '../../../domain/terrain/terrain_edits.dart';
import '../../../domain/terrain/terrain_field.dart';
import '../../../domain/terrain/terrain_feature.dart';
import '../../../domain/planetary/planet_surface.dart';
import '../../../domain/universe/real_solar_system.dart';
import '../body_nodes.dart';
import '../coord_convert.dart';
import 'scatter_prop_library.dart';

/// Draws the scattered props on the focused body's surface.
///
/// Mirrors [TerrainNodes] deliberately — same body-fixed frame, same
/// snapshot-replayed edits, same per-frame node transform — because props and
/// the ground under them must agree exactly, and the surest way to make two
/// systems agree is to have them do the same thing from the same inputs.
///
/// Cell residency is keyed by `(layer, ChunkKey)` at each layer's own
/// generation level, NOT at the terrain quadtree's leaf levels. Those levels
/// answer a different question: terrain splits by how many pixels a chunk
/// covers, while a scatter layer's level is fixed by its density (see
/// [ScatterLayer.levelFor]). Tying scatter to terrain's leaves would re-dice
/// the whole field every time the camera moved and reshuffle every prop with
/// it.
class ScatterNodes {
  ScatterNodes(this._scene) {
    // An imposter bake landing must reach the NEXT rebuild: the first build
    // typically runs while cards are still baking, and those instances are
    // skipped rather than drawn white — without this they'd stay missing
    // until a cell happened to churn.
    ScatterPropLibrary.instance.addListener(_onLibraryChanged);
  }

  final fs.Scene _scene;

  void _onLibraryChanged() => _dirty = true;

  /// Runtime kill switch (debug panel / dev ext).
  static bool enabled = true;

  /// Global density multiplier — the first knob to reach for when a surface
  /// costs too much. 0 draws nothing without changing any layer.
  static double densityScale = 1.0;

  /// Cell-generation jobs in flight at once. Generation runs on background
  /// isolates on native (inline on web) — a cell is 5-30 ms of field
  /// sampling, and doing several INLINE per frame was a visible hitch on
  /// every walk into fresh ground. This caps CPU occupancy, not a per-frame
  /// stall (same discipline as [TerrainNodes.meshBudgetPerFrame]).
  static int cellBudgetPerFrame = 6;

  /// Kill switch: false forces inline generation for A/B from the dev ext.
  static bool asyncGeneration = true;

  /// Isolates in the generation pool. Two suits a flight; a static camera over
  /// a colony has cores to spare and a wider region to fill.
  static int workerCount = 2;

  /// Highest eye altitude (m) at which props draw at all. Above it the biggest
  /// tree is well under a pixel.
  static double maxAltitudeM = 4000;

  /// Multiplier on every layer's view distance.
  ///
  /// The shipped distances are tuned for a camera ON the ground — a walker
  /// sees 900 m of forest and that is generous. A city-builder camera sits a
  /// kilometre back and looks across the whole colony, where the same number
  /// draws a small island of trees around the pivot and bare ground beyond it.
  /// Cost grows with the AREA, so this is a knob and not a new default.
  static double viewDistanceScale = 1.0;
  double _builtViewScale = 1.0;

  /// Anchor the scatter on the camera's FOCUS rather than its eye.
  ///
  /// The eye is the right anchor when it is the thing moving through the world
  /// (a walk, a flight). Under an orbit camera it is not: the eye swings on a
  /// boom while the player's attention stays on the point it circles, so
  /// anchoring there streams cells in and out on every drag and centres the
  /// loaded region a boom-length away from what is being looked at.
  static bool anchorAtFocus = false;

  /// How far the anchor may drift before instance offsets are rebased (m).
  /// Instances are stored relative to it so their transforms stay small enough
  /// for float32; re-anchoring rewrites every transform, so it is quantised
  /// rather than following the camera continuously.
  static double anchorGridM = 256;

  static String debugLine = '';

  /// Built ground on the focus body, rebuilt from the FRAME when the colony
  /// changes shape. See [ScatterMask].
  ScatterMask? _mask;
  int _maskSig = 0;

  /// [roadMaskSignature] of the roads the live mask was built from: what
  /// says a road was drawn, moved, widened or removed (see [_refreshMask]).
  int _maskRoadHash = 0;

  /// Building sites the live mask was built from, by id. Kept for ONE reason:
  /// to work out what changed when it is rebuilt (see [_maskSitesMoved]).
  final Map<String, (Vector3, double)> _maskSites = {};

  /// Ceiling on masked features. A colony of a hundred thousand buildings
  /// would otherwise rebuild a multi-megabyte capsule list every time one more
  /// grew; past this the mask keeps the roads (which is what the props
  /// actually stand in the middle of) and stops adding lots.
  static const int _maxMaskFeatures = 20000;

  /// Extra clearance around a road corridor, metres — a verge, so a trunk does
  /// not overhang the kerb it was placed beside.
  static const double _roadMarginM = 3.0;

  /// Which gate suppressed scatter this frame, or '' when it drew.
  static String gateReason = '';

  final Map<_CellId, _CellData> _cells = {};
  final Map<_BatchKey, fs.Node> _batches = {};
  final Map<PropKind, _ImposterBatch> _imposters = {};

  // --- Async generation state (mirrors TerrainNodes' meshing state) --------
  ScatterGenScheduler? _scheduler;
  bool _schedulerAsync = true;
  int _schedulerWorkers = 2;
  final Set<_CellId> _pendingCells = {};

  /// In-flight cells a new edit overlaps — their placement sampled the
  /// pre-edit field, so their results are dropped on arrival.
  final Set<_CellId> _stalePending = {};

  /// Resident cells an edit or a new road made stale, still drawn until
  /// their regeneration lands. Dropping them at once blinked the forest out:
  /// a road re-scatters the whole colony, so every prop in view vanished for
  /// the seconds regeneration took. Props the new ground now covers are
  /// taken off a stale cell at once (see [_filterByMask]); the rest stand
  /// until the fresh cell replaces them.
  final Set<_CellId> _staleCells = {};

  /// This frame's wanted set; an arriving cell not in it is dropped rather
  /// than parked (regeneration is cheap and deterministic).
  Set<_CellId> _wantedNow = const {};

  /// Bumped on [_clear] (body switch); results tagged with an older epoch
  /// are another body's props.
  int _genEpoch = 0;

  /// Per-layer cache of the cell set around the anchor, keyed by the cell
  /// the anchor direction falls in at the layer's own level. `_cellsWithin`
  /// is ~700 chunkAt probes per layer; the answer only changes when the
  /// anchor crosses into a new cell, so recomputing it per frame bought
  /// nothing.
  final Map<int, (ChunkKey, Set<ChunkKey>)> _wantedCache = {};

  String? _bodyId;
  TerrainEdits? _edits;
  int _builtEditCount = -1;
  Vector3 _anchorBF = Vector3.zero;
  bool _dirty = true;

  /// Eye-to-anchor distance (m) at the last batch build — the LOD refresh
  /// trigger. Levels are chosen inside the rebuild, so without this the
  /// selection made at the FIRST build (often from the spawn camera, 150 m+
  /// out, where everything resolves to a billboard) froze until a cell
  /// happened to churn: walking right up to a rock never promoted it to a
  /// mesh.
  double _builtEyeM = double.nan;

  /// The body's composed detail layer, cached per body exactly as
  /// [TerrainNodes] caches its own — assembling the feature stack every frame
  /// is the expensive part of the field.
  TerrainDetail? _detail;
  String? _detailBodyId;

  /// Cached fields, mirroring [TerrainNodes]: base per body, edits composed
  /// via [TerrainField.withEdits]. A stable base instance is what lets the
  /// pooled scatter scheduler ship the DEM to its workers once instead of
  /// per job.
  TerrainField? _baseField;
  TerrainField? _composedField;
  Object? _composedEditsId = _unset;
  static const Object _unset = Object();

  /// Cached edit-aware ground radii under the eye (altitude gate) and the
  /// anchor (focus point). `groundRadiusAt` RAYMARCHES wherever an edit
  /// covers the ray — which over a colony pad is every frame, for ground
  /// that moves only when an edit lands or the point drifts.
  Vector3 _groundEyeBF = const Vector3(double.infinity, 0, 0);
  double _groundEyeR = 0;
  Vector3 _groundAnchorBF = const Vector3(double.infinity, 0, 0);
  double _groundAnchorR = 0;

  int _instanceCount = 0;
  int _drawCalls = 0;

  void update(
    WorldSnapshot snap,
    FloatingOrigin origin, {
    required Vector3 cameraEye,
    SceneCamera? camera,
    String? focusBodyId,
    String? focusVesselId,
  }) {
    if (!enabled || !ScatterPropLibrary.texturesReady) {
      gateReason = enabled ? 'textures not ready' : 'disabled';
      _clear();
      return;
    }

    final bodyId = focusBodyId ??
        (focusVesselId == null ? null : snap.vessels[focusVesselId]?.body);
    final b = bodyId == null ? null : snap.bodies[bodyId];
    final d = bodyId == null ? null : snap.descriptors[bodyId];
    if (b == null || d == null || !d.hasTerrain) {
      gateReason = 'no terrain body';
      _clear();
      return;
    }

    final bodyWorld = Vector3(b.px, b.py, b.pz);
    final eyeWorld = origin.focusWorld + cameraEye;

    // Same edits the terrain mesher and collision use, replayed from the
    // authoritative snapshot — so a crater that swallowed a tree swallowed it
    // for the physics too.
    var editCount = 0;
    var editsRebuilt = false;
    for (final e in snap.terrainEdits) {
      if (e.body == bodyId) editCount++;
    }
    if (_builtEditCount != editCount || _bodyId != bodyId) {
      editsRebuilt = true;
      final prevCount = _builtEditCount;
      final sameBody = _bodyId == bodyId;
      _edits = editCount == 0 ? null : snap.editsForBody(bodyId!);
      if (prevCount != editCount) {
        // An edit rewrote the ground: every cell it touches — resident OR in
        // flight — is stale. The store is append-only in tick order, so on
        // the same body the new brushes are exactly the tail; when that is
        // unknowable (body switch, count shrank) everything goes.
        if (sameBody &&
            _edits != null &&
            prevCount >= 0 &&
            editCount > prevCount) {
          _invalidateAround(_edits!.all.sublist(prevCount));
        } else {
          _cells.clear();
          _stalePending.addAll(_pendingCells);
          _dirty = true;
        }
      }
      _builtEditCount = editCount;
    }

    if (_bodyId != bodyId) {
      _clear();
      _bodyId = bodyId;
    }

    // The SAME field the terrain mesher draws, through the one shared builder.
    // Hand-rolling it here once omitted the detail layer, which seated every
    // prop on ground the mesher never drew — buried in crater rims or hovering
    // above valleys by the detail relief.
    if (_detailBodyId != bodyId) {
      _detail = d.buildTerrainDetail();
      _detailBodyId = bodyId;
      _baseField = null;
    }
    // Cached exactly as TerrainNodes caches its field: base per body, edits
    // composed by instance. The stable base identity is what the pooled
    // scheduler keys its "ship the DEM once" logic on.
    _baseField ??= d.buildTerrainField(detail: _detail)!;
    if (!identical(_composedEditsId, _edits)) {
      _composedField = _baseField!.withEdits(_edits);
      _composedEditsId = _edits;
    }
    final field = _composedField!;

    final bodyQuat = Quaternion(b.qw, b.qx, b.qy, b.qz) *
        Quaternion.axisAngle(Vector3.unitZ, BodyNodes.textureYawRad);
    final invQuat = bodyQuat.conjugate;

    // Altitude gate, against the GROUND under the eye — not the datum. With a
    // real DEM the datum is nowhere near the surface: a mare floor sits ~3 km
    // below it and the far-side highlands ~10 km above, so a datum-relative
    // altitude either never gates or gates a craft PARKED ON the ground.
    final eyeBF = invQuat.rotate(eyeWorld - bodyWorld);
    final eyeDir = eyeBF.lengthSquared > 0 ? eyeBF.normalized : Vector3.unitZ;
    // Edit-aware ground radius, cached against eye drift: over a colony pad
    // groundRadiusAt raymarches, and the answer only moves when an edit
    // lands or the eye leaves the neighbourhood. 5 m of drift against a
    // 4000 m gate cannot change the verdict.
    if (editsRebuilt || (eyeBF - _groundEyeBF).length > 5.0) {
      _groundEyeR = field.groundRadiusAt(eyeDir.x, eyeDir.y, eyeDir.z);
      _groundEyeBF = eyeBF;
    }
    final altitude = eyeBF.length - _groundEyeR;
    if (altitude > maxAltitudeM) {
      gateReason = 'altitude ${altitude.toStringAsFixed(0)}m';
      _clear();
      return;
    }
    gateReason = '';

    // Follow the vessel when there is one — that is what the player is looking
    // at, and scattering around the camera instead pops props in and out as the
    // view swings.
    final fv = focusVesselId == null ? null : snap.vessels[focusVesselId];
    // An orbit camera's subject is the point it circles, not the eye on the
    // boom — see [anchorAtFocus].
    var anchorWorld = anchorAtFocus ? origin.focusWorld : eyeWorld;
    if (fv != null) {
      final vb = snap.bodies[fv.body];
      if (vb != null) {
        anchorWorld = Vector3(vb.px + fv.px, vb.py + fv.py, vb.pz + fv.pz);
      }
    }
    final anchorBF = invQuat.rotate(anchorWorld - bodyWorld);
    final anchorDir = anchorBF.normalized;
    // Same caching as the eye's ground radius above — the anchor is a landed
    // craft for most of a session, sitting exactly on the pads whose brushes
    // make this a raymarch.
    if (editsRebuilt || (anchorBF - _groundAnchorBF).length > 2.0) {
      _groundAnchorR =
          field.groundRadiusAt(anchorDir.x, anchorDir.y, anchorDir.z);
      _groundAnchorBF = anchorBF;
    }
    final focusPoint = anchorDir * _groundAnchorR;

    final surface = _surfaceFor(bodyId!);
    if (surface == null) {
      gateReason = 'no climate model for $bodyId';
      _clear();
      return;
    }
    // Built ground. Rebuilt when the colony's shape changes, and the cells
    // dropped are only the ones NEAR what changed — a growing city gains a
    // building every few seconds, and clearing the whole field each time
    // regenerated every cell on the body over and over (the forest vanished
    // for a minute every time a house went up).
    final movedSites = _refreshMask(snap, bodyId);
    if (movedSites.isNotEmpty) {
      _invalidateNear(movedSites);
    }

    final placement = ScatterPlacement(
      field: field,
      surface: surface,
      bodySeed: d.terrainSeed,
      vegetationCap: d.terrainGrassAmount,
      mask: _mask,
    );

    // --- Cell residency ----------------------------------------------------
    // Per layer, the cell set around the anchor is cached against the cell
    // the anchor falls in at that layer's level — it cannot change without
    // the anchor crossing a cell boundary, and computing it fresh was ~700
    // chunkAt probes per layer per frame.
    // The wanted set is cached against the cell the anchor sits in, which
    // cannot notice the RANGE changing under it — a knob turned at runtime
    // (the city rig sets one on entry) has to drop the cache itself.
    if (_builtViewScale != viewDistanceScale) {
      _wantedCache.clear();
      _builtViewScale = viewDistanceScale;
    }

    final wanted = <_CellId>{};
    for (var li = 0; li < ScatterLayers.all.length; li++) {
      final layer = ScatterLayers.all[li];
      if (densityScale <= 0) break;
      final level = layer.levelFor(field.radius);
      final reachM = layer.viewDistanceM * viewDistanceScale;
      final anchorCell = chunkAt(anchorDir, level);
      var cached = _wantedCache[li];
      if (cached == null || cached.$1 != anchorCell) {
        final cells = <ChunkKey>{};
        for (final cell
            in _cellsWithin(anchorDir, reachM / field.radius, level)) {
          // Cells are picked by their own reach, so a cell whose centre is
          // past the view distance still joins when its near edge is inside.
          if (!cellInReach(cell, anchorDir, field.radius, reachM)) {
            continue;
          }
          cells.add(cell);
        }
        cached = (anchorCell, cells);
        _wantedCache[li] = cached;
      }
      for (final cell in cached.$2) {
        wanted.add(_CellId(li, cell));
      }
    }
    _wantedNow = wanted;

    for (final id in _cells.keys.toList()) {
      if (!wanted.contains(id)) {
        _cells.remove(id);
        _staleCells.remove(id);
        _dirty = true;
      }
    }

    // Submit missing cells to the scheduler, nearest first, up to the
    // in-flight cap. Results land in [_cells] from the arrival callback —
    // generation itself happens on a background isolate (see
    // scatter_scheduler.dart), which is what keeps a walk into fresh ground
    // from hitching: a cell is 5-30 ms of field sampling, and this loop used
    // to run several of them inline every frame.
    if (_scheduler == null ||
        _schedulerAsync != asyncGeneration ||
        _schedulerWorkers != workerCount) {
      _scheduler?.dispose();
      _scheduler = asyncGeneration
          ? ScatterGenScheduler.platform(workers: workerCount)
          : SyncScatterScheduler();
      _schedulerAsync = asyncGeneration;
      _schedulerWorkers = workerCount;
    }
    final missing = [
      for (final id in wanted)
        if ((!_cells.containsKey(id) || _staleCells.contains(id)) &&
            !_pendingCells.contains(id))
          id,
    ];
    if (missing.isNotEmpty && _pendingCells.length < cellBudgetPerFrame) {
      final distById = <_CellId, double>{
        for (final id in missing)
          id: (id.cell.centreDirection * field.radius - focusPoint).length,
      };
      missing.sort((x, y) => distById[x]!.compareTo(distById[y]!));
      for (final id in missing) {
        if (_pendingCells.length >= cellBudgetPerFrame) break;
        _submit(placement, id);
      }
    }

    // Re-anchor on a quantised grid: instance transforms are float32 and hold
    // metre-scale offsets, so the anchor has to stay near them — but moving it
    // rewrites every transform, so it only moves when the focus has genuinely
    // left its cell (the same discipline the ring debris field uses).
    final quantised = Vector3(
      (focusPoint.x / anchorGridM).roundToDouble() * anchorGridM,
      (focusPoint.y / anchorGridM).roundToDouble() * anchorGridM,
      (focusPoint.z / anchorGridM).roundToDouble() * anchorGridM,
    );
    if ((quantised - _anchorBF).length > 1e-3) {
      _anchorBF = quantised;
      // Cached instance matrices are anchor-relative — all stale now.
      for (final data in _cells.values) {
        data.matrices = null;
      }
      _dirty = true;
    }

    // LOD refresh: level selection happens inside the rebuild, so a camera
    // moving through a STATIC field (landed craft, orbiting eye) must retrigger
    // it — the relative gate keeps a slow zoom from rewriting every instance
    // per frame, same discipline as the lab preview.
    final eyeM =
        (eyeWorld - (bodyWorld + bodyQuat.rotate(_anchorBF))).length;
    if (zoomInvalidates(_builtEyeM, eyeM)) _dirty = true;

    if (_dirty) {
      _rebuildBatches(camera, origin, bodyWorld, bodyQuat, field.radius);
      _dirty = false;
      _builtEyeM = eyeM;
    }

    // --- Per-frame placement ------------------------------------------------
    // Every batch shares the anchor, so one transform per node per frame keeps
    // the whole field pinned to a spinning planet.
    final transform = batchTransform(origin, bodyWorld, bodyQuat, _anchorBF);
    for (final node in _batches.values) {
      node.localTransform = transform;
    }
    for (final imposter in _imposters.values) {
      imposter.node.localTransform = transform;
    }

    debugLine = 'scatter: $_instanceCount props, $_drawCalls draws, '
        '${_cells.length} cells';
  }

  // ---- Batching -----------------------------------------------------------

  /// Group every resident instance by what it can share a draw with, and build
  /// one instanced mesh per group.
  ///
  /// Instancing needs ONE geometry per draw, but every prop is grown from its
  /// own seed and so has its own mesh. The reconciliation is a small pool of
  /// pre-grown variants per kind ([ScatterPropLibrary.variantSeeds]): an
  /// instance picks a variant from its seed, and yaw and scale carry the rest
  /// of the variety. Four variants of a tree, freely rotated and resized, do
  /// not read as four trees.
  void _rebuildBatches(
    SceneCamera? camera,
    FloatingOrigin origin,
    Vector3 bodyWorld,
    Quaternion bodyQuat,
    double bodyRadius,
  ) {
    final groups = <_BatchKey, List<vm.Matrix4>>{};
    final imposterCards = <PropKind, List<_Card>>{};
    _instanceCount = 0;

    final library = ScatterPropLibrary.instance;
    final eyeOffset = camera?.eyeOffset ?? Vector3.zero;

    for (final entry in _cells.entries) {
      final data = entry.value;
      if (data.instances.isEmpty) continue;

      // Per-cell projection price: radiusPx is linear in its radius argument
      // for every camera, so ONE probe at the cell centre prices every prop
      // in the cell (px = pxPerM * halfHeight) — the per-instance probe was
      // a third of the rebuild's cost. The eye can stand inside or beside a
      // NEAR cell, where the centre distance misprices its props by a large
      // factor; those few cells keep exact per-instance probes. The far
      // majority (ring area grows quadratically) take the cheap path, where
      // the centre-vs-prop distance error is under one part in eight — far
      // below the 2.2x hysteresis between LOD thresholds.
      final cellRel = bodyWorld +
          bodyQuat.rotate(entry.key.cell.centreDirection * bodyRadius) -
          origin.focusWorld;
      final cellRadiusM = entry.key.cell.circumradiusM(bodyRadius);
      final near = camera != null &&
          (cellRel - eyeOffset).length < cellRadiusM * 8;
      final pxPerM = camera == null ? 0.0 : camera.radiusPx(cellRel, 1.0);

      // Instance matrices are anchor-relative and LOD-independent: cached on
      // the cell, rebuilt only after a re-anchor. A zoom that only re-picks
      // levels reuses every matrix.
      final matrices = data.matrices ??= [
        for (final instance in data.instances)
          instanceTransform(instance, _anchorBF),
      ];

      for (var i = 0; i < data.instances.length; i++) {
        final instance = data.instances[i];
        final prop = library.variantFor(instance);
        _instanceCount++;

        final PropLod lod;
        if (camera == null) {
          lod = PropLod.lod2;
        } else {
          final halfHeight = prop.heightM * instance.scale * 0.5;
          final px = near
              ? camera.radiusPx(
                  bodyWorld + bodyQuat.rotate(instance.positionBF) -
                      origin.focusWorld,
                  halfHeight)
              : pxPerM * halfHeight;
          lod = PropLodSet.lodForApparentPx(px * 2);
        }

        if (lod == PropLod.billboard) {
          final tex = prop.imposterTexture;
          if (tex == null) continue; // still baking; skip rather than flash
          final up = instance.upBF;
          final centre = instance.positionBF +
              up * (prop.lodSet.imposter.heightM * instance.scale * 0.5) -
              _anchorBF;
          imposterCards.putIfAbsent(instance.kind, () => []).add(_Card(
                centre: vm.Vector3(centre.x, centre.y, centre.z),
                width: prop.lodSet.imposter.widthM * instance.scale,
                height: prop.lodSet.imposter.heightM * instance.scale,
              ));
          continue;
        }

        final matrix = matrices[i];
        if (prop.solidFor(lod) != null) {
          groups
              .putIfAbsent(
                  _BatchKey(instance.kind, prop.seed, lod, solid: true), () => [])
              .add(matrix);
        }
        if (prop.foliageFor(lod) != null) {
          groups
              .putIfAbsent(
                  _BatchKey(instance.kind, prop.seed, lod, solid: false),
                  () => [])
              .add(matrix);
        }
      }
    }

    // Swap whole nodes rather than mutating live ones — the standing rule in
    // this renderer is never to touch a buffer that may still be in flight.
    for (final node in _batches.values) {
      _scene.remove(node);
    }
    _batches.clear();
    _drawCalls = 0;

    groups.forEach((key, transforms) {
      final prop = library.get(key.kind, seed: key.variantSeed);
      final geometry =
          key.solid ? prop.solidFor(key.lod) : prop.foliageFor(key.lod);
      if (geometry == null || transforms.isEmpty) return;
      final material = key.solid
          ? (key.kind.family == PropFamily.rock
              ? library.stoneMaterial
              : library.barkMaterial)
          : library.foliageMaterial;
      // One instanced draw uploads every transform in a single write, and the
      // engine's transient arena allocates in 1 MiB blocks — 16,384 mat4s. Past
      // that the write overflows and takes the whole frame down (see the ring
      // debris field, which learned this the hard way), so a group that big is
      // split rather than trusted.
      for (var start = 0; start < transforms.length; start += _maxPerDraw) {
        final end = math.min(start + _maxPerDraw, transforms.length);
        final mesh = fs.InstancedMesh(geometry: geometry, material: material);
        for (var i = start; i < end; i++) {
          mesh.addInstance(transforms[i]);
        }
        final node = fs.Node()..addComponent(fs.InstancedMeshComponent(mesh));
        _scene.add(node);
        _batches[_BatchKey(key.kind, key.variantSeed, key.lod,
            solid: key.solid, shard: start ~/ _maxPerDraw)] = node;
        _drawCalls++;
      }
    });

    _syncImposters(imposterCards);
  }

  /// Instances beyond this in one draw overflow the engine's per-frame
  /// transient block.
  static const int _maxPerDraw = 14000;

  void _syncImposters(Map<PropKind, List<_Card>> cards) {
    for (final kind in _imposters.keys.toList()) {
      if (!cards.containsKey(kind)) {
        _scene.remove(_imposters.remove(kind)!.node);
      }
    }
    cards.forEach((kind, list) {
      final batch = _imposters.putIfAbsent(kind, () {
        final geometry = fs.BillboardGeometry(capacity: 8192)
          // Props stand up. Locking the card's up axis and letting it yaw is
          // what keeps a distant tree vertical; spherical facing would tip the
          // whole forest over as the camera climbed.
          ..facing = fs.BillboardFacing.axisLocked
          ..worldUp = vm.Vector3(0, 0, 1);
        final node = fs.Node(
          mesh: fs.Mesh(
              geometry, ScatterPropLibrary.instance.imposterMaterial(kind)),
        );
        _scene.add(node);
        return _ImposterBatch(geometry, node);
      });
      // The batch's up axis is the surface normal at the anchor. Over a ring a
      // few hundred metres wide on a planet-sized sphere the surface has barely
      // turned, so one axis for the batch is indistinguishable from one per
      // card — and per-card is not on offer anyway.
      final up = _anchorBF.lengthSquared > 0
          ? _anchorBF.normalized
          : Vector3.unitZ;
      batch.geometry.worldUp = vm.Vector3(up.x, up.y, up.z);
      final count = math.min(list.length, batch.geometry.capacity);
      for (var i = 0; i < count; i++) {
        batch.geometry.setInstance(
          i,
          center: list[i].centre * lengthToScene(1.0),
          width: lengthToScene(list[i].width),
          height: lengthToScene(list[i].height),
        );
      }
      batch.geometry.commit(count);
      _drawCalls++;
    });
  }

  /// The shared per-frame node transform: anchor position in scene units,
  /// body rotation, UNIT scale.
  ///
  /// Unit scale is load-bearing: every value under this node — instance
  /// offsets ([instanceTransform]) and billboard centres — is written in
  /// scene units already. The node once scaled by [lengthToScene] on top,
  /// which collapsed every prop mesh to millimetres (nothing but billboards
  /// ever showed) and crushed all the imposter cards onto the anchor point —
  /// a 256 m-quantised grid point that can sit well off the ground, read as
  /// "scatter floats in the sky". The ring debris field is the reference
  /// pattern: node at 1.0, conversions in the per-instance data.
  /// Whether the eye has moved enough since the last batch build to re-pick
  /// detail levels. 10% relative: a prop's apparent size moves with 1/d, so
  /// smaller changes cannot cross an LOD threshold that matters, and the gate
  /// keeps a slow zoom from rewriting every instance per frame.
  static bool zoomInvalidates(double builtEyeM, double eyeM) =>
      builtEyeM.isNaN || (eyeM - builtEyeM).abs() > builtEyeM * 0.1;

  static vm.Matrix4 batchTransform(
    FloatingOrigin origin,
    Vector3 bodyWorld,
    Quaternion bodyQuat,
    Vector3 anchorBF,
  ) =>
      vm.Matrix4.compose(
        origin.worldToScene(bodyWorld + bodyQuat.rotate(anchorBF)),
        quatToScene(bodyQuat),
        vm.Vector3.all(1.0),
      );

  /// The instance's model transform, relative to the shared anchor.
  ///
  /// Props stand along the SURFACE NORMAL, not the radius: on a hillside the
  /// two differ by the slope, and a tree planted radially leans visibly
  /// downhill. Static and anchor-explicit so the frame maths is testable
  /// against [batchTransform] without a live scene.
  static vm.Matrix4 instanceTransform(
      ScatterInstance instance, Vector3 anchorBF) {
    final offset = instance.positionBF - anchorBF;
    final tilt = _alignZTo(instance.upBF);
    final spin = Quaternion.axisAngle(Vector3.unitZ, instance.yaw);
    return vm.Matrix4.compose(
      vm.Vector3(lengthToScene(offset.x), lengthToScene(offset.y),
          lengthToScene(offset.z)),
      quatToScene(tilt * spin),
      vm.Vector3.all(lengthToScene(instance.scale)),
    );
  }

  /// Rotation carrying local +Z (the axis every prop is grown along) onto [up].
  static Quaternion _alignZTo(Vector3 up) {
    final axis = Vector3.unitZ.cross(up);
    final sin = axis.length;
    if (sin < 1e-9) {
      return up.z >= 0
          ? Quaternion.identity
          : Quaternion.axisAngle(Vector3.unitX, math.pi);
    }
    return Quaternion.axisAngle(axis, math.atan2(sin, up.z));
  }

  // ---- Housekeeping -------------------------------------------------------

  /// Queue one cell for generation; the result installs itself and marks the
  /// batches dirty. Results that went stale in flight — wrong body (epoch),
  /// pre-edit field ([_stalePending]), or simply no longer wanted — are
  /// dropped: regeneration is deterministic and cheap, so nothing is parked.
  void _submit(ScatterPlacement placement, _CellId id) {
    final epoch = _genEpoch;
    _pendingCells.add(id);
    _scheduler!
        .generate(placement, id.cell, ScatterLayers.all[id.layer])
        .then((instances) {
      _pendingCells.remove(id);
      if (epoch != _genEpoch) return;
      if (_stalePending.remove(id)) return;
      if (!_wantedNow.contains(id)) return;
      _cells[id] = _CellData(instances);
      _staleCells.remove(id);
      _dirty = true;
    }).catchError((Object e) {
      _pendingCells.remove(id);
      _stalePending.remove(id);
      debugLine = 'scatter: cell ${id.cell} failed: $e';
    });
  }

  /// Drop every cell — resident or in flight — that a newly added brush
  /// touches, so its props regenerate against the new ground.
  ///
  /// Touched cells are computed ONCE per (brush, level) — the old loop
  /// recomputed `chunksTouchedBy` per resident cell, and only ever against
  /// the LAST brush, missing invalidation whenever one frame carried two.
  void _invalidateAround(List<TerrainBrush> added) {
    if (added.isEmpty || (_cells.isEmpty && _pendingCells.isEmpty)) return;
    final levels = <int>{
      for (final id in _cells.keys) id.cell.level,
      for (final id in _pendingCells) id.cell.level,
    };
    final touched = <int, Set<ChunkKey>>{
      for (final level in levels)
        level: {
          for (final brush in added)
            ...TerrainEdits.chunksTouchedBy(brush, level),
        },
    };
    for (final id in _cells.keys) {
      // Still drawn until it regenerates (see [_staleCells]).
      if (touched[id.cell.level]!.contains(id.cell)) _staleCells.add(id);
    }
    for (final id in _pendingCells) {
      if (touched[id.cell.level]!.contains(id.cell)) {
        _stalePending.add(id);
      }
    }
  }

  /// Drop the resident cells within reach of [sites], and mark the in-flight
  /// ones stale.
  ///
  /// The mask's own version of [_invalidateAround]: a lot that has just been
  /// built on has to re-generate the props standing where it now stands, and
  /// nothing else does.
  void _invalidateNear(List<(Vector3, double)> sites) {
    if (sites.isEmpty) return;
    _dirty = true;
    final radius = _baseField?.radius ?? 1.0;
    bool near(ChunkKey cell) {
      final centre = cell.centreDirection * radius;
      final reach = cell.circumradiusM(radius);
      for (final (p, r) in sites) {
        if ((p - centre).length <= reach + r) return true;
      }
      return false;
    }

    for (final id in _cells.keys.toList()) {
      if (!near(id.cell)) continue;
      // Still drawn until it regenerates (see [_staleCells]) — less the
      // props the new road or lot now covers, which go now.
      _staleCells.add(id);
      _filterByMask(id);
    }
    for (final id in _pendingCells) {
      if (near(id.cell)) _stalePending.add(id);
    }
  }

  /// Take off a stale cell, at once, every prop the colony's current mask
  /// covers — a tree standing in a road drawn this frame. The cell keeps
  /// drawing the rest until its regeneration replaces it.
  void _filterByMask(_CellId id) {
    final mask = _mask;
    final data = _cells[id];
    if (mask == null || data == null) return;
    final kept = [
      for (final i in data.instances)
        if (!mask.blocks(i.positionBF.normalized)) i
    ];
    if (kept.length == data.instances.length) return;
    _cells[id] = _CellData(kept);
    _dirty = true;
  }

  /// Rebuild the colony footprint from the frame if it has changed.
  ///
  /// Returns the sites whose ground CHANGED — each a body-fixed centre and a
  /// radius — for the caller to invalidate around. Empty when nothing moved.
  ///
  /// Reads the SNAPSHOT, never `CitySim`: roads arrive as sampled body-fixed
  /// polylines and buildings as body-fixed sites, which is all a renderer is
  /// given and all a networked client will ever have.
  List<(Vector3, double)> _refreshMask(WorldSnapshot snap, String bodyId) {
    // A cheap signature rather than a deep compare: a colony's buildings
    // change by GAINING things — a lot grown — so their count catches it,
    // and a per-frame hash over a hundred thousand buildings would cost more
    // than the rebuild it is trying to avoid. Roads are few enough to hash
    // one by one, and must be: the road tool edits them IN PLACE, where no
    // count moves (see [roadMaskSignature]).
    final (:roads, hash: roadHash) = roadMaskSignature(snap.roads, bodyId);
    var builds = 0;
    for (final b in snap.buildings.values) {
      if (b.body == bodyId) builds++;
    }
    final sig = Object.hash(bodyId, roadHash, builds);
    if (sig == _maskSig) return const [];
    final roadsMoved = roadHash != _maskRoadHash;
    _maskSig = sig;
    _maskRoadHash = roadHash;
    if (roads == 0 && builds == 0) {
      final moved = _maskSitesMoved(const {});
      _mask = null;
      return moved;
    }

    // Origin: the mean of the colony's own geometry, so feature coordinates
    // stay small enough for float32 and the whole-colony reject is tight.
    var cx = 0.0, cy = 0.0, cz = 0.0;
    var n = 0;
    for (final r in snap.roads) {
      if (r.body != bodyId || r.points.length < 3) continue;
      cx += r.points[0];
      cy += r.points[1];
      cz += r.points[2];
      n++;
    }
    for (final b in snap.buildings.values) {
      if (b.body != bodyId) continue;
      cx += b.px;
      cy += b.py;
      cz += b.pz;
      n++;
    }
    if (n == 0) {
      final moved = _maskSitesMoved(const {});
      _mask = null;
      return moved;
    }
    final originBF = Vector3(cx / n, cy / n, cz / n);
    final builder = ScatterMaskBuilder(
      originBF: originBF,
      groundRadiusM: originBF.length,
    );

    // Roads first: they are what props most visibly stand in the middle of,
    // and they are the features worth keeping if the cap bites.
    var features = 0;
    for (final r in snap.roads) {
      if (r.body != bodyId) continue;
      features += addRoadCorridor(builder, r);
    }

    // Then the sites. A rectangle is masked as the capsule inscribed along its
    // long axis: a disc of the half-diagonal would clear the trees for tens of
    // metres past a long shed, and one of the half-width would leave them
    // standing through its ends.
    final sites = <String, (Vector3, double)>{};
    for (final b in snap.buildings.values) {
      if (b.body != bodyId) continue;
      if (features >= _maxMaskFeatures) break;
      final w = b.siteWidthM, dpt = b.siteDepthM;
      if (w <= 0 || dpt <= 0) continue;
      final centre = Vector3(b.px, b.py, b.pz);
      final q = Quaternion(b.qw, b.qx, b.qy, b.qz);
      final radius = math.min(w, dpt) * 0.5;
      final half = (math.max(w, dpt) - math.min(w, dpt)) * 0.5;
      if (half < 0.5) {
        builder.addDisc(centre, radius);
      } else {
        final axis = q.rotate(w >= dpt ? Vector3.unitX : Vector3.unitY);
        builder.addCapsule(centre - axis * half, centre + axis * half, radius);
      }
      // The site as ONE disc, for working out what changed. Its long axis is
      // irrelevant here: this is the neighbourhood to re-scatter, not the
      // footprint to mask.
      sites[b.id] = (centre, math.max(w, dpt) * 0.5);
      features++;
    }

    _mask = builder.isEmpty ? null : builder.build(sig);
    final moved = _maskSitesMoved(sites);
    // A road drawn or removed changes ground the length of the street, which
    // is not a site and has no id to diff. Rare (a player draws roads by
    // hand), so it re-scatters the whole colony rather than earning a
    // corridor diff of its own.
    if (roadsMoved && _mask != null) {
      moved.add((_mask!.originBF, _mask!.extentM));
    }
    return moved;
  }

  /// Sites that appeared, vanished or moved since the last mask, as the
  /// neighbourhoods whose scatter is now wrong.
  ///
  /// Diffed by BUILDING ID rather than by count: a colony gains a building
  /// every few seconds while it grows, and what is stale is the lot it went
  /// up on, not the county around it.
  List<(Vector3, double)> _maskSitesMoved(
      Map<String, (Vector3, double)> now) {
    final moved = <(Vector3, double)>[];
    for (final e in now.entries) {
      final was = _maskSites[e.key];
      if (was == null || (was.$1 - e.value.$1).length > 1.0) {
        moved.add(e.value);
      }
    }
    for (final e in _maskSites.entries) {
      if (!now.containsKey(e.key)) moved.add(e.value); // bulldozed
    }
    _maskSites
      ..clear()
      ..addAll(now);
    return moved;
  }

  /// Corridor length a road's samples are merged into, metres.
  static const double _maskSegmentM = 40;

  /// The roads on [bodyId], and a hash of each one's id, half width (to the
  /// centimetre) and sample count.
  ///
  /// Counts alone were the old signature, and the road tool edits in place:
  /// an Upgrade keeps a road's id and controls, so its samples and the
  /// colony's road count stay put while its width doubles, and the trees
  /// stood on in the new lanes. The width catches that. A road that MOVES
  /// always gets a new id — an Adjust drag re-lays it, one road for one and
  /// often with the same sample count, under `layout.childIdFor`
  /// (`CitySim.moveRoadEnd`) — so the id catches that, as it does a Draw or
  /// a Bulldoze; a Reverse keeps the geometry and needs no catching.
  ///
  /// Nothing positional is hashed. A snapshot point is the drape radius
  /// plus a tangent offset in METRES, so ground re-graded under a road
  /// turns its points' directions too — five metres of fill two kilometres
  /// out on the Moon is a few parts in a billion — and hashing its ends
  /// re-scattered the whole colony whenever a pad or a cut reached one.
  /// That is the terrain's own invalidation to answer, not a road that
  /// moved.
  ///
  /// It runs every frame over every road, so it is folded by hand rather
  /// than through `Object.hash`.
  static ({int roads, int hash}) roadMaskSignature(
      Iterable<RoadSnapshot> roads, String bodyId) {
    var count = 0, h = 0;
    for (final r in roads) {
      if (r.body != bodyId) continue;
      count++;
      h = _fold(h, r.id.hashCode);
      h = _fold(h, (r.halfWidthM * 100).round());
      h = _fold(h, r.points.length ~/ 3);
    }
    return (roads: count, hash: h);
  }

  /// One value into a running hash, kept to 30 bits so the arithmetic is
  /// exact on the web too.
  static int _fold(int h, int v) => (h * 31 + (v & 0x3fffffff)) & 0x3fffffff;

  /// Adds [r]'s corridor to [builder], [_roadMarginM] wider than its
  /// carriageway, and returns how many capsules that took.
  ///
  /// Only the stretches that come up to the surface: a tunnel's points are
  /// written at the ground ABOVE it (its deck travels separately, in
  /// [RoadSnapshot.lifts]), and masked they cut a road-wide treeless strip
  /// across the hill it runs under — the one mark it left on the surface,
  /// giving away a tunnel that shows only while the road tool is held below
  /// ground. The corridor is cut at each portal into runs of samples no
  /// deeper than [RoadElevation.tunnelCoverM], the road mesher's own rule
  /// for where tarmac is drawn. A bridge or a viaduct stays masked: it is
  /// over the ground, and a tree through its deck is still a tree in the
  /// road. A road with no deck is one run, masked exactly as before.
  static int addRoadCorridor(ScatterMaskBuilder builder, RoadSnapshot r) {
    final p = r.points;
    final n = p.length ~/ 3;
    if (n < 2) return 0;
    final radius = r.halfWidthM + _roadMarginM;
    final lifts = r.lifts.length == n ? r.lifts : null;
    bool under(int k) =>
        lifts != null && lifts[k] < -RoadElevation.tunnelCoverM;
    var added = 0;
    for (var k = 0; k < n;) {
      if (under(k)) {
        k++;
        continue;
      }
      var end = k;
      while (end + 1 < n && !under(end + 1)) {
        end++;
      }
      added += _addRoadRun(builder, p, k, end, radius);
      k = end + 1;
    }
    return added;
  }

  /// Samples [k0]..[k1] (inclusive) of a road's flattened [p], as capsules.
  static int _addRoadRun(
      ScatterMaskBuilder builder, List<double> p, int k0, int k1, double radius) {
    var ax = p[3 * k0], ay = p[3 * k0 + 1], az = p[3 * k0 + 2];
    if (k1 == k0) {
      // One sample between two tunnels: the road surfaces for a few metres.
      builder.addDisc(Vector3(ax, ay, az), radius);
      return 1;
    }
    var added = 0;
    for (var k = k0 + 1; k <= k1; k++) {
      final bx = p[3 * k], by = p[3 * k + 1], bz = p[3 * k + 2];
      final dx = bx - ax, dy = by - ay, dz = bz - az;
      final run = math.sqrt(dx * dx + dy * dy + dz * dz);
      // Merge the sampled polyline into corridor-length capsules. The
      // samples are metres apart; one capsule each would be tens of
      // thousands of features for a town's worth of streets, and the chord
      // error over 40 m of a street's curvature is under the verge margin.
      if (run < _maskSegmentM && k < k1) continue;
      builder.addCapsule(Vector3(ax, ay, az), Vector3(bx, by, bz), radius);
      added++;
      ax = bx;
      ay = by;
      az = bz;
    }
    return added;
  }

  /// Whether [cell] is within [viewDistanceM] of the surface point under
  /// [anchorDir], measured ALONG THE GROUND (great-circle arc), with the
  /// cell's own reach credited.
  ///
  /// Along the ground, not between 3D points: the old test measured from the
  /// anchor's ground point to the cell centre AT THE DATUM RADIUS, so on a
  /// DEM body the radial gap alone (a mare floor is ~3 km below datum) put
  /// every cell past a 450 m view distance and scatter silently vanished for
  /// a landed craft. Radial offsets are irrelevant to "how far away is this
  /// patch of ground"; the arc is the honest metric and needs no field sample.
  static bool cellInReach(
      ChunkKey cell, Vector3 anchorDir, double radiusM, double viewDistanceM) {
    final cosA = cell.centreDirection.dot(anchorDir).clamp(-1.0, 1.0);
    final surfaceDistM = math.acos(cosA) * radiusM;
    return surfaceDistM - cell.circumradiusM(radiusM) <= viewDistanceM;
  }

  /// Cells at [level] covering a cap of [angularRadius] about [dir].
  ///
  /// Sampled through [chunkAt] rather than walked by adjacency — the trick
  /// `TerrainEdits.chunksTouchedBy` uses, and for the same reason: a direction
  /// is a direction, so the cube's seams and corners never enter into it.
  static Set<ChunkKey> _cellsWithin(
      Vector3 dir, double angularRadius, int level) {
    if (level == 0 || angularRadius >= 0.5) return {...ChunkKey.roots};
    final out = <ChunkKey>{chunkAt(dir, level)};
    if (angularRadius <= 0) return out;
    final seed = dir.x.abs() < 0.9 ? Vector3.unitX : Vector3.unitY;
    final tangent = seed.cross(dir).normalized;
    final bitangent = dir.cross(tangent);
    // Enough rings to cover a cap several cells wide without leaving holes in
    // the middle; under-covering would leave bald patches in the field.
    const rings = [1.0, 0.82, 0.64, 0.46, 0.28, 0.12];
    const samples = 24;
    for (final ring in rings) {
      final sin = math.sin(angularRadius * ring);
      final cos = math.cos(angularRadius * ring);
      for (var i = 0; i < samples; i++) {
        final phi = 2 * math.pi * i / samples;
        final offset =
            tangent * (math.cos(phi) * sin) + bitangent * (math.sin(phi) * sin);
        out.add(chunkAt((dir * cos + offset).normalized, level));
      }
    }
    return out;
  }

  /// The focused body's climate model, from the shared body CATALOG rather
  /// than the snapshot.
  ///
  /// Biomes are reference data — the same on every client and the server, and
  /// unchanging — so they do not belong on the wire, and putting them there
  /// would mean touching the snapshot and codec for something that can simply
  /// be looked up. Built once: `RealSolarSystem.build()` constructs the whole
  /// system, which is not a per-frame cost worth paying.
  static final Map<String, PlanetSurface> _surfaces = {
    for (final b in RealSolarSystem.build().all)
      if (b.surface != null) b.id.value: b.surface!,
  };

  static PlanetSurface? _surfaceFor(String bodyId) => _surfaces[bodyId];

  void _clear() {
    for (final node in _batches.values) {
      _scene.remove(node);
    }
    for (final imposter in _imposters.values) {
      _scene.remove(imposter.node);
    }
    _batches.clear();
    _imposters.clear();
    _cells.clear();
    // In-flight jobs drain on their own; the epoch bump drops their results.
    _genEpoch++;
    _stalePending.clear();
    _staleCells.clear();
    _wantedCache.clear();
    _wantedNow = const {};
    // The mask belongs to the body that was being drawn. Left behind, its
    // sites would diff against the NEXT body's and invalidate cells around
    // coordinates that mean something else there.
    _mask = null;
    _maskSig = 0;
    _maskRoadHash = 0;
    _maskSites.clear();
    _composedField = null;
    _composedEditsId = _unset;
    _groundEyeBF = const Vector3(double.infinity, 0, 0);
    _groundAnchorBF = const Vector3(double.infinity, 0, 0);
    _bodyId = null;
    _instanceCount = 0;
    _drawCalls = 0;
    _dirty = true;
    _builtEyeM = double.nan;
    debugLine = '';
  }

  void dispose() {
    ScatterPropLibrary.instance.removeListener(_onLibraryChanged);
    _scheduler?.dispose();
    _scheduler = null;
    _clear();
  }
}

/// One resident cell's instances plus its cached anchor-relative matrices.
class _CellData {
  _CellData(this.instances);

  final List<ScatterInstance> instances;

  /// One matrix per instance, relative to [ScatterNodes._anchorBF]. Built
  /// lazily on first rebuild, nulled when the anchor rebases — a rebuild
  /// that only re-picks LOD levels (the common kind) reuses all of them.
  List<vm.Matrix4>? matrices;
}

/// One resident cell of one layer.
class _CellId {
  const _CellId(this.layer, this.cell);
  final int layer;
  final ChunkKey cell;

  @override
  bool operator ==(Object other) =>
      other is _CellId && other.layer == layer && other.cell == cell;

  @override
  int get hashCode => Object.hash(layer, cell);
}

/// Everything that must match for two instances to share one draw.
class _BatchKey {
  const _BatchKey(this.kind, this.variantSeed, this.lod,
      {required this.solid, this.shard = 0});
  final PropKind kind;
  final int variantSeed;
  final PropLod lod;
  final bool solid;
  final int shard;

  @override
  bool operator ==(Object other) =>
      other is _BatchKey &&
      other.kind == kind &&
      other.variantSeed == variantSeed &&
      other.lod == lod &&
      other.solid == solid &&
      other.shard == shard;

  @override
  int get hashCode => Object.hash(kind, variantSeed, lod, solid, shard);
}

class _ImposterBatch {
  _ImposterBatch(this.geometry, this.node);
  final fs.BillboardGeometry geometry;
  final fs.Node node;
}

class _Card {
  const _Card({
    required this.centre,
    required this.width,
    required this.height,
  });
  final vm.Vector3 centre;
  final double width, height;
}
