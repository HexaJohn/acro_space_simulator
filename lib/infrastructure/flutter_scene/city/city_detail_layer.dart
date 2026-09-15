// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The per-building detail round the eye, drawn as a layer of its own
/// over the base tiles.
///
/// A near tile used to carry the camera in its build key — quantised to
/// 64 m — whenever any building in it could resolve past a block, so a
/// walk down a street rebuilt whole two-mile tiles every 64 m: roads,
/// junctions, patches, furniture and a thousand boxed buildings re-meshed
/// for the handful within block range that changed tier, thirty-odd
/// milliseconds of build on the UI thread a frame with fifty tiles queued.
/// And every full-detail archetype the walk met for the first time missed
/// the UI-side mesh cache and was generated there, a quarter to two
/// milliseconds each.
///
/// This layer takes that work off the tiles. A base tile never reads the
/// camera: every building in it is its massing boxes, the near tier's a
/// little inset (see [CityTileMesher.nearBoxInset]), and no lot furniture.
/// The layer watches the eye instead. When the eye crosses a [cellM] cell
/// — or the colony's structure, the renderer's invalidation or the knobs
/// move — it submits ONE job to the tile scheduler: the buildings within
/// block range of the eye's cell, gathered from the tiles round it, with
/// the archetype keys the UI thread already holds geometry for. The
/// worker meshes each at its own tier, generates the archetypes the UI
/// thread lacks, and merges the furniture; the UI thread stages what
/// comes back under the frame's byte budget, shows it, and only then lets
/// the previous set go. Nothing here is hidden or culled: the layer is
/// always round the eye, which is always in view.
///
/// `CityNodes.detailLayer` is the switch; off, the tiles carry the detail
/// as they always did and this class does nothing.
library;

import 'dart:typed_data';

import 'package:flutter_scene/scene.dart' as fs;
// The staged upload is a fork patch the public barrel does not export.
import 'package:flutter_scene/src/geometry/mesh_geometry.dart'
    show MeshGeometry, StagedMeshUpload;
import 'package:vector_math/vector_math.dart' as vm;

import '../../../application/snapshot/world_snapshot.dart';
import '../../../domain/architecture/building_generator.dart';
import '../../../domain/scatter/prop_mesh.dart';
import '../../../domain/shared/vector3.dart';
import '../coord_convert.dart';
import 'city_materials.dart';
import 'city_nodes.dart'
    show
        CityMeshUploadStep,
        CityRevealChunk,
        CityStagedUpload,
        CityTileReveal,
        CityUploadByteBudget;
import 'city_tile_bucketing.dart' show CityTileBucketer;
import 'city_tile_columns.dart';
import 'city_tile_mesher.dart';
import 'city_tile_scheduler.dart';
import 'device_buffer_pool.dart';

/// What the layer needs of the scene and the frame, handed by `CityNodes`
/// each update: where to hang its nodes, what to mesh on, what to allocate
/// from, and how much of the frame it may take.
class CityDetailFrame {
  const CityDetailFrame({
    required this.scheduler,
    required this.root,
    required this.rootAnchorBF,
    required this.pool,
    required this.frameIndex,
    required this.reclaim,
    required this.bytes,
    required this.budgetUs,
  });

  /// Where the detail jobs run.
  final CityTileScheduler scheduler;

  /// The body's root node, which the layer's nodes hang under at a fixed
  /// offset like every tile's, and the anchor that offset is measured
  /// from.
  final fs.Node root;
  final Vector3 rootAnchorBF;

  /// The chunk buffers a furniture chunk takes and a dropped set gives
  /// back, and the frame clock the pool cools by.
  final GpuDeviceBufferPool pool;
  final int frameIndex;

  /// The caller's reclaim hook: the buffers of nodes that have left the
  /// scene for good, back to the pool.
  final void Function(Iterable<fs.Node> nodes) reclaim;

  /// What the frame has left of its GPU bytes once the tiles have taken
  /// theirs (see `CityNodes.uploadBytesPerFrame`).
  final CityUploadByteBudget bytes;

  /// Microseconds of UI thread the layer's upload steps may take. One
  /// step always runs, so a step dearer than the budget still lands.
  final int budgetUs;
}

/// The eye and the colony round it, as the layer is asked for them.
class CityDetailWant {
  const CityDetailWant({
    required this.bodyId,
    required this.focusBF,
    required this.structureSig,
    required this.invalidation,
    required this.colonyTier,
    required this.lotFeatures,
    required this.epoch,
    required this.knobs,
    required this.candidates,
    this.sites = const [],
  });

