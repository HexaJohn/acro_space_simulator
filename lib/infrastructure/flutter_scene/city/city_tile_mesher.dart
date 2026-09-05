// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The per-tile meshing of a colony, as a pure function of a request.
///
/// Everything a tile is drawn from — its roads, junctions, buildings,
/// patches and lot furniture — is generated here from the frame's snapshot
/// objects and nothing else: no scene, no GPU, no static read off the UI
/// thread. That is what lets the work run on a worker isolate (see
/// `city_tile_scheduler.dart`); the only thing that has to stay on the
/// render thread is the upload, which `CityNodes` does from the result.
///
/// Determinism is the contract. A worker and the UI thread both compute
/// archetype keys — the worker to group instances, the UI thread to find
/// or generate the archetype's mesh — and they must agree, so every input
/// the keys and the geometry depend on travels in the request as plain
/// values ([CityMeshKnobs]) rather than being read off `CityNodes`
/// statics, which a second isolate holds its own, default copy of. For
/// the same reason nothing here seeds anything from `Object.hash`: that
/// hash is salted per isolate, so two workers would jitter the same
/// street's furniture differently between rebuilds.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:vector_math/vector_math.dart' as vm;

import '../../../application/snapshot/world_snapshot.dart';
import '../../../domain/architecture/architecture_style.dart';
import '../../../domain/architecture/building_generator.dart';
import '../../../domain/architecture/building_massing.dart';
import '../../../domain/colony/city/city_building_spec.dart';
import '../../../domain/colony/city/parcel.dart';
import '../../../domain/scatter/mesh_builder.dart';
import '../../../domain/scatter/prop_mesh.dart';
import '../../../domain/shared/quaternion.dart';
import '../../../domain/shared/vector3.dart';
import '../coord_convert.dart';
import 'city_tile_columns.dart';
import 'elevated_structure.dart';
import 'lot_features.dart';
import 'mesh_merge.dart';
import 'oriented_box.dart';
import 'pedestrian_tube.dart';
import 'railway.dart';
import 'road_mesher.dart';
import 'street_furniture.dart';
import 'vehicle_meshes.dart';

export 'city_tile_columns.dart' show CityTileEnd, CityTileMembers;

/// How much of a tile is drawn, by its distance from the camera.
enum CityTier {
  /// Everything: sidewalks, lamps, furniture, junction signals, lot fences
  /// and car parks, street trees; buildings at their own tier.
  near,

  /// Lanes painted, junction plates, turning circles; buildings as their
  /// block silhouettes.
  mid,

  /// Asphalt ribbons and silhouettes.
  far,
}

/// The colony's distinct surface materials — the merge key of the upload.
///
/// A tile's builders are split by WHAT they draw (ribbons, lamps, props,
/// curbs, tubes, lot fences, cars, rail) so the passes that fill them can
/// stay simple; the GPU cares only which material a triangle takes, and
/// there are seven. Uploading one mesh per builder cost a near tile fifteen
/// to twenty-five draws — about ten microseconds of engine time each in
/// the colour pass, and again in the shadow pass — where seven would do.
/// So the upload merges every builder of one material into one geometry,
/// keyed by THIS rather than by the material handle, which the texture and
/// shader loads reset (see `CityMaterials.reset`) and which is therefore
/// resolved only when the upload step runs.
enum CityMaterialKind { facade, glazing, ground, road, dirt, alley, sidewalk }

/// The renderer-side switches the emitters read, captured as values.
///
/// `CityNodes` holds these as statics the studio's panel flips. A worker
/// isolate has its own copy of every static, at its default, so the values
/// travel with each request instead — and they are part of the tile's
/// build key anyway, so a request built from them describes exactly the
/// output the key promises.
class CityMeshKnobs {
  const CityMeshKnobs({
    required this.styleId,
    required this.bucketM,
    required this.variants,
    required this.perBuildingLod,
    required this.blockRangeM,
    required this.interiorRangeM,
    required this.lodDebug,
    required this.onStreetParking,
    required this.sealedWorld,
    required this.maxParkedCars,
  });

  /// The architecture kit the colony is built in (see
  /// [ArchitectureStyle.byId]).
  final String styleId;

  /// Lot-size quantisation and variant count of the FULL archetype library;
  /// the block-tier library is twice as coarse with half the variants (see
  /// [CityBuildingLibraries]).
  final double bucketM;
  final int variants;

  /// Whether each building takes its tier from its own distance.
  final bool perBuildingLod;

  /// The per-building tier ranges (see [tierForDistance]).
  final double blockRangeM;
  final double interiorRangeM;

  /// The LOD visualiser: every building instanced, none baked into the
  /// skyline, so the UI side can draw a coloured box per archetype.
  final bool lodDebug;

  /// Whether curbside bays are used.
  final bool onStreetParking;

  /// An airless world: parked vehicles are rovers, pavements are tubes.
  final bool sealedWorld;

  /// Ceiling on parked cars per tile.
  final int maxParkedCars;

  ArchitectureStyle get style => ArchitectureStyle.byId(styleId);

  /// Whether the archetype libraries built for [other] serve this too.
  bool sameLibraries(CityMeshKnobs other) =>
      styleId == other.styleId &&
      bucketM == other.bucketM &&
      variants == other.variants;
}

/// Everything one tile build reads: the tile's members, the few facts of
/// the body's whole road network its roads need, the camera, and the knobs.
///
/// Self-contained on purpose. The body root's end table and transit-end
/// list are colony-wide — tens of thousands of entries on a big city — so
/// a request carries only the entries the tile's own roads touch, worked
/// out on the UI thread where the root lives (see
/// [CityTileMembers.roadEnds], [CityTileMembers.transitEnds]). Copying the
/// whole table into a worker per job would cost more than the meshing it
/// enables.
///
/// The members travel as [columns], not as snapshot objects: an isolate
/// send copies a typed list as one block and an object graph one object
/// at a time, and a near tile's roads are tens of thousands of objects
/// (see `city_tile_columns.dart`). The side that meshes rebuilds the
/// snapshots from the columns once, in [CityTileMeshJob.members] — the
/// worker's time, not the UI thread's.
class CityTileRequest {
  const CityTileRequest({
    required this.tileKey,
    required this.key,
    required this.tier,
    required this.canDetail,
    required this.anchorBF,
    required this.columns,
    required this.focusBF,
    required this.colonyTier,
    required this.epoch,
    required this.knobs,
  });

  /// The tile's identity, by body and cell.
  final String tileKey;

  /// The build key this request answers; the result carries it back so a
  /// tile can tell a stale answer from the one it is waiting for.
  final String key;
  final CityTier tier;

  /// Whether any building in the tile can resolve past its block
  /// silhouette (`CityNodes.tileCanDetail`): gates the lot furniture.
  final bool canDetail;

  /// The tile's anchor, body-fixed metres: every vertex is emitted relative
  /// to it.
  final Vector3 anchorBF;

  /// The tile's buildings, roads, patches, ends, road-end facts and
  /// transit ends, packed (see [CityTileColumns]).
  final CityTileColumns columns;

  /// The camera in the body's frame; per-building detail is measured from
  /// it.
  final Vector3 focusBF;

  /// The colony-wide fallback tier, used when [CityMeshKnobs.perBuildingLod]
  /// is off.
  final BuildingDetail colonyTier;

  /// Sim time, for the junction signals' phase.
  final double epoch;
  final CityMeshKnobs knobs;
}

/// One material's merged geometry for a tile, or one chunk of it: one
/// draw, and one GPU buffer of at most [CityTileMesher.maxGroupBytes]
/// (see [CityTileMesher.chunk]).
class CityMeshGroup {
  const CityMeshGroup({
    required this.material,
    required this.castsShadow,
    required this.positions,
    required this.normals,
    required this.texCoords,
    required this.indices,
  });
  final CityMaterialKind material;
  final bool castsShadow;
  final Float32List positions;
  final Float32List normals;
  final Float32List texCoords;
  final Uint32List indices;

  int get vertexCount => positions.length ~/ 3;
  int get triangleCount => indices.length ~/ 3;

  /// What the group occupies on the GPU: every vertex at the engine's
  /// [CityTileMesher.bytesPerVertex] — the colour stream it adds included,
  /// which the four streams here do not carry — plus the indices. The
  /// chunk cap is judged against this, and so is the reveal budget (see
  /// `CityNodes.uploadBytesPerFrame`), so the two agree about what a
  /// frame's worth of geometry is.
  int get bytes =>
      vertexCount * CityTileMesher.bytesPerVertex +
      indices.length * CityTileMesher.bytesPerIndex;
}

/// One archetype's instances in a tile: the key, a building that has it —
/// so the UI thread can generate the archetype's mesh if it holds none —
/// and the transforms, sixteen floats each, column-major.
class CityInstanceGroup {
  const CityInstanceGroup({
    required this.archetype,
    required this.representative,
    required this.transforms,
  });
  final BuildingArchetype archetype;
  final BuildingSnapshot representative;
  final Float32List transforms;

