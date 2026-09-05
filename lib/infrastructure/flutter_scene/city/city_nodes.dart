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
///
/// The MESHING of a tile — its roads, junctions, buildings, patches and
/// lot furniture into geometry — is not done here. It is a pure function
/// of the frame (see `city_tile_mesher.dart`) and runs through a
/// [CityTileScheduler]: on worker isolates where there are any, inline in
/// budgeted steps where there are not. What stays on this thread is what
/// must: cutting the frame into tiles, deciding what each wants, uploading
/// what comes back, and swapping it into the scene.
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
import '../../../domain/terrain/terrain_lod.dart' show ViewCone;
import '../../../domain/architecture/architecture_style.dart';
import '../../../domain/architecture/city_lighting.dart';
import '../coord_convert.dart';
import '../graphics_quality.dart';
import 'city_materials.dart';
import 'city_tile_mesher.dart';
import 'city_tile_scheduler.dart';
import 'elevated_structure.dart';
import 'mesh_merge.dart';
import 'oriented_box.dart';
import 'rail_vehicles.dart';
import 'road_mesher.dart';
import 'vehicle_meshes.dart';
import 'city_textures.dart';
import 'city_traffic.dart';

// The tile vocabulary moved to the mesher with the meshing; everything
// that spoke it through this file still does.
export 'city_tile_mesher.dart'
    show CityTier, CityMaterialKind, kGroundSwatches, kLeafSwatch;

/// One generated archetype, uploaded.
class _CityMesh {
  _CityMesh(this.solid, this.glazing, {this.lod = false});
  final fs.MeshGeometry? solid;
  final fs.MeshGeometry? glazing;

  /// A LOD-debug box rather than a building: drawn on the palette material so
  /// its colour means something, not on the facade one.
  final bool lod;
}

/// The colony's tangent frame on its body: up through the root's anchor,
/// east and north across it, and the radius the anchor sits at.
///
/// One frame serves two things that must agree: the grid the colony is cut
/// into tiles by, and the light map's axes (see `_bakeLightMap`).
///
/// The tiles used to be cells of a cube grid in body-fixed metres. On a
/// curved surface that is the wrong shape: a colony's footprint drifts
/// across the grid's slabs — over forty kilometres the surface sags
/// 40²/(8·6371) ≈ 31 m, and the grid's axes are nowhere near the ground's
/// — so a third of the tiles were slivers holding a few buildings each,
/// and every sliver paid the tile's fixed draws. Two arc coordinates
/// across the tangent plane give one tile per footprint, and a point's
/// height above the ground plays no part in which.
class ColonyTangentBasis {
  ColonyTangentBasis.at(Vector3 anchorBF)
      : radiusM = anchorBF.length,
        up = anchorBF.normalized {
    // Any seed off the pole. The light map has always derived east this
    // way, and the tiles must use the same frame.
    final seed = up.z.abs() < 0.9 ? Vector3.unitZ : Vector3.unitX;
    east = up.cross(seed).normalized;
    north = up.cross(east);
  }

  /// The anchor's distance from the body's centre: the surface radius the
  /// arcs are measured on.
  final double radiusM;
  final Vector3 up;
  late final Vector3 east, north;

  /// Arc coordinates of [p] from the anchor, in metres of surface: east
  /// and north along the great circles through it.
  ///
  /// Measured on the DIRECTION of [p], not its position, so a rooftop and
  /// the street below it read the same — and as arc, not tangent-plane
  /// distance, so a cell [CityNodes.tileM] wide holds exactly that much
  /// ground along each axis rather than the little more the gnomonic
  /// projection's foreshortening would let in.
  (double, double) arcOf(Vector3 p) {
    final u = p.normalized;
    return (
      radiusM * math.asin(u.dot(east).clamp(-1.0, 1.0)),
      radiusM * math.asin(u.dot(north).clamp(-1.0, 1.0)),
    );
  }

  /// The grid cell [p] falls in, cells [tileM] of arc on a side.
  (int, int) cellOf(Vector3 p, double tileM) {
    final (e, n) = arcOf(p);
    return ((e / tileM).floor(), (n / tileM).floor());
  }

  /// The centre of cell ([ie], [iN]), on the surface at the anchor's
  /// radius. Exact along either axis and within a metre off it at any
  /// colony's size; the centre only anchors the tile and measures its
  /// distance, and the half diagonal covers the rest.
  Vector3 cellCentre(int ie, int iN, double tileM) {
    final ae = (ie + 0.5) * tileM / radiusM;
    final an = (iN + 0.5) * tileM / radiusM;
    final v = up + east * math.tan(ae) + north * math.tan(an);
    return v.normalized * radiusM;
  }
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

  /// Milliseconds of UI-thread building the frame will spend before
  /// deferring the rest of the queue: the uploads, and on a platform
  /// without workers the meshing steps too.
  static double buildBudgetMs = 9;

  /// Milliseconds of geometry UPLOAD a frame may start, within
  /// [buildBudgetMs]. One `MeshGeometry.fromArrays` runs per frame at most,
  /// and only when its estimated cost — the group's bytes at
  /// [uploadUsPerMB] — fits what is left of this. A near tile's facade
  /// group is megabytes, and creating its GPU buffers synchronously was
  /// the one spike left in a static frame once the meshing moved off.
  static double uploadBudgetMs = 2;

  /// Measured cost of `MeshGeometry.fromArrays`, microseconds per megabyte
  /// of vertex and index data: a running average over the uploads so far,
  /// seeded with a guess a first upload can plan against.
  static double uploadUsPerMB = 3000;

  /// Tile builds on workers at once. Two workers, two jobs each queued
  /// behind: enough to keep both busy across a frame's dispatch, few
  /// enough that a camera that moves on leaves little stale work behind.
  static int maxInFlight = 4;

  static String debugLine = '';

  /// View culling (see [ViewCone]): a tile outside the lens's view cone takes
  /// the tier BELOW the one its distance earns — near to mid, mid to far,
  /// never gone — so a turn refines from a coarser city rather than from
  /// nothing. On when the caller hands [update] a cone, which the scenes
  /// gate on `GraphicsQuality.terrainFrustumCull`, the same switch as the
  /// terrain. A tile's sphere is its half-diagonal plus [viewCullHeightM],
  /// the building-height allowance that keeps a tower on a tile just past
  /// the cone's edge in view.
  static double viewCullHeightM = 400;

  /// Hysteresis on the cone edge: a tile leaves the view only once it is
  /// this much further out than it had to be to enter. A tile rebuild is
  /// the price of a flip, so the edge must not flicker on a slow pan.
  static double viewCullHysteresisRad = 10 * math.pi / 180;

  /// Tiles stepped down by the view cull on the last [update].
  static int outOfViewTiles = 0;

  /// The tier a tile gets from its distance tier and whether it is in view.
  static CityTier viewTier(CityTier byDistance, {required bool inView}) =>
      inView
          ? byDistance
          : (byDistance == CityTier.near ? CityTier.mid : CityTier.far);

  /// Hysteresis on the tier ranges: a tile enters a tier below its range
  /// and leaves it only this much further out. A tier flip is a whole tile
  /// rebuilt, so a camera settling on the boundary must not flip it twice
  /// a second.
  static double tierHysteresis = 1.15;