  /// The frame's site access plans (`WorldSnapshot.sites`): a job packs the
  /// gathered buildings' own while `knobs.siteAccess` is on.
  final List<CitySiteFrame> sites;

  /// The body the eye is over, and the eye in its frame.
  final String bodyId;
  final Vector3 focusBF;

  /// The frame's structure signature and the renderer's invalidation
  /// count: the two parts of every tile's key that, once moved, mean a
  /// set built before them is stale.
  final String structureSig;
  final int invalidation;
  final BuildingDetail colonyTier;

  /// Whether the lot furniture is wanted at all (`CityNodes.lotFeatures`).
  final bool lotFeatures;
  final double epoch;
  final CityMeshKnobs knobs;

  /// The buildings the gather chooses from — the tiles round the eye's
  /// cell — read only when a job is being made.
  final Iterable<BuildingSnapshot> Function() candidates;
}

/// The per-building detail round the eye (see the library docs).
class CityDetailLayer {
  /// The cell the eye is quantised to, metres: the layer re-gathers and
  /// re-meshes when the eye crosses into another. The tiles' old camera
  /// term used the same 64 m, so a walk pays a job every 64 m as it paid
  /// a tile rebuild — but the job is a few hundred buildings and their
  /// furniture, not a two-mile tile. Smaller cells follow the eye more
  /// closely at more jobs; the gather's margin is one cell, so a building
  /// just inside block range is never missed whatever the size.
  static double cellM = 64;

  /// The cell [focusBF] falls in: each axis to the nearest [cellM], the
  /// way the tiles' camera term was quantised.
  static (int, int, int) cellOf(Vector3 focusBF, {double? cellM}) {
    final c = cellM ?? CityDetailLayer.cellM;
    return (
      (focusBF.x / c).round(),
      (focusBF.y / c).round(),
      (focusBF.z / c).round(),
    );
  }

  /// The centre of [cell], body-fixed metres: what a set is gathered
  /// about and what its vertices are relative to.
  static Vector3 cellCentre((int, int, int) cell, {double? cellM}) {
    final c = cellM ?? CityDetailLayer.cellM;
    return Vector3(cell.$1 * c, cell.$2 * c, cell.$3 * c);
  }

  /// How far from the cell's centre a building is gathered: the block
  /// range plus one cell, so every building within the block range of ANY
  /// eye in the cell is in (the eye is at most half a cell's diagonal,
  /// under one cell, from the centre).
  static double gatherRadiusM(double blockRangeM, {double? cellM}) =>
      blockRangeM + (cellM ?? CityDetailLayer.cellM);

  /// The buildings of [candidates] whose centres lie within [radiusM] of
  /// [centreBF], in the candidates' order — a pure function of the key,
  /// so the same cell gathers the same set.
  static List<BuildingSnapshot> gather(
      Iterable<BuildingSnapshot> candidates, Vector3 centreBF, double radiusM) {
    final r2 = radiusM * radiusM;
    return [
      for (final b in candidates)
        if ((Vector3(b.px, b.py, b.pz) - centreBF).lengthSquared <= r2) b,
    ];
  }

  /// The key a set is wanted under: the body, the eye's cell, and every
  /// input the meshing reads that is not in the buildings themselves.
  static String keyFor({
    required String bodyId,
    required (int, int, int) cell,
    required String structureSig,
    required int invalidation,
    required BuildingDetail colonyTier,
    required bool lotFeatures,
    required CityMeshKnobs knobs,
  }) =>
      '$bodyId|${cell.$1},${cell.$2},${cell.$3}|$structureSig|$invalidation'
      '|${colonyTier.index}|${lotFeatures ? 1 : 0}|${knobs.keyTerms}';

  /// Of the archetypes [buildings] will key to — each at the tier its
  /// distance from [focusBF] gives it, block left out — the ones [has]
  /// answers for: what the request tells the worker not to generate.
  /// Computed here from the same inputs the worker groups by, so the two
  /// sides agree key for key (see [CityTileMesher.archetypeOf]).
  static List<BuildingArchetype> knownArchetypes(
    List<BuildingSnapshot> buildings,
    Vector3 focusBF,
    BuildingDetail colonyTier,
    CityMeshKnobs knobs,
    bool Function(BuildingArchetype) has,
  ) {
    final known = <BuildingArchetype>{};
    for (final b in buildings) {
      final tier = CityTileMesher.detailFor(b, focusBF, colonyTier, knobs);
      if (tier == BuildingDetail.block) continue;
      // The exterior and full tiers key against the FULL library, whose
      // quantisation is the knobs' own (see [CityBuildingLibraries]).
      final key = CityTileMesher.archetypeOf(b, tier, knobs,
          bucketM: knobs.bucketM, variants: knobs.variants);
      if (has(key)) known.add(key);
    }
    return known.toList();
  }

