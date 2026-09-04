// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Draws colonies in the 3D scene.
///
/// Buildings arrive as [BuildingSnapshot]s carrying their site size and kind,
/// so this builds a colony from the frame ALONE — it never reaches into the
/// authoritative `CitySim`, which a networked client could not do anyway.
///
/// Geometry is generated once per ARCHETYPE and drawn instanced, the same way
/// the scatter system draws forests: a city of ten thousand buildings resolves
/// to a few hundred meshes and a few hundred draws, not ten thousand of either.
///
/// The colony is drawn in TILES: everything of it — roads, lots, buildings,
/// junctions — within one two-mile cell of the body's frame is one set of
/// nodes, built at a level of detail set by how far the cell is from the
/// camera and rebuilt only when that changes, a little per frame, nearest
/// first. A twenty-mile city is a hundred-odd tiles; the downtown and the
/// farthest subdivision are drawn by the same code at different tiers, and
/// nothing is grown at draw time from anything but the frame.
library;

import 'dart:async' show unawaited;
import 'dart:math' as math;

import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;

import '../../../application/snapshot/world_snapshot.dart';
import '../../../domain/architecture/building_generator.dart';
import '../../../domain/colony/city/city_building_spec.dart';
import '../../../domain/colony/city/parcel.dart';
import '../../../domain/colony/city/sprawl_plan.dart';
import '../../../domain/scatter/mesh_builder.dart';
import '../../../domain/scatter/prop_catalog.dart';
import '../../../domain/scatter/prop_mesh.dart';
import '../../../domain/scatter/prop_model.dart';
import '../scatter/scatter_prop_library.dart';
import '../../../domain/shared/quaternion.dart';
import '../../../domain/shared/vector3.dart';
import '../../../domain/architecture/architecture_style.dart';
import '../../../domain/architecture/city_lighting.dart';
import '../coord_convert.dart';
import 'city_materials.dart';
import 'elevated_structure.dart';
import 'lot_features.dart';
import 'mesh_merge.dart';
import 'oriented_box.dart';
import 'pedestrian_tube.dart';
import 'rail_vehicles.dart';
import 'railway.dart';
import 'road_mesher.dart';
import 'street_furniture.dart';
import 'vehicle_meshes.dart';
import 'city_textures.dart';

/// One generated archetype, uploaded.
class _CityMesh {
  _CityMesh(this.solid, this.glazing, {this.lod = false});
  final fs.MeshGeometry? solid;
  final fs.MeshGeometry? glazing;

  /// A LOD-debug box rather than a building: drawn on the palette material so
  /// its colour means something, not on the facade one.
  final bool lod;
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

class CityNodes {
  CityNodes(this._scene);

  final fs.Scene _scene;

  /// Off switch for profiling, matching the other node families.
  static bool enabled = true;

  /// Milliseconds spent in each phase of the LAST update, and what each one
  /// produced. Read by the studio's frame breakdown.
  ///
  /// A frame counter alone says the city is slow; it does not say whether that
  /// is the structural rebuild, the per-frame traffic pass, or simply too many
  /// draw calls. Timing the phases separately is the difference between
  /// knowing there is a problem and knowing where it is.
  static final Map<String, double> phaseMs = {};
  static final Map<String, int> phaseCount = {};

  /// Beyond this the whole colony is skipped — from far enough out a city is
  /// smaller than a pixel and the terrain's own texture carries it.
  static double maxRangeM = 400000;

  /// Draw every building as a plain box coloured by the detail tier it was
  /// actually generated at, instead of as the building.
  ///
  /// A LOD problem is invisible in a normal view: a city drawn entirely at
  /// full detail looks exactly like a city drawn sensibly, it just costs ten
  /// times as much. Painting the tier is the only way to SEE which buildings
  /// are expensive — and the first thing it showed was that they all were.
  static bool lodDebug = false;

  /// Pick each building's tier from ITS OWN distance rather than one tier for
  /// the whole colony. See [detailFor].
  static bool perBuildingLod = true;

  /// Buildings resolved to each tier last frame, for the panel.
  static final Map<BuildingDetail, int> lodCounts = {};

  /// Distance past which a building is only its block silhouette.
  static double blockRangeM = 300;

  /// Distance inside which interiors are generated.
  static double interiorRangeM = 50;

  /// Tiles nearer than this get the street's furniture: sidewalks, lamps,
  /// signals, fences, car parks, trees.
  static double nearRangeM = 2800;

  /// Tiles nearer than this get their lanes painted and their junction
  /// plates; beyond, bare ribbons and silhouettes.
  static double midRangeM = 7500;

  /// The tile: one cell of the body's frame this size on a side.
  static double tileM = 2 * kMileM;

  /// Milliseconds of building the frame will spend before deferring the
  /// rest of the queue.
  static double buildBudgetMs = 9;

  static String debugLine = '';

  /// The editor's ground cursor, in BODY-FIXED metres, or null when nothing is
  /// being pointed at.
  ///
  /// A static rather than snapshot state, deliberately: where the mouse is
  /// hovering is a property of the VIEW, not of the world. Putting it in the
  /// frame would replicate a cursor to every multiplayer client and make the
  /// snapshot change on every mouse move.
  static Vector3? cursorBF;
  static String cursorBodyId = '';
  static double cursorSizeM = 24;

  /// Depth of the ground cursor. Separate from [cursorSizeM] because the sites
  /// it previews are not square — a starport is 1800 x 2600 m.
  static double cursorDepthM = 24;

  /// True when what is held cannot be placed where the cursor is.
  static bool cursorBad = false;

  /// Whether to draw road traffic at all.
  static bool traffic = true;

  /// Whether to draw lot fences, shop signs, car parks and their cars.
  static bool lotFeatures = true;

  /// Set when the colony's roads are sealed — an airless world, where parked
  /// vehicles are rovers rather than cars.
  static bool sealedWorld = false;

  /// Whether curbside bays are used. OFF makes a colony read as newer, or as
  /// somewhere parking is not tolerated on the carriageway; ON fills the verge
  /// the way an older street does. Optional because it is a look, not a rule.
  static bool onStreetParking = true;

  /// Ceiling on parked cars per TILE. They are static geometry, unlike road
  /// traffic, but a district each with a full car park is still a lot of
  /// triangles for something nobody counts.
  static const int _maxParkedCars = 400;

  /// Scales how many vehicles a road carries. A hook for the colony's own
  /// congestion once that reaches the frame; 1.0 is an ordinary working day.
  static double trafficDensity = 1.0;

  /// Hard ceiling on vehicles per frame. The whole set is rebuilt every frame
  /// and pushed through the transient buffer, which is the same budget the
  /// asteroid fields already have to respect. Gated by [trafficRangeM], so
  /// the count is spent where the camera is.
  static const int _maxVehicles = 600;

  /// Roads further than this from the focus carry no vehicles. Traffic is
  /// a per-frame cost, and a car six kilometres away is under a pixel.
  static double trafficRangeM = 3500;

  /// Resident traffic draws — one per (body, vehicle kind, material) plus
  /// the train's — keyed so a frame REUSES last frame's node and moves its
  /// instances in place. Tearing every one down and re-adding it each frame
  /// (the old shape) removed and re-added render items, which marks the
  /// engine's BVH structurally dirty and rebuilt it over the whole scene
  /// sixty times a second: more per-frame cost than the traffic itself.
  final Map<String, _TrafficSlot> _trafficSlots = {};

  /// The train's canonical car (body + window band), instanced along the
  /// line like any other vehicle — it used to be re-meshed every frame.
  _CityMesh? _trainCar;

  /// One uploaded mesh per vehicle kind, built the first time it is needed.
  ///
  /// This is what makes traffic cheap: the geometry goes to the GPU ONCE and
  /// every car afterwards costs a 4x4 matrix. Re-baking each vehicle into a
  /// per-frame mesh meant uploading thousands of vertices sixty times a second
  /// for shapes that never change.
  final Map<VehicleKind, _CityMesh> _vehicleMeshes = {};

  _CityMesh _vehicleMesh(VehicleKind kind) =>
      _vehicleMeshes.putIfAbsent(kind, () {
        final body = MeshBuilder();
        final glass = MeshBuilder();
        VehicleMeshes.emitModel(body, glass, kind);
        return _CityMesh(_geometryOf(body.build()), _geometryOf(glass.build()));
      });

  /// Rolling stock, one upload per kind, instanced along the railway.
  final Map<RailCarKind, _CityMesh> _railCarMeshes = {};

  _CityMesh _railCarMesh(RailCarKind kind) =>
      _railCarMeshes.putIfAbsent(kind, () {
        final body = MeshBuilder();
        final glass = MeshBuilder();
        RailVehicleMeshes.emitModel(body, glass, kind);
        return _CityMesh(_geometryOf(body.build()), _geometryOf(glass.build()));
      });

  // ---- Placement heatmap -------------------------------------------------
  //
  // A sprawling installation cannot go just anywhere: it needs a plot clear of
  // roads and other plots, within reach of a street, on ground it can be cut
  // into. Refusing the player's click and printing why is a poor way to say
  // that. These paint the ANSWER on the ground before the click.

  /// Candidate site centres, body-fixed.
  static List<Vector3> heatBF = const [];

  /// Verdict per centre: 0 placeable, 1 too steep, 2 blocked.
  static List<int> heatKind = const [];

  /// Edge length of one heatmap cell, metres.
  static double heatCellM = 0;

  /// The road being DRAWN: committed control points plus the hover point, in
  /// body-fixed metres. The editor writes it; the cursor pass draws it as a
  /// ghost ribbon so the player sees the road before paying for it.
  static List<Vector3> pendingRouteBF = const [];
  static double pendingWidthM = 8;

  /// Whether the pending route violates its tier's grade limit — drawn in the
  /// refusal red so the player sees the problem BEFORE paying for the road.
  static bool pendingRouteBad = false;

  /// Whether a texture upload is still in flight (see [update]).
  bool _texturesPending = false;

  /// Whether the custom surface shader is still compiling in (see [update]).
  bool _glowShaderPending = false;

  /// The skyglow's reference frame, stashed by [_nightFactorAt] — the same
  /// site pick that decides how dark it is decides where "ground" is.
  Vector3? _glowBodyWorld;
  Quaternion? _glowBodyQuat;
  double _glowGroundRadiusM = 0;

  /// The light-density map's frame, body-fixed, written by [_bakeLightMap]
  /// each structural change. The map itself lives in [CityMaterials].
  Vector3 _glowAnchorBF = Vector3.zero;
  Vector3 _glowEastBF = const Vector3(1, 0, 0);
  Vector3 _glowNorthBF = const Vector3(0, 1, 0);
  double _glowHalfExtentM = 1;

  /// Cursor node, rebuilt every frame it is visible. One quad — cheap enough
  /// that tracking the mouse never touches the city's cached batches, which is
  /// the whole point of keeping it separate from them.
  fs.Node? _cursorNode;

  /// What [_cursorNode] was built from, so an unmoved mouse costs nothing.
  Object? _cursorKey;

  /// Lot-size quantisation and variant count for the building archetypes.
  ///
  /// These are the DRAW CALL dial. Every distinct archetype is its own
  /// uploaded mesh and its own submission, so a colony's cost at the GPU is
  /// driven by how many different buildings it asks for, not by how many it
  /// has: 670 buildings drew in 92 calls off 41 archetypes. Coarser buckets
  /// and fewer variants collapse that; a street of identical houses is the
  /// price.
  static double archetypeBucketM = 6;
  static int archetypeVariants = 4;