  int get count => transforms.length ~/ 16;
}

/// What a tile build produced, ready to upload. Typed data and small
/// values only, so it crosses an isolate boundary cheaply (see [pack]).
class CityTileResult {
  const CityTileResult({
    required this.tileKey,
    required this.key,
    required this.tier,
    required this.groups,
    required this.instances,
    required this.treePits,
    required this.shrubPits,
    required this.lodCounts,
    required this.skylineTris,
  });
  final String tileKey;
  final String key;
  final CityTier tier;
  final List<CityMeshGroup> groups;
  final List<CityInstanceGroup> instances;

  /// Street-tree pits and planter soil lines, four doubles each — the pit
  /// relative to the tile's anchor, metres, then its yaw — planted by the
  /// UI side as instances of the scatter props, which are textured and
  /// cached there.
  final Float64List treePits;
  final Float64List shrubPits;
  final Map<BuildingDetail, int> lodCounts;

  /// Triangles of block-tier buildings baked into the facade and glazing
  /// groups: the panel's "skyline tris".
  final int skylineTris;

  /// The upload's bytes, over every group.
  int get bytes => groups.fold(0, (n, g) => n + g.bytes);

  static int pitCount(Float64List pits) => pits.length ~/ 4;

  /// Lay every typed array out in ONE byte blob, eight-byte aligned, and
  /// describe where each lies: the shape a worker sends back. The blob can
  /// travel as a `TransferableTypedData` — one copy on the worker, none on
  /// the receiver — and [unpack] rebuilds the result as views over it.
  (CityTilePackedLayout, Uint8List) pack() {
    var offset = 0;
    final spans = <(int, int)>[];
    int reserve(TypedData d) {
      final at = offset;
      spans.add((at, d.lengthInBytes));
      offset = (at + d.lengthInBytes + 7) & ~7;
      return at;
    }

    final groupSpans = <List<int>>[];
    for (final g in groups) {
      groupSpans.add([
        g.material.index,
        g.castsShadow ? 1 : 0,
        reserve(g.positions),
        g.positions.length,
        reserve(g.normals),
        g.normals.length,
        reserve(g.texCoords),
        g.texCoords.length,
        reserve(g.indices),
        g.indices.length,
      ]);
    }
    final instanceSpans = <List<int>>[
      for (final g in instances) [reserve(g.transforms), g.transforms.length],
    ];
    final treeSpan = [reserve(treePits), treePits.length];
    final shrubSpan = [reserve(shrubPits), shrubPits.length];
    final blob = Uint8List(offset);
    var i = 0;
    void put(TypedData d) {
      final (at, len) = spans[i++];
      blob.setRange(at, at + len, d.buffer.asUint8List(d.offsetInBytes, len));
    }

    for (final g in groups) {
      put(g.positions);
      put(g.normals);
      put(g.texCoords);
      put(g.indices);
    }
    for (final g in instances) {
      put(g.transforms);
    }
    put(treePits);
    put(shrubPits);
    return (
      CityTilePackedLayout(
        tileKey: tileKey,
        key: key,
        tierIndex: tier.index,
        groups: groupSpans,
        archetypes: [for (final g in instances) g.archetype],
        representatives: [for (final g in instances) g.representative],
        instanceSpans: instanceSpans,
        treeSpan: treeSpan,
        shrubSpan: shrubSpan,
        lodCounts: {for (final e in lodCounts.entries) e.key.index: e.value},
        skylineTris: skylineTris,
      ),
      blob,
    );
  }

  /// A copy that aliases nothing: [pack]ed and [unpack]ed. A job's own
  /// result is views over its scratch sinks (see [CityMeshScratch]), which
  /// the next job on the same scheduler overwrites; the worker path detaches
  /// by sending the blob, and the inline scheduler by this.
  CityTileResult detached() {
    final (layout, blob) = pack();
    return unpack(layout, blob.buffer);
  }

  /// The inverse of [pack]: the result as views over [blob], no copies.
  static CityTileResult unpack(CityTilePackedLayout layout, ByteBuffer blob) {
    Float32List f32(int at, int len) => Float32List.view(blob, at, len);
    return CityTileResult(
      tileKey: layout.tileKey,
      key: layout.key,
      tier: CityTier.values[layout.tierIndex],
      groups: [
        for (final s in layout.groups)
          CityMeshGroup(
            material: CityMaterialKind.values[s[0]],
            castsShadow: s[1] != 0,
            positions: f32(s[2], s[3]),
            normals: f32(s[4], s[5]),
            texCoords: f32(s[6], s[7]),
            indices: Uint32List.view(blob, s[8], s[9]),
          ),
      ],
      instances: [
        for (var i = 0; i < layout.archetypes.length; i++)
          CityInstanceGroup(
            archetype: layout.archetypes[i],
            representative: layout.representatives[i],
            transforms:
                f32(layout.instanceSpans[i][0], layout.instanceSpans[i][1]),
          ),
      ],
      treePits:
          Float64List.view(blob, layout.treeSpan[0], layout.treeSpan[1]),
      shrubPits:
          Float64List.view(blob, layout.shrubSpan[0], layout.shrubSpan[1]),
      lodCounts: {
        for (final e in layout.lodCounts.entries)
          BuildingDetail.values[e.key]: e.value
      },
      skylineTris: layout.skylineTris,
    );
  }
}

/// Where everything of a [CityTileResult] lies in its packed blob: the
/// small, plainly sendable half of a worker's answer.
class CityTilePackedLayout {
  const CityTilePackedLayout({
    required this.tileKey,
    required this.key,
    required this.tierIndex,
    required this.groups,
    required this.archetypes,
    required this.representatives,
    required this.instanceSpans,
    required this.treeSpan,
    required this.shrubSpan,
    required this.lodCounts,
    required this.skylineTris,
  });
  final String tileKey;
  final String key;
  final int tierIndex;

  /// Per group: material index, casts (0/1), then byte offset and element
  /// count of positions, normals, texCoords, indices.
  final List<List<int>> groups;
  final List<BuildingArchetype> archetypes;
  final List<BuildingSnapshot> representatives;

  /// Per instance group: byte offset and float count of its transforms.
  final List<List<int>> instanceSpans;
  final List<int> treeSpan, shrubSpan;
  final Map<int, int> lodCounts;
  final int skylineTris;
}

/// The archetype libraries a mesher generates from, full and coarse, keyed
/// by the knobs that shape them. Every side that meshes — each worker, the
/// inline scheduler, and the UI thread for the instanced meshes it uploads
/// — holds its own, rebuilt when the knobs move.
class CityBuildingLibraries {
  BuildingLibrary? _full, _coarse;
  String _styleId = '';
  double _bucketM = -1;
  int _variants = -1;

  /// The libraries built for the knobs, rebuilt if these differ from the
  /// last. Returns true when they were rebuilt: everything keyed by the old
  /// quantisation is then stale.
  bool sync(String styleId, double bucketM, int variants) {
    if (_full != null &&
        _styleId == styleId &&
        _bucketM == bucketM &&
        _variants == variants) {
      return false;
    }
    final style = ArchitectureStyle.byId(styleId);
    _styleId = styleId;
    _bucketM = bucketM;
    _variants = variants;
    _full = BuildingLibrary(
      generator: const BuildingGenerator().withStyle(style),
      bucketM: bucketM,
      variants: variants,
    );
    // The library the BLOCK tier draws from: buckets twice as coarse, half
    // the variants. A block-tier building is a silhouette box hundreds of
    // metres away, where a two-metre size quantum and a repeated massing
    // are invisible — but every distinct archetype is an uploaded mesh and
    // a solid+glazing draw pair, and the block tier is most of any city
    // seen from its framing distance. Coarser sharing there is draw calls
    // off the dominant tier for a difference nobody can resolve.
    _coarse = BuildingLibrary(
      generator: const BuildingGenerator().withStyle(style),
      bucketM: bucketM * 2,
      variants: math.max(1, variants ~/ 2),
    );
    // Keyed by the old coarse library's objects, which nothing will ask
    // for again.
    _massingBoxes.clear();
    return true;
  }

  bool syncKnobs(CityMeshKnobs k) => sync(k.styleId, k.bucketM, k.variants);

  /// The library serving [tier]. [sync] must have run.
  BuildingLibrary forTier(BuildingDetail tier) =>
      tier == BuildingDetail.block ? _coarse! : _full!;

  /// The far tier's version of a coarse archetype: its massing as plain
  /// boxes (see [CityTileMesher.massingBoxes]), built once per cached
  /// archetype and keyed by the library's own object, so a district of
  /// one archetype boxes it once whichever tile asks.
  final Map<GeneratedBuilding, PropMesh> _massingBoxes = {};

  PropMesh massingBoxesOf(GeneratedBuilding built) => _massingBoxes
      .putIfAbsent(built, () => CityTileMesher.massingBoxes(built.massing));

  /// Meshes cached, both libraries.
  int get meshCount => (_full?.meshCount ?? 0) + (_coarse?.meshCount ?? 0);