  /// The tier a tile earns from its distance, given the tier it had.
  ///
  /// Inside [nearRangeM] a tile is near, inside [midRangeM] mid, else far —
  /// except that a tile already at a tier keeps it until it is
  /// [tierHysteresis] times further out than the range that let it in. A
  /// tile never tiered ([previous] null) takes the plain answer.
  static CityTier tierAtDistance(double distanceM, {CityTier? previous}) {
    final h = tierHysteresis;
    if (distanceM < nearRangeM ||
        (previous == CityTier.near && distanceM < nearRangeM * h)) {
      return CityTier.near;
    }
    // A tile at near or mid is inside mid's leave band either way: leaving
    // near lands in mid, and mid is not left for far until its own edge.
    final inMid = previous == CityTier.near || previous == CityTier.mid;
    if (distanceM < midRangeM || (inMid && distanceM < midRangeM * h)) {
      return CityTier.mid;
    }
    return CityTier.far;
  }

  /// Whether ANY building in a tile can resolve past its block silhouette.
  ///
  /// [tileDistanceM] is the least distance from the focus to any point of
  /// the tile (see [_Tile.distanceM]), so with per-building LOD a tile past
  /// [blockRangeM] gets [BuildingDetail.block] from [detailFor] for every
  /// building in it — and its build then does not depend on where the
  /// camera is. The near tier's build key used to carry the camera
  /// regardless, so at orbit altitude every near tile was re-keyed on every
  /// frame of a drag and built towards an output identical to the one it
  /// had: twelve milliseconds a frame of work that never landed. Without
  /// per-building LOD the colony tier answers, and it is already in the
  /// key. The lot furniture is gated by the same answer: it skips every
  /// block-tier building, so a tile that cannot detail has none.
  ///
  /// Compared with `<=`, not `<`: [tierForDistance] keeps a building at
  /// exactly [blockRangeM] out of the block tier, and the least distance
  /// to the tile is a lower bound on every building's.
  ///
  /// The tile's bounding sphere is a loose bound from above: a two-mile
  /// cell's sphere reaches 2.8 km up, so an orbit camera 700 m over the
  /// colony sits INSIDE the sphere of the tile beneath it and the least
  /// distance reads zero — and that tile kept its camera term, re-keying on
  /// every turn of a drag. [focusRadiusM] and [tileMaxRadiusM] add the bound
  /// from below: every building's centre lies within [tileMaxRadiusM] of
  /// the body centre, so no building is nearer the eye than the eye's
  /// height over that shell (|eye − b| ≥ |eye| − |b|). Both bounds must
  /// allow a refinement for the camera to enter the key.
  static bool tileCanDetail(
    CityTier tier,
    double tileDistanceM, {
    required BuildingDetail colonyTier,
    bool? perBuildingLod,
    double? blockRangeM,
    double? focusRadiusM,
    double? tileMaxRadiusM,
  }) {
    if (tier != CityTier.near) return false;
    if (!(perBuildingLod ?? CityNodes.perBuildingLod)) {
      return colonyTier != BuildingDetail.block;
    }
    final range = blockRangeM ?? CityNodes.blockRangeM;
    if (tileDistanceM > range) return false;
    if (focusRadiusM != null && tileMaxRadiusM != null) {
      return focusRadiusM - tileMaxRadiusM <= range;
    }
    return true;
  }

  /// Tiles nearer than this show their planter shrubs. Beyond it a shrub
  /// seventy centimetres high is under a pixel, and its instances are pure
  /// cost — repacked every pass, colour and shadow. A hidden node costs
  /// nothing per frame (the pre-pass hides its render item), so the
  /// planting is toggled on the tile's nodes rather than rebuilt.
  static double floraShrubRangeM = 400;

  /// Tiles nearer than this show their street trees; an eight-metre tree
  /// is a few pixels at a kilometre and a half.
  static double floraTreeRangeM = 1500;

  /// Hysteresis on the planting ranges: shown planting stays shown until
  /// it is this much further out, so a camera resting on the edge does not
  /// blink a whole tile's trees.
  static double floraHysteresis = 1.15;

  /// Whether a tile's planting of [kind] is shown at [distanceM] — the
  /// tile's least distance from the focus — given whether it is [shown]
  /// now. Anything but a shrub takes the tree range: only the two are
  /// planted (see [_emitStreetFlora]).
  static bool floraVisibleAt(PropKind kind, double distanceM,
      {required bool shown}) {
    final range = kind == PropKind.shrub ? floraShrubRangeM : floraTreeRangeM;
    return distanceM < (shown ? range * floraHysteresis : range);
  }

  /// Whether a tile's mesh on [material] at [tier] goes into the shadow
  /// map. The rule lives with the meshing ([CityTileMesher.castsShadowFor]),
  /// which groups a tile's geometry by it; this is the same answer for the
  /// instanced archetypes, which are grouped here.
  static bool castsShadowFor(CityTier tier, CityMaterialKind material,
          {bool elevated = false}) =>
      CityTileMesher.castsShadowFor(tier, material, elevated: elevated);

  /// Whether a tile's planting of [kind] casts: trees on near tiles only.
  /// A shrub's shadow is a smudge smaller than the shrub, which is itself
  /// only drawn inside [floraShrubRangeM].
  static bool floraCastsShadow(CityTier tier, PropKind kind) =>
      tier == CityTier.near && kind != PropKind.shrub;

  /// The upload's groups (see [CityTileMesher.uploadGroups]).
  static Map<(CityMaterialKind, bool), List<MeshBuilder>> uploadGroups(
    Iterable<(MeshBuilder, CityMaterialKind, bool)> sources,
    CityTier tier,
  ) =>
      CityTileMesher.uploadGroups(sources, tier);

  /// Every builder's mesh appended into [into] (see
  /// [CityTileMesher.mergeBuilders]).
  static MergedMeshSink mergeBuilders(Iterable<MeshBuilder> builders,
          {MergedMeshSink? into}) =>
      CityTileMesher.mergeBuilders(builders, into: into);

  /// The material handle for [kind], resolved NOW: the handles are lazy
  /// and the texture and shader loads reset them, so a step queued before
  /// a reset must not upload against the handle it replaced.
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

  /// Microseconds the last step of each kind took, by kind name. The build
  /// loop keeps it to decide whether the next step fits the frame; the
  /// panel may read it to see which kind is the expensive one.
  static final Map<String, int> stepCostUs = {};
  final Map<_StepKind, int> _stepCostUs = {};

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

  /// Hard ceiling on ROAD vehicles per frame. Every one is a matrix moved
  /// through the transient buffer each frame, which is the same budget the
  /// asteroid fields already have to respect. Gated by [trafficRangeM], so
  /// the count is spent where the camera is. Trains are not counted against
  /// it (see [CityTraffic.maxVehicles]).
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

  /// The traffic pass's tables and placement (see [CityTraffic]): what the
  /// slots above draw, worked out from the tiles within range.
  final CityTraffic _traffic = CityTraffic();

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

  /// The archetype libraries THIS thread generates from — full and coarse
  /// (see [CityBuildingLibraries]) — for the instanced buildings' meshes,
  /// which are uploaded here and cached in [_uploaded]. The workers hold
  /// their own, for the skyline they bake and the lot massing they read,
  /// built from the same knobs: a key a worker groups instances by is a
  /// key this library computes for the same building, or the instanced
  /// groups would come back under keys nothing here can mesh.
  final CityBuildingLibraries _libraries = CityBuildingLibraries();