  /// The architecture kit the whole colony is built in.
  ///
  /// A street wall by default, because that is what a city looks like: the
  /// buildings stand on their property lines, meet their neighbours, and put
  /// the parking round the back. The old setback-box idiom is still here as
  /// [ArchitectureStyle.utilitarian] and is still right for a works or a
  /// retail shed — it just should not be the whole world.
  static ArchitectureStyle style = ArchitectureStyle.masonryStreet;

  static BuildingLibrary _newLibrary() => BuildingLibrary(
        generator: const BuildingGenerator().withStyle(style),
        bucketM: archetypeBucketM,
        variants: archetypeVariants,
      );

  /// The library the BLOCK tier draws from: buckets twice as coarse, half
  /// the variants. A block-tier building is a silhouette box hundreds of
  /// metres away, where a two-metre size quantum and a repeated massing are
  /// invisible — but every distinct archetype is an uploaded mesh and a
  /// solid+glazing draw pair, and the block tier is most of any city seen
  /// from its framing distance. Coarser sharing there is draw calls off the
  /// dominant tier for a difference nobody can resolve.
  static BuildingLibrary _newCoarseLibrary() => BuildingLibrary(
        generator: const BuildingGenerator().withStyle(style),
        bucketM: archetypeBucketM * 2,
        variants: math.max(1, archetypeVariants ~/ 2),
      );

  BuildingLibrary _library = _newLibrary();
  BuildingLibrary _libraryCoarse = _newCoarseLibrary();
  double _libraryBucketM = archetypeBucketM;
  int _libraryVariants = archetypeVariants;
  String _libraryStyle = style.id;

  /// The library serving [tier].
  BuildingLibrary _libraryFor(BuildingDetail tier) =>
      tier == BuildingDetail.block ? _libraryCoarse : _library;

  /// Rebuild the archetype libraries if their knobs moved. Everything already
  /// uploaded is keyed by the old quantisation, so it all has to go.
  void _syncLibrary() {
    if (_libraryBucketM == archetypeBucketM &&
        _libraryVariants == archetypeVariants &&
        _libraryStyle == style.id) {
      return;
    }
    _libraryBucketM = archetypeBucketM;
    _libraryVariants = archetypeVariants;
    _libraryStyle = style.id;
    _library = _newLibrary();
    _libraryCoarse = _newCoarseLibrary();
    _uploaded.clear();
    invalidate();
  }

  final Map<BuildingArchetype, _CityMesh> _uploaded = {};

  /// Which visualiser state the meshes in [_uploaded] were built in.
  bool? _uploadedLodDebug;

  /// Drop the mesh cache when [lodDebug] is toggled.
  ///
  /// [_uploaded] is keyed by [BuildingArchetype] — type, size bucket, detail
  /// tier, variant, style, corner — and NOTHING in that key says whether the
  /// entry is a real building or a debug box. The tile keys carry `lodDebug`,
  /// so flipping the toggle rebuilds every tile; but a rebuild fills its
  /// batches with `putIfAbsent`, which hands back whatever is already cached
  /// for that archetype. Only archetypes never meshed BEFORE the toggle
  /// actually got a box — so the cache goes too.
  void _syncLodDebug() {
    if (_uploadedLodDebug == lodDebug) return;
    _uploadedLodDebug = lodDebug;
    _uploaded.clear();
  }

  /// The tiles, by body and cell.
  final Map<String, _Tile> _tiles = {};

  /// Tiles waiting to build, nearest first.
  final List<_Tile> _queue = [];

  /// One root node per body: the colony's anchor on the body, placed each
  /// frame the body moves. Every tile's batches hang under it at a fixed
  /// offset, so a spinning planet costs one transform write per body rather
  /// than one per batch — a thousand of which would each refit the BVH.
  final Map<String, _BodyRoot> _roots = {};

  /// Buildings per body, from the last bucketing; the night factor and the
  /// light map read it.
  Map<String, List<BuildingSnapshot>> _byBody = {};

  /// What the tiles were bucketed from.
  String _structureSig = '';
  Object? _lastBuildings, _lastRoads, _lastPatches;

  /// Bumped by [invalidate]; part of every tile's key.
  int _invalidation = 0;

  /// Force every tile to rebuild.
  ///
  /// The tiles are keyed on what the COLONY looks like, which is right — a
  /// static city should not be re-meshed sixty times a second — but it means
  /// a renderer-side switch (street furniture, say) changes nothing until
  /// something in the city does. The studio's toggles need this or they
  /// appear to be dead.
  void invalidate() => _invalidation++;

  /// Instances above this in one draw overflow the engine's per-frame transient
  /// block — the same 1 MiB / 16,384-mat4 ceiling the scatter batches hit.
  static const int _maxPerDraw = 14000;

  /// Curb reveal: how far the sidewalk stands above the carriageway. 150 mm
  /// is the real standard, and it is the "subtle elevation difference" that
  /// makes a street read as built rather than painted.
  static const double kCurbHeightM = RoadMesher.curbHeightM;

  /// The carriageway ribbon's own lift over the graded ground.
  static const double _ribbonLiftM = RoadMesher.ribbonLiftM;

  /// Where the walk surface sits: the ribbon's lift plus the curb reveal.
  static const double _walkTopLiftM = _ribbonLiftM + kCurbHeightM;

  void update(
    WorldSnapshot snap,
    FloatingOrigin origin, {
    required Vector3 focusWorld,
  }) {
    if (!enabled ||
        (snap.buildings.isEmpty &&
            snap.roads.isEmpty &&
            snap.patches.isEmpty)) {
      if (_tiles.isNotEmpty || _roots.isNotEmpty) _clear();
      debugLine = 'city: frame carries none '
          '(b=${snap.buildings.length} r=${snap.roads.length} '
          'p=${snap.patches.length})';
      // The cursor still draws over bare ground: pointing at an empty site is
      // exactly when the player most needs to see where a building would go.
      _syncCursor(snap, origin, _bodyMotion(snap, origin));
      return;
    }
    final sw = Stopwatch()..start();

    // Tiles are cut from the frame when its STRUCTURE changes: a building
    // built, a road drawn, the ground graded. A frame captured every tick
    // carries new lists with the same contents, so identity alone would
    // re-bucket two hundred thousand buildings sixty times a second, and
    // the counts are the change detector — the same one the old rebuild
    // key used.
    final sig = '${snap.buildings.length}|${snap.roads.length}|'
        '${snap.patches.length}|${snap.terrainEdits.length}';
    final sameLists = identical(snap.buildings, _lastBuildings) &&
        identical(snap.roads, _lastRoads) &&
        identical(snap.patches, _lastPatches);
    if (!sameLists && sig != _structureSig) {
      _bucket(snap);
      _structureSig = sig;
    }
    _lastBuildings = snap.buildings;
    _lastRoads = snap.roads;
    _lastPatches = snap.patches;
    phaseMs['city.bucket'] = sw.elapsedMicroseconds / 1000;
    sw.reset();

    // Range gate off the nearest tile, and the camera in each body's frame.
    var nearest = double.infinity;
    final focusByBody = <String, Vector3>{};
    for (final t in _tiles.values) {
      final body = snap.bodies[t.bodyId];
      if (body == null) continue;
      final focusBF = focusByBody[t.bodyId] ??= focusInBodyFrame(
        focusWorld,
        Vector3(body.px, body.py, body.pz),
        Quaternion(body.qw, body.qx, body.qy, body.qz),
      );
      t.distanceM =
          math.max(0.0, (t.centreBF - focusBF).length - t.halfDiagonalM);
      if (t.distanceM < nearest) nearest = t.distanceM;
    }
    if (nearest > maxRangeM) {
      if (_tiles.isNotEmpty) _clear();
      debugLine = 'city: culled, nearest '
          '${(nearest / 1000).toStringAsFixed(1)}km > '
          '${(maxRangeM / 1000).toStringAsFixed(0)}km';
      return;
    }

    // Textures load once, off the first frame that needs them; until they
    // land the materials draw against the engine's white placeholder rather
    // than blocking the frame.
    //
    // The materials cache their texture handle at first use, so the ones built
    // during that wait captured NULL and would have stayed untextured for the
    // rest of the session. Dropping them the frame the upload lands is what
    // makes the city actually take its facades — the first colony founded in a
    // session is always the one that races the load.
    if (!CityTextures.ready) {
      unawaited(CityTextures.load());
      _texturesPending = true;
    } else if (_texturesPending) {
      _texturesPending = false;
      CityMaterials.reset();
      _dropResident();
      invalidate();
    }
    // Same race for the scatter atlas: a tile built before it landed skipped
    // its street trees, so rebuild once the upload lands.
    if (_floraPending && ScatterPropLibrary.texturesReady) {
      _floraPending = false;
      invalidate();
    }
    // And for the custom surface shader: batches built before it landed hold
    // materials on the stock fragment, so drop the materials AND the batches
    // the frame it arrives — resetting the material cache alone leaves every
    // existing node bound to the old instances.
    if (!CityMaterials.shaderReady) {
      unawaited(CityMaterials.loadShader());
      _glowShaderPending = true;
    } else if (_glowShaderPending) {
      _glowShaderPending = false;
      CityMaterials.reset();
      invalidate();
      _dropResident();
    }
    CityMaterials.nightFactor = _nightFactorAt(snap, _byBody);
    // Where the skyglow's height falloff and its density map are measured
    // from, in the shader's own scene space. Per frame: the floating origin
    // moves, and the body spins under its light map.
    final glowBody = _glowBodyWorld;
    final glowQuat = _glowBodyQuat;
    if (glowBody != null && glowQuat != null) {
      CityMaterials.glowCentreScene = origin.worldToScene(glowBody);
      CityMaterials.glowGroundRadiusScene = lengthToScene(_glowGroundRadiusM);
      CityMaterials.glowMetresToScene = lengthToScene(1.0);
      CityMaterials.lightMapAnchorScene =
          origin.worldToScene(glowBody + glowQuat.rotate(_glowAnchorBF));
      final e = glowQuat.rotate(_glowEastBF);
      final n = glowQuat.rotate(_glowNorthBF);
      CityMaterials.lightMapEast = vm.Vector3(e.x, e.y, e.z);
      CityMaterials.lightMapNorth = vm.Vector3(n.x, n.y, n.z);
      CityMaterials.lightMapHalfExtentScene = lengthToScene(_glowHalfExtentM);
    }

    _syncLibrary();
    _syncLodDebug();

    // The colony-wide fallback tier, off the nearest tile. Kept for the
    // whole-colony path; see [detailFor] for why one tier for a whole city
    // is not enough once the city is big.
    final colonyTier = tierForDistance(nearest);

    // Each tile's tier from its distance, and the key its build depends
    // on: what is in it, the tier, and — inside the near tier, where every
    // building takes its own detail from its own distance — the camera,
    // quantised hard to 64 m, because rebuilding on every centimetre of
    // travel would cost far more than the LOD saves.
    var near = 0, mid = 0, far = 0;
    for (final t in _tiles.values) {
      final focusBF = focusByBody[t.bodyId];
      if (focusBF == null) continue;
      final tier = t.distanceM < nearRangeM
          ? CityTier.near
          : (t.distanceM < midRangeM ? CityTier.mid : CityTier.far);
      switch (tier) {
        case CityTier.near:
          near++;
        case CityTier.mid:
          mid++;
        case CityTier.far:
          far++;
      }
      final cam = tier == CityTier.near && perBuildingLod
          ? '${(focusBF.x / 64).round()},${(focusBF.y / 64).round()},'
              '${(focusBF.z / 64).round()}'
          : '';
      final want = '${t.structureKey}|${tier.index}|$cam'
          '|${lodDebug ? 1 : 0}|${perBuildingLod ? 1 : 0}'
          '|${interiorRangeM.round()}|${blockRangeM.round()}'
          '|${colonyTier.index}|$_invalidation';
      if (t.wantKey != want) {
        t.wantKey = want;
        t.wantTier = tier;
        if (!t.queued) {
          t.queued = true;
          _queue.add(t);
        }
      }
    }
    phaseMs['city.tier'] = sw.elapsedMicroseconds / 1000;
    sw.reset();

    // Build, nearest first, within the budget: a part of a tile at a time,
    // so a near tile never takes the whole frame.
    var builtThisFrame = 0;
    if (_queue.isNotEmpty) {
      _queue.sort((a, b) => a.distanceM.compareTo(b.distanceM));
      while (_queue.isNotEmpty && sw.elapsedMilliseconds < buildBudgetMs) {
        final t = _queue.first;
        final focusBF = focusByBody[t.bodyId];
        if (focusBF == null || _stepBuild(t, snap, focusBF, colonyTier)) {
          _queue.removeAt(0);
          t.queued = false;
          builtThisFrame++;
        }
      }
    }
    phaseMs['city.build'] = sw.elapsedMicroseconds / 1000;
    phaseMs['city.rebuild'] = phaseMs['city.build']!;
    sw.reset();

    // Every frame: put each body's root where the body is. A planet spins,
    // so even a completely static colony needs a new root matrix — but only
    // the root's, and only on bodies that moved against the floating origin
    // since last frame. Writing a node's transform dirties its bounds and
    // refits the engine's BVH, so a static studio frame must write none.
    final moved = _bodyMotion(snap, origin);
    _placeRoots(snap, origin, moved);
    phaseMs['city.anchors'] = sw.elapsedMicroseconds / 1000;
    sw.reset();
    _syncTraffic(snap, origin, moved, focusWorld);
    phaseMs['city.traffic'] = sw.elapsedMicroseconds / 1000;
    sw.reset();
    _syncCursor(snap, origin, moved);
    phaseMs['city.cursor'] = sw.elapsedMicroseconds / 1000;

    var draws = 0, skylineTris = 0;
    lodCounts.clear();
    for (final t in _tiles.values) {
      draws += t.batches.length;
      skylineTris += t.skylineTris;
      t.lodCounts.forEach((k, v) => lodCounts[k] = (lodCounts[k] ?? 0) + v);
    }
    phaseCount['draws'] = draws;
    phaseCount['batches'] = draws;
    phaseCount['meshes'] = _uploaded.length;
    phaseCount['buildings'] = snap.buildings.length;
    phaseCount['tiles'] = _tiles.length;
    phaseCount['near'] = near;
    phaseCount['mid'] = mid;
    phaseCount['far'] = far;
    phaseCount['queued'] = _queue.length;
    phaseCount['builtThisFrame'] = builtThisFrame;
    phaseCount['trafficNodes'] =
        _trafficSlots.values.where((slot) => slot.node.visible).length;
    phaseCount['skylineTris'] = skylineTris;
    debugLine = 'city: ${snap.buildings.length} bldg, ${_tiles.length} tiles '
        '($near near, $mid mid, $far far), $draws draws, '
        '${_queue.length} queued, meshes ${_uploaded.length}, '
        'skyline $skylineTris tris';
  }