  void clear() {
    _full?.clear();
    _coarse?.clear();
    _massingBoxes.clear();
  }
}

/// The merge sinks one side's tile builds share, job after job.
///
/// A tile build merges every builder of a material into one sink, and a
/// near tile's are megabytes each. Allocated per job they went straight to
/// the old generation (large typed lists never see the nursery), so a
/// worker meshing a few tiles ran an old-space collection whose
/// stop-the-world phases — the mark, the weak-handle sweep — paused every
/// isolate of the group, the UI isolate included. Held here, one set per
/// worker (or per inline scheduler), the sinks are grown to the largest
/// tile once and [MergedMeshSink.reset] between jobs, and the per-tile
/// garbage is the small stuff.
///
/// The price is that a job's result is VIEWS over these buffers, valid
/// only until the next job claims them: every path that hands a result
/// on copies it first ([CityTileResult.pack] on the worker,
/// [CityTileResult.detached] inline). A [claim] by a new owner resets
/// every sink, so a job that appended after another claimed would corrupt
/// both; the schedulers run their jobs one at a time, which is the
/// contract.
class CityMeshScratch {
  final Map<CityMaterialKind, MergedMeshSink> _plain = {};
  final List<MergedMeshSink> _spare = [];
  Object? _owner;

  /// Make [owner]'s the sinks: the first claim by a new owner empties them.
  void claim(Object owner) {
    if (identical(_owner, owner)) return;
    _owner = owner;
    for (final sink in _plain.values) {
      sink.reset();
    }
    for (final sink in _spare) {
      sink.reset();
    }
  }

  /// The sink for [kind]'s plain group — the one its skyline goes into.
  MergedMeshSink plain(CityMaterialKind kind) =>
      _plain.putIfAbsent(kind, () => MergedMeshSink());

  /// The [i]th odd group's sink: a material whose shadow answer differs
  /// from its plain group's (the elevated deck on a near tile).
  MergedMeshSink spare(int i) {
    while (_spare.length <= i) {
      _spare.add(MergedMeshSink());
    }
    return _spare[i];
  }

  /// Vertex capacity over every sink, for the reuse test.
  int get vertexCapacity =>
      _plain.values.fold(0, (n, s) => n + s.vertexCapacity) +
      _spare.fold(0, (n, s) => n + s.vertexCapacity);
}

/// The kinds of step a tile's meshing is made of. The inline scheduler
/// books the last cost of each kind and will not start one that would not
/// fit the frame's remaining budget.
enum CityMeshStepKind {
  roads,
  junctions,
  buildings,
  patches,
  lots,
  // Every builder of one material and the skyline into one geometry.
  merge,
  // The instance groups and pits into their typed arrays.
  pack,
}

/// One part of a tile's meshing.
class CityMeshStep {
  const CityMeshStep(this.kind, this.run);
  final CityMeshStepKind kind;
  final void Function() run;
}

/// A tile's meshing in progress: its builders, and the parts still to run.
///
/// Parts, run from the end: roads in runs, then the junctions and the
/// terminals over them, then buildings in runs, the ground, the lot
/// furniture, then the merge — every builder into geometry — and last the
/// pack. Small runs: a worker runs them back to back, but the inline
/// scheduler checks its budget between parts, and a part is the least a
/// frame can overshoot by. A run of four hundred buildings against a cold
/// archetype cache was a hundred milliseconds; a twenty-mile city has a
/// thousand such runs.
class CityTileMeshJob {
  CityTileMeshJob(this.request, this.libraries, {CityMeshScratch? scratch})
      : _scratch = scratch ?? CityMeshScratch() {
    libraries.syncKnobs(request.knobs);
    _plan();
  }

  final CityTileRequest request;
  final CityBuildingLibraries libraries;

  /// The merge sinks, shared with every other job on this side and claimed
  /// on first touch — at the first step that appends, not at construction,
  /// since an inline scheduler constructs a job while the one before it is
  /// still running. The result aliases them (see [CityMeshScratch]).
  final CityMeshScratch _scratch;

  /// The tile's members, rebuilt from the request's columns here — once
  /// per job, on whichever side meshes — so the emitters read the snapshot
  /// objects they always did (see `city_tile_columns.dart`).
  late final CityTileMembers members = request.columns.toSnapshots();

  /// The parts of the build, run one per call from the end. A running
  /// step may push more onto the end, and they run next.
  final List<CityMeshStep> steps = [];

  final _RoadBuilders _roads = _RoadBuilders();
  final MeshBuilder _patches = MeshBuilder();
  final MeshBuilder _featureSolid = MeshBuilder();
  final MeshBuilder _featureGlow = MeshBuilder();
  final MeshBuilder _featureApron = MeshBuilder();
  final MeshBuilder _featureCars = MeshBuilder();
  late int _carBudget = request.knobs.maxParkedCars;

  /// One merged sink per material: the skyline's block-tier buildings and
  /// every builder of that material, one geometry per chunk and one draw
  /// each (see [CityTileMesher.uploadGroups], [CityTileMesher.chunk]).
  MergedMeshSink _sinkFor(CityMaterialKind kind) {
    _scratch.claim(this);
    return _scratch.plain(kind);
  }

  MergedMeshSink _spareSink(int i) {
    _scratch.claim(this);
    return _scratch.spare(i);
  }

  /// The skyline: block-tier buildings baked straight into the facade and
  /// glazing sinks rather than instanced per archetype — see
  /// [_emitBuilding].
  MergedMeshSink get _skylineSolid => _sinkFor(CityMaterialKind.facade);
  MergedMeshSink get _skylineGlazing => _sinkFor(CityMaterialKind.glazing);

  /// Instances per archetype, in first-seen order, with the building each
  /// group was first keyed from.
  final Map<BuildingArchetype, (BuildingSnapshot, List<vm.Matrix4>)> _groups =
      {};
  final Map<BuildingDetail, int> _lodCounts = {};
  int _skylineTris = 0;
  final List<CityMeshGroup> _merged = [];
  CityTileResult? _result;

  bool get done => steps.isEmpty;

  /// The result, once every step has run.
  CityTileResult get result {
    final r = _result;
    if (r == null) throw StateError('tile ${request.tileKey} not meshed yet');
    return r;
  }

  /// Run the next step. Returns its kind.
  CityMeshStepKind step() {
    final s = steps.removeLast();
    s.run();
    return s.kind;
  }

  /// Run every remaining step: the worker's way through.
  CityTileResult runAll() {
    while (steps.isNotEmpty) {
      step();
    }
    return result;
  }

  void _plan() {
    final r = request;
    final m = members;
    const roadsPerStep = 16;
    for (var i = 0; i < m.roads.length; i += roadsPerStep) {
      final from = i, to = math.min(i + roadsPerStep, m.roads.length);
      steps.add(CityMeshStep(CityMeshStepKind.roads, () {
        for (var k = from; k < to; k++) {
          _emitRoad(k);
        }
      }));
    }
    steps.add(CityMeshStep(CityMeshStepKind.junctions, _emitJunctions));
    const buildingsPerStep = 100;
    for (var i = 0; i < m.buildings.length; i += buildingsPerStep) {
      final from = i, to = math.min(i + buildingsPerStep, m.buildings.length);
      steps.add(CityMeshStep(CityMeshStepKind.buildings, () {
        for (var k = from; k < to; k++) {
          _emitBuilding(m.buildings[k]);
        }
      }));
    }
    steps.add(CityMeshStep(CityMeshStepKind.patches, _emitPatches));
    // Only where some building can resolve past a box: the furniture pass
    // skips every block-tier lot, so a tile that cannot detail would run
    // its steps to emit nothing (see `CityNodes.tileCanDetail`).
    if (r.canDetail) {
      const perStep = 60;
      for (var i = 0; i < m.buildings.length; i += perStep) {
        final from = i, to = math.min(i + perStep, m.buildings.length);
        steps.add(CityMeshStep(CityMeshStepKind.lots,
            () => _emitLotFeatures(m.buildings.sublist(from, to))));
      }
    }
    _addMergeSteps();
    steps.add(CityMeshStep(CityMeshStepKind.pack, _pack));
    // The caller pops from the end.
    steps.setAll(0, steps.reversed.toList());
  }