  /// The knobs as the meshing reads them, as values: a worker isolate has
  /// its own copy of every static here, at its default, so a request
  /// carries what the build depends on instead (see [CityMeshKnobs]).
  static CityMeshKnobs _knobsNow() => CityMeshKnobs(
        styleId: style.id,
        bucketM: archetypeBucketM,
        variants: archetypeVariants,
        perBuildingLod: perBuildingLod,
        blockRangeM: blockRangeM,
        interiorRangeM: interiorRangeM,
        lodDebug: lodDebug,
        onStreetParking: onStreetParking,
        sealedWorld: sealedWorld,
        maxParkedCars: _maxParkedCars,
      );

  /// Rebuild the archetype libraries if their knobs moved. Everything already
  /// uploaded is keyed by the old quantisation, so it all has to go.
  void _syncLibrary() {
    if (!_libraries.sync(style.id, archetypeBucketM, archetypeVariants)) {
      return;
    }
    _uploaded.clear();
    invalidate();
  }

  /// Where the meshing runs (see [CityTileScheduler]): worker isolates
  /// where the platform has them, inline steps under the build budget
  /// where it does not.
  final CityTileScheduler _scheduler = CityTileScheduler.platform();

  /// Which build each tile is waiting on, so a result for a build the tile
  /// has since abandoned is dropped (see [PendingTileJobs]).
  final PendingTileJobs _pending = PendingTileJobs();

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

  /// The building whose footprint [bf] (body-fixed metres) lies on, or
  /// within [withinM] of — or null over bare ground.
  ///
  /// A picker's question, answered from the TILES rather than the sim: the
  /// sim's `siteAt` walks every parcel in the colony testing polygon
  /// containment, which on a 127k-building colony is most of a tenth of a
  /// second per click. The tiles already bucket every building by the cell
  /// its centre falls in, so the point's own cell and the ring around it
  /// (a footprint on a cell edge is bucketed by ONE of the cells it
  /// straddles) hold every candidate — a few hundred buildings, not a
  /// hundred thousand. Read-only: nothing here touches the build pipeline.
  BuildingSnapshot? buildingNearBF(String bodyId, Vector3 bf,
      {double withinM = 4}) {
    final root = _roots[bodyId];
    if (root == null) return null;
    final (ie, iN) = root.basis.cellOf(bf, tileM);
    Iterable<BuildingSnapshot> candidates() sync* {
      for (var de = -1; de <= 1; de++) {
        for (var dn = -1; dn <= 1; dn++) {
          final t = _tiles['$bodyId/${ie + de}/${iN + dn}'];
          if (t != null) yield* t.buildings;
        }
      }
    }

    return nearestFootprint(candidates(), bf, withinM: withinM);
  }

  /// Of [buildings], the one whose footprint [bf] is on or nearest to,
  /// within [withinM]; null when none is that close.
  ///
  /// The footprint is the snapshot's site rectangle centred on its position
  /// and turned by its orientation (local +X along the frontage, +Y into
  /// the lot, +Z up — the frame [instanceTransform] stands the building up
  /// in), so the test is a point-to-box distance in the building's own
  /// plane. Nearest FOOTPRINT wins, not nearest centre: a click on the
  /// corner of a warehouse is nearer the house next door's centre than the
  /// warehouse's, and it is the warehouse that was clicked. A coarse
  /// centre-distance bound skips most candidates before the rotation.
  static BuildingSnapshot? nearestFootprint(
      Iterable<BuildingSnapshot> buildings, Vector3 bf,
      {double withinM = 4}) {
    BuildingSnapshot? best;
    var bestDist = double.infinity;
    var bestCentre = double.infinity;
    for (final b in buildings) {
      final rel = bf - Vector3(b.px, b.py, b.pz);
      final centre = rel.length;
      // (w + d) / 2 bounds the half diagonal, so nothing this far from the
      // centre can be within reach of the rectangle.
      if (centre > (b.siteWidthM + b.siteDepthM) * 0.5 + withinM) continue;
      final local = Quaternion(b.qw, b.qx, b.qy, b.qz).conjugate.rotate(rel);
      final dx = math.max(0.0, local.x.abs() - b.siteWidthM * 0.5);
      final dy = math.max(0.0, local.y.abs() - b.siteDepthM * 0.5);
      final dist = math.sqrt(dx * dx + dy * dy);
      if (dist > withinM) continue;
      if (dist < bestDist || (dist == bestDist && centre < bestCentre)) {
        best = b;
        bestDist = dist;
        bestCentre = centre;
      }
    }
    return best;
  }

  /// Instances above this in one draw overflow the engine's per-frame transient
  /// block — the same 1 MiB / 16,384-mat4 ceiling the scatter batches hit.
  static const int _maxPerDraw = 14000;

  /// Curb reveal: how far the sidewalk stands above the carriageway. 150 mm
  /// is the real standard, and it is the "subtle elevation difference" that
  /// makes a street read as built rather than painted.
  static const double kCurbHeightM = RoadMesher.curbHeightM;