  // ---- Tiles ----------------------------------------------------------------

  /// Cut the frame into tiles: every building, road and patch to the cell
  /// its position (a road's middle) falls in, every road END to the cell IT
  /// falls in — so a junction where roads of two tiles meet is drawn once,
  /// by the tile that holds the crossing, from all of its legs.
  void _bucket(WorldSnapshot snap) {
    for (final t in _tiles.values) {
      _dropTile(t);
    }
    _tiles.clear();
    _queue.clear();
    _byBody = {};
    for (final r in _roots.values) {
      r.endHalf.clear();
      r.planNodeKeys.clear();
      r.transitEnds.clear();
    }
    sealedWorld = false;

    _Tile tileFor(String bodyId, Vector3 p) {
      final ix = (p.x / tileM).floor(),
          iy = (p.y / tileM).floor(),
          iz = (p.z / tileM).floor();
      final key = '$bodyId/$ix/$iy/$iz';
      return _tiles.putIfAbsent(key, () {
        final centre = Vector3((ix + 0.5) * tileM, (iy + 0.5) * tileM,
            (iz + 0.5) * tileM);
        return _Tile(key, bodyId, centre, tileM * math.sqrt(3) / 2);
      });
    }

    _BodyRoot rootFor(String bodyId, Vector3 anchorBF) =>
        _roots.putIfAbsent(bodyId, () {
          final node = fs.Node();
          _scene.add(node);
          return _BodyRoot(node, bodyId, anchorBF);
        });

    for (final b in snap.buildings.values) {
      final p = Vector3(b.px, b.py, b.pz);
      rootFor(b.body, p);
      (_byBody[b.body] ??= []).add(b);
      tileFor(b.body, p).buildings.add(b);
    }
    for (final p in snap.patches) {
      final at = Vector3(p.px, p.py, p.pz);
      rootFor(p.body, at);
      _byBody.putIfAbsent(p.body, () => []);
      tileFor(p.body, at).patches.add(p);
    }
    for (final r in snap.roads) {
      final n = r.points.length ~/ 3;
      if (n < 2) continue;
      final m = (n ~/ 2) * 3;
      final mid = Vector3(r.points[m], r.points[m + 1], r.points[m + 2]);
      rootFor(r.body, mid);
      _byBody.putIfAbsent(r.body, () => []);
      tileFor(r.body, mid).roads.add(r);
      if (r.sealed) sealedWorld = true;
      final cls = RoadClass
          .values[r.roadClassIndex.clamp(0, RoadClass.values.length - 1)];
      final first = Vector3(r.points[0], r.points[1], r.points[2]);
      final last = Vector3(r.points[3 * n - 3], r.points[3 * n - 2],
          r.points[3 * n - 1]);
      final root = _roots[r.body]!;
      // Widest carriageway meeting each road END, so a sidewalk can stop
      // short of its crossing instead of bridging the intersecting street.
      // Legs split from one crossing land on (nearly) the same point — the
      // junction pass tolerates 8 m of drift — so a coarse quantised key
      // groups them. The count says whether anything ELSE meets there: a
      // dead end keeps its pavement all the way to the kerb line.
      if (!cls.isElevated) {
        for (final p in [first, last]) {
          final k = _endKey(p);
          final prev = root.endHalf[k];
          root.endHalf[k] = prev == null
              ? (r.halfWidthM, 1)
              : (math.max(prev.$1, r.halfWidthM), prev.$2 + 1);
        }
      }
      // Every road END, with the point just inside it (for the leg
      // direction), to the tile the end lies in. Roads are already SPLIT at
      // their crossings, so an intersection is simply a place where three
      // or more ends meet.
      if (cls.joinsJunctions) {
        final second = Vector3(r.points[3], r.points[4], r.points[5]);
        final penult = Vector3(r.points[3 * n - 6], r.points[3 * n - 5],
            r.points[3 * n - 4]);
        tileFor(r.body, first).ends.add(_TileEnd(
            first, second, r.halfWidthM, cls, cls.paved, r.collector));
        tileFor(r.body, last).ends.add(_TileEnd(
            last, penult, r.halfWidthM, cls, cls.paved, r.collector));
      }
      if (cls == RoadClass.transit) {
        root.transitEnds.add(first);
        root.transitEnds.add(last);
      }
    }
    // The plan's junctions per body, keyed like the ends and with their
    // neighbouring cells, so a street ending on one is not a dead end.
    for (final nd in snap.sprawlNodes) {
      final root = _roots[nd.body];
      if (root == null) continue;
      final p = Vector3(nd.px, nd.py, nd.pz);
      final cx = (p.x / 10).round(), cy = (p.y / 10).round();
      final cz = (p.z / 10).round();
      for (var dx = -1; dx <= 1; dx++) {
        for (var dy = -1; dy <= 1; dy++) {
          for (var dz = -1; dz <= 1; dz++) {
            root.planNodeKeys.add(Object.hash(cx + dx, cy + dy, cz + dz));
          }
        }
      }
    }
    // Each tile's identity: what it holds, so a tile whose members did not
    // change keeps its build across a frame that changed another's.
    for (final t in _tiles.values) {
      var h = t.buildings.length * 0x9E3779B1 + t.roads.length * 0x85EBCA6B +
          t.patches.length * 0xC2B2AE35;
      for (final b in t.buildings) {
        h = (h ^ b.id.hashCode) * 0x27D4EB2F & 0xFFFFFFFF;
      }
      for (final r in t.roads) {
        h = (h ^ r.points.length ^ r.points[0].round()) * 0x165667B1 &
            0xFFFFFFFF;
      }
      t.structureKey = '${t.buildings.length}|${t.roads.length}|'
          '${t.patches.length}|${snap.terrainEdits.length}|$h';
    }
    // The skyglow's density map, from the first body with buildings — the
    // same single-colony assumption the night factor makes.
    for (final entry in _byBody.entries) {
      if (entry.value.isEmpty) continue;
      final root = _roots[entry.key];
      if (root == null) continue;
      _bakeLightMap(entry.value, root.anchorBF);
      break;
    }
  }

  static int _endKey(Vector3 p) => Object.hash(
      (p.x / 10).round(), (p.y / 10).round(), (p.z / 10).round());

  /// One step of a tile's build: the next part into its builders, or — when
  /// everything is in — the upload that swaps the tile's nodes. Returns true
  /// when the tile is done.
  bool _stepBuild(
      _Tile t, WorldSnapshot snap, Vector3 focusBF, BuildingDetail colonyTier) {
    var job = t.job;
    if (job == null || job.key != t.wantKey) {
      final tier = t.wantTier ?? CityTier.far;
      final root = _roots[t.bodyId];
      if (root == null) return true;
      job = t.job = _TileJob(t.wantKey, tier, t.centreBF);
      final j = job;
      final epoch = snap.epoch;
      // Parts, run from the end: roads in runs, then the junctions and the
      // terminals over them, then buildings in runs, the ground, the lot
      // furniture, and the planting last, off the pits the roads left.
      const roadsPerStep = 40;
      for (var i = 0; i < t.roads.length; i += roadsPerStep) {
        final from = i, to = math.min(i + roadsPerStep, t.roads.length);
        j.steps.add(() {
          for (var k = from; k < to; k++) {
            _emitRoad(j.roads, t.roads[k], tier, j.anchorBF, root);
          }
        });
      }
      j.steps.add(() => _emitJunctions(j, t, epoch, root));
      const buildingsPerStep = 400;
      for (var i = 0; i < t.buildings.length; i += buildingsPerStep) {
        final from = i, to = math.min(i + buildingsPerStep, t.buildings.length);
        j.steps.add(() {
          for (var k = from; k < to; k++) {
            _emitBuilding(j, t.buildings[k], focusBF, colonyTier);
          }
        });
      }
      j.steps.add(() => _emitPatches(t.patches, j));
      if (tier == CityTier.near && lotFeatures) {
        const perStep = 200;
        for (var i = 0; i < t.buildings.length; i += perStep) {
          final from = i, to = math.min(i + perStep, t.buildings.length);
          j.steps.add(() => _emitLotFeatures(
              t.buildings.sublist(from, to), j, focusBF, colonyTier));
        }
      }
      // The caller pops from the end.
      j.steps.setAll(0, j.steps.reversed.toList());
    }
    if (job.steps.isNotEmpty) {
      job.steps.removeLast()();
      return false;
    }
    _upload(t, job);
    t.builtKey = job.key;
    t.job = null;
    return true;
  }