  /// Every builder by the material it takes, and whether it stands off
  /// the ground. The builders stay split by what they draw; the upload
  /// does not: each (material, casts-a-shadow) group is ONE geometry and
  /// one draw, merged with the skyline of the same material — seven or so
  /// draws for a near tile where a builder each was two dozen.
  void _addMergeSteps() {
    final r = _roads;
    final sources = <(MeshBuilder, CityMaterialKind, bool)>[
      // The ribbon takes the dedicated road strip — on the facade material it
      // rendered as a run of blank concrete with no curbs and no centre line,
      // which from the cockpit read as "roads are missing".
      (r.ribbon, CityMaterialKind.road, false),
      (r.dirtRibbon, CityMaterialKind.dirt, false),
      (r.alleyRibbon, CityMaterialKind.alley, false),
      (r.walkRibbon, CityMaterialKind.sidewalk, false),
      (r.railBallast, CityMaterialKind.dirt, false),
      (r.railConcrete, CityMaterialKind.sidewalk, false),
      (r.railSteel, CityMaterialKind.alley, false),
      // The elevated deck is the one flat surface that casts: the street
      // under an overpass is in its shadow.
      (r.airDeck, CityMaterialKind.road, true),
      (r.airSolid, CityMaterialKind.facade, false),
      (r.airGlow, CityMaterialKind.glazing, false),
      (r.propSolid, CityMaterialKind.facade, false),
      (r.propGlow, CityMaterialKind.glazing, false),
      (r.lampSolid, CityMaterialKind.facade, false),
      (r.lampGlow, CityMaterialKind.glazing, false),
      // The pedestrian tube: a concrete curb carrying a glass barrel.
      (r.tubeSolid, CityMaterialKind.facade, false),
      (r.tubeGlass, CityMaterialKind.glazing, false),
      (r.curbSolid, CityMaterialKind.facade, false),
      (r.curbGlass, CityMaterialKind.glazing, false),
      // The lot furniture: fences, aprons, parked cars, lit signs.
      (_featureSolid, CityMaterialKind.facade, false),
      (_featureApron, CityMaterialKind.road, false),
      (_featureCars, CityMaterialKind.facade, false),
      (_featureGlow, CityMaterialKind.glazing, false),
      (_patches, CityMaterialKind.ground, false),
    ];
    final tier = request.tier;
    // One step per group, so the inline scheduler can stop between them: a
    // downtown tile's facade group is most of its triangles.
    var spares = 0;
    for (final entry in CityTileMesher.uploadGroups(sources, tier).entries) {
      final (kind, casts) = entry.key;
      final builders = entry.value;
      // A group with the material's own shadow answer merges into the
      // job's sink for it — where the block-tier skyline already is, on
      // facade and glazing. The odd group out (the elevated deck on a
      // near tile) takes a spare sink of its own, numbered at plan time
      // so the same tile claims the same spare on every side.
      final plain = casts == CityTileMesher.castsShadowFor(tier, kind);
      final spare = plain ? -1 : spares++;
      steps.add(CityMeshStep(CityMeshStepKind.merge, () {
        final sink = plain ? _sinkFor(kind) : _spareSink(spare);
        // The skyline's share of the sink, counted before the street's
        // builders join it: the panel's "skyline tris" means buildings.
        if (plain &&
            (kind == CityMaterialKind.facade ||
                kind == CityMaterialKind.glazing)) {
          _skylineTris += sink.triangleCount;
        }
        CityTileMesher.mergeBuilders(builders, into: sink);
        if (sink.isEmpty) return;
        // Cut to the chunk cap here, on the worker, so what the UI thread
        // receives is already the buffers it will make, each small
        // enough to reveal in a frame.
        _merged.addAll(CityTileMesher.chunk(sink.build(),
            material: kind, castsShadow: casts));
      }));
    }
  }

  void _pack() {
    final instances = <CityInstanceGroup>[];
    _groups.forEach((key, entry) {
      final (rep, transforms) = entry;
      final out = Float32List(transforms.length * 16);
      for (var i = 0; i < transforms.length; i++) {
        out.setRange(i * 16, i * 16 + 16, transforms[i].storage);
      }
      instances.add(CityInstanceGroup(
          archetype: key, representative: rep, transforms: out));
    });
    _result = CityTileResult(
      tileKey: request.tileKey,
      key: request.key,
      tier: request.tier,
      groups: _merged,
      instances: instances,
      treePits: _packPits(_roads.treePits),
      shrubPits: _packPits(_roads.shrubPits),
      lodCounts: _lodCounts,
      skylineTris: _skylineTris,
    );
  }

  static Float64List _packPits(List<(Vector3, double)> pits) {
    final out = Float64List(pits.length * 4);
    for (var i = 0; i < pits.length; i++) {
      final (at, yaw) = pits[i];
      out[i * 4] = at.x;
      out[i * 4 + 1] = at.y;
      out[i * 4 + 2] = at.z;
      out[i * 4 + 3] = yaw;
    }
    return out;
  }

  /// One building into the tile: an instance of its archetype at its own
  /// tier, or a box in the tile's skyline.
  void _emitBuilding(BuildingSnapshot b) {
    final r = request;
    final k = r.knobs;
    final spec = CityTileMesher.specOf(b);
    final parcel = CityTileMesher.parcelOf(b, k.style);
    final seed = b.id.hashCode;
    // A tile beyond the near range is silhouettes whatever the building's
    // own distance says: nothing in it resolves past a box.
    final tier = r.tier == CityTier.near
        ? CityTileMesher.detailFor(b, r.focusBF, r.colonyTier, k)
        : BuildingDetail.block;
    _lodCounts[tier] = (_lodCounts[tier] ?? 0) + 1;
    // Block tier keys and meshes against the coarse library, so the
    // dominant tier shares far fewer archetypes (and draws).
    final lib = libraries.forTier(tier);
    // The skyline: block-tier buildings are BAKED into one mesh per
    // material for the whole tile rather than instanced per archetype.
    // The visualiser keeps the instanced path so its boxes stay one per
    // archetype.
    if (tier == BuildingDetail.block && !k.lodDebug) {
      final built = lib.get(spec, parcel, seed: seed, detail: tier);
      final m = CityTileMesher.instanceTransform(r.anchorBF, b);
      if (r.tier == CityTier.far) {
        // A far tile's buildings are one or two pixels tall from where the
        // tile is judged far: its massing as plain boxes, on the building's
        // own facade band, and no glazing — the skyglow carries the night
        // look at that range. The coarse model is still a facade — a quad
        // per three metres of wall and a window band per storey — and at
        // a hundred thousand triangles a tile, over the hundred-odd far
        // tiles of a colony, it was most of the skyline's triangles and
        // most of every far tile's upload, for silhouettes nothing can
        // resolve (see [CityTileMesher.massingBoxes]).
        _skylineSolid.append(libraries.massingBoxesOf(built), m);
        return;
      }
      _skylineSolid.append(built.model.solid, m);
      _skylineGlazing.append(built.model.foliage, m);
      return;
    }
    // The style is part of the key here for the same reason it is part of
    // it inside the library: this map and the UI thread's mesh cache are
    // looked up with keys built independently, and a key that forgot the
    // style would upload one building's mesh and then serve it for a
    // different kit's.
    final key = BuildingArchetype.of(spec, parcel,
        detail: tier,
        seed: seed,
        bucketM: lib.bucketM,
        variants: lib.variants,
        styleId: k.styleId,
        corner: b.corner);
    _groups
        .putIfAbsent(key, () => (b, []))
        .$2
        .add(CityTileMesher.instanceTransform(r.anchorBF, b));
  }

  /// Flat ground patches: roads, zoned lots, support decks.
  ///
  /// One mesh for all of them, coloured by a UV into the ground palette. The
  /// mesh format has no vertex-colour channel, and a material per colour would
  /// be five draws for what is a single sheet of ground.
  void _emitPatches() {
    final m = _patches;
    final anchorBF = request.anchorBF;
    for (final p in members.patches) {
      final centre = Vector3(p.px, p.py, p.pz) - anchorBF;
      final up = (centre + anchorBF).normalized;
      final basis = Quaternion(p.qw, p.qx, p.qy, p.qz);
      final east = basis.rotate(Vector3.unitX);
      final north = basis.rotate(Vector3.unitY);
      final hw = p.sizeM / 2;
      final hd = p.depthM / 2;
      // Lifted clear of the levelled pad, and each kind by a different amount,
      // so a road drawn over a zoned lot does not z-fight it.
      final lift = up * (0.05 + p.kind * 0.01);
      final c = [
        centre + east * -hw + north * -hd + lift,
        centre + east * hw + north * -hd + lift,
        centre + east * hw + north * hd + lift,
        centre + east * -hw + north * hd + lift,
      ];
      // A road maps its whole quad ACROSS its swatch, so the tile's markings
      // and curbs land on the pavement. Every other kind is a flat colour and
      // samples the swatch CENTRE, where no filtering or mip level can bleed a
      // neighbouring kind's colour in.
      final List<(double, double)> uv;
      if (p.kind == CityPatchSnapshot.kindRoad) {
        // Inset by a texel's worth so the sampler cannot reach the next swatch.
        const e = 0.004;
        final u0 = p.kind / kGroundSwatches + e,
            u1 = (p.kind + 1) / kGroundSwatches - e;
        uv = [(u0, 1.0), (u1, 1.0), (u1, 0.0), (u0, 0.0)];
      } else {
        // Against kGroundSwatches, NOT the number of patch kinds. The palette
        // has grown twice — cursor and refusal swatches, then the two the
        // placement heatmap paints with — and a local divisor of 5 does not
        // grow with it. Every patch was reading the wrong band: residential
        // sampled commercial blue, industrial sampled refusal red, support
        // sampled the heatmap amber. Exactly the drift kGroundSwatches was
        // introduced to stop, still live at this one call site.
        final u = (p.kind + 0.5) / kGroundSwatches;
        uv = [(u, 0.5), (u, 0.5), (u, 0.5), (u, 0.5)];
      }
      final idx = [
        for (var k = 0; k < 4; k++)
          m.vertex(CityTileMesher.scenePos(c[k]), up, uv[k].$1, uv[k].$2)
      ];
      m.quad(idx[0], idx[1], idx[2], idx[3]);
    }
  }

