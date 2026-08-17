// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;

import '../../../adapters/presenters/camera_view.dart';
import '../../../application/snapshot/world_snapshot.dart';
import '../../../domain/scatter/prop_catalog.dart';
import '../../../domain/scatter/prop_model.dart';
import '../../../domain/scatter/scatter_instance.dart';
import '../../../domain/scatter/scatter_layer.dart';
import '../../../domain/scatter/scatter_placement.dart';
import '../../../domain/scatter/scatter_scheduler.dart';
import '../../../domain/shared/quaternion.dart';
import '../../../domain/shared/vector3.dart';
import '../../../domain/terrain/cubed_sphere.dart';
import '../../../domain/terrain/terrain_brush.dart';
import '../../../domain/terrain/terrain_edits.dart';
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

  /// Highest eye altitude (m) at which props draw at all. Above it the biggest
  /// tree is well under a pixel.
  static double maxAltitudeM = 4000;

  /// How far the anchor may drift before instance offsets are rebased (m).
  /// Instances are stored relative to it so their transforms stay small enough
  /// for float32; re-anchoring rewrites every transform, so it is quantised
  /// rather than following the camera continuously.
  static double anchorGridM = 256;

  static String debugLine = '';

  /// Which gate suppressed scatter this frame, or '' when it drew.
  static String gateReason = '';

  final Map<_CellId, _CellData> _cells = {};
  final Map<_BatchKey, fs.Node> _batches = {};
  final Map<PropKind, _ImposterBatch> _imposters = {};

  // --- Async generation state (mirrors TerrainNodes' meshing state) --------
  ScatterGenScheduler? _scheduler;
  bool _schedulerAsync = true;
  final Set<_CellId> _pendingCells = {};

  /// In-flight cells a new edit overlaps — their placement sampled the
  /// pre-edit field, so their results are dropped on arrival.
  final Set<_CellId> _stalePending = {};

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
    for (final e in snap.terrainEdits) {
      if (e.body == bodyId) editCount++;
    }
    if (_builtEditCount != editCount || _bodyId != bodyId) {
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
    }
    final field = d.buildTerrainField(edits: _edits, detail: _detail)!;

    final bodyQuat = Quaternion(b.qw, b.qx, b.qy, b.qz) *
        Quaternion.axisAngle(Vector3.unitZ, BodyNodes.textureYawRad);
    final invQuat = bodyQuat.conjugate;

    // Altitude gate, against the GROUND under the eye — not the datum. With a
    // real DEM the datum is nowhere near the surface: a mare floor sits ~3 km
    // below it and the far-side highlands ~10 km above, so a datum-relative
    // altitude either never gates or gates a craft PARKED ON the ground.
    final eyeBF = invQuat.rotate(eyeWorld - bodyWorld);
    final eyeDir = eyeBF.lengthSquared > 0 ? eyeBF.normalized : Vector3.unitZ;
    final altitude =
        eyeBF.length - field.groundRadiusAt(eyeDir.x, eyeDir.y, eyeDir.z);
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
    var anchorWorld = eyeWorld;
    if (fv != null) {
      final vb = snap.bodies[fv.body];
      if (vb != null) {
        anchorWorld = Vector3(vb.px + fv.px, vb.py + fv.py, vb.pz + fv.pz);
      }
    }
    final anchorBF = invQuat.rotate(anchorWorld - bodyWorld);
    final anchorDir = anchorBF.normalized;
    final focusPoint = anchorDir * field.groundRadiusAt(
        anchorDir.x, anchorDir.y, anchorDir.z);

    final surface = _surfaceFor(bodyId!);
    if (surface == null) {
      gateReason = 'no climate model for $bodyId';
      _clear();
      return;
    }
    final placement = ScatterPlacement(
      field: field,
      surface: surface,
      bodySeed: d.terrainSeed,
      vegetationCap: d.terrainGrassAmount,
    );

    // --- Cell residency ----------------------------------------------------
    // Per layer, the cell set around the anchor is cached against the cell
    // the anchor falls in at that layer's level — it cannot change without
    // the anchor crossing a cell boundary, and computing it fresh was ~700
    // chunkAt probes per layer per frame.
    final wanted = <_CellId>{};
    for (var li = 0; li < ScatterLayers.all.length; li++) {
      final layer = ScatterLayers.all[li];
      if (densityScale <= 0) break;
      final level = layer.levelFor(field.radius);
      final anchorCell = chunkAt(anchorDir, level);
      var cached = _wantedCache[li];
      if (cached == null || cached.$1 != anchorCell) {
        final cells = <ChunkKey>{};
        for (final cell in _cellsWithin(
            anchorDir, layer.viewDistanceM / field.radius, level)) {
          // Cells are picked by their own reach, so a cell whose centre is
          // past the view distance still joins when its near edge is inside.
          if (!cellInReach(
              cell, anchorDir, field.radius, layer.viewDistanceM)) {
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
        _dirty = true;
      }
    }

    // Submit missing cells to the scheduler, nearest first, up to the
    // in-flight cap. Results land in [_cells] from the arrival callback —
    // generation itself happens on a background isolate (see
    // scatter_scheduler.dart), which is what keeps a walk into fresh ground
    // from hitching: a cell is 5-30 ms of field sampling, and this loop used
    // to run several of them inline every frame.
    if (_scheduler == null || _schedulerAsync != asyncGeneration) {
      _scheduler?.dispose();
      _scheduler = asyncGeneration
          ? ScatterGenScheduler.platform()
          : SyncScatterScheduler();
      _schedulerAsync = asyncGeneration;
    }
    final missing = [
      for (final id in wanted)
        if (!_cells.containsKey(id) && !_pendingCells.contains(id)) id,
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
    for (final id in _cells.keys.toList()) {
      if (touched[id.cell.level]!.contains(id.cell)) {
        _cells.remove(id);
        _dirty = true;
      }
    }
    for (final id in _pendingCells) {
      if (touched[id.cell.level]!.contains(id.cell)) {
        _stalePending.add(id);
      }
    }
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
    _wantedCache.clear();
    _wantedNow = const {};
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