  /// Swap a tile's nodes for the job's finished builders.
  void _upload(_Tile t, _TileJob job) {
    final root = _roots[t.bodyId];
    if (root == null) return;
    // The old nodes only: the tile stays queued until the build loop pops
    // it — dropping it from the queue here left the loop's removeAt(0)
    // taking the NEXT tile, or throwing on an empty queue.
    _dropBatches(t);
    final offset = t.centreBF - root.anchorBF;
    final local = vm.Matrix4.translation(vm.Vector3(
        lengthToScene(offset.x), lengthToScene(offset.y),
        lengthToScene(offset.z)));
    void add(fs.Node node) {
      node.localTransform = local;
      root.node.add(node);
      t.batches.add(node);
    }

    void mesh(MeshBuilder builder, fs.Material material) {
      final built = builder.build();
      if (built.isEmpty) return;
      final geometry = _geometryOf(built);
      if (geometry == null) return;
      add(fs.Node(
        mesh: fs.Mesh.primitives(
            primitives: [fs.MeshPrimitive(geometry, material)]),
      ));
    }

    final r = job.roads;
    for (final (builder, material) in [
      // The ribbon takes the dedicated road strip — on the facade material it
      // rendered as a run of blank concrete with no curbs and no centre line,
      // which from the cockpit read as "roads are missing".
      (r.ribbon, CityMaterials.road),
      (r.dirtRibbon, CityMaterials.dirt),
      (r.alleyRibbon, CityMaterials.alley),
      (r.walkRibbon, CityMaterials.sidewalk),
      (r.railBallast, CityMaterials.dirt),
      (r.railConcrete, CityMaterials.sidewalk),
      (r.railSteel, CityMaterials.alley),
      (r.airDeck, CityMaterials.road),
      (r.airSolid, CityMaterials.facade),
      (r.airGlow, CityMaterials.glazing),
      (r.propSolid, CityMaterials.facade),
      (r.propGlow, CityMaterials.glazing),
      (r.lampSolid, CityMaterials.facade),
      (r.lampGlow, CityMaterials.glazing),
      // The pedestrian tube: a concrete curb carrying a glass barrel.
      (r.tubeSolid, CityMaterials.facade),
      (r.tubeGlass, CityMaterials.glazing),
      (r.curbSolid, CityMaterials.facade),
      (r.curbGlass, CityMaterials.glazing),
      // The lot furniture: fences, aprons, parked cars, lit signs.
      (job.featureSolid, CityMaterials.facade),
      (job.featureApron, CityMaterials.road),
      (job.featureCars, CityMaterials.facade),
      (job.featureGlow, CityMaterials.glazing),
      (job.patches, CityMaterials.ground),
    ]) {
      mesh(builder, material);
    }
    // The skyline: block-tier buildings as one mesh per material.
    var tris = 0;
    for (final (sink, material) in [
      (job.skylineSolid, CityMaterials.facade),
      (job.skylineGlazing, CityMaterials.glazing),
    ]) {
      if (sink.isEmpty) continue;
      final geometry = _geometryOf(sink.build());
      if (geometry == null) continue;
      add(fs.Node(
        mesh: fs.Mesh.primitives(
            primitives: [fs.MeshPrimitive(geometry, material)]),
      ));
      tris += sink.triangleCount;
    }
    t.skylineTris = tris;
    // The instanced buildings, per archetype.
    job.groups.forEach((key, transforms) {
      final m = _uploaded[key];
      if (m == null) return;
      // Walls take the stone material (concrete is closer to rock than
      // bark); glazing takes the foliage one, which is the alpha-capable
      // pass and is where the night lighting hooks in.
      for (final (geometry, material) in [
        (m.solid, m.lod ? CityMaterials.ground : CityMaterials.facade),
        (m.glazing, CityMaterials.glazing),
      ]) {
        if (geometry == null) continue;
        for (var start = 0; start < transforms.length; start += _maxPerDraw) {
          final end = math.min(start + _maxPerDraw, transforms.length);
          final instanced =
              fs.InstancedMesh(geometry: geometry, material: material);
          for (var i = start; i < end; i++) {
            instanced.addInstance(transforms[i]);
          }
          add(fs.Node()..addComponent(fs.InstancedMeshComponent(instanced)));
        }
      }
    });
    // Street planting, instanced off the scatter props.
    _emitStreetFlora(PropKind.broadleafTree, streetTreeHeightM,
        job.roads.treePits, job.anchorBF, add);
    _emitStreetFlora(PropKind.shrub, planterShrubHeightM, job.roads.shrubPits,
        job.anchorBF, add);
    t.lodCounts = job.lodCounts;
  }

  /// Take a tile's nodes out of the scene.
  void _dropBatches(_Tile t) {
    final root = _roots[t.bodyId];
    for (final n in t.batches) {
      root?.node.remove(n);
    }
    t.batches.clear();
    t.skylineTris = 0;
    t.lodCounts = const {};
  }

  /// Forget a tile: its nodes, its place in the queue, its build.
  void _dropTile(_Tile t) {
    _dropBatches(t);
    _queue.remove(t);
    t.queued = false;
    t.job = null;
    t.builtKey = '';
  }

  /// One building into a tile's job: an instance of its archetype at its
  /// own tier, or a box in the tile's skyline.
  void _emitBuilding(
      _TileJob job, BuildingSnapshot b, Vector3 focusBF, BuildingDetail colonyTier) {
    final spec = specOf(b);
    final parcel = parcelOf(b);
    final seed = b.id.hashCode;
    // A tile beyond the near range is silhouettes whatever the building's
    // own distance says: nothing in it resolves past a box.
    final tier = job.tier == CityTier.near
        ? detailFor(b, focusBF, colonyTier)
        : BuildingDetail.block;
    job.lodCounts[tier] = (job.lodCounts[tier] ?? 0) + 1;
    // Block tier keys and meshes against the coarse library, so the
    // dominant tier shares far fewer archetypes (and draws).
    final lib = _libraryFor(tier);
    // The skyline: block-tier buildings are BAKED into one mesh per
    // material for the whole tile rather than instanced per archetype —
    // see [_upload]. The visualiser keeps the instanced path so its boxes
    // stay one per archetype.
    if (tier == BuildingDetail.block && !lodDebug) {
      final built = lib.get(spec, parcel, seed: seed, detail: tier);
      final m = instanceTransform(job.anchorBF, b);
      job.skylineSolid.append(built.model.solid, m);
      job.skylineGlazing.append(built.model.foliage, m);
      return;
    }
    // The style is part of the key here for the same reason it is part of
    // it inside the library: these two maps are looked up with keys built
    // independently, and a key that forgot the style would upload one
    // building's mesh and then serve it for a different kit's.
    final key = BuildingArchetype.of(spec, parcel,
        detail: tier,
        seed: seed,
        bucketM: lib.bucketM,
        variants: lib.variants,
        styleId: style.id,
        corner: b.corner);
    _uploaded.putIfAbsent(key, () {
      final built = lib.get(spec, parcel, seed: seed, detail: tier);
      if (lodDebug) {
        // The building's own massing, as one box. Same size, same place,
        // no detail — so what you are looking at is purely which tier each
        // building resolved to.
        final m = MeshBuilder();
        final fp = built.massing.footprint;
        final u = _lodSwatchU(tier);
        OrientedBox.emit(
          m,
          Vector3(0, 0, built.massing.height / 2),
          Vector3.unitX,
          Vector3.unitY,
          Vector3.unitZ,
          math.max(1.0, fp.width) / 2,
          math.max(1.0, fp.depth) / 2,
          math.max(1.0, built.massing.height) / 2,
          u: u,
          v: 0.5,
          // Metres: the instance transform carries the scene conversion.
          unitScale: 1.0,
        );
        return _CityMesh(_geometryOf(m.build()), null, lod: true);
      }
      return _CityMesh(
        _geometryOf(built.model.solid),
        _geometryOf(built.model.foliage),
      );
    });
    job.groups.putIfAbsent(key, () => []).add(instanceTransform(job.anchorBF, b));
  }

  /// How dark it is over the colony, from the frame's own sun.
  ///
  /// Uses the same ramp the colony sim lights its windows by — a second copy
  /// of the curve here would drift from the domain's the first time either was
  /// tuned.
  double _nightFactorAt(
    WorldSnapshot snap,
    Map<String, List<BuildingSnapshot>> byBody,
  ) {
    // The star is the light source. A frame carries no "is a star" flag on the
    // body itself (descriptors are sticky and often absent), so it is found by
    // being the biggest thing present — which on any real system it is, by
    // orders of magnitude.
    BodySnapshot? star;
    for (final b in snap.bodies.values) {
      if (star == null || b.radius > star.radius) star = b;
    }
    if (star == null) return 0;

    // Any point in the colony will do — this only needs a surface normal to
    // measure the sun against. A BUILDING is not guaranteed to exist: a colony
    // that has only been zoned carries patches and nothing else, and taking
    // `first` of that empty list threw straight out of the scene build, which
    // took down the entire frame rather than just the city.
    ({String bodyId, Vector3 posBF})? site;
    for (final entry in byBody.entries) {
      if (entry.value.isNotEmpty) {
        final b = entry.value.first;
        site = (bodyId: entry.key, posBF: Vector3(b.px, b.py, b.pz));
        break;
      }
    }
    site ??= () {
      for (final p in snap.patches) {
        return (bodyId: p.body, posBF: Vector3(p.px, p.py, p.pz));
      }
      for (final r in snap.roads) {
        if (r.points.length >= 3) {
          return (
            bodyId: r.body,
            posBF: Vector3(r.points[0], r.points[1], r.points[2]),
          );
        }
      }
      return null;
    }();
    if (site == null) return 0;

    final body = snap.bodies[site.bodyId];
    if (body == null) return 0;
    final bodyWorld = Vector3(body.px, body.py, body.pz);
    // The skyglow measures height off this same site: one pick decides both
    // how dark the colony is and where its ground shell sits.
    _glowBodyWorld = bodyWorld;
    _glowGroundRadiusM = site.posBF.length;
    _glowBodyQuat = Quaternion(body.qw, body.qx, body.qy, body.qz);
    final quat = Quaternion(body.qw, body.qx, body.qy, body.qz);
    final siteWorld = bodyWorld + quat.rotate(site.posBF);
    final up = quat.rotate(site.posBF).normalized;
    final toSun = (Vector3(star.px, star.py, star.pz) - siteWorld).normalized;
    return const CityLighting().nightFactor(
      up.x * toSun.x + up.y * toSun.y + up.z * toSun.z,
    );
  }