  /// Fences and shop signs, car parks and their cars, into the tile.
  ///
  /// What a lot is zoned decides what stands on its boundary: a picket fence
  /// round a house, chain link round a works, a lit board over a shopfront.
  /// Derived from the building's own type, which already encodes both kind and
  /// density, so nothing new crosses the wire.
  ///
  /// Tiered by the building's OWN LOD, the same way the building is: a lot the
  /// camera resolves as a block silhouette gets no furniture at all, an
  /// exterior-tier lot gets the coarse fence, and only a full-tier lot pays
  /// for pickets. Fences were being emitted per picket for every lot in the
  /// colony — 774 ms of a 780 ms rebuild spent on geometry that, from the
  /// studio's framing distance, was entirely sub-pixel.
  void _emitLotFeatures(List<BuildingSnapshot> buildings) {
    final r = request;
    final k = r.knobs;
    final solid = _featureSolid;
    final glow = _featureGlow;
    final apron = _featureApron;
    final cars = _featureCars;
    final anchorBF = r.anchorBF;

    for (final b in buildings) {
      final tier = CityTileMesher.detailFor(b, r.focusBF, r.colonyTier, k);
      if (tier == BuildingDetail.block) continue;
      final edging = LotFeatures.edgingFor(b.type);
      final sign = LotFeatures.signFor(b.type);
      final spec = CityTileMesher.specOf(b);
      final parcel = CityTileMesher.parcelOf(b, k.style);
      // The massing the building was DRAWN from — the library's cached one,
      // canonical lot and variant and all — so the lot the paint goes on and
      // the door the path runs to are the ones in the mesh.
      final built = libraries
          .forTier(tier)
          .get(spec, parcel, seed: b.id.hashCode, detail: tier);
      final massing = built.massing;
      final lot = massing.parking;
      if (edging == LotEdging.none && !sign && lot == null) continue;

      final at = Vector3(b.px, b.py, b.pz) - anchorBF;
      final up = (at + anchorBF).normalized;
      // The building's own frame: its orientation carries the surface basis
      // plus the spin onto its street, so +X runs along the street and +Y
      // from the street into the lot.
      final q = Quaternion(b.qw, b.qx, b.qy, b.qz);
      final along = q.rotate(Vector3.unitY).normalized;
      final sideAxis = q.rotate(Vector3.unitX).normalized;

      // Out to the LOT LINE, not the building's own edge: the footprint has
      // already been inset by its setback and shrunk by its coverage, and a
      // fence hugging the walls would enclose no garden at all.
      final back = lotSetbackFor(spec);
      final cover = lotCoverageFor(spec);
      final halfW = b.siteWidthM / cover / 2 + back;
      final halfD = b.siteDepthM / cover / 2 + back;

      if (edging != LotEdging.none) {
        LotFeatures.emitFence(solid, edging, at, along, up, halfW, halfD,
            coarse: tier != BuildingDetail.full);
      }
      if (sign) {
        LotFeatures.emitSign(solid, glow, at, along, up, halfW, halfD,
            math.max(1.0, b.siteWidthM / 18));
      }
      if (lot != null && _carBudget > 0) {
        // Occupancy has no field on the wire yet, so it is DERIVED: a
        // deterministic per-lot fraction, so a district reads as busy or quiet
        // and two clients agree, without pretending to know the real number.
        final h = (b.id.hashCode & 0x7FFFFFFF) % 1000 / 1000.0;
        // The parcel's REAL lot lines, in the frame the massing was placed
        // in — its centroid, the street at negative Y. [halfD] is the lot
        // line the fence stands on: the site plus the coverage and setback
        // the density rule took off it, which is where the sidewalk begins.
        final depth = halfD * 2;
        // The back wall: the rear of the deepest floored volume.
        var rearWall = double.negativeInfinity;
        for (final v in massing.volumes) {
          if (v.floors > 0) rearWall = math.max(rearWall, v.y + v.depth / 2);
        }
        _carBudget -= LotFeatures.emitLot(
          apron, cars, glow, at, sideAxis, along, up, lot, massing.entrance,
          frontLineY: -depth / 2,
          rearLineY: depth / 2,
          // Where the lot IS, not where the style says it goes: an
          // installation's lot is out front whatever the kit.
          behind: lot.y > massing.entrance.$2,
          rearDoorY: rearWall.isFinite ? rearWall : lot.y - lot.depth / 2,
          occupancy: 0.25 + h * 0.6,
          airless: k.sealedWorld,
          maxCars: math.min(12, _carBudget),
          detailed: tier == BuildingDetail.full,
        );
      }
    }
  }

  /// Road [index] into the tile's builders, at the tile's tier.
  ///
  /// Far: the carriageway as a bare ribbon, the railway as track, the
  /// viaduct as structure. Mid: lanes painted, turning circles. Near: the
  /// pavements with their curbs, the lamps, the furniture, the tube on a
  /// sealed world, the cars at the curb.
  void _emitRoad(int index) {
    final r = request;
    final rb = _roads;
    final road = members.roads[index];
    final tier = r.tier;
    final anchorBF = r.anchorBF;
    final pts = <Vector3>[];
    for (var i = 0; i + 2 < road.points.length; i += 3) {
      pts.add(Vector3(
        road.points[i] - anchorBF.x,
        road.points[i + 1] - anchorBF.y,
        road.points[i + 2] - anchorBF.z,
      ));
    }
    if (pts.length < 2) return;
    final cls = RoadClass
        .values[road.roadClassIndex.clamp(0, RoadClass.values.length - 1)];
    final paved = cls.paved;
    final near = tier == CityTier.near;
    final paint = tier != CityTier.far;

    if (cls.isElevated) {
      // No ground ribbon, no curb, no junction furniture: there is nothing
      // at ground level here but the columns. Drawing the ribbon anyway
      // painted a road stripe along the floor under the viaduct, which read
      // as the structure having fallen down.
      ElevatedStructure.emit(
        rb.airSolid,
        rb.airDeck,
        rb.airGlow,
        pts: pts,
        anchorBF: anchorBF,
        cls: cls,
        halfWidthM: road.halfWidthM,
      );
      if (cls == RoadClass.transit) {
        // Terminals at the free ends of the L: the line is split at every
        // street it crosses, so an end is free only when no other piece of
        // line ends on it — anywhere on the body, not just in this tile.
        // The end's own entry is in the list too, so a second entry within
        // 8 m means another piece ends here.
        for (final (at, next) in [
          (pts.first, pts[1]),
          (pts.last, pts[pts.length - 2])
        ]) {
          final atBF = at + anchorBF;
          var meeting = 0;
          for (final other in members.transitEnds) {
            if ((other - atBF).length < 8.0) meeting++;
          }
          if (meeting > 1) continue;
          final inward = next - at;
          if (inward.length < 1e-6) continue;
          ElevatedStructure.emitTerminal(rb.airSolid, rb.airGlow,
              at: at,
              inward: inward.normalized,
              anchorBF: anchorBF,
              halfWidthM: road.halfWidthM);
        }
      }
      return;
    }

    if (cls == RoadClass.rail) {
      // Track, not tarmac: no ribbon, no pavement, no furniture, no
      // junction plates — a level crossing is the road's business.
      Railway.emit(rb.railBallast, rb.railConcrete, rb.railSteel,
          pts: pts, anchorBF: anchorBF, halfWidthM: road.halfWidthM);
      return;
    }

    if (cls == RoadClass.alley) {
      RoadMesher.ribbon(rb.alleyRibbon, pts, anchorBF, road.halfWidthM);
    } else if (!paved) {
      RoadMesher.ribbon(rb.dirtRibbon, pts, anchorBF, road.halfWidthM);
    } else {
      // The carriageway with its lanes painted on — the same pipeline the
      // whole city draws through, downtown and county line alike — lifted
      // onto its bridges and tapered into what it meets.
      final ranges = <(double, double)>[
        for (var i = 0; i + 1 < road.bridges.length; i += 2)
          (road.bridges[i], road.bridges[i + 1]),
      ];
      final liftAt = ranges.isEmpty
          ? null
          : (double s) => RoadMesher.bridgeLiftAt(s, ranges);
      RoadMesher.carriageway(rb.ribbon, pts, anchorBF, cls,
          halfWidthM: road.halfWidthM,
          startHalfWidthM: road.startHalfWidthM,
          endHalfWidthM: road.endHalfWidthM,
          liftAt: liftAt,
          paint: paint,
          solid: near ? rb.propSolid : null);
      if (liftAt != null) {
        RoadMesher.piers(rb.propSolid, pts, anchorBF, road.halfWidthM, liftAt);
      }
      if (road.soundWalls && cls.canHaveSoundWalls && paint) {
        RoadMesher.soundWalls(rb.propSolid, pts, anchorBF, road.halfWidthM,
            startHalfWidthM: road.startHalfWidthM,
            endHalfWidthM: road.endHalfWidthM,
            liftAt: liftAt,
            posts: near);
      }
    }
    // What the body's end table says of this road's two ends (see
    // [CityTileMembers.roadEnds]).
    final startEnd = members.roadEnds[2 * index];
    final lastEnd = members.roadEnds[2 * index + 1];
    // A street that ends where nothing else does ends in a turning
    // circle: a subdivision's cul-de-sac, or the edge of town.
    if (paint && cls == RoadClass.street) {
      for (final (end, e) in [(pts.first, startEnd), (pts.last, lastEnd)]) {
        if (e != null && e.$2 > 1) continue;
        RoadMesher.culDeSac(rb.ribbon, end, anchorBF, 11.0);
      }
    }
    if (!near) return;

    // How far a sidewalk stops before an end: past the junction plate
    // (r = widest * 1.45) and its zebra (5 m past the bar). Zero at an end
    // nothing else meets.
    double pullAt((double, int)? e) =>
        e == null || e.$2 <= 1 ? 0.0 : e.$1 * 1.45 + 5.5;

    // Raised pavements with a curb face, on anything that has a pavement
    // to raise. Not on a sealed world — pedestrians there travel in the
    // tube, and an open sidewalk in vacuum is set dressing for nobody.
    final walked = paved && cls.hasPavement && !road.sealed;
    if (walked) {
      RoadMesher.sidewalks(rb.walkRibbon, pts, road.halfWidthM, 3.0, anchorBF,
          pullStart: pullAt(startEnd), pullEnd: pullAt(lastEnd));
    }
    // Nobody lights a dirt track, and nobody lights an alley either.
    if (paved && cls.hasPavement) {
      RoadMesher.lamps(rb.lampSolid, rb.lampGlow, pts, anchorBF,
          road.halfWidthM, cls,
          liftM: walked ? CityTileMesher.walkTopLiftM : 0.0);
    }
    if (rb.propBudget > 0) {
      rb.propBudget -= StreetFurniture.emit(
        rb.propSolid,
        rb.propGlow,
        pts: pts,
        anchorBF: anchorBF,
        cls: cls,
        halfWidthM: road.halfWidthM,
        pavementM: 3.0,
        // Furniture stands on the raised walk now, not on the bare drape.
        liftM: walked ? CityTileMesher.walkTopLiftM : 0.0,
        // A RoadSnapshot carries no id — it is pure geometry on the wire —
        // so the seed comes from the geometry itself. Stable frame to frame
        // for a road that has not been redrawn, which is what keeps the
        // furniture from jittering about the pavement — and stable across
        // isolates, which `Object.hash` is not (see the library docs).
        seed: CityTileMesher.roadSeed(road),
        budget: rb.propBudget,
        treesOut: rb.treePits,
        shrubsOut: rb.shrubPits,
      );
    }
    // Vacuum outside: pedestrians travel in a pressurised tube, not on a
    // pavement. The glazing builder already exists for dome caps.
    if (paved && cls.hasPavement && r.knobs.onStreetParking && rb.curbCars > 0) {
      rb.curbCars -= CityTileMesher.curbParkingFor(
          rb.curbSolid, rb.curbGlass, pts, road, anchorBF,
          budget: rb.curbCars);
    }
    if (road.sealed) {
      PedestrianTube.emit(rb.tubeSolid, rb.tubeGlass,
          pts: pts, halfWidthM: road.halfWidthM, anchorBF: anchorBF);
    }
  }