  /// A detail job's request: the gathered [buildings] as columns, the eye,
  /// and the known keys (see [CityDetailSpec]).
  static CityTileRequest requestFor({
    required String key,
    required String bodyId,
    required Vector3 anchorBF,
    required List<BuildingSnapshot> buildings,
    required Vector3 focusBF,
    required BuildingDetail colonyTier,
    required bool lotFeatures,
    required double epoch,
    required CityMeshKnobs knobs,
    required List<BuildingArchetype> known,
    List<CitySiteFrame> sites = const [],
  }) =>
      CityTileRequest(
        tileKey: 'detail/$bodyId',
        key: key,
        tier: CityTier.near,
        canDetail: lotFeatures,
        anchorBF: anchorBF,
        columns: CityTileColumns.fromSnapshots(
          buildings: buildings,
          roads: const [],
          patches: CityPatchColumns.empty,
          ends: const [],
          roadEnds: const [],
          transitEnds: const [],
          // The gathered buildings' plans, by `siteSlot >> 10` → chunk
          // (docs/plans/site-access.md §5.3); none while the knob is off.
          sites: knobs.siteAccess
              ? CityTileBucketer.siteFramesOf(
                  CityTileBucketer.sitesOfBuildings(sites, buildings))
              : const [],
        ),
        focusBF: focusBF,
        colonyTier: colonyTier,
        epoch: epoch,
        knobs: knobs,
        detailLayer: true,
        detail: CityDetailSpec(knownArchetypes: known),
      );

  // ---- State ----------------------------------------------------------------

  /// The archetype geometries this thread holds: the UI-side cache the
  /// request's known keys are read from, filled from what the workers
  /// send back. Kept across sets — a walk back down the same street
  /// generates nothing — and dropped when the knobs that shape the
  /// archetypes move, since the keys would then mean other buildings.
  final Map<BuildingArchetype, _ArchetypeGeometry> _geometry = {};
  String _librarySig = '';

  /// Bumped when [_geometry] is cleared: a job submitted against the old
  /// cache would land instances keyed to geometry that is gone.
  int _cacheEpoch = 0;

  _DetailJob? _job;
  _DetailSet? _shown;
  _DetailSet? _incoming;
  CityTileReveal? _reveal;

  /// The last frame's hooks, for the reveal's completion, which lands
  /// inside the frame's advance but through the reveal's own callback.
  void Function(Iterable<fs.Node>)? _reclaim;
  int _frameIndex = 0;

  /// Jobs submitted so far.
  int jobs = 0;

  /// Instance groups whose archetype geometry was missing when they were
  /// staged: never, unless the cache was cleared under a job.
  int misses = 0;

  /// The key of the set shown, or being shown; '' with none.
  String get currentKey => _incoming?.key ?? _shown?.key ?? '';

  /// Whether a job is between submission and swap.
  bool get busy => _job != null;

  /// Buildings in the shown set, and their tiers.
  int get shownBuildings => _shown?.buildings ?? 0;
  Map<BuildingDetail, int> get shownLodCounts => _shown?.lodCounts ?? const {};

  /// Archetype geometries held.
  int get archetypeCount => _geometry.length;

  /// One frame of the layer: re-key against [want], submit a job if the
  /// key moved and none is running, and advance the landed job's upload
  /// and the reveal under [frame]'s budgets.
  void sync(CityDetailFrame frame, CityDetailWant want) {
    _reclaim = frame.reclaim;
    _frameIndex = frame.frameIndex;
    _syncLibrary(want.knobs);
    // A set under a root that is not this frame's — the colony was
    // re-cut and its roots remade — is orphaned: out of the scene
    // already, and its buffers still held.
    final shown = _shown;
    if (shown != null && !identical(shown.root, frame.root)) {
      _dropSet(shown);
      _shown = null;
    }
    final incoming = _incoming;
    if (incoming != null && !identical(incoming.root, frame.root)) {
      _dropIncoming();
    }

    final cell = cellOf(want.focusBF);
    final key = keyFor(
      bodyId: want.bodyId,
      cell: cell,
      structureSig: want.structureSig,
      invalidation: want.invalidation,
      colonyTier: want.colonyTier,
      lotFeatures: want.lotFeatures,
      knobs: want.knobs,
    );
    if (_job == null && key != currentKey) {
      _submit(frame, want, key, cell);
    }

    // The reveal first, as the tiles' run first: a chunk bigger than what
    // the tiles left of the frame's bytes would otherwise never show.
    _reveal?.advance(frame.bytes, first: true);
    final job = _job;
    if (job != null && job.result != null) {
      _advance(frame, job);
    }
  }