  /// Bake how much lit city surrounds each point of the colony, as a small
  /// texture the surface shader samples per fragment.
  ///
  /// Each building splats a soft disc — wider for a bigger site, hotter for
  /// a denser zone type — onto a 64-cell grid over the colony's extent, and
  /// the sum saturates as s/(s+1). One tower over open ground peaks around a
  /// quarter; a core block under the summed splats of all its neighbours
  /// rides near one. That ratio IS the fake GI's density term: bounced light
  /// is borrowed from the neighbours, and a lone building has none to
  /// borrow.
  void _bakeLightMap(List<BuildingSnapshot> buildings, Vector3 anchorBF) {
    const size = 64;
    final up = anchorBF.normalized;
    final seed = up.z.abs() < 0.9 ? Vector3.unitZ : Vector3.unitX;
    final east = up.cross(seed).normalized;
    final north = up.cross(east);

    // Extent from the buildings themselves, plus margin past the biggest
    // splat radius so the map's border stays dark and the clamp-sample
    // beyond the edge reads "empty country", not a smeared edge texel.
    var maxAbs = 60.0;
    final es = Float32List(buildings.length);
    final ns = Float32List(buildings.length);
    for (var i = 0; i < buildings.length; i++) {
      final b = buildings[i];
      final rel = Vector3(b.px, b.py, b.pz) - anchorBF;
      es[i] = rel.dot(east);
      ns[i] = rel.dot(north);
      final a = math.max(es[i].abs(), ns[i].abs());
      if (a > maxAbs) maxAbs = a;
    }
    final halfM = maxAbs + 120.0;
    final cellM = halfM * 2 / size;

    final grid = Float32List(size * size);
    for (var i = 0; i < buildings.length; i++) {
      final b = buildings[i];
      // A denser zone is more window per metre of street.
      final band = b.type.endsWith('-high')
          ? 2.4
          : (b.type.endsWith('-med') ? 1.2 : 0.6);
      final w = b.siteWidthM * b.siteDepthM / 700.0 * band;
      final rM = (math.max(b.siteWidthM, b.siteDepthM) * 1.6).clamp(18.0, 80.0);
      final cx = (es[i] + halfM) / cellM;
      final cy = (ns[i] + halfM) / cellM;
      final rC = rM / cellM;
      final x0 = math.max(0, (cx - rC).floor());
      final x1 = math.min(size - 1, (cx + rC).ceil());
      final y0 = math.max(0, (cy - rC).floor());
      final y1 = math.min(size - 1, (cy + rC).ceil());
      for (var y = y0; y <= y1; y++) {
        for (var x = x0; x <= x1; x++) {
          final dx = x - cx, dy = y - cy;
          final d2 = (dx * dx + dy * dy) / (rC * rC);
          if (d2 > 1) continue;
          grid[y * size + x] += w * (1.0 - d2);
        }
      }
    }

    final rgba = Uint8List(size * size * 4);
    for (var i = 0; i < grid.length; i++) {
      final v = grid[i] / (grid[i] + 1.0);
      final c = (v * 255).round().clamp(0, 255);
      rgba[i * 4] = c;
      rgba[i * 4 + 1] = c;
      rgba[i * 4 + 2] = c;
      rgba[i * 4 + 3] = 255;
    }
    CityMaterials.lightMap = CityTextures.uploadRgba(rgba, size);
    _glowAnchorBF = anchorBF;
    _glowEastBF = east;
    _glowNorthBF = north;
    _glowHalfExtentM = halfM;
  }

  /// Vehicles running the colony's roads.
  ///
  /// Rebuilt every frame, unlike the buildings: traffic MOVES, and the
  /// structural rebuild only fires when the colony's shape changes. Derived
  /// entirely from the frame — road polylines plus [WorldSnapshot.epoch] — the
  /// way street lamps and junctions already are, so there is no traffic state
  /// anywhere in the sim, nothing on the wire, and every client watching the
  /// same tick sees the same cars in the same places.
  ///
  /// COSMETIC. Nothing here routes, yields, or knows a signal exists; vehicles
  /// slide along their road and wrap. It is scenery, and the moment it stops
  /// being scenery it belongs in the tick instead.
  void _syncTraffic(WorldSnapshot snap, FloatingOrigin origin,
      Map<String, bool> moved, Vector3 focusWorld) {
    if (!traffic) {
      if (_trafficSlots.isNotEmpty) _dropTraffic();
      return;
    }
    for (final slot in _trafficSlots.values) {
      slot.touched = false;
    }

    // Every road that carries traffic, the plat's and the plan's alike:
    // one loop, one rule for what drives where. The plat's come off the
    // tiles within range, so a twenty-mile city costs the pass only the
    // roads the camera could see a car on.
    final byBody = <String, List<_TrafficRoad>>{};
    for (final t in _tiles.values) {
      if (t.distanceM > trafficRangeM) continue;
      for (final r in t.roads) {
        (byBody[r.body] ??= []).add(_TrafficRoad(
            r.points, r.roadClassIndex, r.halfWidthM, r.sealed, const []));
      }
    }
    for (final r in snap.sprawlRoads) {
      final kind = SprawlRoadKind
          .values[r.kind.clamp(0, SprawlRoadKind.values.length - 1)];
      // The plat draws and drives its own rights-of-way.
      if (kind == SprawlRoadKind.corridor) continue;
      // A piece that tapers is driven at its narrower width, so nothing
      // runs in the lane that is dropped along it.
      var narrow = r.halfWidthM;
      for (final w in [r.startHalfWidthM, r.endHalfWidthM]) {
        if (w != null && w < narrow) narrow = w;
      }
      (byBody[r.body] ??= []).add(_TrafficRoad(
          r.points, r.roadClassIndex, r.halfWidthM, false, r.overpasses,
          narrowHalfWidthM: narrow));
    }

    for (final entry in byBody.entries) {
      final body = snap.bodies[entry.key];
      if (body == null) continue;
      // Anchor on the first road point: traffic cannot use the structural
      // batches' anchors — but it must share their FRAME, which the body
      // transform below supplies.
      final first = entry.value.firstWhere((r) => r.points.length >= 3,
          orElse: () => entry.value.first);
      if (first.points.length < 3) continue;
      final anchorBF =
          Vector3(first.points[0], first.points[1], first.points[2]);
      final bodyWorld = Vector3(body.px, body.py, body.pz);
      final bodyQuat = Quaternion(body.qw, body.qx, body.qy, body.qz);
      // The focus in the body's frame, so the range gate is one subtraction
      // per road rather than a rotation per road.
      final focusBF = focusInBodyFrame(focusWorld, bodyWorld, bodyQuat);

      final byKind = <VehicleKind, List<vm.Matrix4>>{};
      final trainCars = <vm.Matrix4>[];
      // Ground railway segments, joined into lines and run below.
      final railSegments = <List<Vector3>>[];
      var placed = 0;

      for (final road in entry.value) {
        if (placed >= _maxVehicles) break;
        if (road.points.length < 6) continue;
        final cls = RoadClass
            .values[road.roadClassIndex.clamp(0, RoadClass.values.length - 1)];
        // Out of range: nothing to see. Rail is kept — a train is a long
        // thing on a long line, and the chains below want every segment.
        if (cls != RoadClass.rail) {
          final n = road.points.length;
          final a = Vector3(road.points[0], road.points[1], road.points[2]);
          final b = Vector3(
              road.points[n - 3], road.points[n - 2], road.points[n - 1]);
          final near = math.min((a - focusBF).length, (b - focusBF).length);
          if (near > trafficRangeM) continue;
        }
        final pts = <Vector3>[];
        for (var i = 0; i + 2 < road.points.length; i += 3) {
          pts.add(Vector3(road.points[i] - anchorBF.x,
              road.points[i + 1] - anchorBF.y, road.points[i + 2] - anchorBF.z));
        }
        if (pts.length < 2) continue;

        // Cumulative length, so a vehicle can be placed at a distance rather
        // than at a vertex — otherwise they would snap between samples.
        final cum = <double>[0];
        for (var i = 1; i < pts.length; i++) {
          cum.add(cum[i - 1] + (pts[i] - pts[i - 1]).length);
        }
        final total = cum.last;
        if (total < 30) continue;

        if (cls == RoadClass.rail) {
          railSegments.add(pts);
          continue;
        }
        // Elevated rail carries the L's train, not cars: one canonical car,
        // instanced at each pose, on the same convention as the road vehicles
        // (model +X across, +Y along, +Z up; vertices in scene units).
        if (!cls.carriesCars) {
          for (final car in ElevatedStructure.trainCarPoses(
            pts: pts,
            anchorBF: anchorBF,
            lengthM: total,
            epochS: snap.epoch,
            seed: road.points.length,
          )) {
            trainCars.add(vm.Matrix4.compose(
              vm.Vector3(lengthToScene(car.centre.x),
                  lengthToScene(car.centre.y), lengthToScene(car.centre.z)),
              quatToScene(Quaternion.fromBasis(car.side, car.along, car.up)),
              vm.Vector3.all(1.0),
            ));
          }
          continue;
        }

        // Metres of road per vehicle PER LANE, and speed, by class.
        //
        // Both were derived from `cls.index` arithmetic, which happened to
        // work while there were four classes and broke the moment there were
        // seven: the spacing divisor `110 - index*22` reached zero at the
        // elevated tier and went negative at rail. An enum's index is not a
        // quantity — writing the quantity down is both correct and readable.
        final (spacingM, speed) = switch (cls) {
          RoadClass.street => (110.0, 8.0),
          RoadClass.avenue => (120.0, 13.0),
          RoadClass.highway => (110.0, 22.0),
          RoadClass.elevated => (95.0, 24.0),
          RoadClass.alley => (200.0, 4.0),
          RoadClass.path => (150.0, 6.0),
          // Out of town: sparse and fast.
          RoadClass.trunk => (140.0, 30.0),
          RoadClass.expressway4 => (90.0, 31.0),
          RoadClass.expressway6 => (95.0, 31.0),
          RoadClass.expressway8 => (100.0, 31.0),
          RoadClass.ramp => (160.0, 14.0),
          RoadClass.transit || RoadClass.rail => (0.0, 0.0),
        };
        if (spacingM <= 0) continue;
        final perLane = (total / spacingM * trafficDensity).floor();
        if (perLane <= 0) continue;
        final family =
            road.sealed ? VehicleKind.airless : VehicleKind.road;
        final seed = road.points.length * 2654435761 + entry.key.hashCode;
        // Where the lanes are. A road with no layout — there is none — gets
        // one stream each way, half way out to the curb.
        final layout = cls.lanes;
        final laneScale = layout == null ? 1.0 : road.halfWidthM / layout.halfWidthM;
        // Only the lanes that run the piece's whole length.
        final drivable = road.narrowHalfWidthM - (layout?.shoulderM ?? 0) * laneScale;
        final laneOffsets = [
          for (final o in layout?.laneOffsets ?? [road.halfWidthM * 0.5])
            if (o.abs() * laneScale + 1.0 <= drivable) o
        ];
        final ranges = <(double, double)>[
          for (var i = 0; i + 1 < road.overpasses.length; i += 2)
            (road.overpasses[i], road.overpasses[i + 1]),
        ];
        final oneWay = layout?.oneWay ?? false;

        var stream = 0;
        for (var dirIndex = 0; dirIndex < (oneWay ? 1 : 2); dirIndex++) {
          final dirSign = dirIndex == 0 ? 1.0 : -1.0;
          for (final laneOffset in laneOffsets) {
            final lane = stream++;
            for (var i = 0; i < perLane && placed < _maxVehicles; i++) {
              final h = _hash(seed + lane * 7919 + i * 104729);
              final kind = family[h % family.length];
              // Longer vehicles need more room; spacing them by their own
              // length keeps a semi from sitting inside the car behind it.
              final phase = (h >> 8 & 0xFFFF) / 65536.0;
              var d = (cum.last * (i + phase) / perLane +
                      dirSign * snap.epoch * speed) %
                  total;
              if (d < 0) d += total;
              final at = _alongPolyline(pts, cum, d);
              if (at == null) continue;
              final fwd = at.$2 * dirSign;
              final up = (at.$1 + anchorBF).normalized;
              final side = fwd.cross(up).normalized;
              // In its lane, to the right of the centreline in its own
              // direction of travel — and on the DECK of an elevated road or
              // a bridge rather than the ground the columns stand on.
              final lift = cls.deckHeightM + RoadMesher.bridgeLiftAt(d, ranges);
              final offset = side * (laneOffset * laneScale) + up * lift;
              // Model space is +Y forward, +Z up, so the instance rotation is
              // the basis (side, forward, up) expressed as a quaternion.
              final rot = Quaternion.fromBasis(side, fwd, up);
              (byKind[kind] ??= []).add(vm.Matrix4.compose(
                vm.Vector3(
                    lengthToScene((at.$1 + offset).x),
                    lengthToScene((at.$1 + offset).y),
                    lengthToScene((at.$1 + offset).z)),
                quatToScene(rot),
                // UNIT scale: `VehicleMeshes.emit` already builds its
                // vertices in scene units, unlike the building library which
                // works in metres. Applying the metres-to-scene factor again
                // here made every vehicle a thousand times too small.
                vm.Vector3.all(1.0),
              ));
              placed++;
            }
          }
        }
      }

      // The railway's trains: a passenger shuttle calling at the stations
      // and a freight working calling at the yard, on every line long
      // enough to hold one; a short line with no stops is a siding, and a
      // freight rake stands on it.
      final railCars = <RailCarKind, List<vm.Matrix4>>{};
      if (railSegments.isNotEmpty) {
        final stops = <(String, Vector3)>[
          for (final b in snap.buildings.values)
            if (b.body == entry.key &&
                (b.type == 'station' || b.type == 'freightyard'))
              (b.type, Vector3(b.px, b.py, b.pz) - anchorBF),
        ];
        var line = 0;
        for (final chain in Railway.chains(railSegments)) {
          final cum = RailConsist.cumulative(chain);
          if (cum.last < 200) continue;
          final stationsM = <double>[];
          final yardsM = <double>[];
          for (final (type, at) in stops) {
            final n = RailConsist.nearestOn(chain, cum, at);
            if (n.offM > 160) continue;
            (type == 'station' ? stationsM : yardsM).add(n.alongM);
          }
          final phase = ((line++ * 977 + entry.key.hashCode) % 1000).toDouble();
          final siding = cum.last < 900 && stationsM.isEmpty && yardsM.isEmpty;
          final runs = siding
              ? [(RailConsist.freight, const <double>[], 0.0, false)]
              : [
                  (RailConsist.passenger, stationsM, phase, true),
                  (
                    RailConsist.freight,
                    yardsM,
                    phase + cum.last / RailConsist.freight.speedMs,
                    true
                  ),
                ];
          for (final (consist, stopsM, phaseS, moving) in runs) {
            for (final car in consist.posesAt(
              pts: chain,
              anchorBF: anchorBF,
              epochS: snap.epoch,
              stopsM: stopsM,
              phaseS: phaseS,
              moving: moving,
              parkedAtM: cum.last / 2 + consist.lengthM / 2,
            )) {
              (railCars[car.kind] ??= []).add(vm.Matrix4.compose(
                vm.Vector3(lengthToScene(car.centre.x),
                    lengthToScene(car.centre.y), lengthToScene(car.centre.z)),
                quatToScene(Quaternion.fromBasis(car.side, car.along, car.up)),
                vm.Vector3.all(1.0),
              ));
            }
          }
        }
      }

      // The anchor is written only when this body moved or the slot is new.
      final bodyMoved = moved[entry.key] ?? true;
      vm.Matrix4? anchor;
      void place(String key, fs.MeshGeometry? geometry, fs.Material material,
          List<vm.Matrix4> transforms) {
        if (geometry == null || transforms.isEmpty) return;
        // _maxVehicles is far under _maxPerDraw, so one draw per slot.
        final slot = _trafficSlots.putIfAbsent(key, () {
          final mesh = fs.InstancedMesh(geometry: geometry, material: material);
          final node = fs.Node()
            ..addComponent(fs.InstancedMeshComponent(mesh));
          _scene.add(node);
          return _TrafficSlot(node, mesh);
        });
        slot.touched = true;
        _setInstances(slot.mesh, transforms);
        if (!slot.placed || bodyMoved) {
          slot.node.localTransform =
              anchor ??= _anchorTransform(body, anchorBF, origin);
          slot.placed = true;
        }
        slot.node.visible = true;
      }

      byKind.forEach((kind, transforms) {
        final mesh = _vehicleMesh(kind);
        place('${entry.key}/${kind.name}/solid', mesh.solid,
            CityMaterials.facade, transforms);
        place('${entry.key}/${kind.name}/glazing', mesh.glazing,
            CityMaterials.glazing, transforms);
      });
      railCars.forEach((kind, transforms) {
        final mesh = _railCarMesh(kind);
        place('${entry.key}/rail/${kind.name}/solid', mesh.solid,
            CityMaterials.facade, transforms);
        place('${entry.key}/rail/${kind.name}/glazing', mesh.glazing,
            CityMaterials.glazing, transforms);
      });
      if (trainCars.isNotEmpty) {
        final car = _trainCar ??= () {
          final carBody = MeshBuilder();
          final carGlass = MeshBuilder();
          ElevatedStructure.emitTrainCar(carBody, carGlass);
          return _CityMesh(
              _geometryOf(carBody.build()), _geometryOf(carGlass.build()));
        }();
        place('${entry.key}/train/solid', car.solid, CityMaterials.facade,
            trainCars);
        place('${entry.key}/train/glazing', car.glazing,
            CityMaterials.glazing, trainCars);
      }
    }
    // A slot nothing used this frame — a kind that placed no vehicle, a body
    // out of the frame — hides rather than dies: it will be wanted again.
    for (final slot in _trafficSlots.values) {
      if (!slot.touched) slot.node.visible = false;
    }
  }