  /// The junctions whose crossings lie in the tile, from every road end
  /// that falls there — whichever tile the road itself belongs to.
  ///
  /// This step finds them; the meshing goes in runs, as steps pushed to
  /// run next (the steps pop from the end). A downtown tile's crossings
  /// with all their masts and zebras were one indivisible step, and the
  /// most a frame could overshoot by.
  void _emitJunctions() {
    final r = request;
    if (r.tier == CityTier.far || members.ends.isEmpty) return;
    final ends = <RoadEnd>[
      for (final e in members.ends)
        RoadEnd(e.at - r.anchorBF, e.next - r.anchorBF, e.halfWidthM,
            e.roadClass,
            paved: e.paved, collector: e.collector),
    ];
    final junctions = RoadMesher.junctionsFromEnds(ends);
    final furniture = r.tier == CityTier.near;
    const perStep = 40;
    for (var end = junctions.length; end > 0; end -= perStep) {
      final from = math.max(0, end - perStep), to = end;
      steps.add(CityMeshStep(CityMeshStepKind.junctions, () {
        // Signal phase comes from sim time: deterministic, stateless, and
        // the same on every client looking at the same tick.
        RoadMesher.junctions(_roads.ribbon, _roads.lampSolid, _roads.lampGlow,
            junctions.sublist(from, to), r.anchorBF, r.epoch,
            furniture: furniture);
      }));
    }
  }
}

/// Swatch count of the ground palette. ONE constant for the bake and every
/// sampler of it: the patch pass used to divide by 5 against a 6-band texture,
/// which quietly recoloured commercial lots industrial-tan and support decks
/// cursor-cyan.
const int kGroundSwatches = 10;

/// The palette band tree crowns take — the yard and park trees are baked
/// into the ground material for it, since the facade atlas has no green.
/// Last in the palette, after the placement heatmap's pair.
const int kLeafSwatch = 9;

/// The pure functions of the tile build: the frame-to-geometry mapping and
/// the rules the UI thread and the workers must agree on.
class CityTileMesher {
  CityTileMesher._();

  /// Mesh one tile to completion, against [libraries] and, when given, the
  /// caller's reusable [scratch] — in which case the result is views over
  /// it, good until the next job claims it (see [CityMeshScratch]).
  static CityTileResult mesh(
          CityTileRequest request, CityBuildingLibraries libraries,
          {CityMeshScratch? scratch}) =>
      CityTileMeshJob(request, libraries, scratch: scratch).runAll();

  /// What one vertex costs on the GPU: the engine's interleaved layout is
  /// position (12 bytes), normal (12), texture coordinate (8) and a colour
  /// it adds itself (four floats, 16) — 48 bytes — whether or not the mesh
  /// brings a colour stream. The group's four arrays alone say 32, and
  /// planning against that undercounted every chunk by a third.
  static const int bytesPerVertex = 48;

  /// An index as the mesher emits it. The engine packs a chunk's indices to
  /// 16 bits where they fit, which they do under the cap, so this is the
  /// upper bound.
  static const int bytesPerIndex = 4;

  /// Ceiling on one uploaded group's GPU bytes (see [chunk]).
  ///
  /// The GLES backend hands a buffer's WHOLE backing store to the driver at
  /// the geometry's first draw, not as it is written: staging a
  /// several-megabyte facade group a slice a frame spread the Dart-side
  /// copies but left the raster thread 80 ms in the reactor on the frame
  /// the group first drew, with the UI thread throttled behind it. A
  /// megabyte is ~10 ms of that upload, one frame's worth under the reveal
  /// budget, and a far tile stays one group per material.
  static int maxGroupBytes = 1024 * 1024;

  /// [mesh] as groups of at most [maxBytes] each — one where it fits, else
  /// consecutive runs of its triangles, each with the vertex range those
  /// triangles reach and its indices rebased to it. A triangle never
  /// straddles two chunks; the chunks' triangles, in order, are the mesh's.
  ///
  /// A chunk's vertices are the contiguous range from the lowest index its
  /// triangles use to the highest, not a remap: the builders emit each
  /// primitive's vertices and then its triangles, and the skyline appends a
  /// building's at a time, so the range is tight — and a range is three
  /// views and a subtraction where a remap is a table and four copies.
  /// Ranges of neighbouring chunks may overlap by a primitive's vertices,
  /// which the cap accounts for. Only a single triangle whose own vertex
  /// span is over the cap can make a chunk over it.
  ///
  /// The mesh's index stream is consumed: rebased IN PLACE, so every chunk
  /// is views over the merged buffers and a worker allocates nothing per
  /// tile beyond the packed blob it sends (see [CityMeshScratch]).
  static List<CityMeshGroup> chunk(
    PropMesh mesh, {
    required CityMaterialKind material,
    required bool castsShadow,
    int? maxBytes,
  }) {
    final cap = maxBytes ?? maxGroupBytes;
    final idx = mesh.indices;
    final triangles = idx.length ~/ 3;
    if (triangles == 0) return const [];
    final out = <CityMeshGroup>[];
    void emit(int fromTri, int toTri, int lo, int hi) {
      final i0 = fromTri * 3, i1 = toTri * 3;
      if (lo != 0) {
        for (var i = i0; i < i1; i++) {
          idx[i] -= lo;
        }
      }
      final v1 = hi + 1;
      out.add(CityMeshGroup(
        material: material,
        castsShadow: castsShadow,
        positions: Float32List.sublistView(mesh.positions, lo * 3, v1 * 3),
        normals: Float32List.sublistView(mesh.normals, lo * 3, v1 * 3),
        texCoords: Float32List.sublistView(mesh.texCoords, lo * 2, v1 * 2),
        indices: Uint32List.sublistView(idx, i0, i1),
      ));
    }

    var start = 0, lo = 0, hi = 0;
    for (var t = 0; t < triangles; t++) {
      final a = idx[t * 3], b = idx[t * 3 + 1], c = idx[t * 3 + 2];
      final tLo = math.min(a, math.min(b, c));
      final tHi = math.max(a, math.max(b, c));
      if (t == start) {
        // A chunk's first triangle always joins it, whatever it costs.
        lo = tLo;
        hi = tHi;
        continue;
      }
      final nLo = math.min(lo, tLo), nHi = math.max(hi, tHi);
      final bytes = (nHi - nLo + 1) * bytesPerVertex +
          (t + 1 - start) * 3 * bytesPerIndex;
      if (bytes > cap) {
        emit(start, t, lo, hi);
        start = t;
        lo = tLo;
        hi = tHi;
      } else {
        lo = nLo;
        hi = nHi;
      }
    }
    emit(start, triangles, lo, hi);
    return out;
  }

