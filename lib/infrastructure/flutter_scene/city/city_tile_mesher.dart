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
import '../../../domain/colony/city/road_catalog.dart';
import '../../../domain/colony/city/road_elevation.dart';
import '../../../domain/colony/city/site_access/kerb_cuts.dart';
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
import 'road_deck.dart';
import 'road_mesher.dart';
import 'site_access_mesher.dart';
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
    this.agentSignals = false,
    this.siteAccess = false,
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

  /// Signal masts baked without lit lamps: agent traffic draws the live
  /// heads (signal_head_layer.dart, agent-traffic.md C3).
  final bool agentSignals;

  /// Site access plans served (docs/plans/site-access.md §5.3,
  /// `CityNodes.siteAccess`): the tiles take the frame's sites and kerb
  /// cuts. Off, every building is legacy and every build is as it was.
  final bool siteAccess;

  ArchitectureStyle get style => ArchitectureStyle.byId(styleId);

  /// Whether the archetype libraries built for [other] serve this too.
  bool sameLibraries(CityMeshKnobs other) =>
      styleId == other.styleId &&
      bucketM == other.bucketM &&
      variants == other.variants;

  /// Every knob as one string, for a build key: two requests whose terms
  /// differ may mesh differently, and two whose terms agree mesh the same.
  /// The ranges go rounded to the metre, as the tile keys carry them.
  String get keyTerms => '$styleId|$bucketM|$variants|${perBuildingLod ? 1 : 0}'
      '|${blockRangeM.round()}|${interiorRangeM.round()}|${lodDebug ? 1 : 0}'
      '|${onStreetParking ? 1 : 0}|${sealedWorld ? 1 : 0}|$maxParkedCars'
      // Appended only when on, so every existing key reads as it did.
      '${agentSignals ? '|agentSignals' : ''}'
      '${siteAccess ? '|siteAccess' : ''}';
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
    this.detailLayer = false,
    this.detail,
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

  /// Whether the per-building detail is drawn by the detail layer (see
  /// `city_detail_layer.dart`) rather than by the tiles. With it a BASE
  /// tile reads nothing off the camera: every building is its block
  /// silhouette, the near tier's boxes inset by
  /// [CityTileMesher.nearBoxInset] for the layer's models to cover, and
  /// the lot furniture is the layer's to draw. False is the tile as it
  /// always was — the near tier resolving each building from [focusBF],
  /// and the furniture with it — so the two paths can be measured against
  /// each other (see `CityNodes.detailLayer`).
  final bool detailLayer;

  /// Non-null for a DETAIL job: not a tile but the buildings round the eye,
  /// meshed at their own tier with their lot furniture, and the archetype
  /// meshes the UI thread lacks generated here (see [CityDetailSpec]). The
  /// tile fields keep their meaning — [anchorBF] is what the vertices are
  /// relative to, [tier] is near — and [columns] carries buildings only.
  final CityDetailSpec? detail;

  /// Whether this is a detail job rather than a tile build.
  bool get isDetail => detail != null;
}

/// What a detail job knows beyond a tile's request: the archetype keys the
/// UI thread already holds geometry for.
///
/// A worker groups the instances it emits by archetype and generates the
/// MESH of every archetype not in this list — the UI thread would
/// otherwise generate it cold, a quarter to two milliseconds each, on the
/// frame the group lands. The list is the keys the UI side computed for
/// these very buildings from the same request (see
/// `CityDetailLayer.knownArchetypes`), so it is short; a key in it that
/// the worker does not meet costs nothing, and a key it meets that is not
/// in it comes back with its mesh.
class CityDetailSpec {
  const CityDetailSpec({required this.knownArchetypes});

  final List<BuildingArchetype> knownArchetypes;
}

/// One archetype's geometry, generated on the worker for a UI thread that
/// had none: the solid and the glazing as the generator makes them, or —
/// under the LOD visualiser — a box in the tier's colour as the solid
/// and no glazing, with [lod] set so the UI side draws it on the palette
/// material rather than the facade.
class CityArchetypeMesh {
  const CityArchetypeMesh({
    required this.archetype,
    required this.solid,
    required this.glazing,
    this.lod = false,
  });
  final BuildingArchetype archetype;
  final PropMesh solid;
  final PropMesh glazing;
  final bool lod;