  /// Move [mesh]'s instances to [transforms] in place. A plain move only
  /// refits the BVH; instances are added or removed only when the count
  /// changes.
  static void _setInstances(
      fs.InstancedMesh mesh, List<vm.Matrix4> transforms) {
    if (mesh.instanceCount == transforms.length) {
      for (var i = 0; i < transforms.length; i++) {
        mesh.setInstanceTransform(i, transforms[i]);
      }
      return;
    }
    mesh.clearInstances();
    for (final t in transforms) {
      mesh.addInstance(t);
    }
  }

  void _dropTraffic() {
    for (final slot in _trafficSlots.values) {
      _scene.remove(slot.node);
    }
    _trafficSlots.clear();
  }

  /// Drop the nodes that keep MATERIAL instances across frames — traffic and
  /// the cursor — when the material cache is reset, or they would go on
  /// drawing with the old ones.
  void _dropResident() {
    _dropTraffic();
    final cursor = _cursorNode;
    if (cursor != null) {
      _scene.remove(cursor);
      _cursorNode = null;
      _cursorKey = null;
    }
  }

  /// Point and forward direction [d] metres along a polyline.
  static (Vector3, Vector3)? _alongPolyline(
      List<Vector3> pts, List<double> cum, double d) {
    for (var i = 1; i < pts.length; i++) {
      if (d > cum[i]) continue;
      final seg = pts[i] - pts[i - 1];
      final len = seg.length;
      if (len < 1e-6) continue;
      final t = ((d - cum[i - 1]) / len).clamp(0.0, 1.0);
      return (pts[i - 1] + seg * t, seg.normalized);
    }
    return null;
  }

  /// A cheap integer scramble, so two vehicles from adjacent indices do not
  /// come out the same model at the same offset.
  static int _hash(int x) {
    var h = x & 0x7FFFFFFF;
    h = (h ^ (h >> 15)) * 0x2C1B3C6D & 0x7FFFFFFF;
    h = (h ^ (h >> 12)) * 0x297A2D39 & 0x7FFFFFFF;
    return h ^ (h >> 15);
  }

  /// Draw (or clear) the editor's ground cursor.
  void _syncCursor(
      WorldSnapshot snap, FloatingOrigin origin, Map<String, bool> moved) {
    final route = pendingRouteBF;
    // The anchor: the cursor when there is one, else the route's first point —
    // a half-drawn road must stay visible while the mouse is off the map.
    final at = cursorBF ?? (route.length >= 2 ? route.first : null);
    final body = at == null ? null : snap.bodies[cursorBodyId];
    final existing = _cursorNode;
    if (at == null || body == null) {
      if (existing != null) {
        _scene.remove(existing);
        _cursorNode = null;
        _cursorKey = null;
      }
      return;
    }
    // Everything the cursor mesh is built from. Unchanged — the usual frame,
    // the mouse at rest — the node stays and at most its anchor moves.
    // Rebuilding it every frame removed and re-added a render item, which
    // is a whole-scene BVH rebuild for a square that had not moved.
    final key = (
      at,
      cursorBodyId,
      cursorSizeM,
      cursorDepthM,
      cursorBad,
      identityHashCode(heatBF),
      identityHashCode(heatKind),
      heatCellM,
      identityHashCode(route),
      pendingRouteBad,
      pendingWidthM,
    );
    if (existing != null && key == _cursorKey) {
      if (moved[cursorBodyId] ?? true) {
        existing.localTransform = _anchorTransform(body, at, origin);
      }
      return;
    }
    if (existing != null) {
      _scene.remove(existing);
      _cursorNode = null;
    }
    _cursorKey = key;

    final up = at.normalized;
    // A stable tangent frame: any vector not parallel to up will do, and the
    // cursor is a square, so its spin about the normal does not matter.
    final east = (up.cross(Vector3.unitZ).lengthSquared > 1e-9
            ? up.cross(Vector3.unitZ)
            : up.cross(Vector3.unitX))
        .normalized;
    final north = up.cross(east);
    final h = cursorSizeM / 2;
    final hd = cursorDepthM / 2;
    // Above every patch kind, so the cursor always reads on top of whatever it
    // is hovering over.
    final lift = up * 0.3;

    final m = MeshBuilder();
    const u = 5.5 / kGroundSwatches; // the cursor swatch

    // Heatmap first, so the cursor and the road ghost draw over it.
    if (heatBF.length == heatKind.length && heatCellM > 0) {
      final hc = heatCellM / 2;
      for (var i = 0; i < heatBF.length; i++) {
        // A gap between cells: an unbroken sheet reads as one slab of colour
        // rather than as a sampled field, and hides the ground it describes.
        final e = east * (hc * 0.86), n2 = north * (hc * 0.86);
        final o = heatBF[i] - at;
        final hu = switch (heatKind[i]) {
              0 => 7.5,
              1 => 8.5,
              _ => 6.5,
            } /
            kGroundSwatches;
        final q = [
          o - e - n2 + lift * 0.5,
          o + e - n2 + lift * 0.5,
          o + e + n2 + lift * 0.5,
          o - e + n2 + lift * 0.5,
        ];
        final qi = [for (final c in q) m.vertex(_scenePos(c), up, hu, 0.5)];
        m.quad(qi[0], qi[1], qi[2], qi[3]);
      }
    }
    if (cursorBF != null) {
      final corners = [
        east * -h + north * -hd + lift,
        east * h + north * -hd + lift,
        east * h + north * hd + lift,
        east * -h + north * hd + lift,
      ];
      // The blocked swatch is the one the bad road ghost already uses, so
      // "you cannot put that there" reads the same whatever tool is held.
      final cu = cursorBad ? 6.5 / kGroundSwatches : u;
      final idx = [
        for (final c in corners) m.vertex(_scenePos(c), up, cu, 0.5)
      ];
      m.quad(idx[0], idx[1], idx[2], idx[3]);
    }
    // Ghost ribbon for the road being drawn, relative to the cursor's anchor
    // frame (the cursor node is placed at [at]; route points are body-fixed,
    // so they are expressed relative to it here).
    if (route.length >= 2) {
      final ghostU = pendingRouteBad
          ? 6.5 / kGroundSwatches // refusal red
          : 5.5 / kGroundSwatches;
      final hw = pendingWidthM / 2;
      int? pl, pr;
      for (var i = 0; i < route.length; i++) {
        final p = route[i] - at;
        final upI = route[i].normalized;
        final ahead =
            i + 1 < route.length ? route[i + 1] - route[i] : route[i] - route[i - 1];
        if (ahead.length <= 1e-9) continue;
        final along = ahead.normalized;
        final side = along.cross(upI).normalized;
        final l = m.vertex(
            _scenePos(p + side * -hw + upI * 0.35), upI, ghostU, 0.5);
        final r = m.vertex(
            _scenePos(p + side * hw + upI * 0.35), upI, ghostU, 0.5);
        if (pl != null && pr != null) m.quad(pl, pr, r, l);
        pl = l;
        pr = r;
      }
    }

    final geometry = _geometryOf(m.build());
    if (geometry == null) return;
    final node = fs.Node(
      mesh: fs.Mesh.primitives(primitives: [
        fs.MeshPrimitive(geometry, CityMaterials.ground),
      ]),
    );
    node.localTransform = _anchorTransform(body, at, origin);
    _scene.add(node);
    _cursorNode = node;
  }