  /// Curb reveal: how far the sidewalk stands above the carriageway. 150 mm
  /// is the real standard, and it is the "subtle elevation difference" that
  /// makes a street read as built rather than painted.
  static const double curbHeightM = RoadMesher.curbHeightM;

  /// The carriageway ribbon's own lift over the graded ground.
  static const double ribbonLiftM = RoadMesher.ribbonLiftM;

  /// Where the walk surface sits: the ribbon's lift plus the curb reveal.
  static const double walkTopLiftM = ribbonLiftM + curbHeightM;

  /// Whether a tile's mesh on [material] at [tier] goes into the shadow
  /// map.
  ///
  /// The shadow pass encoded everything — five milliseconds a frame,
  /// measured — and most of it could cast nothing anyone sees. Glazing is
  /// bands on a wall whose solid already casts the wall. The ground, the
  /// carriageways, the pavements, the dirt and alley ribbons LIE ON the
  /// ground: receivers, never casters. And a mid or far tile is
  /// kilometres off, where its whole shadow is under a pixel of the
  /// cascade. What is left — a near tile's facades, props, lamps, curbs,
  /// lot furniture, parked cars and the solids of its skyline — is what
  /// throws the shadows a street actually shows. [elevated] is the one
  /// exception on a flat material: a deck in the air throws a shadow the
  /// street below it plainly shows.
  static bool castsShadowFor(CityTier tier, CityMaterialKind material,
      {bool elevated = false}) {
    if (tier != CityTier.near) return false;
    switch (material) {
      case CityMaterialKind.facade:
        return true;
      case CityMaterialKind.glazing:
        return false;
      case CityMaterialKind.ground:
      case CityMaterialKind.road:
      case CityMaterialKind.dirt:
      case CityMaterialKind.alley:
      case CityMaterialKind.sidewalk:
        return elevated;
    }
  }

  /// The upload's groups: every builder by the material it takes and
  /// whether it casts a shadow at [tier] (see [castsShadowFor]), each
  /// group one geometry and one draw. [sources] carry the builder, its
  /// material and whether it stands off the ground.
  static Map<(CityMaterialKind, bool), List<MeshBuilder>> uploadGroups(
    Iterable<(MeshBuilder, CityMaterialKind, bool)> sources,
    CityTier tier,
  ) {
    final groups = <(CityMaterialKind, bool), List<MeshBuilder>>{};
    // Every material's plain group first, even if no builder lands in it:
    // the facade and glazing sinks also carry the skyline, which has to
    // be flushed whether or not the street contributed anything.
    for (final kind in CityMaterialKind.values) {
      groups[(kind, castsShadowFor(tier, kind))] = [];
    }
    for (final (builder, kind, elevated) in sources) {
      final casts = castsShadowFor(tier, kind, elevated: elevated);
      (groups[(kind, casts)] ??= []).add(builder);
    }
    return groups;
  }

  /// Every builder's mesh appended into [into] (a fresh sink by default),
  /// as it is: the builders emit in the tile's own space already.
  static MergedMeshSink mergeBuilders(Iterable<MeshBuilder> builders,
      {MergedMeshSink? into}) {
    final sink = into ?? MergedMeshSink();
    for (final b in builders) {
      if (b.triangleCount == 0) continue;
      sink.appendMesh(b.build());
    }
    return sink;
  }

  /// Detail tier for a building [d] metres from the camera.
  static BuildingDetail tierForDistance(double d,
          {required double blockRangeM, required double interiorRangeM}) =>
      d > blockRangeM
          ? BuildingDetail.block
          : (d > interiorRangeM ? BuildingDetail.exterior : BuildingDetail.full);

  /// The tier one building is generated at, from ITS OWN distance to the
  /// camera. [focusBF] must be in the same body-fixed frame the building is.
  ///
  /// Was chosen ONCE for the whole colony, from the distance to whichever
  /// building happened to be nearest. Standing in a city therefore built every
  /// building in it at full detail — interiors, fire escapes, roof plant and
  /// all — including the ones two kilometres away that cover four pixels. On a
  /// small colony that is invisible; on an eight-block one it is the whole
  /// frame budget.
  ///
  /// The archetype key has always carried `detail`, so mixing tiers within a
  /// colony needs no new machinery: buildings at different tiers simply land
  /// in different batches, exactly as different sizes already do.
  static BuildingDetail detailFor(BuildingSnapshot b, Vector3 focusBF,
      BuildingDetail colonyTier, CityMeshKnobs k) {
    if (!k.perBuildingLod) return colonyTier;
    return tierForDistance((Vector3(b.px, b.py, b.pz) - focusBF).length,
        blockRangeM: k.blockRangeM, interiorRangeM: k.interiorRangeM);
  }

  /// Reconstruct enough of a spec for the massing rules from the wire fields.
  ///
  /// Only the geometry-relevant parts are needed — the economy never runs on
  /// the client — so this is deliberately a shell rather than a catalogue
  /// lookup, which would break the moment a server ran a modded catalogue.
  /// Static and snapshot-explicit so the wire-to-geometry mapping is testable
  /// without a live scene — the same arrangement `ScatterNodes` uses for its
  /// frame maths.
  static CityBuildingSpec specOf(BuildingSnapshot b) => CityBuildingSpec(
        type: b.type,
        label: b.type,
        colorArgb: b.colorArgb,
        group: _groupFor(b),
        siteWidthM: b.siteWidthM,
        siteDepthM: b.siteDepthM,
        siteKind: SiteKind.values[
            b.siteKindIndex.clamp(0, SiteKind.values.length - 1)],
        // Massing needs SOMETHING to size floor area from. Site area is the
        // honest proxy available on the wire: a big site implies a big
        // programme, which is what the rules would have derived anyway.
        jobs: (b.siteWidthM * b.siteDepthM / 90).round().clamp(0, 4000),
      );

  static String _groupFor(BuildingSnapshot b) => switch (b.type) {
        'r-low' || 'r-med' || 'r-high' => 'res',
        'c-low' || 'c-med' || 'c-high' => 'com',
        'i-low' || 'i-med' || 'i-high' => 'ind',
        _ => 'svc',
      };

  /// The lot a building stands on, in its own frontage-aligned frame.
  static Parcel parcelOf(BuildingSnapshot b, ArchitectureStyle style) {
    // Inflated by the massing's OWN setback, because it will inset whatever it
    // is handed — and what it is handed here is already the finished footprint,
    // not a lot.
    //
    // Applied twice, the two setbacks ate the small buildings alive: a
    // low-density house arrives at 11.6 m wide, loses 6 m to the second inset
    // and another 30% to coverage, and renders about four metres across. All
    // of residential simply vanished from the city while the towers, which had
    // metres to spare, looked fine.
    //
    // The amount comes from the ACTIVE STYLE, and it must: a street wall insets
    // by nothing, so inflating by a hard-coded 3 m would hand it a lot 6 m
    // wider than its site and push every frontage out over the pavement and
    // into its neighbour. Front and rear are added separately because a street
    // wall's setbacks are deliberately asymmetric.
    final w = b.siteWidthM + style.sideSetbackM * 2;
    final d = b.siteDepthM + style.frontSetbackM + style.rearSetbackM;
    return Parcel(
      id: b.id,
      polygon: [
        Vec2(-w / 2, 0),
        Vec2(w / 2, 0),
        Vec2(w / 2, d),
        Vec2(-w / 2, d),
      ],
      frontage: (Vec2(-w / 2, 0), Vec2(w / 2, 0)),
      // Which side the cross street is on is not on the frame — only THAT
      // there is one. +X by convention, and it does not matter: the generator
      // mirrors the treatment onto whichever flank the variant picks, and a
      // corner reads as a corner either way round.
      sideStreet: b.corner ? (Vec2(w / 2, 0), Vec2(w / 2, d)) : null,
    );
  }