  /// Everything out of the scene and forgotten — the layer switched off,
  /// or the renderer going. A job still on a worker answers into the
  /// void. The geometries go too: with the layer off the tiles' own cache
  /// serves, and this one would hold its buffers for nothing.
  void drop(void Function(Iterable<fs.Node>) reclaim) {
    _reclaim = reclaim;
    _dropIncoming();
    final shown = _shown;
    if (shown != null) {
      _dropSet(shown);
      _shown = null;
    }
    _job = null;
    _geometry.clear();
    _cacheEpoch++;
  }

  /// Drop the geometry cache when the knobs that shape the archetypes
  /// move: the same keys would then name other buildings (see
  /// `CityNodes._syncLibrary`, `_syncLodDebug`, which do this for the
  /// tiles' cache).
  void _syncLibrary(CityMeshKnobs k) {
    final sig = '${k.styleId}|${k.bucketM}|${k.variants}|${k.lodDebug}';
    if (sig == _librarySig) return;
    _librarySig = sig;
    _geometry.clear();
    _cacheEpoch++;
  }

  /// Gather the set for [key] and send it to the scheduler — or, with
  /// nothing in range, show the empty set at once.
  void _submit(
      CityDetailFrame frame, CityDetailWant want, String key, (int, int, int) cell) {
    final centre = cellCentre(cell);
    final buildings = gather(want.candidates(), centre,
        gatherRadiusM(want.knobs.blockRangeM));
    if (buildings.isEmpty) {
      _dropIncoming();
      final shown = _shown;
      if (shown != null) _dropSet(shown);
      _shown = _DetailSet(key, frame.root, const [], 0, const {});
      return;
    }
    final known = knownArchetypes(buildings, want.focusBF, want.colonyTier,
        want.knobs, _geometry.containsKey);
    final request = requestFor(
      key: key,
      bodyId: want.bodyId,
      anchorBF: centre,
      buildings: buildings,
      focusBF: want.focusBF,
      colonyTier: want.colonyTier,
      lotFeatures: want.lotFeatures,
      epoch: want.epoch,
      knobs: want.knobs,
      known: known,
      sites: want.sites,
    );
    final job = _job = _DetailJob(key, _cacheEpoch, frame.root, centre,
        frame.rootAnchorBF, frame.pool);
    jobs++;
    frame.scheduler.mesh(request).then((result) => _onResult(job, result),
        onError: (Object e, StackTrace st) {
      if (_job == job) _job = null;
    });
  }

  /// A result back: onto its job as upload steps, unless the job was
  /// dropped or the cache it was keyed against is gone.
  void _onResult(_DetailJob job, CityTileResult result) {
    if (_job != job || result.key != job.key) return;
    if (job.cacheEpoch != _cacheEpoch) {
      _job = null;
      return;
    }
    job.result = result;
    _planUpload(job, result);
  }

  /// The upload as steps, popped from the end: the archetype geometries
  /// one each, so the byte gate can stop between them; the instanced
  /// nodes in runs; the furniture chunks, resumable a slice a frame; then
  /// the one swap that attaches everything.
  void _planUpload(_DetailJob job, CityTileResult result) {
    final steps = job.steps;
    for (final a in result.archetypeMeshes) {
      steps.add(_Step.archetype(a.bytes, () {
        _geometry[a.archetype] = _ArchetypeGeometry(
            _geometryOf(a.solid), _geometryOf(a.glazing), a.lod);
      }));
    }
    final groups = result.instances;
    const perStep = 24;
    for (var i = 0; i < groups.length; i += perStep) {
      final from = i, to = (i + perStep).clamp(0, groups.length);
      steps.add(_Step.run(() {
        for (var k = from; k < to; k++) {
          _stageGroup(job, groups[k]);
        }
      }));
    }
    for (final g in result.groups) {
      _StagedChunk? staged;
      steps.add(_Step.mesh(CityMeshUploadStep(
        g.bytes,
        () => staged = _StagedChunk(g, job.pool, _frameIndex),
        () => job.stageChunk(
            fs.Node(
              mesh: fs.Mesh.primitives(primitives: [
                fs.MeshPrimitive(staged!.finish(), _materialOf(g.material))
              ]),
            )..castsShadow = g.castsShadow,
            staged!.totalBytes),
      )));
    }
    var buildings = 0;
    for (final g in groups) {
      buildings += g.count;
    }
    steps.add(_Step.run(() => _swap(job, buildings, result.lodCounts)));
    job.steps.setAll(0, steps.reversed.toList());
  }