  /// What the two meshes occupy on the GPU, counted as a group's are (see
  /// [CityMeshGroup.bytes]).
  int get bytes =>
      (solid.vertexCount + glazing.vertexCount) * CityTileMesher.bytesPerVertex +
      (solid.indices.length + glazing.indices.length) *
          CityTileMesher.bytesPerIndex;
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
    this.archetypeMeshes = const [],
  });
  final String tileKey;
  final String key;
  final CityTier tier;
  final List<CityMeshGroup> groups;
  final List<CityInstanceGroup> instances;

  /// The archetype meshes a detail job generated for the UI thread (see
  /// [CityDetailSpec]); empty for a tile build.
  final List<CityArchetypeMesh> archetypeMeshes;

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
    // Per archetype mesh: the solid's four streams then the glazing's,
    // offset and count each, and the LOD flag last.
    final archetypeSpans = <List<int>>[
      for (final a in archetypeMeshes)
        [
          for (final m in [a.solid, a.glazing]) ...[
            reserve(m.positions),
            m.positions.length,
            reserve(m.normals),
            m.normals.length,
            reserve(m.texCoords),
            m.texCoords.length,
            reserve(m.indices),
            m.indices.length,
          ],
          a.lod ? 1 : 0,
        ],
    ];
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
    for (final a in archetypeMeshes) {
      for (final m in [a.solid, a.glazing]) {
        put(m.positions);
        put(m.normals);
        put(m.texCoords);
        put(m.indices);
      }
    }
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
        archetypeMeshKeys: [for (final a in archetypeMeshes) a.archetype],
        archetypeMeshSpans: archetypeSpans,
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
      archetypeMeshes: [
        for (var i = 0; i < layout.archetypeMeshKeys.length; i++)
          () {
            final s = layout.archetypeMeshSpans[i];
            PropMesh mesh(int at) => PropMesh(
                  positions: f32(s[at], s[at + 1]),
                  normals: f32(s[at + 2], s[at + 3]),
                  texCoords: f32(s[at + 4], s[at + 5]),
                  indices: Uint32List.view(blob, s[at + 6], s[at + 7]),
                );
            return CityArchetypeMesh(
              archetype: layout.archetypeMeshKeys[i],
              solid: mesh(0),
              glazing: mesh(8),
              lod: s[16] != 0,
            );
          }(),
      ],
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
    this.archetypeMeshKeys = const [],
    this.archetypeMeshSpans = const [],
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

  /// A detail job's generated archetypes (see [CityArchetypeMesh]): the
  /// keys, and per key the byte offset and element count of the solid's
  /// positions, normals, texCoords and indices, then the glazing's, then
  /// the LOD flag — seventeen ints.
  final List<BuildingArchetype> archetypeMeshKeys;
  final List<List<int>> archetypeMeshSpans;
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
  final CityRoadBuilders _roads = CityRoadBuilders();
  final CityTileBuilders _tile = CityTileBuilders();
  Object? _owner;

  /// Make [owner]'s the sinks, the road builders and the tile builders:
  /// the first claim by a new owner empties them.
  void claim(Object owner) {
    if (identical(_owner, owner)) return;
    _owner = owner;
    for (final sink in _plain.values) {
      sink.reset();
    }
    for (final sink in _spare) {
      sink.reset();
    }
    _roads.reset();
    _tile.reset();
  }

  /// The road pass's builders — two dozen [MeshBuilder]s and the pit
  /// lists — kept here for the same reason the sinks are: made fresh per
  /// job they were their full size in old-generation garbage every tile,
  /// and their [MeshBuilder.build] copied the used prefix besides. One set
  /// per worker, [claim] resets them, and every tile's road pass fills the
  /// same buffers. Reading them does not claim: a job gathers them at plan
  /// time, while the job before it may still be running, and claims at its
  /// first step that emits.
  CityRoadBuilders get roads => _roads;

  /// The ground sheet's builder and the lot furniture's four, kept and
  /// claimed the same way as [roads]: they were still made fresh per job
  /// after the road builders moved in here, and a near tile's ground
  /// sheet is thousands of quads and its furniture a builder's worth of
  /// pickets and parked cars — old-generation garbage per tile, and a
  /// copy at [MeshBuilder.build] besides.
  CityTileBuilders get tile => _tile;

  /// Vertex capacity over every sink, for the reuse test.
  int get vertexCapacity =>
      _plain.values.fold(0, (n, s) => n + s.vertexCapacity) +
      _spare.fold(0, (n, s) => n + s.vertexCapacity);

  /// Vertex capacity over the road builders, for the reuse test.
  int get roadVertexCapacity => _roads.vertexCapacity;

  /// Vertex capacity over the ground and lot builders, for the reuse test.
  int get tileVertexCapacity => _tile.vertexCapacity;

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
  // A site access plan's structural surfaces: paving, ribbons, throats,
  // gates and stall paint (see `site_access_mesher.dart`).
  sites,
  // A detail job's archetype meshes the UI thread lacks, generated.
  archetypes,
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
  CityTileMeshJob(this.request, this.libraries,
      {CityMeshScratch? scratch, CityTileMembers? members})
      : _scratch = scratch ?? CityMeshScratch(),
        _given = members {
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
  /// objects they always did (see `city_tile_columns.dart`). A caller that
  /// already holds them hands them in instead ([_given]) — a test meshing
  /// a road's deck and dressing straight from its snapshot, say — and the
  /// columns are then read for nothing but the transit ends.
  late final CityTileMembers members = _given ?? request.columns.toSnapshots();
  final CityTileMembers? _given;

  /// The parts of the build, run one per call from the end. A running
  /// step may push more onto the end, and they run next.
  final List<CityMeshStep> steps = [];

  /// The road pass's builders: the scratch's, claimed on first touch like
  /// the sinks (see [CityMeshScratch.roads]).
  CityRoadBuilders get _roads {
    _scratch.claim(this);
    return _scratch.roads;
  }

  /// The ground and lot builders: the scratch's, claimed on first touch
  /// like the road builders (see [CityMeshScratch.tile]).
  CityTileBuilders get _tile {
    _scratch.claim(this);
    return _scratch.tile;
  }

  late int _carBudget = request.knobs.maxParkedCars;

  /// The tile's roads as the carriageways a pier keeps out of, gathered
  /// the first time a deck or a bridge asks — a tile whose roads all lie
  /// on the ground never does. The viaduct and the L stand on columns of
  /// their own up in the air; every other road has lanes a pier must not
  /// stand in.
  ///
  /// And the other tiles' roads that pass near the tile's decks
  /// ([CityTileMembers.corridors]): a road belongs to the tile its middle
  /// lies in, and the one under a deck near a tile's edge is as often as
  /// not the neighbour's. Numbered below zero, which no member's index is,
  /// so no road's piers ever pass one over as their own.
  late final RoadCorridors _corridors = () {
    final c = RoadCorridors(request.anchorBF);
    final roads = members.roads;
    for (var i = 0; i < roads.length; i++) {
      final road = roads[i];
      final cls = RoadClass
          .values[road.roadClassIndex.clamp(0, RoadClass.values.length - 1)];
      if (cls.isElevated) continue;
      c.add(i, road.points, road.halfWidthM);
    }
    final more = members.corridors;
    for (var k = 0; k < more.length; k++) {
      c.add(-1 - k, more[k].pointsBF, more[k].halfWidthM);
    }
    return c;
  }();

  /// [_corridors] as road [index]'s piers ask it: every road but its own.
  PierBlocked _pierBlocked(int index) =>
      (foot, along, up, halfAcrossM, halfAlongM) => _corridors
          .blocks(foot, along, up, halfAcrossM, halfAlongM, except: index);

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
    if (request.isDetail) {
      _planDetail();
      return;
    }
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
    // The tile's site access plans, at EVERY tier and gated by neither
    // `canDetail` nor the detail layer (§5.4): a 900 m site's access road
    // is structure, not dressing, and the 300 m lot-dressing gate is what
    // hid the starter kit's sites in the first place.
    _addSiteStep(SiteAccessMesher.tierFor(r.tier));
    // Only where some building can resolve past a box: the furniture pass
    // skips every block-tier lot, so a tile that cannot detail would run
    // its steps to emit nothing (see `CityNodes.tileCanDetail`). Under the
    // detail layer no base tile has furniture at all — the layer draws it
    // round the eye — whatever the caller's answer.
    if (r.canDetail && !r.detailLayer) {
      _addLotSteps(m.buildings);
    }
    _addMergeSteps(_tileMergeSources());
    steps.add(CityMeshStep(CityMeshStepKind.pack, _pack));
    // The caller pops from the end.
    steps.setAll(0, steps.reversed.toList());
  }

  /// A detail job's parts: the buildings in runs, each at its own tier and
  /// none at block; then the archetypes the UI thread lacks, generated in
  /// runs planned once the groups are known; the lot furniture, if wanted;
  /// the furniture builders merged; the pack. No roads, junctions, patches
  /// or planting — the base tiles under the layer draw those.
  void _planDetail() {
    final r = request;
    final m = members;
    const buildingsPerStep = 100;
    for (var i = 0; i < m.buildings.length; i += buildingsPerStep) {
      final from = i, to = math.min(i + buildingsPerStep, m.buildings.length);
      steps.add(CityMeshStep(CityMeshStepKind.buildings, () {
        for (var k = from; k < to; k++) {
          _emitBuilding(m.buildings[k]);
        }
      }));
    }
    steps.add(CityMeshStep(CityMeshStepKind.archetypes, _planArchetypes));
    if (r.canDetail) _addLotSteps(m.buildings);
    _addMergeSteps(_detailMergeSources());
    steps.add(CityMeshStep(CityMeshStepKind.pack, _pack));
    steps.setAll(0, steps.reversed.toList());
  }

  /// The lot furniture, in runs. A plan-served building's site is DRESSED
  /// here, with the furniture of the building it serves (§5.4, R6), so the
  /// same site draws the same dressing whether the detail layer is on (the
  /// layer's job runs this) or off (a near tile runs it).
  void _addLotSteps(List<BuildingSnapshot> buildings) {
    const perStep = 60;
    for (var i = 0; i < buildings.length; i += perStep) {
      final from = i, to = math.min(i + perStep, buildings.length);
      steps.add(CityMeshStep(CityMeshStepKind.lots,
          () => _emitLotFeatures(buildings.sublist(from, to))));
    }
  }

  /// A step for the tile's sites at [tier], when the knob is on and the
  /// request carries any. At the NEAR tier a big site takes its dressing
  /// here — its lamps and its stalls' cars — since no lot pass draws it.
  void _addSiteStep(SiteDrawTier tier) {
    if (!request.knobs.siteAccess || members.sites.isEmpty) return;
    steps.add(CityMeshStep(CityMeshStepKind.sites, () {
      final tb = _tile;
      final near = tier == SiteDrawTier.near;
      _carBudget -= SiteAccessMesher.emitAll(
        members.sites,
        apron: tb.featureApron,
        solid: tb.featureSolid,
        anchorBF: request.anchorBF,
        tier: tier,
        cars: near ? tb.featureCars : null,
        glow: near ? tb.featureGlow : null,
        carBudget: near ? _carBudget : 0,
        airless: request.knobs.sealedWorld,
      );
    }));
  }

  /// The site of plan-served building [b], or null: its book slot in the
  /// frames the request carries (`CityTileMembers.sites`), looked up
  /// through one index built on first use.
  ///
  /// Gated on the knob like `_addSiteStep`: with `siteAccess` off a request
  /// that carries sites anyway draws the legacy lot, never the plan's
  /// dressing (the knob discipline of §5.5 as built).
  (CitySiteFrame, SiteChunkGeometry, int, bool)? _siteOf(BuildingSnapshot b) {
    if (!request.knobs.siteAccess || b.siteSlot < 0 || members.sites.isEmpty) {
      return null;
    }
    final byColony = _siteIndex ??= () {
      final out = <String, Map<int, (CitySiteFrame, SiteChunkGeometry, int, bool)>>{};
      for (final f in members.sites) {
        final on = out['${f.colonyId}|${f.bodyId}'] ??= {};
        for (var c = 0; c < f.chunks.length; c++) {
          final g = f.chunks[c];
          for (var k = 0; k < g.siteCount; k++) {
            on[g.siteSlot(k)] = (f, g, k, f.isAgentManaged(c, k));
          }
        }
      }
      return out;
    }();
    return byColony['${b.colonyId}|${b.body}']?[b.siteSlot];
  }

  Map<String, Map<int, (CitySiteFrame, SiteChunkGeometry, int, bool)>>?
      _siteIndex;

  /// The archetypes this job's instances key to that the UI thread did
  /// not list, as generation steps pushed to run next — a few keys a
  /// step, since a full archetype is up to two milliseconds and the
  /// inline scheduler stops between steps. Runs after the buildings, when
  /// the groups are complete.
  void _planArchetypes() {
    final known = request.detail!.knownArchetypes.toSet();
    final missing = [
      for (final e in _groups.entries)
        if (!known.contains(e.key)) (e.key, e.value.$1),
    ];
    const perStep = 4;
    for (var end = missing.length; end > 0; end -= perStep) {
      final from = math.max(0, end - perStep), to = end;
      steps.add(CityMeshStep(CityMeshStepKind.archetypes, () {
        for (var i = from; i < to; i++) {
          final (key, rep) = missing[i];
          _archetypeMeshes.add(_generateArchetype(key, rep));
        }
      }));
    }
  }

  /// [key]'s mesh, from a building that keys to it, through this side's
  /// library — the same key the UI thread's library would compute from
  /// the same building, so the mesh that comes back is the one every
  /// instance in the group shares (see [CityTileMesher.archetypeOf]).
  CityArchetypeMesh _generateArchetype(BuildingArchetype key, BuildingSnapshot b) {
    final k = request.knobs;
    final tier = key.detail;
    final built = libraries.forTier(tier).get(
        CityTileMesher.specOf(b), CityTileMesher.parcelOf(b, k.style),
        seed: b.id.hashCode,
        detail: tier,
        gate: CityTileMesher.gateOf(b, siteAccess: k.siteAccess));
    if (k.lodDebug) {
      return CityArchetypeMesh(
        archetype: key,
        solid: CityTileMesher.lodDebugBox(built.massing, tier),
        glazing: PropMesh.empty,
        lod: true,
      );
    }
    return CityArchetypeMesh(
      archetype: key,
      solid: built.model.solid,
      glazing: built.model.foliage,
    );
  }

  final List<CityArchetypeMesh> _archetypeMeshes = [];

  /// Every builder by the material it takes, and whether it stands off
  /// the ground. The builders stay split by what they draw; the upload
  /// does not: each (material, casts-a-shadow) group is ONE geometry and
  /// one draw, merged with the skyline of the same material — seven or so
  /// draws for a near tile where a builder each was two dozen.
  void _addMergeSteps(List<(MeshBuilder, CityMaterialKind, bool)> sources) {
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

  /// A detail job's builders: the lot furniture only. Gathered, not
  /// claimed, for the reason [_tileMergeSources] gives.
  List<(MeshBuilder, CityMaterialKind, bool)> _detailMergeSources() {
    final t = _scratch.tile;
    return [
      (t.featureSolid, CityMaterialKind.facade, false),
      (t.featureApron, CityMaterialKind.road, false),
      (t.featureCars, CityMaterialKind.facade, false),
      (t.featureGlow, CityMaterialKind.glazing, false),
    ];
  }

  /// A tile's builders, every one.
  List<(MeshBuilder, CityMaterialKind, bool)> _tileMergeSources() {
    // Gathered, not claimed: this runs at plan time, and an inline
    // scheduler plans a job while the one before it still owns the scratch.
    // The builders are the same objects whichever job owns them, so the
    // references are good once the road steps have claimed.
    final r = _scratch.roads;
    final t = _scratch.tile;
    return <(MeshBuilder, CityMaterialKind, bool)>[
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
      (t.featureSolid, CityMaterialKind.facade, false),
      (t.featureApron, CityMaterialKind.road, false),
      (t.featureCars, CityMaterialKind.facade, false),
      (t.featureGlow, CityMaterialKind.glazing, false),
      (t.patches, CityMaterialKind.ground, false),
      // A decorated road's grass, on the ground sheet's palette and in its
      // draw; empty — and so skipped by the merge — on every other road.
      (r.verge, CityMaterialKind.ground, false),
    ];
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
    // A detail job plants nothing, and has not claimed the road builders.
    final detail = request.isDetail;
    _result = CityTileResult(
      tileKey: request.tileKey,
      key: request.key,
      tier: request.tier,
      groups: _merged,
      instances: instances,
      treePits: detail ? Float64List(0) : _packPits(_roads.treePits),
      shrubPits: detail ? Float64List(0) : _packPits(_roads.shrubPits),
      lodCounts: _lodCounts,
      skylineTris: _skylineTris,
      archetypeMeshes: _archetypeMeshes,
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
    // own distance says: nothing in it resolves past a box. A BASE tile
    // under the detail layer is silhouettes at every range: the layer
    // resolves the buildings round the eye, and a base tile that read the
    // camera would be re-keyed by it. A DETAIL job is the other half:
    // each building at its own tier, and the ones at block — beyond the
    // block range, inside the gather's margin — are the base tile's and
    // are left out here.
    final BuildingDetail tier;
    if (r.isDetail) {
      tier = CityTileMesher.detailFor(b, r.focusBF, r.colonyTier, k);
      if (tier == BuildingDetail.block) return;
    } else if (r.detailLayer || r.tier != CityTier.near) {
      tier = BuildingDetail.block;
    } else {
      tier = CityTileMesher.detailFor(b, r.focusBF, r.colonyTier, k);
    }
    _lodCounts[tier] = (_lodCounts[tier] ?? 0) + 1;
    // Block tier keys and meshes against the coarse library, so the
    // dominant tier shares far fewer archetypes (and draws).
    final lib = libraries.forTier(tier);
    // The skyline: block-tier buildings are BAKED into one mesh per
    // material for the whole tile rather than instanced per archetype.
    // The visualiser keeps the instanced path so its boxes stay one per
    // archetype.
    final gate = CityTileMesher.gateOf(b, siteAccess: k.siteAccess);
    if (tier == BuildingDetail.block && !k.lodDebug) {
      final built = lib.get(spec, parcel, seed: seed, detail: tier, gate: gate);
      final m = CityTileMesher.instanceTransform(r.anchorBF, b,
          gate: gate, style: k.style, bucketM: lib.bucketM);
      // Under the detail layer a NEAR tile's boxes are drawn a little
      // inside the building, so the layer's model over one hides it (see
      // [CityTileMesher.nearBoxInset]). The glazing bands take the same
      // scale: left at full size they would stand off the shrunken wall
      // and lie in the plane of the detailed facade drawn over them.
      if (r.detailLayer && r.tier == CityTier.near) {
        final s = CityTileMesher.nearBoxInset;
        m.multiply(vm.Matrix4.diagonal3Values(s, s, s));
      }
      // A block-tier building is its massing as plain boxes at EVERY tier,
      // on the building's own facade band (see
      // [CityTileMesher.massingBoxes]). The coarse model is still a facade
      // — a quad per three metres of wall and a window band per storey,
      // some two hundred triangles a building against a dozen a volume —
      // and block tier is every building beyond the block range, which
      // from a camera high enough to see a district is all of them. The
      // far tiles were boxed first, for silhouettes one or two pixels
      // tall; the mid and near tiles kept the coarse model, and from
      // orbit a mid tile's facade was five megabytes cut into five draws
      // and a near tile's ten, which doubled the colony's colour draws
      // and put five milliseconds on a static frame, for walls nothing
      // that far resolves past a box either. What the boxes lack is
      // windows. Beyond the far range the skyglow carries the night look;
      // a mid or near tile keeps the coarse model's glazing — the window
      // bands alone, which a sited building's coarse model has none of —
      // so its towers still light up at night.
      _skylineSolid.append(libraries.massingBoxesOf(built), m);
      if (r.tier != CityTier.far) {
        _skylineGlazing.append(built.model.foliage, m);
      }
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
        corner: b.corner,
        gate: gate);
    _groups.putIfAbsent(key, () => (b, [])).$2.add(
        CityTileMesher.instanceTransform(r.anchorBF, b,
            gate: gate, style: k.style, bucketM: lib.bucketM));
  }

  /// Flat ground patches: roads, zoned lots, support decks.
  ///
  /// One mesh for all of them, coloured by a UV into the ground palette. The
  /// mesh format has no vertex-colour channel, and a material per colour would
  /// be five draws for what is a single sheet of ground.
  void _emitPatches() {
    final m = _tile.patches;
    final anchorBF = request.anchorBF;
    // Read straight off the columns: a near tile has thousands of patches,
    // and a snapshot object per patch per build was allocation the worker
    // did not need (see `city_patch_columns.dart`).
    final ps = members.patches;
    for (var i = 0; i < ps.length; i++) {
      final centre = Vector3(ps.px[i], ps.py[i], ps.pz[i]) - anchorBF;
      final up = (centre + anchorBF).normalized;
      final basis = Quaternion(ps.qw[i], ps.qx[i], ps.qy[i], ps.qz[i]);
      final east = basis.rotate(Vector3.unitX);
      final north = basis.rotate(Vector3.unitY);
      final hw = ps.sizeM[i] / 2;
      final hd = ps.depthM[i] / 2;
      final packed = ps.kind[i];
      // Plat lots are drawn by `CityNodes`' zoning node, rebuilt the frame
      // they change; a tile re-meshes on a worker in the background, and
      // zoning paint that arrives seconds after the stroke is not paint.
      if ((packed & CityPatchSnapshot.lotFlag) != 0) continue;
      final kind = packed & 0xFF;
      // Lifted clear of the levelled pad, and each kind by a different amount,
      // so a road drawn over a zoned lot does not z-fight it.
      final lift = up * (0.05 + kind * 0.01);
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
      if (kind == CityPatchSnapshot.kindRoad) {
        // Inset by a texel's worth so the sampler cannot reach the next swatch.
        const e = 0.004;
        final u0 = kind / kGroundSwatches + e,
            u1 = (kind + 1) / kGroundSwatches - e;
        uv = [(u0, 1.0), (u1, 1.0), (u1, 0.0), (u0, 0.0)];
      } else {
        // Against kGroundSwatches, NOT the number of patch kinds. The palette
        // has grown twice — cursor and refusal swatches, then the two the
        // placement heatmap paints with — and a local divisor of 5 does not
        // grow with it. Every patch was reading the wrong band: residential
        // sampled commercial blue, industrial sampled refusal red, support
        // sampled the heatmap amber. Exactly the drift kGroundSwatches was
        // introduced to stop, still live at this one call site.
        final u = (kind + 0.5) / kGroundSwatches;
        uv = [(u, 0.5), (u, 0.5), (u, 0.5), (u, 0.5)];
      }
      final idx = [
        for (var k = 0; k < 4; k++)
          m.vertex(CityTileMesher.scenePos(c[k]), up, uv[k].$1, uv[k].$2)
      ];
      m.quad(idx[0], idx[1], idx[2], idx[3]);
    }
  }

  /// What stands on a lot beside its building, into the tile: a plan-served
  /// lot's whole dressing (its fence ring, sign, footpaths, stall paint, lamps
  /// and parked cars), and an unserved one's fence and sign.
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
    final tb = _tile;
    final solid = tb.featureSolid;
    final glow = tb.featureGlow;
    final apron = tb.featureApron;
    final cars = tb.featureCars;
    final anchorBF = r.anchorBF;

    for (final b in buildings) {
      final tier = CityTileMesher.detailFor(b, r.focusBF, r.colonyTier, k);
      if (tier == BuildingDetail.block) continue;
      final edging = LotFeatures.edgingFor(b.type);
      final sign = LotFeatures.signFor(b.type);
      // PLAN-SERVED (§5.5): the plan's own dressing instead of the legacy
      // guess — the fence ring on the REAL parcel polygon with the plan's
      // gaps open, the sign beside the throat, the footpaths, the lamps,
      // the wheel stops and the cars in the stalls. A served building whose
      // site the request does not carry falls through to the legacy path,
      // which is what it drew before.
      final served = _siteOf(b);
      if (served != null) {
        final (frame, geo, site, managed) = served;
        _carBudget -= SiteAccessMesher.emitDressing(
          apron: apron,
          solid: solid,
          glow: glow,
          cars: cars,
          frame: frame,
          geo: geo,
          site: site,
          anchorBF: anchorBF,
          full: tier == BuildingDetail.full,
          edging: edging,
          sign: sign,
          signScale: math.max(1.0, b.siteWidthM / 18),
          airless: k.sealedWorld,
          agentManaged: managed,
          carBudget: _carBudget,
        );
        continue;
      }
      // UNSERVED (no plan on the wire for this building): the fence and the
      // sign it always had, on the canonical lot rectangle. The car park,
      // its drive, its bays and its footpath are the PLAN's now (R7), so a
      // lot without one keeps only what a lot line carries.
      if (edging == LotEdging.none && !sign) continue;
      final spec = CityTileMesher.specOf(b);

      final at = Vector3(b.px, b.py, b.pz) - anchorBF;
      final up = (at + anchorBF).normalized;
      // The building's own frame: its orientation carries the surface basis
      // plus the spin onto its street, so +X runs along the street and +Y
      // from the street into the lot.
      final q = Quaternion(b.qw, b.qx, b.qy, b.qz);
      final along = q.rotate(Vector3.unitY).normalized;

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
    // The road's points anchor-relative, as the emitters take them, into
    // the one list the road builders keep: no emitter holds the list past
    // its call (the pits keep points, which are values), so a list per
    // road was a growable buffer thrown away per road.
    final pts = rb.points..clear();
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
    // The road's kerb cuts as the tiles read them — the frame's own copy,
    // already in this polyline's drawn arc and flipped for a reversed road
    // (§5.2) — as a typed list the masks walk without a bounds check per
    // read. Null with the knob off, so a road with cuts on the wire draws
    // exactly as it did.
    final cuts = r.knobs.siteAccess ? CityTileMesher.cutsOf(road) : null;

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
          // Counted off the column, not the unpacked list: every transit
          // end against every end of every transit road was a vector per
          // pair, for a test that only needs the distance.
          final meeting = r.columns.transitEndsNear(
              at.x + anchorBF.x, at.y + anchorBF.y, at.z + anchorBF.z, 8.0);
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

    // A raised or sunk road's deck, as a lift above the drape at each
    // point (see `RoadSnapshot.lifts`). Null for a road that follows the
    // ground — every road the generator lays — which takes exactly the
    // path every road took before one could leave the ground: one run, its
    // own points, the plan's bridges, to the byte.
    final lifts = road.lifts.isNotEmpty && road.lifts.length == pts.length
        ? road.lifts
        : null;
    final ranges = <(double, double)>[
      for (var i = 0; i + 1 < road.bridges.length; i += 2)
        (road.bridges[i], road.bridges[i + 1]),
    ];
    // The stretches above ground: the whole road, or — for one the tool
    // sank into a tunnel — the runs between its portals.
    final runs =
        lifts == null ? [RoadRun.whole(pts)] : RoadDeckMesher.runs(pts, lifts);
    final liftAts = <double Function(double s)?>[
      for (final run in runs)
        run.lifts != null
            ? RoadDeckMesher.liftAt(run.pts, run.lifts!,
                bridges: ranges, s0: run.s0)
            : ranges.isEmpty
                ? null
                : (double s) => RoadMesher.bridgeLiftAt(s, ranges),
    ];
    final deco = RoadDecoration
        .values[road.decoration.clamp(0, RoadDecoration.values.length - 1)];
    // The cross-section as dressed: a decorated four- or six-lane road
    // gives lane width to a planted median, at the class's own width.
    final lanes = cls.lanesFor(deco);

    // What the body's end table says of this road's two ends (see
    // [CityTileMembers.roadEnds]).
    final startEnd = members.roadEnds[2 * index];
    final lastEnd = members.roadEnds[2 * index + 1];
    // How far a deck's parapets stop before an end: the junction plate
    // (r = widest * 1.45), which is the other legs' lanes as much as this
    // one's — where three ends or more meet, and where two meet at a bend:
    // an L's inside parapet stands across the other leg's lanes as surely
    // as a T's does. Two meeting straight on are one road going on, and its
    // parapet goes on with it. The table keys an end by its lift, so a deck
    // passing over a crossing is no leg of it and keeps its parapets. Which
    // two meeting turn is the cut's to say, off the whole body's roads
    // ([CityTileMembers.roadEndBent]): the other leg can be any tile's.
    final bent = members.roadEndBent;
    double trimAt((double, int)? e, int end) => e == null ||
            e.$2 < 2 ||
            (e.$2 == 2 && !(end < bent.length && bent[end]))
        ? 0.0
        : e.$1 * 1.45;

    for (var k = 0; k < runs.length; k++) {
      final run = runs[k];
      final rp = run.pts;
      final liftAt = liftAts[k];
      final raised = run.lifts != null;
      if (cls == RoadClass.rail) {
        // Track, not tarmac: no ribbon, no pavement, no furniture, no
        // junction plates — a level crossing is the road's business. A
        // raised line's track is laid on its deck.
        Railway.emit(rb.railBallast, rb.railConcrete, rb.railSteel,
            pts: raised ? RoadDeckMesher.raise(rp, anchorBF, liftAt!) : rp,
            anchorBF: anchorBF,
            halfWidthM: road.halfWidthM);
      } else if (cls == RoadClass.alley) {
        RoadMesher.ribbon(rb.alleyRibbon, rp, anchorBF, road.halfWidthM,
            liftAt: raised ? liftAt : null);
      } else if (!paved) {
        RoadMesher.ribbon(rb.dirtRibbon, rp, anchorBF, road.halfWidthM,
            liftAt: raised ? liftAt : null);
      } else {
        // The carriageway with its lanes painted on — the same pipeline the
        // whole city draws through, downtown and county line alike — lifted
        // onto its deck and its bridges, tapered into what it meets, and
        // on a one-way road an arrow down every lane.
        RoadMesher.carriageway(rb.ribbon, rp, anchorBF, cls,
            halfWidthM: road.halfWidthM,
            startHalfWidthM: run.fromStart ? road.startHalfWidthM : null,
            endHalfWidthM: run.toEnd ? road.endHalfWidthM : null,
            liftAt: liftAt,
            paint: paint,
            solid: near ? rb.propSolid : null,
            layout: lanes,
            arrows: true,
            // Nothing grows in vacuum.
            planting: road.sealed ? null : rb.verge,
            plantingU: CityTileMesher.grassU);
        if (!raised && liftAt != null) {
          RoadMesher.piers(rb.propSolid, rp, anchorBF, road.halfWidthM, liftAt,
              blocked: _pierBlocked(index));
        }
        if (road.soundWalls && cls.canHaveSoundWalls && paint) {
          RoadMesher.soundWalls(rb.propSolid, rp, anchorBF, road.halfWidthM,
              startHalfWidthM: run.fromStart ? road.startHalfWidthM : null,
              endHalfWidthM: run.toEnd ? road.endHalfWidthM : null,
              liftAt: liftAt,
              posts: near,
              // Up on a structure the parapets are the walls.
              skipAboveM: raised ? RoadElevation.structureClearM : 0.3);
        }
      }
      if (!raised) continue;
      // What a raised deck stands on, and a portal at each end of the run
      // that is a tunnel's mouth, facing out of the hill.
      RoadDeckMesher.structure(
          rb.propSolid, rp, anchorBF, road.halfWidthM, liftAt!,
          blocked: _pierBlocked(index),
          trimStartM: run.fromStart ? trimAt(startEnd, 2 * index) : 0.0,
          trimEndM: run.toEnd ? trimAt(lastEnd, 2 * index + 1) : 0.0);
      if (!run.fromStart) {
        RoadDeckMesher.portal(
            rb.propSolid, rp.first, rp.first - rp[1], anchorBF, road.halfWidthM);
      }
      if (!run.toEnd) {
        RoadDeckMesher.portal(rb.propSolid, rp.last,
            rp.last - rp[rp.length - 2], anchorBF, road.halfWidthM);
      }
    }
    if (cls == RoadClass.rail) return;

    // A street that ends where nothing else does ends in a turning
    // circle: a subdivision's cul-de-sac, or the edge of town — on its
    // deck where the tool raised it a little, and not at all where it
    // ends in its tunnel or up on a structure.
    if (paint && cls == RoadClass.street) {
      for (final (end, e, lift) in [
        (pts.first, startEnd, lifts?.first ?? 0.0),
        (pts.last, lastEnd, lifts?.last ?? 0.0),
      ]) {
        if (e != null && e.$2 > 1) continue;
        if (lifts == null) {
          RoadMesher.culDeSac(rb.ribbon, end, anchorBF, 11.0);
        } else if (lift >= -RoadElevation.tunnelCoverM &&
            lift <= RoadElevation.structureClearM) {
          RoadMesher.culDeSac(rb.ribbon, end, anchorBF, 11.0,
              liftM: RoadMesher.ribbonLiftM + lift);
        }
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
    // Decoration: grass — and trees — on a two-lane road's verges, trees
    // down a four- or six-lane road's planted median, and the kerb the
    // parked cars would have had (see [CityTileMesher.curbParks]).
    final verged = walked &&
        deco != RoadDecoration.none &&
        (cls == RoadClass.street || cls == RoadClass.streetOneWay);
    final medianTrees = deco == RoadDecoration.trees &&
        !road.sealed &&
        lanes?.median == MedianStyle.planted;
    final parks = CityTileMesher.curbParks(cls, deco);
    // A RoadSnapshot's id never reaches the tiles — it is not in the
    // columns — so the seed comes from the geometry itself. Stable frame
    // to frame for a road that has not been redrawn, which is what keeps
    // the furniture from jittering about the pavement — and stable across
    // isolates, which `Object.hash` is not (see the library docs).
    final seed = CityTileMesher.roadSeed(road);
    var span = 0;
    for (var k = 0; k < runs.length; k++) {
      final run = runs[k];
      final liftAt = liftAts[k];
      // The pavement and all it carries stand where the deck runs at
      // grade: on the drape itself for a road on the ground, on the points
      // lifted onto the deck for a raised or sunk one. Not beside a
      // structure — the ground under a deck is no pavement's — which keeps
      // only its lamps, up on the deck.
      final List<(int, int)> graded;
      final List<(int, int)> onDeck;
      if (run.lifts == null) {
        graded = [(0, run.pts.length - 1)];
        onDeck = const [];
      } else {
        final s = RoadDeckMesher.spans(run.pts, liftAt!);
        graded = s.graded;
        onDeck = s.raised;
      }
      for (final (a, b) in graded) {
        final sp = run.lifts == null
            ? run.pts
            : RoadDeckMesher.raise(run.pts, anchorBF, liftAt!, from: a, to: b);
        final pullStart = run.fromStart && a == 0 ? pullAt(startEnd) : 0.0;
        final pullEnd =
            run.toEnd && b == run.pts.length - 1 ? pullAt(lastEnd) : 0.0;
        // Where this span's first point stands along the whole road: what
        // its kerb cuts are measured from.
        var spanArc = 0.0;
        if (cuts != null) {
          spanArc = run.s0;
          for (var i = 0; i < a; i++) {
            spanArc += (run.pts[i + 1] - run.pts[i]).length;
          }
        }
        // Every span after the first dresses from a seed of its own.
        final spanSeed =
            span == 0 ? seed : (seed ^ (span * 0x9E3779B1)) & 0xFFFFFFFF;
        span++;
        if (walked) {
          RoadMesher.sidewalks(rb.walkRibbon, sp, road.halfWidthM, 3.0,
              anchorBF,
              pullStart: pullStart,
              pullEnd: pullEnd,
              cuts: cuts,
              arcOffset: spanArc);
        }
        if (verged) {
          RoadMesher.verges(rb.verge, sp, road.halfWidthM, anchorBF,
              widthM: CityTileMesher.vergeWidthM,
              u: CityTileMesher.grassU,
              pullStart: pullStart,
              pullEnd: pullEnd,
              treesOut: deco == RoadDecoration.trees ? rb.treePits : null,
              seed: spanSeed,
              cuts: cuts,
              arcOffset: spanArc);
        }
        // Nobody lights a dirt track, and nobody lights an alley either.
        if (paved && cls.hasPavement) {
          RoadMesher.lamps(rb.lampSolid, rb.lampGlow, sp, anchorBF,
              road.halfWidthM, cls,
              liftM: walked ? CityTileMesher.walkTopLiftM : 0.0,
              cuts: cuts,
              arcOffset: spanArc);
        }
        if (rb.propBudget > 0) {
          rb.propBudget -= StreetFurniture.emit(
            rb.propSolid,
            rb.propGlow,
            pts: sp,
            anchorBF: anchorBF,
            cls: cls,
            halfWidthM: road.halfWidthM,
            pavementM: 3.0,
            // Furniture stands on the raised walk now, not on the bare drape.
            liftM: walked ? CityTileMesher.walkTopLiftM : 0.0,
            seed: spanSeed,
            budget: rb.propBudget,
            treesOut: rb.treePits,
            shrubsOut: rb.shrubPits,
            cuts: cuts,
            arcOffset: spanArc,
          );
        }
        // Cars at the kerb, where the road keeps one to park at.
        if (paved &&
            cls.hasPavement &&
            parks &&
            r.knobs.onStreetParking &&
            rb.curbCars > 0) {
          rb.curbCars -= CityTileMesher.curbParkingFor(
              rb.curbSolid, rb.curbGlass, sp, road, anchorBF,
              budget: rb.curbCars, cuts: cuts, arcOffset: spanArc);
        }
        // Vacuum outside: pedestrians travel in a pressurised tube, not on
        // a pavement. The glazing builder already exists for dome caps.
        // A sealed road has no pavement (`walked` above), so the tube is the
        // only thing a kerb cut can break here: it rises over each drive on
        // its own kerb and the drive passes under (§10.2 Q8 option (a)).
        if (road.sealed) {
          PedestrianTube.emit(rb.tubeSolid, rb.tubeGlass,
              pts: sp,
              halfWidthM: road.halfWidthM,
              anchorBF: anchorBF,
              cuts: cuts,
              arcOffset: spanArc);
        }
        if (medianTrees) {
          // A row down the planted median, clear of the crossings.
          final total = RoadDeckMesher.cumulative(sp).last;
          var i = 0;
          for (final (p, _, s)
              in RoadMesher.every(sp, CityTileMesher.medianTreeSpacingM)) {
            if (s < pullStart + 6 || s > total - pullEnd - 6) continue;
            final up = (p + anchorBF).normalized;
            rb.treePits.add((
              p + up * (RoadMesher.ribbonLiftM + 0.05),
              RoadMesher.yawOf(spanSeed, i++),
            ));
          }
        }
      }
      // A structure's lamps, up on its deck just inside the parapet.
      if (paved && cls.hasPavement) {
        for (final (a, b) in onDeck) {
          RoadMesher.lamps(
              rb.lampSolid,
              rb.lampGlow,
              RoadDeckMesher.raise(run.pts, anchorBF, liftAt!, from: a, to: b),
              anchorBF,
              road.halfWidthM,
              cls,
              liftM: RoadMesher.ribbonLiftM,
              offsetM: road.halfWidthM - 0.45);
        }
      }
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
            paved: e.paved,
            collector: e.collector,
            isStart: e.isStart,
            liftM: e.liftM,
            onDeck: e.onDeck),
    ];
    // The player's say over the tile's junctions (the Junctions view):
    // lights 1 on, 0 off, -1 the warrant's; and a point out along each
    // leg that stops. `stopsSet` says whether the player chose the stop
    // legs at all: clear, the warrant's default legs stop; set with no
    // points, no leg does.
    final overrides = <RoadOverride>[
      for (final o in members.junctions)
        RoadOverride(
          o.at - r.anchorBF,
          lights: o.lights == 1 ? true : (o.lights == 0 ? false : null),
          stopPoints: !o.stopsSet
              ? null
              : [
                  for (var i = 0; i + 2 < o.stopPoints.length; i += 3)
                    Vector3(o.stopPoints[i], o.stopPoints[i + 1],
                            o.stopPoints[i + 2]) -
                        r.anchorBF,
                ],
        ),
    ];
    final junctions = RoadMesher.junctionsFromEnds(ends,
        overrides: overrides, anchorBF: r.anchorBF);
    final furniture = r.tier == CityTier.near;
    const perStep = 40;
    for (var end = junctions.length; end > 0; end -= perStep) {
      final from = math.max(0, end - perStep), to = end;
      steps.add(CityMeshStep(CityMeshStepKind.junctions, () {
        // Signal phase comes from sim time: deterministic, stateless, and
        // the same on every client looking at the same tick.
        RoadMesher.junctions(_roads.ribbon, _roads.lampSolid, _roads.lampGlow,
            junctions.sublist(from, to), r.anchorBF, r.epoch,
            furniture: furniture, litHeads: !r.knobs.agentSignals);
      }));
    }
  }
}

/// Swatch count of the ground palette. ONE constant for the bake and every
/// sampler of it: the patch pass used to divide by 5 against a 6-band texture,
/// which quietly recoloured commercial lots industrial-tan and support decks
/// cursor-cyan.
const int kGroundSwatches = 14;

/// The palette band tree crowns take — the yard and park trees are baked
/// into the ground material for it, since the facade atlas has no green.
/// Last in the palette, after the placement heatmap's pair.
const int kLeafSwatch = 9;

/// The palette band a road's grass takes — its verges and a planted
/// median: the leaf's green. A band nothing else lays on the ground, so a
/// verge never reads as zoning (bands 1-4 and their pale twins), and the
/// palette keeps its size — [kGroundSwatches] is still every colour the
/// bake holds.
const int kVergeSwatch = kLeafSwatch;

/// The palette band a PLAT LOT is painted in, or null when it is not painted.
///
/// The whole of the zoning view's policy, kept pure so it can be tested without
/// a scene graph:
///
/// * Not a lot (a road cell, a support deck): never — the tiles draw those.
/// * [zoning] (the Zone tool held, or the view pinned): every lot, in its zone
///   colour at full strength — built, empty or unzoned. Zoning is when the
///   whole plat is the point.
/// * Otherwise: only a lot that is zoned AND empty, in its PALE band. That is
///   the one state worth reading at a glance, because it is the one about to
///   change. A built lot's building already says what the ground is for, and
///   an unzoned lot says nothing — every street is lined with them, and
///   painted they were endless rows of grey plots.
int? zoningBandFor(int packedKind, {required bool zoning}) {
  if ((packedKind & CityPatchSnapshot.lotFlag) == 0) return null;
  final kind = packedKind & 0xFF;
  if (zoning) return kind;
  final built = (packedKind & CityPatchSnapshot.builtFlag) != 0;
  final unzoned = (packedKind & CityPatchSnapshot.unzonedFlag) != 0;
  if (built || unzoned) return null;
  return kind + kPaleZoneOffset;
}

/// Distance from a zone band to its PALE twin in the ground palette.
///
/// Bands 1-4 are the zone colours at full strength (what the zoning overlay
/// paints with); 10-13 are the same hues lifted toward the ground under them,
/// which is what an un-built lot is painted with by default.
const int kPaleZoneOffset = 9;

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
  /// the group first drew, with the UI thread throttled behind it. That
  /// upload runs ~10 ms a megabyte, so two megabytes is ~20 ms: one hitch,
  /// on the frame the chunk first draws, and a tile makes one at most.
  ///
  /// The cap was a megabyte while the mid and near skylines were the
  /// coarse model, five and ten megabytes a tile; a chunk that size
  /// showed on its own frame under the reveal budget. It is two now that
  /// the block tier is boxes at every tier (see [massingBoxes]) and a
  /// tile's biggest group is the near tile's street furniture: every
  /// chunk is a draw of its own for the rest of the tile's life, and at a
  /// megabyte the furniture was two or three of them and the skylines
  /// five and ten, which doubled the colony's colour draws. Two
  /// megabytes makes the furniture one chunk — one hitch as it arrives,
  /// one draw after — and every skyline well under it.
  static int maxGroupBytes = 2 * 1024 * 1024;

  /// How much smaller than the building a NEAR base tile draws its block
  /// boxes under the detail layer (see [CityTileRequest.detailLayer]):
  /// the box is scaled by this about the building's centre and base, in
  /// all three axes.
  ///
  /// The layer draws a building's exterior or full model over its box,
  /// and a model drawn over a box the same size z-fights it wall for
  /// wall. Three per cent is the least that keeps the walls apart at
  /// every distance the layer draws at: a ten-metre house's walls sit
  /// fifteen centimetres inside the model's, a two-hundred-metre tower's
  /// three metres — both far more than the depth buffer's resolution at
  /// three hundred metres — and the model hides the box entirely. The
  /// price is paid by every OTHER building in the tile, the ones beyond
  /// the block range that no model covers: three per cent smaller, which
  /// at three hundred metres and beyond is under a pixel. One is no
  /// inset at all, for measuring against; a value under about 0.9 shows
  /// as buildings standing off their lots.
  static double nearBoxInset = 0.97;

  /// Palette swatch a tier is painted with under the LOD visualiser: a
  /// heat ramp on the ground palette, which already exists and is
  /// already bound — red the expensive tier, amber the middle, green the
  /// cheap one. The same mapping `CityNodes` paints its own boxes with.
  static double lodSwatchU(BuildingDetail d) {
    final swatch = switch (d) {
      BuildingDetail.full => 6, // refusal red — the costly one
      BuildingDetail.exterior => 8, // heatmap amber
      BuildingDetail.block => 7, // site-ok green
    };
    return (swatch + 0.5) / kGroundSwatches;
  }

  /// A building's own massing as one box in its tier's colour: what the
  /// LOD visualiser draws instead of the building. Same size, same place,
  /// no detail, so what is seen is purely which tier each resolved to.
  /// Metres, in the building's frame; the instance transform carries the
  /// scene conversion.
  static PropMesh lodDebugBox(BuildingMassing massing, BuildingDetail tier) {
    final m = MeshBuilder();
    final fp = massing.footprint;
    OrientedBox.emit(
      m,
      Vector3(0, 0, massing.height / 2),
      Vector3.unitX,
      Vector3.unitY,
      Vector3.unitZ,
      math.max(1.0, fp.width) / 2,
      math.max(1.0, fp.depth) / 2,
      math.max(1.0, massing.height) / 2,
      u: lodSwatchU(tier),
      v: 0.5,
      unitScale: 1.0,
    );
    return m.build();
  }

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
    // The distance as the subtraction and the norm would compute it, term
    // for term, without the two vectors: this runs per building, twice on
    // a lot-featured tile, and they were the job's steadiest garbage.
    final dx = b.px - focusBF.x, dy = b.py - focusBF.y, dz = b.pz - focusBF.z;
    return tierForDistance(math.sqrt(dx * dx + dy * dy + dz * dz),
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

  /// The plan brief [b] is drawn from, or null for the legacy path
  /// (docs/plans/site-access.md §6.2).
  ///
  /// A building is PLAN-SERVED when it carries a site access slot and the
  /// knob is on: it then stands on its plan's envelope (the wire's
  /// `siteWidthM`/`siteDepthM` ARE that envelope), front-aligned on the
  /// envelope's front edge, with the plan's parking instead of its own and
  /// its gate left open. With the knob off, or with no plan, every building
  /// is legacy and nothing below it changes.
  static SiteGate? gateOf(BuildingSnapshot b, {required bool siteAccess}) =>
      siteAccess && b.siteSlot >= 0
          ? SiteGate(xM: b.gateXM, widthM: b.gateWM)
          : null;

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
        corner: b.corner,
        gate: gateOf(b, siteAccess: k.siteAccess));
  }

  /// Model transform for one building.
  ///
  /// The snapshot's orientation already carries the surface basis (local +X
  /// east, +Y north, +Z radial up), and generated buildings are authored Z-up
  /// with their origin at the base — so the two compose directly, and a
  /// building lands standing on its pad rather than buried or lying down.
  /// Pass [gate] (with the [style] and the library's [bucketM]) for a
  /// PLAN-SERVED building: its mesh was generated against the BUCKETED
  /// envelope, so the instance is shifted back along its own local +Y by half
  /// the bucketing slack, which keeps the drawn front wall — and the door on
  /// it — on the envelope's real front edge (§6.2). Without it the transform
  /// is exactly what it was.
  static vm.Matrix4 instanceTransform(Vector3 anchorBF, BuildingSnapshot b,
      {SiteGate? gate, ArchitectureStyle? style, double bucketM = 6}) {
    final offset = Vector3(b.px, b.py, b.pz) - anchorBF;
    final surface = Quaternion(b.qw, b.qx, b.qy, b.qz);
    final m = vm.Matrix4.compose(
      vm.Vector3(lengthToScene(offset.x), lengthToScene(offset.y),
          lengthToScene(offset.z)),
      quatToScene(surface),
      vm.Vector3.all(lengthToScene(1.0)),
    );
    if (gate == null || style == null) return m;
    final depth = b.siteDepthM + style.frontSetbackM + style.rearSetbackM;
    final bucketed =
        BuildingArchetype.bucketOf(depth, bucketM, minFit: true) * bucketM;
    final shift = (bucketed - depth) / 2;
    if (shift != 0) m.multiply(vm.Matrix4.translationValues(0, shift, 0));
    return m;
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

  /// U of a road's grass on the ground palette: the middle of the verge
  /// swatch, where no filtering or mip level reaches a neighbour.
  static const double grassU = (kVergeSwatch + 0.5) / kGroundSwatches;

  /// Width of the grass verge a decorated two-lane road lays between its
  /// kerb and its walk, out of the pavement's three metres.
  static const double vergeWidthM = 1.3;

  /// Spacing of the trees down a planted median.
  static const double medianTreeSpacingM = 14.0;

  /// Whether a road of [cls] dressed with [decoration] parks cars at its
  /// kerb: the menu's own answer ([RoadType.hasParking]) — decoration
  /// takes the kerb, except on a four-lane road, which keeps its parking.
  /// Undecorated, it is every road with a pavement, as it always was.
  static bool curbParks(RoadClass cls, RoadDecoration decoration) =>
      decoration == RoadDecoration.none
          ? cls.hasPavement
          : RoadType.forClass(cls, decoration: decoration).hasParking;

  /// Cars parked at the curb, nose to tail.
  ///
  /// Static, unlike the road traffic: these are part of the street's furniture
  /// rather than something moving through it, so they are built with the road
  /// mesh and not rebuilt every frame. Spacing leaves a real gap between
  /// bumpers — a solid line of touching cars reads as a wall.
  ///
  /// Returns how many it placed, so the caller can hold a budget.
  ///
  /// With [cuts] — the road's drawn kerb cuts, measured from the arc
  /// [arcOffset] of [pts]'s first point — a bay whose centre
  /// `KerbCuts.parkingBlocked` masks stands empty: the SAME asymmetric form
  /// the agents' kerb slots ask (§5.5, A12), so a baked car never stands
  /// across a drive or in a home back-out's swing. The kerb alternation
  /// still advances over a masked bay, so the cars either side of one are
  /// on the kerbs they always were.
  static int curbParkingFor(
    MeshBuilder body,
    MeshBuilder glass,
    List<Vector3> pts,
    RoadSnapshot road,
    Vector3 anchorBF, {
    required int budget,
    Float64List? cuts,
    double arcOffset = 0,
  }) {
    const spacing = 7.4; // a car plus the room to get out of the bay
    var travelled = 0.0;
    var next = spacing;
    var placed = 0;
    final masked = cuts != null && cuts.isNotEmpty;
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
      if (masked &&
          KerbCuts.parkingBlocked(
              cuts, s > 0 ? 1 : 0, arcOffset + travelled)) {
        placed++;
        continue;
      }
      VehicleMeshes.emit(body, glass, kind,
          p + side * (road.halfWidthM * s * 0.78), along, up,
          u: (h >> 16 & 0xFF) / 255.0);
      placed++;
    }
    return placed;
  }

  /// [road]'s kerb cuts as a typed list, or null when it carries none. The
  /// wire holds them as a plain `List<double>`; a road cut by the capture
  /// already hands over a `Float64List` view, which is taken as it is.
  static Float64List? cutsOf(RoadSnapshot road) {
    final k = road.kerbCuts;
    if (k.isEmpty) return null;
    return k is Float64List ? k : Float64List.fromList(k);
  }
}