  /// The archetype [b] keys to at [detail] under [k]: exactly the key the
  /// meshing groups its instances by, for the UI side to look its mesh up
  /// with.
  static BuildingArchetype archetypeOf(
      BuildingSnapshot b, BuildingDetail detail, CityMeshKnobs k,
      {required double bucketM, required int variants}) {
    return BuildingArchetype.of(specOf(b), parcelOf(b, k.style),
        detail: detail,
        seed: b.id.hashCode,
        bucketM: bucketM,
        variants: variants,
        styleId: k.styleId,
        corner: b.corner);
  }

  /// Model transform for one building.
  ///
  /// The snapshot's orientation already carries the surface basis (local +X
  /// east, +Y north, +Z radial up), and generated buildings are authored Z-up
  /// with their origin at the base — so the two compose directly, and a
  /// building lands standing on its pad rather than buried or lying down.
  static vm.Matrix4 instanceTransform(Vector3 anchorBF, BuildingSnapshot b) {
    final offset = Vector3(b.px, b.py, b.pz) - anchorBF;
    final surface = Quaternion(b.qw, b.qx, b.qy, b.qz);
    return vm.Matrix4.compose(
      vm.Vector3(lengthToScene(offset.x), lengthToScene(offset.y),
          lengthToScene(offset.z)),
      quatToScene(surface),
      vm.Vector3.all(lengthToScene(1.0)),
    );
  }

  /// A massing as plain boxes: what a far tile draws a building as.
  ///
  /// One [OrientedBox] per volume — podium, tower, plant room, a works'
  /// tanks and sheds, whatever the massing carries — in the building's own
  /// frame and metres, so it takes exactly the [instanceTransform] the
  /// coarse model does and stands where that model would. Twelve triangles
  /// a volume where the coarse box was a quad per three metres of wall plus
  /// a window band per storey: an eight-kilometre view has the same
  /// silhouettes at a fortieth of the triangles.
  ///
  /// Every vertex samples the middle of the volume's facade band (its own
  /// or the massing's — see [BuildingGenerator.bandUV]). The facade atlas
  /// is masonry only, the windows live in the glazing texture, so a flat
  /// lookup is a plain wall in the building's colour: the flat concrete a
  /// tower IS from that far, and a district that keeps its hue as it drops
  /// to boxes. A curved or gabled volume is boxed on its footprint: a
  /// cooling tower is a stack at that range whichever way it is drawn.
  ///
  /// A massing with no volumes at all boxes its footprint by its height,
  /// the way the LOD visualiser does — nothing generates one today, but a
  /// far building must never be nothing.
  static PropMesh massingBoxes(BuildingMassing massing) {
    final m = MeshBuilder();
    void box(double x, double y, double z, double width, double depth,
        double height, int material, double yaw, bool plate) {
      final (u0, u1) = BuildingGenerator.bandUV(material);
      // A box (and a vehicle) runs its width along its yaw, from +X; a
      // plate — a heliostat, a solar table — runs its width ACROSS its
      // bearing, the way the generator faces one. Both are the conventions
      // the massing rules site them by (see `BuildingMassingRules`), and a
      // box turned the other way would stand across the parcel it was
      // fitted into.
      final s = math.sin(yaw), c = math.cos(yaw);
      final ex = plate ? Vector3(-s, c, 0) : Vector3(c, s, 0);
      final ey = plate ? Vector3(-c, -s, 0) : Vector3(-s, c, 0);
      final h = math.max(1.0, height);
      OrientedBox.emit(
        m,
        Vector3(x, y, z + h / 2),
        ex,
        ey,
        Vector3.unitZ,
        math.max(1.0, width) / 2,
        math.max(1.0, depth) / 2,
        h / 2,
        u: (u0 + u1) / 2,
        v: 0.5,
        // Metres: the instance transform carries the scene conversion.
        unitScale: 1.0,
      );
    }

    if (massing.volumes.isEmpty) {
      final fp = massing.footprint;
      box(0, 0, 0, fp.width, fp.depth, massing.height, massing.material, 0,
          false);
      return m.build();
    }
    for (final v in massing.volumes) {
      final plate =
          v.shape == MassShape.mirror || v.shape == MassShape.panel;
      box(v.x, v.y, v.z, v.width, v.depth, v.height,
          v.material ?? massing.material, v.yaw, plate);
    }
    return m.build();
  }

  /// Metres -> scene units.
  ///
  /// The scene renders in kilometres. Building INSTANCES get this through
  /// their transform's scale, but the patch, road, lamp and cursor meshes bake
  /// their vertices directly and carry an unscaled node transform — so without
  /// this they came out a thousand times life size, which is a colony wider
  /// than the moon it stands on.
  static Vector3 scenePos(Vector3 metres) => metres * kRenderScale;

  /// A road's furniture seed, from its geometry: its first point, its
  /// length and its class, mixed with plain integer arithmetic so every
  /// isolate agrees. (`Object.hash` is salted per isolate.)
  static int roadSeed(RoadSnapshot road) {
    var h = 0x811C9DC5;
    void mix(int v) {
      h = ((h ^ (v & 0xFFFFFFFF)) * 0x01000193) & 0xFFFFFFFF;
    }

    mix((road.points.first * 16).round());
    mix((road.points[1] * 16).round());
    mix(road.points.length);
    mix(road.roadClassIndex);
    return h;
  }

  /// Cars parked at the curb, nose to tail.
  ///
  /// Static, unlike the road traffic: these are part of the street's furniture
  /// rather than something moving through it, so they are built with the road
  /// mesh and not rebuilt every frame. Spacing leaves a real gap between
  /// bumpers — a solid line of touching cars reads as a wall.
  ///
  /// Returns how many it placed, so the caller can hold a budget.
  static int curbParkingFor(
    MeshBuilder body,
    MeshBuilder glass,
    List<Vector3> pts,
    RoadSnapshot road,
    Vector3 anchorBF, {
    required int budget,
  }) {
    const spacing = 7.4; // a car plus the room to get out of the bay
    var travelled = 0.0;
    var next = spacing;
    var placed = 0;
    final family = road.sealed ? VehicleKind.airless : VehicleKind.road;
    for (var i = 1; i < pts.length && placed < budget; i++) {
      travelled += (pts[i] - pts[i - 1]).length;
      if (travelled < next) continue;
      next += spacing;
      final p = pts[i];
      final up = (p + anchorBF).normalized;
      final along = (pts[i] - pts[i - 1]).normalized;
      final side = along.cross(up).normalized;
      // Alternate curbs, so both sides of the street fill.
      final s = placed.isEven ? 1.0 : -1.0;
      final h = (i * 2654435761) & 0x7FFFFFFF;
      final kind = family[h % family.length];
      // Nothing long parks at a curb bay.
      if (kind.lengthM > spacing * 0.85) continue;
      VehicleMeshes.emit(body, glass, kind,
          p + side * (road.halfWidthM * s * 0.78), along, up,
          u: (h >> 16 & 0xFF) / 255.0);
      placed++;
    }
    return placed;
  }
}

/// The road pass's builders for one tile, and its budgets.
class _RoadBuilders {
  final MeshBuilder ribbon = MeshBuilder();
  final MeshBuilder dirtRibbon = MeshBuilder();
  final MeshBuilder alleyRibbon = MeshBuilder();
  // Everything in the air: steel, concrete, and the deck it carries.
  final MeshBuilder airSolid = MeshBuilder();
  final MeshBuilder airDeck = MeshBuilder();
  final MeshBuilder airGlow = MeshBuilder();
  // Pavement clutter, budgeted per tile — a city of ten thousand hydrants
  // is a city nobody can draw.
  final MeshBuilder propSolid = MeshBuilder();
  final MeshBuilder propGlow = MeshBuilder();
  int propBudget = 2600;
  // Street-tree pits and planter soil lines, collected here and drawn as
  // INSTANCES of the scatter system's props — the same generators,
  // materials and atlas the wild ones use, so a street tree and a forest
  // tree agree about what a tree is. Airless worlds plant nothing.
  final List<(Vector3, double)> treePits = [];
  final List<(Vector3, double)> shrubPits = [];
  final MeshBuilder tubeSolid = MeshBuilder();
  final MeshBuilder tubeGlass = MeshBuilder();
  final MeshBuilder curbSolid = MeshBuilder();
  final MeshBuilder curbGlass = MeshBuilder();
  int curbCars = 240;
  final MeshBuilder lampSolid = MeshBuilder();
  final MeshBuilder lampGlow = MeshBuilder();
  final MeshBuilder walkRibbon = MeshBuilder();
  // The railway: ballast, sleepers, rails.
  final MeshBuilder railBallast = MeshBuilder();
  final MeshBuilder railConcrete = MeshBuilder();
  final MeshBuilder railSteel = MeshBuilder();
}