  /// Flat ground patches: roads, zoned lots, support decks.
  ///
  /// One mesh for all of them, coloured by a UV into the ground palette. The
  /// mesh format has no vertex-colour channel, and a material per colour would
  /// be five draws for what is a single sheet of ground.
  void _emitPatches(List<CityPatchSnapshot> patches, _TileJob job) {
    final m = job.patches;
    final anchorBF = job.anchorBF;
    for (final p in patches) {
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
          m.vertex(_scenePos(c[k]), up, uv[k].$1, uv[k].$2)
      ];
      m.quad(idx[0], idx[1], idx[2], idx[3]);
    }
  }

  /// Fences and shop signs, car parks and their cars, into a tile's job.
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
  void _emitLotFeatures(List<BuildingSnapshot> buildings, _TileJob job,
      Vector3 focusBF, BuildingDetail colonyTier) {
    final solid = job.featureSolid;
    final glow = job.featureGlow;
    final apron = job.featureApron;
    final cars = job.featureCars;
    final anchorBF = job.anchorBF;

    for (final b in buildings) {
      final tier = detailFor(b, focusBF, colonyTier);
      if (tier == BuildingDetail.block) continue;
      final edging = LotFeatures.edgingFor(b.type);
      final sign = LotFeatures.signFor(b.type);
      final spec = specOf(b);
      final parcel = parcelOf(b);
      // The massing the building was DRAWN from — the library's cached one,
      // canonical lot and variant and all — so the lot the paint goes on and
      // the door the path runs to are the ones in the mesh.
      final built =
          _libraryFor(tier).get(spec, parcel, seed: b.id.hashCode, detail: tier);
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
      if (lot != null && job.carBudget > 0) {
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
        job.carBudget -= LotFeatures.emitLot(
          apron, cars, glow, at, sideAxis, along, up, lot, massing.entrance,
          frontLineY: -depth / 2,
          rearLineY: depth / 2,
          // Where the lot IS, not where the style says it goes: an
          // installation's lot is out front whatever the kit.
          behind: lot.y > massing.entrance.$2,
          rearDoorY: rearWall.isFinite ? rearWall : lot.y - lot.depth / 2,
          occupancy: 0.25 + h * 0.6,
          airless: sealedWorld,
          maxCars: math.min(12, job.carBudget),
          detailed: tier == BuildingDetail.full,
        );
      }
    }
  }