  void update(
    WorldSnapshot snap,
    FloatingOrigin origin, {
    required Vector3 focusWorld,
    // The lens's eye, for the view cull's apex; defaults to [focusWorld].
    // The flight view measures tier distances from the focus (the craft)
    // but culls from where the camera actually is.
    Vector3? eyeWorld,
    // The lens's view cone in WORLD axes; tiles outside it step down a tier
    // (see [viewTier]). Null = no view culling.
    ViewCone? viewCone,
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
    // The view cull's apex and cones per body, in that body's frame. Two
    // cones: a tile ENTERS the view inside the narrow one and LEAVES only
    // outside the wide one (see [viewCullHysteresisRad]).
    final eyeByBody = <String, Vector3>{};
    final conesByBody = <String, ({ViewCone enter, ViewCone leave})>{};
    for (final t in _tiles.values) {
      final body = snap.bodies[t.bodyId];
      if (body == null) continue;
      final bodyWorld = Vector3(body.px, body.py, body.pz);
      final bodyQuat = Quaternion(body.qw, body.qx, body.qy, body.qz);
      final focusBF = focusByBody[t.bodyId] ??=
          focusInBodyFrame(focusWorld, bodyWorld, bodyQuat);
      if (viewCone != null) {
        eyeByBody[t.bodyId] ??=
            focusInBodyFrame(eyeWorld ?? focusWorld, bodyWorld, bodyQuat);
        conesByBody[t.bodyId] ??= () {
          final fwdBF = bodyQuat.conjugate.rotate(viewCone.forward);
          return (
            enter: ViewCone(fwdBF, viewCone.halfAngle),
            leave: ViewCone(fwdBF, viewCone.halfAngle + viewCullHysteresisRad),
          );
        }();
      }
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

    // Each tile's tier from its distance (with hysteresis, see
    // [tierAtDistance]), and the key its build depends on: what is in it,
    // the tier, and — inside the near tier, where every building takes its
    // own detail from its own distance AND some building is close enough
    // to take more than a box (see [tileCanDetail]) — the camera, quantised
    // hard to 64 m, because rebuilding on every centimetre of travel would
    // cost far more than the LOD saves.
    var near = 0, mid = 0, far = 0, outOfView = 0;
    for (final t in _tiles.values) {
      final focusBF = focusByBody[t.bodyId];
      if (focusBF == null) continue;
      var tier = tierAtDistance(t.distanceM, previous: t.distanceTier);
      t.distanceTier = tier;
      // The tile's planting shown or hidden by the same distance, on the
      // nodes it already has: no key, no rebuild (see [floraVisibleAt]).
      _syncFlora(t);
      final cones = conesByBody[t.bodyId];
      if (cones != null) {
        final rel = t.centreBF - eyeByBody[t.bodyId]!;
        final radius = t.halfDiagonalM + viewCullHeightM;
        t.inView = t.inView
            ? cones.leave.containsSphere(rel, radius)
            : cones.enter.containsSphere(rel, radius);
        if (!t.inView) {
          outOfView++;
          switch (GraphicsQuality.cityOutOfView) {
            case CityOutOfView.stepDown:
              tier = viewTier(tier, inView: false);
            case CityOutOfView.far:
              tier = CityTier.far;
            case CityOutOfView.hidden:
              break; // the tier stands; the nodes leave the scene below
          }
        }
      } else {
        t.inView = true;
      }
      // Hidden: the built nodes come out of the scene and are KEPT, so a
      // return re-attaches them without a rebuild. The want key is frozen
      // while hidden — nothing is built behind the camera — so a tier that
      // moved meanwhile is caught by the compare on the way back in.
      final hide =
          !t.inView && GraphicsQuality.cityOutOfView == CityOutOfView.hidden;
      if (hide != t.hidden) {
        t.hidden = hide;
        _setAttached(t, !hide);
      }
      switch (tier) {
        case CityTier.near:
          near++;
        case CityTier.mid:
          mid++;
        case CityTier.far:
          far++;
      }
      final canDetail =
          tileCanDetail(tier, t.distanceM,
              colonyTier: colonyTier,
              focusRadiusM: focusBF.length,
              tileMaxRadiusM: t.maxRadiusM);
      final cam = perBuildingLod && canDetail
          ? '${(focusBF.x / 64).round()},${(focusBF.y / 64).round()},'
              '${(focusBF.z / 64).round()}'
          : '';
      final want = '${t.structureKey}|${tier.index}|$cam'
          '|${lodDebug ? 1 : 0}|${perBuildingLod ? 1 : 0}'
          '|${interiorRangeM.round()}|${blockRangeM.round()}'
          '|${colonyTier.index}|$_invalidation';
      if (!hide && t.wantKey != want) {
        t.wantKey = want;
        t.wantTier = tier;
        t.wantCanDetail = canDetail;
        if (!t.queued) {
          t.queued = true;
          _queue.add(t);
        }
      }
    }
    outOfViewTiles = outOfView;
    phaseMs['city.tier'] = sw.elapsedMicroseconds / 1000;
    sw.reset();

    // Build, nearest first, within the budget. Three parts, all on this
    // thread and all of them what the panel's "build" means: the tiles at
    // the head of the queue are SUBMITTED to the scheduler — their requests
    // cut from the frame, at most [maxInFlight] between submission and
    // swap; the scheduler is PUMPED, which on a platform without workers
    // is where the meshing steps run; and the tiles whose results have
    // landed run their UPLOAD steps — a geometry, a run of archetype
    // groups, the planting, the one swap into the scene — a part at a
    // time, so a near tile never takes the whole frame. The budget is
    // checked in microseconds — whole milliseconds between steps overshot
    // it by most of one — and against what a step of that KIND cost last
    // time, so a step that would not fit waits for the next frame; a
    // geometry upload is checked against its bytes at the measured rate
    // instead (see [uploadBudgetMs]). One step always runs, or a step
    // dearer than the whole budget would never run at all.
    var builtThisFrame = 0, stepsThisFrame = 0;
    if (_queue.isNotEmpty) {
      _queue.sort((a, b) => a.distanceM.compareTo(b.distanceM));
      final budgetUs = (buildBudgetMs * 1000).round();
      final uploadBudgetUs = math.min(budgetUs, (uploadBudgetMs * 1000).round());
      _submitQueued(snap, focusByBody, colonyTier);
      // The inline scheduler gets the budget less the upload's share, or
      // a platform without workers would mesh every frame and upload on
      // none: the meshing is always queued while a colony streams in.
      stepsThisFrame += _scheduler.pump(
          math.max(0, budgetUs - uploadBudgetUs - sw.elapsedMicroseconds),
          onStep: (kind, costUs) => stepCostUs[kind.name] = costUs);
      final uploadStartUs = sw.elapsedMicroseconds;
      var uploadSteps = 0, geometries = 0;
      while (sw.elapsedMicroseconds < budgetUs) {
        final t = _nextUploadable();
        if (t == null) break;
        final job = t.job!;
        final next = job.steps.last;
        if (uploadSteps > 0) {
          if (next.bytes > 0) {
            // A geometry: one a frame, and only one whose bytes fit what
            // is left of the upload budget at the rate measured so far.
            final estimateUs = next.bytes / (1024 * 1024) * uploadUsPerMB;
            final spentUs = sw.elapsedMicroseconds - uploadStartUs;
            if (geometries > 0 ||
                spentUs + estimateUs > uploadBudgetUs ||
                sw.elapsedMicroseconds + estimateUs > budgetUs) {
              break;
            }
          } else {
            final lastUs = _stepCostUs[next.kind];
            if (lastUs != null && sw.elapsedMicroseconds + lastUs > budgetUs) {
              break;
            }
          }
        }
        final startUs = sw.elapsedMicroseconds;
        job.steps.removeLast().run();
        final costUs = sw.elapsedMicroseconds - startUs;
        _stepCostUs[next.kind] = costUs;
        stepCostUs[next.kind.name] = costUs;
        stepsThisFrame++;
        uploadSteps++;
        if (next.bytes > 0) geometries++;
        if (job.steps.isEmpty) {
          // The swap was the last step: the tile shows this job now. A job
          // is never abandoned for a newer key — a tile one camera cell
          // stale is invisible, a tile that never finishes is not — so a
          // key that moved while it ran queues the tile again, behind the
          // rest. Hidden or not: the want key is frozen while hidden, so
          // this is the only compare that would catch it.
          t.builtKey = job.key;
          t.job = null;
          _queue.remove(t);
          t.queued = false;
          builtThisFrame++;
          if (t.builtKey != t.wantKey) {
            t.queued = true;
            _queue.add(t);
          }
        }
      }
    }
    phaseCount['steps'] = stepsThisFrame;
    phaseCount['inFlight'] = _scheduler.inFlight;
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
      if (t.hidden) continue;
      for (final n in t.batches) {
        if (n.visible) draws++;
      }
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
      r.transitEnds.clear();
    }
    sealedWorld = false;

    // The cell in the body root's tangent grid (see [ColonyTangentBasis]):
    // two arc coordinates across the colony, each cell [tileM] of ground
    // on a side. The root always exists by the time a tile is asked for —
    // every loop below makes it first.
    _Tile tileFor(String bodyId, Vector3 p) {
      final basis = _roots[bodyId]!.basis;
      final (ie, iN) = basis.cellOf(p, tileM);
      final key = '$bodyId/$ie/$iN';
      // The half diagonal stays the cube cell's, not the square's: it is
      // a LOWER bound on the distance to anything in the tile, it leaves
      // headroom for relief and towers standing off the cell's surface,
      // and the tier ranges were tuned against it.
      return _tiles.putIfAbsent(
          key,
          () => _Tile(key, bodyId, basis.cellCentre(ie, iN, tileM),
              tileM * math.sqrt(3) / 2));
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
      final t = tileFor(b.body, p);
      t.buildings.add(b);
      // The outermost building centre, for the altitude bound in
      // [tileCanDetail]. A centre, not a roof: the bound is on the distance
      // to the point [detailFor] measures, which is the centre.
      final r = p.length;
      if (r > t.maxRadiusM) t.maxRadiusM = r;
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
        tileFor(r.body, first).ends.add(CityTileEnd(
            first, second, r.halfWidthM, cls, cls.paved, r.collector));
        tileFor(r.body, last).ends.add(CityTileEnd(
            last, penult, r.halfWidthM, cls, cls.paved, r.collector));
      }
      if (cls == RoadClass.transit) {
        root.transitEnds.add(first);
        root.transitEnds.add(last);
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

  // ---- The build pipeline ---------------------------------------------------
  //
  // A tile's build is a JOB: submitted to the scheduler from its want key,
  // answered with a [CityTileResult] some frames later, uploaded a step at
  // a time, swapped in at once. A job runs to its end once started, on its
  // OWN key, tier and anchor: the build loop never trades it for the
  // tile's newer want key. It used to — and a near tile under a dragged
  // camera, re-keyed every frame, was thrown away every frame a few steps
  // in, so the frame paid for a build that never once landed ("queued 31,
  // built 0").

  /// Submit the queued tiles that have no job yet, nearest first, until
  /// [maxInFlight] are between submission and swap.
  ///
  /// Counted to the SWAP, not to the worker's answer: a result waiting on
  /// its upload holds megabytes, and the uploads go one geometry a frame
  /// (see [uploadBudgetMs]), so workers answering faster than the frame
  /// can upload would otherwise pile results up behind the queue — and a
  /// camera that moved on would find every one of them stale.
  void _submitQueued(WorldSnapshot snap, Map<String, Vector3> focusByBody,
      BuildingDetail colonyTier) {
    var open = _scheduler.inFlight;
    for (final t in _queue) {
      if (t.job != null && t.job!.result != null) open++;
    }
    phaseMs['city.submit'] = 0;
    if (open >= maxInFlight) return;
    final knobs = _knobsNow();
    var i = 0;
    // One tile a frame: the request is the tile's own snapshot objects,
    // and an isolate send deep-copies them on THIS thread — thirteen tiles
    // in one frame measured 214 ms. One near tile is a few ms; the budget
    // loop cannot slice a send, so the cap is the slice.
    var submitted = 0;
    final sendClock = Stopwatch()..start();
    while (i < _queue.length && open < maxInFlight && submitted < 1) {
      final t = _queue[i];
      if (t.job != null) {
        i++;
        continue;
      }
      final focusBF = focusByBody[t.bodyId];
      final root = _roots[t.bodyId];
      if (focusBF == null || root == null) {
        // No body in the frame, or no root on it: nothing to build
        // against. Off the queue; a key that moves re-queues it.
        _queue.removeAt(i);
        t.queued = false;
        continue;
      }
      _submit(t, snap, root, focusBF, colonyTier, knobs);
      open++;
      submitted++;
      i++;
    }
    phaseMs['city.submit'] = sendClock.elapsedMicroseconds / 1000;
  }

  /// Start a tile's build from its want key.
  void _submit(_Tile t, WorldSnapshot snap, _BodyRoot root, Vector3 focusBF,
      BuildingDetail colonyTier, CityMeshKnobs knobs) {
    final tier = t.wantTier ?? CityTier.far;
    final key = t.wantKey;
    final job = t.job = _TileJob(key, tier, t.centreBF, root.anchorBF);
    final request = _requestFor(t, snap, root, tier, key, focusBF,
        colonyTier, knobs);
    _pending.start(t.key, key);
    _scheduler.mesh(request).then(_onResult,
        onError: (Object e, StackTrace st) => _onFailure(t, job, e));
  }

  /// Everything the meshing reads, cut from the tile and the body's root
  /// (see [CityTileRequest]). The root's end table and transit-end list
  /// are colony-wide; only the entries this tile's own roads touch go.
  CityTileRequest _requestFor(
    _Tile t,
    WorldSnapshot snap,
    _BodyRoot root,
    CityTier tier,
    String key,
    Vector3 focusBF,
    BuildingDetail colonyTier,
    CityMeshKnobs knobs,
  ) {
    final roadEnds = <(double, int)?>[];
    final transitFrom = <Vector3>[];
    for (final r in t.roads) {
      final n = r.points.length ~/ 3;
      final first = Vector3(r.points[0], r.points[1], r.points[2]);
      final last = Vector3(
          r.points[3 * n - 3], r.points[3 * n - 2], r.points[3 * n - 1]);
      roadEnds.add(root.endHalf[_endKey(first)]);
      roadEnds.add(root.endHalf[_endKey(last)]);
      final cls = RoadClass
          .values[r.roadClassIndex.clamp(0, RoadClass.values.length - 1)];
      if (cls == RoadClass.transit) {
        transitFrom.add(first);
        transitFrom.add(last);
      }
    }
    // Every transit end on the body within the terminal test's reach (8 m)
    // of an end of one of this tile's transit roads — each entry ONCE,
    // whichever ends it is near, since the test counts entries.
    final transitEnds = <Vector3>[];
    if (transitFrom.isNotEmpty) {
      for (final other in root.transitEnds) {
        for (final at in transitFrom) {
          if ((other - at).length < 8.0) {
            transitEnds.add(other);
            break;
          }
        }
      }
    }
    return CityTileRequest(
      tileKey: t.key,
      key: key,
      tier: tier,
      // Only where some building can resolve past a box: the furniture
      // pass skips every block-tier lot, so a tile that cannot detail
      // would run its steps to emit nothing (see [tileCanDetail]).
      canDetail: lotFeatures && t.wantCanDetail,
      anchorBF: t.centreBF,
      buildings: t.buildings,
      roads: t.roads,
      patches: t.patches,
      ends: t.ends,
      roadEnds: roadEnds,
      transitEnds: transitEnds,
      focusBF: focusBF,
      colonyTier: colonyTier,
      epoch: snap.epoch,
      knobs: knobs,
    );
  }

  /// A result back from the scheduler: onto its tile's job as upload
  /// steps, or dropped if the tile has moved on (see [PendingTileJobs]).
  void _onResult(CityTileResult result) {
    final t = _tiles[result.tileKey];
    if (!_pending.accept(result) || t == null) return;
    final job = t.job;
    if (job == null || job.key != result.key || job.result != null) return;
    final root = _roots[t.bodyId];
    if (root == null) {
      // The root went while the job ran; the tile is still queued and
      // resubmits against whatever root the next frame has.
      t.job = null;
      return;
    }
    job.result = result;
    _addUploadSteps(t, job, root, result);
  }

  /// A build that threw. Off the queue rather than resubmitted, or a
  /// deterministic failure would loop forever; a key that moves re-queues
  /// the tile.
  void _onFailure(_Tile t, _TileJob job, Object error) {
    if (t.job != job) return;
    debugPrint('city: tile ${t.key} failed to mesh: $error');
    t.job = null;
    _pending.forget(t.key);
    _queue.remove(t);
    t.queued = false;
  }

  /// The nearest queued tile with upload steps to run, or null.
  _Tile? _nextUploadable() {
    for (final t in _queue) {
      final job = t.job;
      if (job != null && job.steps.isNotEmpty) return t;
    }
    return null;
  }

  /// The upload, as steps: each of the result's geometries onto the job's
  /// staging list — no scene mutation — the archetype groups in runs, the
  /// planting, then ONE swap that drops the tile's old nodes and attaches
  /// every staged one in the same frame.
  ///
  /// The upload was one indivisible step, and the largest: a downtown
  /// tile's two dozen builders, its skyline, its archetype groups and its
  /// planting in one go, however much of the budget was left. Staged a
  /// geometry at a time it fits between frames; swapped all at once the
  /// engine sees one structural change and rebuilds its BVH once, and no
  /// frame ever shows a tile half old and half new.
  ///
  /// The material handles are resolved when a step RUNS, not here (see
  /// [_materialOf]): they are lazy, and the texture and shader loads
  /// reset them.
  void _addUploadSteps(
      _Tile t, _TileJob j, _BodyRoot root, CityTileResult result) {
    // One step per merged group — each (material, casts-a-shadow) group is
    // ONE geometry and one draw — so the budget loop can stop between
    // them: a downtown tile's facade group is most of its triangles.
    for (final g in result.groups) {
      j.steps.add(_BuildStep(_StepKind.mesh, () {
        final sw = Stopwatch()..start();
        final geometry = fs.MeshGeometry.fromArrays(
          positions: g.positions,
          normals: g.normals,
          texCoords: g.texCoords,
          indices: g.indices,
        );
        _bookUpload(g.bytes, sw.elapsedMicroseconds);
        j.stage(fs.Node(
          mesh: fs.Mesh.primitives(
              primitives: [fs.MeshPrimitive(geometry, _materialOf(g.material))]),
        )..castsShadow = g.castsShadow);
      }, bytes: g.bytes));
    }
    // The instanced buildings, per archetype, in runs.
    final groups = result.instances;
    const perStep = 24;
    for (var i = 0; i < groups.length; i += perStep) {
      final from = i, to = math.min(i + perStep, groups.length);
      j.steps.add(_BuildStep(_StepKind.instances, () {
        for (var k = from; k < to; k++) {
          _stageGroup(j, groups[k]);
        }
      }));
    }
    // Street planting, instanced off the scatter props.
    j.steps.add(_BuildStep(
        _StepKind.flora,
        () => _emitStreetFlora(
            PropKind.broadleafTree, streetTreeHeightM, result.treePits, j)));
    j.steps.add(_BuildStep(
        _StepKind.flora,
        () => _emitStreetFlora(
            PropKind.shrub, planterShrubHeightM, result.shrubPits, j)));
    j.steps.add(_BuildStep(_StepKind.swap, () => _swap(t, j, root)));
    j.skylineTris = result.skylineTris;
    j.lodCounts = result.lodCounts;
    // The caller pops from the end.
    j.steps.setAll(0, j.steps.reversed.toList());
  }

  /// Bytes and microseconds of every geometry upload so far, for
  /// [uploadUsPerMB]: a byte-weighted average, so a run of tiny uploads
  /// with their fixed cost does not read as a slow rate and stall the
  /// big one behind them. Halved past a window so the rate follows the
  /// machine's current state rather than its history.
  static double _uploadBytes = 0, _uploadUs = 0;

  static void _bookUpload(int bytes, int us) {
    if (bytes <= 0) return;
    _uploadBytes += bytes;
    _uploadUs += us;
    const window = 64.0 * 1024 * 1024;
    if (_uploadBytes > window) {
      _uploadBytes /= 2;
      _uploadUs /= 2;
    }
    uploadUsPerMB = _uploadUs / (_uploadBytes / (1024 * 1024));
  }

  /// One archetype's instances onto the job's staging list.
  void _stageGroup(_TileJob j, CityInstanceGroup group) {
    final m = _uploaded.putIfAbsent(
        group.archetype, () => _meshArchetype(group.archetype, group.representative));
    final transforms = group.transforms;
    final count = group.count;
    // Walls take the stone material (concrete is closer to rock than
    // bark); glazing takes the foliage one, which is the alpha-capable
    // pass and is where the night lighting hooks in. The solid casts as a
    // facade does — a debug box stands in for the building it colours —
    // and the glazing never (see [castsShadowFor]).
    for (final (geometry, material, casts) in [
      (
        m.solid,
        m.lod ? CityMaterials.ground : CityMaterials.facade,
        castsShadowFor(j.tier, CityMaterialKind.facade),
      ),
      (m.glazing, CityMaterials.glazing, false),
    ]) {
      if (geometry == null) continue;
      for (var start = 0; start < count; start += _maxPerDraw) {
        final end = math.min(start + _maxPerDraw, count);
        final instanced =
            fs.InstancedMesh(geometry: geometry, material: material);
        for (var i = start; i < end; i++) {
          // A view over the packed transforms; the mesh copies the matrix.
          instanced.addInstance(vm.Matrix4.fromFloat32List(
              Float32List.sublistView(transforms, i * 16, i * 16 + 16)));
        }
        j.stage(fs.Node()
          ..addComponent(fs.InstancedMeshComponent(instanced))
          ..castsShadow = casts);
      }
    }
  }

  /// The mesh of an archetype this thread has not uploaded yet, generated
  /// from a building that keys to it. The library computes the key again
  /// from the same inputs the worker did (see [CityTileMesher.archetypeOf]),
  /// so the mesh it caches is the one every instance in the group shares.
  _CityMesh _meshArchetype(BuildingArchetype key, BuildingSnapshot b) {
    final tier = key.detail;
    final lib = _libraries.forTier(tier);
    final built =
        lib.get(specOf(b), parcelOf(b), seed: b.id.hashCode, detail: tier);
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
  }

  /// Swap a tile's nodes for the job's staged ones, all in one frame.
  void _swap(_Tile t, _TileJob job, _BodyRoot root) {
    // The old nodes only: the tile stays queued until the build loop pops
    // it — dropping it from the queue here left the loop's removeAt(0)
    // taking the NEXT tile, or throwing on an empty queue.
    _dropBatches(t);
    for (final node in job.staged) {
      // A build that lands while the tile is hidden stays off the scene;
      // _setAttached puts it in when the tile comes back into view.
      if (!t.hidden) root.node.add(node);
      t.batches.add(node);
    }
    job.staged.clear();
    t.flora
      ..clear()
      ..addAll(job.flora);
    job.flora.clear();
    // The planting shown or hidden by the tile's distance from THIS frame:
    // a new node is visible by default, and a far tile must not flash its
    // trees for the frame between its swap and the next visibility pass.
    _syncFlora(t, apply: true);
    t.skylineTris = job.skylineTris;
    t.lodCounts = job.lodCounts;
  }

  /// Show or hide a tile's planting by its distance (see [floraVisibleAt]),
  /// touching the nodes only when an answer changes — or all of them when
  /// [apply] is set, for nodes that have never been told.
  void _syncFlora(_Tile t, {bool apply = false}) {
    if (t.flora.isEmpty) return;
    var changed = apply;
    for (final kind in const [PropKind.broadleafTree, PropKind.shrub]) {
      final was = t.floraShown[kind] ?? false;
      final now = floraVisibleAt(kind, t.distanceM, shown: was);
      if (now != was) {
        t.floraShown[kind] = now;
        changed = true;
      }
    }
    if (!changed) return;
    for (final (node, kind) in t.flora) {
      node.visible = t.floraShown[kind] ?? false;
    }
  }

  /// Take a tile's nodes out of the scene (a hidden tile's are already out).
  void _dropBatches(_Tile t) {
    final root = _roots[t.bodyId];
    if (!t.hidden) {
      for (final n in t.batches) {
        root?.node.remove(n);
      }
    }
    t.batches.clear();
    t.flora.clear();
    t.skylineTris = 0;
    t.lodCounts = const {};
  }

  /// Put a tile's built nodes into the scene or take them out, keeping them
  /// either way — the [CityOutOfView.hidden] path.
  void _setAttached(_Tile t, bool attached) {
    final root = _roots[t.bodyId];
    if (root == null) return;
    for (final n in t.batches) {
      if (attached) {
        root.node.add(n);
      } else {
        root.node.remove(n);
      }
    }
  }

  /// Forget a tile: its nodes, its place in the queue, its build.
  void _dropTile(_Tile t) {
    _dropBatches(t);
    _queue.remove(t);
    t.queued = false;
    t.job = null;
    t.builtKey = '';
    // A build still on a worker answers into the void.
    _pending.forget(t.key);
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
    // The same frame the tiles are cut in (see [ColonyTangentBasis]).
    final basis = ColonyTangentBasis.at(anchorBF);
    final east = basis.east, north = basis.north;

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
  /// Placed every frame, unlike the buildings: traffic MOVES, and the
  /// structural rebuild only fires when the colony's shape changes. Derived
  /// entirely from the frame — road polylines plus [WorldSnapshot.epoch] — the
  /// way street lamps and junctions already are, so there is no traffic state
  /// anywhere in the sim, nothing on the wire, and every client watching the
  /// same tick sees the same cars in the same places.
  ///
  /// The tables the placement runs on — points, lengths, lanes, the rail
  /// chains, the station list — live in [_traffic], built once per tile
  /// structure and per structure change (see [CityTraffic]); this pass
  /// feeds it the tiles within range, in the frame's tile order, and moves
  /// the resident draws to what it placed.
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
    // roads the camera could see a car on. Traffic shares the structural
    // batches' FRAME — the body root's anchor, fixed for the root's life,
    // which is what lets the tables be built once.
    _traffic
      ..density = trafficDensity
      ..maxVehicles = _maxVehicles
      ..rangeM = trafficRangeM
      ..begin(_structureSig);
    for (final t in _tiles.values) {
      if (t.distanceM > trafficRangeM) continue;
      final root = _roots[t.bodyId];
      if (root == null) continue;
      _traffic.visitTile(t.key, t.structureKey, t.bodyId, t.roads, root.anchorBF);
    }
    for (final bodyId in _traffic.visitedBodies) {
      final body = snap.bodies[bodyId];
      if (body == null) continue;
      final bodyWorld = Vector3(body.px, body.py, body.pz);
      final bodyQuat = Quaternion(body.qw, body.qx, body.qy, body.qz);
      // The focus in the body's frame, so the range gate is one subtraction
      // per road rather than a rotation per road.
      final focusBF = focusInBodyFrame(focusWorld, bodyWorld, bodyQuat);
      final sink = _traffic.place(bodyId, snap.epoch, focusBF, snap.buildings);

      // The anchor is written only when this body moved or the slot is new.
      final bodyMoved = moved[bodyId] ?? true;
      vm.Matrix4? anchor;
      void place(String key, fs.MeshGeometry? geometry, fs.Material material,
          TrafficBuffer poses) {
        if (geometry == null || poses.count == 0) return;
        // _maxVehicles is far under _maxPerDraw, so one draw per slot.
        final slot = _trafficSlots.putIfAbsent(key, () {
          final mesh = fs.InstancedMesh(geometry: geometry, material: material);
          // Never frustum culled. These are a couple of dozen draws the
          // frame wants anyway — the range gate has already kept them to
          // the roads round the camera — and a culled node's bound is
          // refitted through the engine's BVH every time an instance
          // moves, which every one of these does, every frame. Off the
          // cull, moving the cars is a buffer write and nothing else.
          final node = fs.Node()
            ..addComponent(fs.InstancedMeshComponent(mesh))
            ..frustumCulled = false;
          _scene.add(node);
          return _TrafficSlot(node, mesh);
        });
        slot.touched = true;
        _setInstances(slot.mesh, poses);
        if (!slot.placed || bodyMoved) {
          slot.node.localTransform =
              anchor ??= _anchorTransform(body, sink.anchorBF, origin);
          slot.placed = true;
        }
        slot.node.visible = true;
      }

      sink.byKind.forEach((kind, poses) {
        final mesh = _vehicleMesh(kind);
        place('$bodyId/${kind.name}/solid', mesh.solid, CityMaterials.facade,
            poses);
        place('$bodyId/${kind.name}/glazing', mesh.glazing,
            CityMaterials.glazing, poses);
      });
      sink.railCars.forEach((kind, poses) {
        final mesh = _railCarMesh(kind);
        place('$bodyId/rail/${kind.name}/solid', mesh.solid,
            CityMaterials.facade, poses);
        place('$bodyId/rail/${kind.name}/glazing', mesh.glazing,
            CityMaterials.glazing, poses);
      });
      if (sink.trainCars.count > 0) {
        final car = _trainCar ??= () {
          final carBody = MeshBuilder();
          final carGlass = MeshBuilder();
          ElevatedStructure.emitTrainCar(carBody, carGlass);
          return _CityMesh(
              _geometryOf(carBody.build()), _geometryOf(carGlass.build()));
        }();
        place('$bodyId/train/solid', car.solid, CityMaterials.facade,
            sink.trainCars);
        place('$bodyId/train/glazing', car.glazing, CityMaterials.glazing,
            sink.trainCars);
      }
    }
    _traffic.end();
    // A slot nothing used this frame — a kind that placed no vehicle, a body
    // out of the frame — hides rather than dies: it will be wanted again.
    for (final slot in _trafficSlots.values) {
      if (!slot.touched) slot.node.visible = false;
    }
  }

  /// Move [mesh]'s instances to the live part of [poses] in place. The
  /// mesh copies each matrix, so the buffer's own matrices are rewritten
  /// next frame without touching it again; instances are added or removed
  /// only when the count changes.
  static void _setInstances(fs.InstancedMesh mesh, TrafficBuffer poses) {
    final n = poses.count;
    final m = poses.matrices;
    if (mesh.instanceCount == n) {
      for (var i = 0; i < n; i++) {
        mesh.setInstanceTransform(i, m[i]);
      }
      return;
    }
    mesh.clearInstances();
    for (var i = 0; i < n; i++) {
      mesh.addInstance(m[i]);
    }
  }

  /// Drop the traffic draws, and the tables behind them: the tables are
  /// cheap to rebuild and this runs on a structure reset, when they are
  /// stale anyway.
  void _dropTraffic() {
    for (final slot in _trafficSlots.values) {
      _scene.remove(slot.node);
    }
    _trafficSlots.clear();
    _traffic.drop();
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
  /// polylines, static while a colony grows. [pits] are the mesher's packed
  /// pits (see [CityTileResult.treePits]): four doubles each, the pit
  /// relative to the tile's anchor and its yaw.
  void _emitStreetFlora(
    PropKind kind,
    double sizeM,
    Float64List pits,
    _TileJob job,
  ) {
    final anchorBF = job.anchorBF;
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
    // four solid draws and four foliage draws per kind. Staged as planting
    // so the tile can show and hide it by distance without a rebuild (see
    // [floraVisibleAt]); trees on a near tile cast, shrubs never (see
    // [floraCastsShadow]).
    final casts = floraCastsShadow(job.tier, kind);
    final byVariant = <int, List<vm.Matrix4>>{};
    for (var i = 0; i + 3 < pits.length; i += 4) {
      final at = Vector3(pits[i], pits[i + 1], pits[i + 2]);
      final yaw = pits[i + 3];
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
        job.stageFlora(
            fs.Node()
              ..addComponent(fs.InstancedMeshComponent(instanced))
              ..castsShadow = casts,
            kind);
      }
    });
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

  /// Reconstruct enough of a spec for the massing rules from the wire fields
  /// (see [CityTileMesher.specOf], where the mapping lives with the meshing
  /// that reads it).
  static CityBuildingSpec specOf(BuildingSnapshot b) => CityTileMesher.specOf(b);

  /// Detail tier for a building [d] metres from the camera.
  static BuildingDetail tierForDistance(double d) => CityTileMesher
      .tierForDistance(d, blockRangeM: blockRangeM, interiorRangeM: interiorRangeM);

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

  /// The lot a building stands on, in its own frontage-aligned frame, under
  /// the active [style] (see [CityTileMesher.parcelOf]).
  static Parcel parcelOf(BuildingSnapshot b) =>
      CityTileMesher.parcelOf(b, style);

  /// Model transform for one building (see
  /// [CityTileMesher.instanceTransform]).
  static vm.Matrix4 instanceTransform(Vector3 anchorBF, BuildingSnapshot b) =>
      CityTileMesher.instanceTransform(anchorBF, b);

  /// Metres -> scene units (see [CityTileMesher.scenePos]); the cursor
  /// bakes its vertices directly, as the tile meshes do.
  static Vector3 _scenePos(Vector3 metres) => CityTileMesher.scenePos(metres);

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
    _libraries.clear();
    _scheduler.dispose();
    _pending.clear();
    if (debugLine.isNotEmpty) debugPrint('cityNodes disposed');
  }
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
  _BodyRoot(this.node, this.bodyId, this.anchorBF)
      : basis = ColonyTangentBasis.at(anchorBF);
  final fs.Node node;
  final String bodyId;

  /// Where the root stands, body-fixed. Fixed for the root's life: every
  /// tile's offset is measured from it.
  final Vector3 anchorBF;

  /// The tangent frame at the anchor the colony's tiles are cut in.
  final ColonyTangentBasis basis;
  bool placed = false;

  /// Widest half width and count of road ends at each quantised end point.
  final Map<int, (double, int)> endHalf = {};

  /// Every end of every piece of elevated rail, body-fixed.
  final List<Vector3> transitEnds = [];
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
  final List<CityTileEnd> ends = [];

  /// Body-centre distance of the outermost building centre in the tile
  /// (0 with no buildings): the shell the camera's altitude is measured
  /// over in [CityNodes.tileCanDetail].
  double maxRadiusM = 0;

  /// The tile's nodes, children of the body's root.
  final List<fs.Node> batches = [];

  /// The planting among [batches], by kind: shown or hidden by distance
  /// each update (see [CityNodes.floraVisibleAt]) without a rebuild.
  final List<(fs.Node, PropKind)> flora = [];

  /// Whether each kind of planting is shown now — the hysteresis state,
  /// kept across rebuilds so a rebuilt tile does not blink its trees.
  final Map<PropKind, bool> floraShown = {};
  String structureKey = '';
  String builtKey = '';
  String wantKey = '';
  CityTier? wantTier;

  /// Whether the wanted build can resolve any building past a box (see
  /// [CityNodes.tileCanDetail]); decided with [wantKey], so the job that
  /// builds it gates its lot furniture on the same answer the key carries.
  bool wantCanDetail = false;

  /// The tier the tile's distance earned it last update, before the view
  /// cull — the hysteresis in [CityNodes.tierAtDistance] needs it.
  CityTier? distanceTier;
  bool queued = false;

  /// The least distance from the focus to any point of the tile's bounding
  /// sphere: |centre − focus| less the half diagonal, floored at zero.
  double distanceM = double.infinity;

  /// Inside the lens's view cone as of the last update — with hysteresis,
  /// so the previous answer is part of the next (see [CityNodes.update]).
  bool inView = true;

  /// Nodes taken out of the scene but kept ([CityOutOfView.hidden]).
  bool hidden = false;
  int skylineTris = 0;
  Map<BuildingDetail, int> lodCounts = const {};
  _TileJob? job;
}

/// The kinds of UI-thread step a tile build is made of — the upload. The
/// build loop books the last cost of each kind and will not start one
/// that would not fit the frame's remaining budget (see [CityNodes.update]);
/// a [mesh] step is judged by its bytes instead. The meshing's own steps
/// are the scheduler's (see [CityMeshStepKind]).
enum _StepKind {
  // One merged group into geometry.
  mesh,
  // A run of archetype groups.
  instances,
  // The planting.
  flora,
  // The one swap into the scene.
  swap,
}

/// One part of a tile's upload. [bytes] is what a [_StepKind.mesh] step
/// moves to the GPU, for the byte-rate gate; zero for the rest.
class _BuildStep {
  const _BuildStep(this.kind, this.run, {this.bytes = 0});
  final _StepKind kind;
  final void Function() run;
  final int bytes;
}

/// A tile build in progress: the key it answers, the result once the
/// scheduler has one, and the upload steps still to run.
class _TileJob {
  _TileJob(this.key, this.tier, this.anchorBF, Vector3 rootAnchorBF)
      : local = vm.Matrix4.translation(vm.Vector3(
            lengthToScene(anchorBF.x - rootAnchorBF.x),
            lengthToScene(anchorBF.y - rootAnchorBF.y),
            lengthToScene(anchorBF.z - rootAnchorBF.z)));
  final String key;
  final CityTier tier;
  final Vector3 anchorBF;

  /// The tile's place under its body's root, fixed for the job's life.
  final vm.Matrix4 local;

  /// The meshing's answer, once it has landed; null while the job is on
  /// the scheduler. Set once.
  CityTileResult? result;

  /// The upload's parts, run one per call from the end, planned when
  /// [result] lands (see [CityNodes._addUploadSteps]).
  final List<_BuildStep> steps = [];

  /// Nodes built and placed but not yet in the scene: the swap step adds
  /// them all in one frame.
  final List<fs.Node> staged = [];
  int skylineTris = 0;
  Map<BuildingDetail, int> lodCounts = const {};

  void stage(fs.Node node) {
    node.localTransform = local;
    staged.add(node);
  }

  /// The planting, staged like any node and remembered with its kind, so
  /// the tile can show and hide it by distance (see [_Tile.flora]).
  final List<(fs.Node, PropKind)> flora = [];

  void stageFlora(fs.Node node, PropKind kind) {
    stage(node);
    flora.add((node, kind));
  }
}