/// The road pass's builders for one tile, and its budgets. One set lives
/// per [CityMeshScratch] and is [reset] between tiles.
class CityRoadBuilders {
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
  static const int propBudgetPerTile = 2600;
  int propBudget = propBudgetPerTile;
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
  static const int curbCarsPerTile = 240;
  int curbCars = curbCarsPerTile;
  final MeshBuilder lampSolid = MeshBuilder();
  final MeshBuilder lampGlow = MeshBuilder();
  final MeshBuilder walkRibbon = MeshBuilder();
  // The railway: ballast, sleepers, rails.
  final MeshBuilder railBallast = MeshBuilder();
  final MeshBuilder railConcrete = MeshBuilder();
  final MeshBuilder railSteel = MeshBuilder();
  // A decorated road's grass: its verges and its planted median, on the
  // ground palette.
  final MeshBuilder verge = MeshBuilder();

  /// The road being emitted, as the anchor-relative points every emitter
  /// takes: filled per road and read within the same call, one list for
  /// the whole pass (see `CityTileMeshJob._emitRoad`).
  final List<Vector3> points = [];

  /// Every builder in the order the merge reads them, for [reset] and the
  /// capacity count.
  List<MeshBuilder> get _all => [
        ribbon,
        dirtRibbon,
        alleyRibbon,
        airSolid,
        airDeck,
        airGlow,
        propSolid,
        propGlow,
        tubeSolid,
        tubeGlass,
        curbSolid,
        curbGlass,
        lampSolid,
        lampGlow,
        walkRibbon,
        railBallast,
        railConcrete,
        railSteel,
        verge,
      ];