  /// One archetype's instances onto the job's staging list: the solid on
  /// the facade (or, for a visualiser box, the palette), casting as a
  /// near tile's facades do; the glazing never casting. A set is the
  /// buildings within block range — hundreds at most — so the engine's
  /// per-draw instance ceiling is never near and one draw per archetype
  /// and material is the whole of it.
  void _stageGroup(_DetailJob job, CityInstanceGroup group) {
    final g = _geometry[group.archetype];
    if (g == null) {
      misses++;
      return;
    }
    final transforms = group.transforms;
    for (final (geometry, material, casts) in [
      (g.solid, g.lod ? CityMaterials.ground : CityMaterials.facade, true),
      (g.glazing, CityMaterials.glazing, false),
    ]) {
      if (geometry == null) continue;
      final instanced = fs.InstancedMesh(geometry: geometry, material: material);
      for (var i = 0; i < group.count; i++) {
        instanced.addInstance(vm.Matrix4.fromFloat32List(
            Float32List.sublistView(transforms, i * 16, i * 16 + 16)));
      }
      job.stage(fs.Node()
        ..addComponent(fs.InstancedMeshComponent(instanced))
        ..castsShadow = casts);
    }
  }

  /// Run the landed job's steps under the frame's budgets: the first
  /// always, then while time is left — a chunk while bytes are left, an
  /// archetype geometry likewise (it hands its whole mesh to the driver
  /// at its first draw, the same cost a revealed chunk has).
  void _advance(CityDetailFrame frame, _DetailJob job) {
    final sw = Stopwatch()..start();
    var ran = 0;
    while (job.steps.isNotEmpty) {
      if (ran > 0 && sw.elapsedMicroseconds >= frame.budgetUs) break;
      final s = job.steps.last;
      final mesh = s.mesh;
      if (mesh != null) {
        if (frame.bytes.remaining <= 0) break;
        final moved = frame.bytes.take(mesh);
        ran++;
        if (!mesh.done) {
          if (moved == 0) break;
          continue;
        }
        job.steps.removeLast();
        continue;
      }
      if (s.bytes > 0 && ran > 0 && frame.bytes.remaining <= 0) break;
      job.steps.removeLast();
      s.run!();
      if (s.bytes > 0) frame.bytes.spend(s.bytes);
      ran++;
    }
  }

  /// Attach the job's staged nodes as the incoming set, the chunks hidden
  /// for the reveal; the shown set stays until the reveal is through.
  void _swap(_DetailJob job, int buildings, Map<BuildingDetail, int> lodCounts) {
    _dropIncoming();
    final set = _DetailSet(
        job.key, job.root, List.of(job.staged), buildings, lodCounts);
    for (final node in set.nodes) {
      job.root.add(node);
    }
    _incoming = set;
    _job = null;
    if (job.reveal.isEmpty) {
      _finish();
    } else {
      _reveal = CityTileReveal(job.reveal, onDone: _finish);
    }
  }

  /// The incoming set is all shown: the old set leaves, and the incoming
  /// one is the layer's from here.
  void _finish() {
    final old = _shown;
    _shown = _incoming;
    _incoming = null;
    _reveal = null;
    if (old != null) _dropSet(old);
  }

  /// Take an incoming set out of the scene and forget its reveal: it was
  /// never fully shown, so it is not one the layer had.
  void _dropIncoming() {
    final set = _incoming;
    _incoming = null;
    _reveal = null;
    if (set != null) _dropSet(set);
  }

  /// A set out of the scene for good: its chunk buffers to the pool, its
  /// instanced nodes dropped. The archetype geometries stay in the cache.
  void _dropSet(_DetailSet set) {
    for (final node in set.nodes) {
      set.root.remove(node);
    }
    _reclaim?.call(set.nodes);
  }