  /// One road into a tile's builders, at the tile's tier.
  ///
  /// Far: the carriageway as a bare ribbon, the railway as track, the
  /// viaduct as structure. Mid: lanes painted, turning circles. Near: the
  /// pavements with their curbs, the lamps, the furniture, the tube on a
  /// sealed world, the cars at the curb.
  void _emitRoad(_RoadBuilders rb, RoadSnapshot road, CityTier tier,
      Vector3 anchorBF, _BodyRoot root) {
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
        for (final (at, next) in [(pts.first, pts[1]), (pts.last, pts[pts.length - 2])]) {
          final atBF = at + anchorBF;
          var free = true;
          for (final other in root.transitEnds) {
            if (!identical(other, atBF) && (other - atBF).length < 8.0 &&
                (other - atBF).length > 1e-6) {
              free = false;
              break;
            }
          }
          // The end's own entry is in the list too; a second entry within
          // 8 m that is not it means another piece ends here.
          var self = 0;
          for (final other in root.transitEnds) {
            if ((other - atBF).length < 8.0) self++;
          }
          if (self > 1) free = false;
          if (!free) continue;
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
      // whole city draws through, downtown and county line alike.
      RoadMesher.carriageway(rb.ribbon, pts, anchorBF, cls,
          halfWidthM: road.halfWidthM,
          paint: paint,
          solid: near ? rb.propSolid : null);
      if (road.soundWalls && cls.canHaveSoundWalls && paint) {
        RoadMesher.soundWalls(rb.propSolid, pts, anchorBF, road.halfWidthM,
            posts: near);
      }
    }
    // A street that ends where nothing else does ends in a turning
    // circle: a subdivision's cul-de-sac, or the edge of town. Not where
    // it meets the plan's highway — that junction is the plan's to draw.
    if (paint && cls == RoadClass.street) {
      for (final end in [pts.first, pts.last]) {
        final e = root.endHalf[_endKey(end + anchorBF)];
        if (e != null && e.$2 > 1) continue;
        if (root.planNodeKeys.contains(_endKey(end + anchorBF))) continue;
        RoadMesher.culDeSac(rb.ribbon, end, anchorBF, 11.0);
      }
    }
    if (!near) return;

    // How far a sidewalk stops before an end: past the junction plate
    // (r = widest * 1.45) and its zebra (5 m past the bar). Zero at an end
    // nothing else meets.
    double pullAt(Vector3 endPt) {
      final e = root.endHalf[_endKey(endPt + anchorBF)];
      return e == null || e.$2 <= 1 ? 0.0 : e.$1 * 1.45 + 5.5;
    }

    // Raised pavements with a curb face, on anything that has a pavement
    // to raise. Not on a sealed world — pedestrians there travel in the
    // tube, and an open sidewalk in vacuum is set dressing for nobody.
    final walked = paved && cls.hasPavement && !road.sealed;
    if (walked) {
      RoadMesher.sidewalks(rb.walkRibbon, pts, road.halfWidthM, 3.0, anchorBF,
          pullStart: pullAt(pts.first), pullEnd: pullAt(pts.last));
    }
    // Nobody lights a dirt track, and nobody lights an alley either.
    if (paved && cls.hasPavement) {
      RoadMesher.lamps(rb.lampSolid, rb.lampGlow, pts, anchorBF,
          road.halfWidthM, cls,
          liftM: walked ? _walkTopLiftM : 0.0);
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
        liftM: walked ? _walkTopLiftM : 0.0,
        // A RoadSnapshot carries no id — it is pure geometry on the wire —
        // so the seed comes from the geometry itself. Stable frame to frame
        // for a road that has not been redrawn, which is what keeps the
        // furniture from jittering about the pavement.
        seed: Object.hash(road.points.first, road.points[1],
            road.points.length, road.roadClassIndex),
        budget: rb.propBudget,
        treesOut: rb.treePits,
        shrubsOut: rb.shrubPits,
      );
    }
    // Vacuum outside: pedestrians travel in a pressurised tube, not on a
    // pavement. The glazing builder already exists for dome caps.
    if (paved && cls.hasPavement && onStreetParking && rb.curbCars > 0) {
      rb.curbCars -= _curbParkingFor(rb.curbSolid, rb.curbGlass, pts, road,
          anchorBF,
          budget: rb.curbCars);
    }
    if (road.sealed) {
      PedestrianTube.emit(rb.tubeSolid, rb.tubeGlass,
          pts: pts, halfWidthM: road.halfWidthM, anchorBF: anchorBF);
    }
  }

  /// The junctions whose crossings lie in the tile, from every road end
  /// that falls there — whichever tile the road itself belongs to.
  void _emitJunctions(_TileJob job, _Tile t, double epoch, _BodyRoot root) {
    if (job.tier == CityTier.far || t.ends.isEmpty) return;
    final ends = <RoadEnd>[
      for (final e in t.ends)
        RoadEnd(e.at - job.anchorBF, e.next - job.anchorBF, e.halfWidthM,
            e.roadClass,
            paved: e.paved, collector: e.collector),
    ];
    // Signal phase comes from sim time: deterministic, stateless, and the
    // same on every client looking at the same tick.
    RoadMesher.junctions(job.roads.ribbon, job.roads.lampSolid,
        job.roads.lampGlow, RoadMesher.junctionsFromEnds(ends), job.anchorBF,
        epoch,
        furniture: job.tier == CityTier.near);
  }

  /// Height a street tree is grown at. Real pollarded street stock runs
  /// 7-10 m; the wild broadleaf default is taller.
  static double streetTreeHeightM = 8.0;

  /// What grows in a planter: a shrub about knee-to-waist high over the rim.
  static double planterShrubHeightM = 0.7;

  /// Whether the scatter atlas is still uploading (see [_emitStreetFlora]).
  bool _floraPending = false;

  /// Street planting as INSTANCES of the scatter system's props — the same
  /// generators, LODs, bark and foliage atlas the wild ones use, so a street
  /// tree and a forest tree agree about what a tree is. Planted off the road
  /// polylines, static while a colony grows.
  void _emitStreetFlora(
    PropKind kind,
    double sizeM,
    List<(Vector3, double)> pits,
    Vector3 anchorBF,
    void Function(fs.Node) add,
  ) {
    // A plant stands in vacuum nowhere. The pits are still COLLECTED on a
    // sealed world so the furniture draw sequence stays identical either
    // way; they are simply not planted.
    if (pits.isEmpty || sealedWorld) return;
    final lib = ScatterPropLibrary.instance;
    if (!ScatterPropLibrary.texturesReady) {
      // First colony of a session races the atlas. Skip the planting this
      // build; update() rebuilds when the upload lands.
      unawaited(ScatterPropLibrary.loadTextures());
      _floraPending = true;
      return;
    }

    // Group per pre-grown variant, so a whole tile's planting is at most
    // four solid draws and four foliage draws per kind.
    final byVariant = <int, List<vm.Matrix4>>{};
    for (final (at, yaw) in pits) {
      // The pit is relative to the tile's anchor; the surface normal is
      // through the body-fixed point.
      final up = (at + anchorBF).normalized;
      // Local +Z (the axis every prop grows along) onto the surface normal,
      // then the pit's own spin about it.
      final axis = Vector3.unitZ.cross(up);
      final sin = axis.length;
      final tilt = sin < 1e-9
          ? (up.z >= 0
              ? Quaternion.identity
              : Quaternion.axisAngle(Vector3.unitX, math.pi))
          : Quaternion.axisAngle(axis, math.atan2(sin, up.z));
      final spin = Quaternion.axisAngle(Vector3.unitZ, yaw);
      final variant = (yaw * 1000).round() % ScatterPropLibrary.variantSeeds.length;
      byVariant.putIfAbsent(variant, () => []).add(vm.Matrix4.compose(
            vm.Vector3(
                lengthToScene(at.x), lengthToScene(at.y), lengthToScene(at.z)),
            quatToScene(tilt * spin),
            vm.Vector3.all(lengthToScene(1.0)),
          ));
    }

    byVariant.forEach((variant, transforms) {
      final prop = lib.get(kind,
          seed: ScatterPropLibrary.variantSeeds[variant], sizeM: sizeM);
      for (final (geometry, material) in [
        (prop.solidFor(PropLod.lod1), lib.barkMaterial),
        (prop.foliageFor(PropLod.lod1), lib.foliageMaterial),
      ]) {
        if (geometry == null) continue;
        final instanced =
            fs.InstancedMesh(geometry: geometry, material: material);
        for (final t in transforms) {
          instanced.addInstance(t);
        }
        add(fs.Node()..addComponent(fs.InstancedMeshComponent(instanced)));
      }
    });
  }

  /// Cars parked at the curb, nose to tail.
  ///
  /// Static, unlike the road traffic: these are part of the street's furniture
  /// rather than something moving through it, so they are built with the road
  /// mesh and not rebuilt every frame. Spacing leaves a real gap between
  /// bumpers — a solid line of touching cars reads as a wall.
  ///
  /// Returns how many it placed, so the caller can hold a budget.
  static int _curbParkingFor(
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
    final family =
        road.sealed ? VehicleKind.airless : VehicleKind.road;
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

  /// Which bodies moved against the floating origin since the last frame.
  ///
  /// Body pose and origin together are what every anchored node's transform
  /// is a function of, so a body whose pair is unchanged needs none of its
  /// nodes written. One answer per frame, shared by the roots, traffic and
  /// cursor passes; the pose cache advances here.
  Map<String, bool> _bodyMotion(WorldSnapshot snap, FloatingOrigin origin) {
    final moved = <String, bool>{};
    for (final entry in snap.bodies.entries) {
      final body = entry.value;
      final pose = (
        Vector3(body.px, body.py, body.pz),
        Quaternion(body.qw, body.qx, body.qy, body.qz),
        origin.focusWorld,
      );
      final last = _placedPose[entry.key];
      final same = last != null &&
          last.$1 == pose.$1 &&
          last.$2 == pose.$2 &&
          last.$3 == pose.$3;
      moved[entry.key] = !same;
      if (!same) _placedPose[entry.key] = pose;
    }
    return moved;
  }

  /// Body pose and floating origin each body's nodes were last placed at.
  final Map<String, (Vector3, Quaternion, Vector3)> _placedPose = {};

  /// The node transform for [anchorBF] on [body], this frame.
  static vm.Matrix4 _anchorTransform(
      BodySnapshot body, Vector3 anchorBF, FloatingOrigin origin) {
    final bodyWorld = Vector3(body.px, body.py, body.pz);
    final bodyQuat = Quaternion(body.qw, body.qx, body.qy, body.qz);
    return vm.Matrix4.compose(
      origin.worldToScene(bodyWorld + bodyQuat.rotate(anchorBF)),
      quatToScene(bodyQuat),
      vm.Vector3.all(1.0),
    );
  }

  /// Per-frame: put each body's root where the body currently is — on the
  /// bodies that moved, plus any root not yet placed since it was made.
  void _placeRoots(
      WorldSnapshot snap, FloatingOrigin origin, Map<String, bool> moved) {
    for (final root in _roots.values) {
      if (root.placed && !(moved[root.bodyId] ?? true)) continue;
      final body = snap.bodies[root.bodyId];
      if (body == null) continue;
      root.node.localTransform = _anchorTransform(body, root.anchorBF, origin);
      root.placed = true;
    }
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

  /// Detail tier for a building [d] metres from the camera.
  static BuildingDetail tierForDistance(double d) => d > blockRangeM
      ? BuildingDetail.block
      : (d > interiorRangeM ? BuildingDetail.exterior : BuildingDetail.full);

  /// The camera, expressed in a body's own rotating frame.
  ///
  /// A building's `px/py/pz` are BODY-FIXED metres — a few thousand from the
  /// planet's centre — while the camera is in world space, which for Earth is
  /// about 1.5e11 m from the origin. Subtracting one from the other is not a
  /// distance, it is the radius of the orbit, and every building in every
  /// colony duly resolved to the coarsest tier. Converting the camera down
  /// into the body frame is one inverse rotation per BODY, against one
  /// rotation per building the other way round.
  static Vector3 focusInBodyFrame(
    Vector3 focusWorld,
    Vector3 bodyWorld,
    Quaternion bodyRotation,
  ) =>
      bodyRotation.conjugate.rotate(focusWorld - bodyWorld);

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
  static BuildingDetail detailFor(
      BuildingSnapshot b, Vector3 focusBF, BuildingDetail colonyTier) {
    if (!perBuildingLod) return colonyTier;
    return tierForDistance((Vector3(b.px, b.py, b.pz) - focusBF).length);
  }

  /// Palette swatch a tier is painted with in [lodDebug].
  ///
  /// A heat ramp on the ground palette, which already exists and is already
  /// bound: red is the expensive tier, amber the middle, green the cheap one.
  /// Reusing the placement-heatmap swatches rather than growing the palette —
  /// its divisor has been got wrong twice, and this is a debug view.
  static double _lodSwatchU(BuildingDetail d) {
    final swatch = switch (d) {
      BuildingDetail.full => 6, // refusal red — the costly one
      BuildingDetail.exterior => 8, // heatmap amber
      BuildingDetail.block => 7, // site-ok green
    };
    return (swatch + 0.5) / kGroundSwatches;
  }

  /// The lot a building stands on, in its own frontage-aligned frame.
  static Parcel parcelOf(BuildingSnapshot b) {
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
      sideStreet:
          b.corner ? (Vec2(w / 2, 0), Vec2(w / 2, d)) : null,
    );
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

  /// Metres -> scene units.
  ///
  /// The scene renders in kilometres. Building INSTANCES get this through
  /// their transform's scale, but the patch, road, lamp and cursor meshes bake
  /// their vertices directly and carry an unscaled node transform — so without
  /// this they came out a thousand times life size, which is a colony wider
  /// than the moon it stands on.
  static Vector3 _scenePos(Vector3 metres) => metres * kRenderScale;

  /// Upload a built mesh, for callers outside this class (the studio's scale
  /// reference builds its own geometry and needs the same path).
  static fs.MeshGeometry? geometryOf(PropMesh mesh) => _geometryOf(mesh);

  static fs.MeshGeometry? _geometryOf(PropMesh mesh) {
    if (mesh.isEmpty) return null;
    return fs.MeshGeometry.fromArrays(
      positions: mesh.positions,
      normals: mesh.normals,
      texCoords: mesh.texCoords,
      indices: mesh.indices,
    );
  }

  /// Drop everything, and the keys with it — an emptied scene with a stale
  /// key would skip the bucketing that repopulates it.
  void _clear() {
    for (final t in _tiles.values) {
      _dropTile(t);
    }
    _tiles.clear();
    _queue.clear();
    for (final root in _roots.values) {
      _scene.remove(root.node);
    }
    _roots.clear();
    _byBody = {};
    _structureSig = '';
    _lastBuildings = null;
    _lastRoads = null;
    _lastPatches = null;
    _dropResident();
  }

  void dispose() {
    _clear();
    _uploaded.clear();
    _library.clear();
    _libraryCoarse.clear();
    if (debugLine.isNotEmpty) debugPrint('cityNodes disposed');
  }
}

/// A road as the traffic pass sees it: the plat's and the plan's alike.
class _TrafficRoad {
  const _TrafficRoad(this.points, this.roadClassIndex, this.halfWidthM,
      this.sealed, this.overpasses,
      {double? narrowHalfWidthM})
      : narrowHalfWidthM = narrowHalfWidthM ?? halfWidthM;
  final List<double> points;
  final int roadClassIndex;
  final double halfWidthM;
  final bool sealed;

  /// The narrowest the piece gets — its own width unless it tapers.
  final double narrowHalfWidthM;

  /// Flattened start,end pairs along the road that ride a bridge.
  final List<double> overpasses;
}

/// One resident traffic draw: its node and the instanced mesh it moves.
class _TrafficSlot {
  _TrafficSlot(this.node, this.mesh);
  final fs.Node node;
  final fs.InstancedMesh mesh;

  /// Used this frame.
  bool touched = false;

  /// Anchor written at least once.
  bool placed = false;
}

/// A colony's root on a body: the node every tile hangs from, and what the
/// road pass needs to know body-wide — which ends meet which, where the
/// plan's junctions are, where the L's pieces end.
class _BodyRoot {
  _BodyRoot(this.node, this.bodyId, this.anchorBF);
  final fs.Node node;
  final String bodyId;

  /// Where the root stands, body-fixed. Fixed for the root's life: every
  /// tile's offset is measured from it.
  final Vector3 anchorBF;
  bool placed = false;

  /// Widest half width and count of road ends at each quantised end point.
  final Map<int, (double, int)> endHalf = {};

  /// The plan's junctions, keyed like the ends.
  final Set<int> planNodeKeys = {};

  /// Every end of every piece of elevated rail, body-fixed.
  final List<Vector3> transitEnds = [];
}

/// A road end that falls in a tile: where, the point just inside it, and
/// what the road is. Body-fixed; the junction pass anchors it.
class _TileEnd {
  const _TileEnd(this.at, this.next, this.halfWidthM, this.roadClass,
      this.paved, this.collector);
  final Vector3 at, next;
  final double halfWidthM;
  final RoadClass roadClass;
  final bool paved, collector;
}

/// Everything of one colony within one cell of the body's frame.
class _Tile {
  _Tile(this.key, this.bodyId, this.centreBF, this.halfDiagonalM);
  final String key;
  final String bodyId;

  /// The cell's centre, body-fixed: the tile's anchor.
  final Vector3 centreBF;
  final double halfDiagonalM;
  final List<BuildingSnapshot> buildings = [];
  final List<RoadSnapshot> roads = [];
  final List<CityPatchSnapshot> patches = [];
  final List<_TileEnd> ends = [];

  /// The tile's nodes, children of the body's root.
  final List<fs.Node> batches = [];
  String structureKey = '';
  String builtKey = '';
  String wantKey = '';
  CityTier? wantTier;
  bool queued = false;
  double distanceM = double.infinity;
  int skylineTris = 0;
  Map<BuildingDetail, int> lodCounts = const {};
  _TileJob? job;
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

/// A tile build in progress: its builders, and the parts still to run.
class _TileJob {
  _TileJob(this.key, this.tier, this.anchorBF);
  final String key;
  final CityTier tier;
  final Vector3 anchorBF;

  /// The parts of the build, run one per call from the end.
  final List<void Function()> steps = [];
  final _RoadBuilders roads = _RoadBuilders();
  final MeshBuilder patches = MeshBuilder();
  final MeshBuilder featureSolid = MeshBuilder();
  final MeshBuilder featureGlow = MeshBuilder();
  final MeshBuilder featureApron = MeshBuilder();
  final MeshBuilder featureCars = MeshBuilder();
  int carBudget = CityNodes._maxParkedCars;
  final MergedMeshSink skylineSolid = MergedMeshSink();
  final MergedMeshSink skylineGlazing = MergedMeshSink();
  final Map<BuildingArchetype, List<vm.Matrix4>> groups = {};
  final Map<BuildingDetail, int> lodCounts = {};
}