  /// Empty every builder and list, keeping their capacity, and restore the
  /// per-tile budgets: the state a fresh set had.
  void reset() {
    for (final b in _all) {
      b.reset();
    }
    treePits.clear();
    shrubPits.clear();
    points.clear();
    propBudget = propBudgetPerTile;
    curbCars = curbCarsPerTile;
  }

  /// Vertex capacity over every builder.
  int get vertexCapacity => _all.fold(0, (n, b) => n + b.vertexCapacity);
}

/// The builders of a tile's other passes — the ground sheet, and the lot
/// furniture in its four materials — for one tile. One set lives per
/// [CityMeshScratch] beside the road builders and is [reset] between
/// tiles, so a tile's ground and gardens fill the buffers the last tile's
/// grew rather than a fresh set each (see [CityMeshScratch.tile]).
class CityTileBuilders {
  /// The ground sheet: every flat patch, coloured through the palette.
  final MeshBuilder patches = MeshBuilder();
  // The lot furniture: fences and signs, the lit faces, the parking
  // aprons, and the cars on them.
  final MeshBuilder featureSolid = MeshBuilder();
  final MeshBuilder featureGlow = MeshBuilder();
  final MeshBuilder featureApron = MeshBuilder();
  final MeshBuilder featureCars = MeshBuilder();

  List<MeshBuilder> get _all =>
      [patches, featureSolid, featureGlow, featureApron, featureCars];

  /// Empty every builder, keeping its capacity.
  void reset() {
    for (final b in _all) {
      b.reset();
    }
  }

  /// Vertex capacity over every builder.
  int get vertexCapacity => _all.fold(0, (n, b) => n + b.vertexCapacity);
}