  static fs.Material _materialOf(CityMaterialKind kind) {
    switch (kind) {
      case CityMaterialKind.facade:
        return CityMaterials.facade;
      case CityMaterialKind.glazing:
        return CityMaterials.glazing;
      case CityMaterialKind.ground:
        return CityMaterials.ground;
      case CityMaterialKind.road:
        return CityMaterials.road;
      case CityMaterialKind.dirt:
        return CityMaterials.dirt;
      case CityMaterialKind.alley:
        return CityMaterials.alley;
      case CityMaterialKind.sidewalk:
        return CityMaterials.sidewalk;
    }
  }

  /// An archetype mesh as geometry, with no CPU copy kept: the engine's
  /// raycast is never asked of a building, and every retained copy was
  /// old-generation data the collector marked on each pass.
  static fs.MeshGeometry? _geometryOf(PropMesh mesh) {
    if (mesh.isEmpty) return null;
    return fs.MeshGeometry.fromArrays(
      positions: mesh.positions,
      normals: mesh.normals,
      texCoords: mesh.texCoords,
      indices: mesh.indices,
      retainCpuData: false,
    );
  }
}

/// One archetype's uploaded geometry: solid and glazing, and whether the
/// solid is a visualiser box.
class _ArchetypeGeometry {
  const _ArchetypeGeometry(this.solid, this.glazing, this.lod);
  final fs.MeshGeometry? solid;
  final fs.MeshGeometry? glazing;
  final bool lod;
}

/// One shown (or being shown) set: its key, the root it hangs under, its
/// nodes, and what the panel counts.
class _DetailSet {
  const _DetailSet(
      this.key, this.root, this.nodes, this.buildings, this.lodCounts);
  final String key;
  final fs.Node root;
  final List<fs.Node> nodes;
  final int buildings;
  final Map<BuildingDetail, int> lodCounts;
}

/// One upload step: a resumable chunk ([mesh]), or a run — an archetype
/// geometry's, with the [bytes] it puts before the driver, or a plain one.
class _Step {
  _Step.mesh(CityMeshUploadStep this.mesh)
      : run = null,
        bytes = 0;
  _Step.archetype(this.bytes, void Function() this.run) : mesh = null;
  _Step.run(void Function() this.run)
      : mesh = null,
        bytes = 0;
  final CityMeshUploadStep? mesh;
  final void Function()? run;
  final int bytes;
}

/// A detail job between submission and swap.
class _DetailJob {
  _DetailJob(this.key, this.cacheEpoch, this.root, Vector3 anchorBF,
      Vector3 rootAnchorBF, this.pool)
      : local = vm.Matrix4.translation(vm.Vector3(
            lengthToScene(anchorBF.x - rootAnchorBF.x),
            lengthToScene(anchorBF.y - rootAnchorBF.y),
            lengthToScene(anchorBF.z - rootAnchorBF.z)));
  final String key;
  final int cacheEpoch;
  final fs.Node root;
  final GpuDeviceBufferPool pool;

  /// The set's place under the root: the anchor's offset, fixed for the
  /// job's life.
  final vm.Matrix4 local;
  CityTileResult? result;
  final List<_Step> steps = [];
  final List<fs.Node> staged = [];
  final List<CityRevealChunk> reveal = [];

  void stage(fs.Node node) {
    node.localTransform = local;
    staged.add(node);
  }

  void stageChunk(fs.Node node, int bytes) {
    node.visible = false;
    stage(node);
    reveal.add(CityRevealChunk(bytes, () => node.visible = true));
  }
}

/// A furniture chunk's staged upload, its buffer from the pool (see
/// `CityNodes._EngineStagedUpload`, which this mirrors for the layer).
class _StagedChunk implements CityStagedUpload {
  _StagedChunk(CityMeshGroup g, GpuDeviceBufferPool pool, int frame)
      : _staged = MeshGeometry.stageFromArrays(
          positions: g.positions,
          normals: g.normals,
          texCoords: g.texCoords,
          indices: g.indices,
          retainCpuData: false,
          allocate: (bytes) => pool.allocate(bytes, frame),
        );
  final StagedMeshUpload _staged;

  @override
  int get totalBytes => _staged.totalBytes;
  @override
  int get uploadedBytes => _staged.uploadedBytes;
  @override
  bool step(int maxBytes) => _staged.step(maxBytes);

  fs.MeshGeometry finish() => _staged.finish();
}
