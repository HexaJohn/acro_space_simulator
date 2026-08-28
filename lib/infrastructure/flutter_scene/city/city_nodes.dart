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
import '../../../domain/architecture/building_massing.dart';
import 'elevated_structure.dart';
import 'lot_features.dart';
import 'oriented_box.dart';
import 'pedestrian_tube.dart';
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
const int kGroundSwatches = 9;

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

  /// Distance at which buildings drop to their block silhouette.
  /// Draw every building as a plain box coloured by the detail tier it was
  /// actually generated at, instead of as the building.
  ///
  /// A LOD problem is invisible in a normal view: a city drawn entirely at
  /// full detail looks exactly like a city drawn sensibly, it just costs ten
  /// times as much. Painting the tier is the only way to SEE which buildings
  /// are expensive — and the first thing it showed was that they all were.
  static bool lodDebug = false;

  /// Pick each building's tier from ITS OWN distance rather than one tier for
  /// the whole colony. See [_detailFor].
  static bool perBuildingLod = true;

  /// Buildings resolved to each tier last frame, for the panel.
  static final Map<BuildingDetail, int> lodCounts = {};

  /// Distance past which a building is only its block silhouette.
  static double blockRangeM = 300;

  /// Distance inside which interiors are generated.
  static double interiorRangeM = 50;

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

  /// Ceiling on parked cars per colony. They are static geometry, unlike road
  /// traffic, but a thousand lots each with a full car park is still a lot of
  /// triangles for something nobody counts.
  static const int _maxParkedCars = 400;

  /// Scales how many vehicles a road carries. A hook for the colony's own
  /// congestion once that reaches the frame; 1.0 is an ordinary working day.
  static double trafficDensity = 1.0;

  /// Hard ceiling on vehicles per frame. The whole set is rebuilt every frame
  /// and pushed through the transient buffer, which is the same budget the
  /// asteroid fields already have to respect.
  static const int _maxVehicles = 220;

  final List<fs.Node> _trafficNodes = [];

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
  /// each structural rebuild. The map itself lives in [CityMaterials].
  Vector3 _glowAnchorBF = Vector3.zero;
  Vector3 _glowEastBF = const Vector3(1, 0, 0);
  Vector3 _glowNorthBF = const Vector3(0, 1, 0);
  double _glowHalfExtentM = 1;

  /// Cursor node, rebuilt every frame it is visible. One quad — cheap enough
  /// that tracking the mouse never touches the city's cached batches, which is
  /// the whole point of keeping it separate from them.
  fs.Node? _cursorNode;

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
    _builtKey = ''; // forces the structural rebuild on the next frame
  }
  final Map<BuildingArchetype, _CityMesh> _uploaded = {};

  /// Which visualiser state the meshes in [_uploaded] were built in.
  bool? _uploadedLodDebug;

  /// Drop the mesh cache when [lodDebug] is toggled.
  ///
  /// [_uploaded] is keyed by [BuildingArchetype] — type, size bucket, detail
  /// tier, variant, style, corner — and NOTHING in that key says whether the
  /// entry is a real building or a debug box. The rebuild key does carry
  /// `lodDebug`, so flipping the toggle rebuilds the scene; but the rebuild
  /// fills its batches with `putIfAbsent`, which hands back whatever is
  /// already cached for that archetype. Only archetypes never meshed BEFORE
  /// the toggle actually got a box.
  ///
  /// Which is why the middle tier appeared to be missing. The studio frames a
  /// colony from `max(600, extent * 1.5)` metres — the exterior tier, so
  /// exactly the archetypes already cached as real buildings at the moment
  /// the toggle was flipped. Fly in and `full` is a new archetype, so red
  /// boxes appear; fly out and `block` is new, so green ones do; the middle
  /// tier stayed real geometry and amber never showed at all. The tiers were
  /// right the whole time — `lodCounts` was already reporting them — it was
  /// the picture that was stale.
  ///
  /// It ran the other way too: turning the visualiser OFF left boxes cached
  /// for whichever tiers had built one, so the city kept rendering them.
  void _syncLodDebug() {
    if (_uploadedLodDebug == lodDebug) return;
    _uploadedLodDebug = lodDebug;
    _uploaded.clear();
  }

  /// Batches, each pinned to a body-fixed anchor. Instance transforms are
  /// stored RELATIVE to that anchor and never touched again; only the node's
  /// own matrix moves per frame. That is what lets a spinning planet carry a
  /// city without re-uploading a single buffer — and it is the same anchoring
  /// the scatter batches use, for the same reason.
  final List<_CityBatch> _batches = [];

  /// The road pass's batches — ribbons, junctions, lamps, pavement props,
  /// tubes, curb parking — kept apart from [_batches] because they age
  /// differently. Roads are the EXPENSIVE emit and the stable one: while a
  /// colony is being generated the road network is finished before the first
  /// building lands, yet every preview frame the studio captured changed the
  /// building count, moved the rebuild key, and re-tessellated every junction
  /// and lamp in town to draw one more house — 2.8 s a frame, nearly all of
  /// it roads that had not changed.
  final List<_CityBatch> _roadBatches = [];

  /// What the last rebuild was keyed on, so a static colony costs nothing.
  String _builtKey = '';

  /// Same, for the road pass alone.
  String _roadsBuiltKey = '';

  /// Force the next frame to rebuild the colony's structural geometry.
  ///
  /// The structural passes are keyed on what the COLONY looks like, which is
  /// right — a static city should not be re-meshed sixty times a second — but
  /// it means a renderer-side switch (street furniture, say) changes nothing
  /// until something in the city does. The studio's toggles need this or they
  /// appear to be dead.
  void invalidate() {
    _builtKey = '';
    _roadsBuiltKey = '';
  }

  int _drawCalls = 0;
  int _roadDrawCalls = 0;

  /// Instances above this in one draw overflow the engine's per-frame transient
  /// block — the same 1 MiB / 16,384-mat4 ceiling the scatter batches hit.
  static const int _maxPerDraw = 14000;

  /// Curb reveal: how far the sidewalk stands above the carriageway. 150 mm
  /// is the real standard, and it is the "subtle elevation difference" that
  /// makes a street read as built rather than painted.
  static const double kCurbHeightM = 0.15;

  /// The carriageway ribbon's own lift over the graded ground ([_ribbonFor]).
  static const double _ribbonLiftM = 0.12;

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
      if (_batches.isNotEmpty) _clear();
      debugLine = 'city: frame carries none '
          '(b=${snap.buildings.length} r=${snap.roads.length} '
          'p=${snap.patches.length})';
      // The cursor still draws over bare ground: pointing at an empty site is
      // exactly when the player most needs to see where a building would go.
      _syncCursor(snap, origin);
      return;
    }

    // Group by body so each colony can use its own body transform. Patches
    // count too: a colony that has been zoned but not yet built is exactly the
    // case that used to render as nothing at all.
    final byBody = <String, List<BuildingSnapshot>>{};
    for (final b in snap.buildings.values) {
      byBody.putIfAbsent(b.body, () => []).add(b);
    }
    for (final p in snap.patches) {
      byBody.putIfAbsent(p.body, () => []);
    }

    // Range gate off the nearest colony, and pick the colony-wide fallback
    // tier from it. Individual buildings then take their own tier from their
    // own distance — see [detailFor].
    var nearest = double.infinity;
    // Camera position per body, quantised, for the rebuild key.
    //
    // BODY-FIXED, not world. A world position is useless as a change detector
    // here: Earth carries everything on it round the sun at 30 km/s, so a
    // camera standing perfectly still on the ground moves half a kilometre of
    // world space between frames and a 64 m quantisation would rebuild the
    // whole colony every single frame. In the body's own frame a stationary
    // observer is stationary.
    final camKeyParts = <String>[];
    for (final entry in byBody.entries) {
      final body = snap.bodies[entry.key];
      if (body == null) continue;
      final bodyWorld = Vector3(body.px, body.py, body.pz);
      final quat = Quaternion(body.qw, body.qx, body.qy, body.qz);
      if (perBuildingLod) {
        final f = focusInBodyFrame(focusWorld, bodyWorld, quat);
        camKeyParts.add('${(f.x / 64).round()},${(f.y / 64).round()},'
            '${(f.z / 64).round()}');
      }
      for (final b in entry.value) {
        final world = bodyWorld + quat.rotate(Vector3(b.px, b.py, b.pz));
        final d = (world - focusWorld).length;
        if (d < nearest) nearest = d;
      }
      for (final p in snap.patches) {
        if (p.body != entry.key) continue;
        final world = bodyWorld + quat.rotate(Vector3(p.px, p.py, p.pz));
        final d = (world - focusWorld).length;
        if (d < nearest) nearest = d;
      }
    }
    if (nearest > maxRangeM) {
      if (_batches.isNotEmpty) _clear();
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
    }
    // Same race for the scatter atlas: a road pass built before it landed
    // skipped its street trees, so re-key that pass once the upload lands.
    if (_floraPending && ScatterPropLibrary.texturesReady) {
      _floraPending = false;
      _roadsBuiltKey = '';
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
    }
    CityMaterials.nightFactor = _nightFactorAt(snap, byBody);
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

    // The colony-wide fallback tier, off the NEAREST building. Kept for the
    // whole-colony path and as the coarse gate; see [_detailFor] for why one
    // tier for a whole city is not enough once the city is big.
    final detail = tierForDistance(nearest);

    // Rebuild only when something the geometry depends on actually changed.
    // Colonies are static between construction events, so this is normally a
    // string compare per frame rather than a scene rebuild.
    //
    // With per-building tiers the camera's own position is part of that: move
    // and a different set of buildings resolves to a different tier. Quantised
    // hard — to 64 m — because rebuilding the colony on every centimetre of
    // camera travel would cost far more than the LOD saves.
    final camKey = camKeyParts.isEmpty ? '' : '|${camKeyParts.join(";")}';
    // The RANGES are part of the key too. They are studio sliders, and
    // without them dragging one changed nothing on screen until the camera
    // happened to cross a 64 m quantum and move `camKey` — so the tiers
    // looked like they were ignoring the sliders, or responding to them
    // several seconds late.
    // Terrain-edit count for the same reason the road key carries it:
    // buildings and patches are draped positions too, and a re-grade moves
    // them without moving any of the counts.
    final key = '${snap.buildings.length}|${snap.roads.length}|'
        '${snap.patches.length}|${snap.terrainEdits.length}|'
        '${detail.index}|${byBody.keys.join(",")}'
        '|${lodDebug ? 1 : 0}|${perBuildingLod ? 1 : 0}'
        '|${interiorRangeM.round()}|${blockRangeM.round()}$camKey';
    _syncLibrary();
    _syncLodDebug();
    final sw = Stopwatch()..start();
    // The road pass has its own key: roads do not carry the building count,
    // the camera or the LOD dials, so a growing colony — the studio's slow
    // mode recapturing a frame per few buildings — re-emits only the
    // buildings, not every junction and lamp in town. Style and sealed-ness
    // ride the ordinary [invalidate] path, same as the furniture toggles.
    //
    // The EDIT count is in the key because the drape is not: road heights
    // come from the ground they were captured over, and grading the site
    // re-drapes every polyline without changing how many there are. Keyed on
    // count alone, the studio's slow mode kept the whole network at its
    // pre-grading heights — a road-shaped sheet floating beside the real
    // terrain. Edits are exactly when the ground under a drape can move.
    final roadsKey = '${snap.roads.length}|${snap.terrainEdits.length}'
        '|${byBody.keys.join(",")}';
    if (_roadsBuiltKey != roadsKey) {
      _roadsBuiltKey = roadsKey;
      _rebuildRoads(snap, byBody);
    }
    phaseMs['city.roads'] = sw.elapsedMicroseconds / 1000;
    sw.reset();
    var rebuiltThisFrame = false;
    if (_builtKey != key || _batches.isEmpty) {
      _builtKey = key;
      _rebuild(snap, byBody, detail, focusWorld);
      rebuiltThisFrame = true;
    }
    phaseMs['city.rebuild'] = rebuiltThisFrame ? sw.elapsedMicroseconds / 1000 : 0;
    sw.reset();
    // Every frame: re-place the anchors. A planet spins, so even a completely
    // static colony needs new node matrices — but only the matrices.
    _placeAnchors(snap, origin);
    phaseMs['city.anchors'] = sw.elapsedMicroseconds / 1000;
    sw.reset();
    _syncTraffic(snap, origin);
    phaseMs['city.traffic'] = sw.elapsedMicroseconds / 1000;
    sw.reset();
    _syncCursor(snap, origin);
    phaseMs['city.cursor'] = sw.elapsedMicroseconds / 1000;
    phaseCount['draws'] = _drawCalls + _roadDrawCalls;
    phaseCount['batches'] = _batches.length + _roadBatches.length;
    phaseCount['meshes'] = _uploaded.length;
    phaseCount['buildings'] = snap.buildings.length;
    phaseCount['trafficNodes'] = _trafficNodes.length;
    debugLine =
        'city: ${snap.buildings.length} bldg, '
        '${_drawCalls + _roadDrawCalls} draws (${detail.name}), '
        'meshes ${_uploaded.length}';
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

  /// Re-emit the road pass alone.
  ///
  /// Anchored on each body's first road point — the same trick the traffic
  /// pass uses — rather than the colony centroid the building pass anchors
  /// on. The centroid MOVES as buildings arrive, and an anchor that moved
  /// would drag this pass into every building rebuild, which is exactly the
  /// coupling being removed. Batches are independent ([_placeAnchors] carries
  /// each one's own anchor), so the two passes agreeing on an origin buys
  /// nothing.
  void _rebuildRoads(
    WorldSnapshot snap,
    Map<String, List<BuildingSnapshot>> byBody,
  ) {
    for (final batch in _roadBatches) {
      _scene.remove(batch.node);
    }
    _roadBatches.clear();
    _roadDrawCalls = 0;

    for (final bodyId in byBody.keys) {
      if (snap.bodies[bodyId] == null) continue;
      Vector3? anchorBF;
      for (final r in snap.roads) {
        if (r.body != bodyId || r.points.length < 3) continue;
        anchorBF = Vector3(r.points[0], r.points[1], r.points[2]);
        break;
      }
      if (anchorBF == null) continue;
      _emitRoads(snap, bodyId: bodyId, anchorBF: anchorBF);
    }
  }

  void _rebuild(
    WorldSnapshot snap,
    Map<String, List<BuildingSnapshot>> byBody,
    BuildingDetail detail,
    Vector3 focusWorld,
  ) {
    _clearDynamic();
    lodCounts.clear();
    // Where the LAST rebuild's time went, phase by phase. Only written on a
    // rebuild frame — the panel reads the split alongside a rebuild figure
    // that is zero on every other frame, so stale numbers describe the same
    // event the headline does.
    var meshUs = 0, emitUs = 0, featUs = 0, patchUs = 0;
    final phaseSw = Stopwatch();
    var bakedLightMap = false;

    for (final entry in byBody.entries) {
      final bodySnap = snap.bodies[entry.key];
      if (bodySnap == null) continue;
      // The camera in THIS body's rotating frame, so a building's distance is
      // measured against something in its own coordinates.
      final focusBF = focusInBodyFrame(
        focusWorld,
        Vector3(bodySnap.px, bodySnap.py, bodySnap.pz),
        Quaternion(bodySnap.qw, bodySnap.qx, bodySnap.qy, bodySnap.qz),
      );
      // Anchor at the colony's centroid, so instance offsets stay small and
      // keep their precision even on a body millions of metres across.
      var sum = Vector3.zero;
      var count = 0;
      for (final b in entry.value) {
        sum = sum + Vector3(b.px, b.py, b.pz);
        count++;
      }
      for (final p in snap.patches) {
        if (p.body != entry.key) continue;
        sum = sum + Vector3(p.px, p.py, p.pz);
        count++;
      }
      if (count == 0) continue;
      final anchorBF = sum * (1.0 / count);

      // The skyglow's density map, from this colony's own layout. First
      // body with buildings wins — the same single-colony assumption the
      // night factor already makes.
      if (entry.value.isNotEmpty && !bakedLightMap) {
        bakedLightMap = true;
        _bakeLightMap(entry.value, anchorBF);
      }

      final groups = <BuildingArchetype, List<vm.Matrix4>>{};
      phaseSw
        ..reset()
        ..start();
      for (final b in entry.value) {
        final spec = specOf(b);
        final parcel = parcelOf(b);
        final seed = b.id.hashCode;
        final tier = detailFor(b, focusBF, detail);
        lodCounts[tier] = (lodCounts[tier] ?? 0) + 1;
        // The style is part of the key here for the same reason it is part of
        // it inside the library: these two maps are looked up with keys built
        // independently, and a key that forgot the style would upload one
        // building's mesh and then serve it for a different kit's.
        // Block tier keys and meshes against the coarse library, so the
        // dominant tier shares far fewer archetypes (and draws).
        final lib = _libraryFor(tier);
        final key = BuildingArchetype.of(spec, parcel,
            detail: tier, seed: seed, bucketM: lib.bucketM,
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
        groups.putIfAbsent(key, () => []).add(instanceTransform(anchorBF, b));
      }
      meshUs += phaseSw.elapsedMicroseconds;
      phaseSw
        ..reset()
        ..start();
      _emit(groups, bodyId: entry.key, anchorBF: anchorBF);
      emitUs += phaseSw.elapsedMicroseconds;
      phaseSw
        ..reset()
        ..start();
      _emitLotFeatures(entry.value,
          bodyId: entry.key,
          anchorBF: anchorBF,
          focusBF: focusBF,
          colonyTier: detail);
      featUs += phaseSw.elapsedMicroseconds;
      phaseSw
        ..reset()
        ..start();
      _emitPatches(snap, bodyId: entry.key, anchorBF: anchorBF);
      patchUs += phaseSw.elapsedMicroseconds;
    }
    phaseMs['city.rebuild.mesh'] = meshUs / 1000;
    phaseMs['city.rebuild.emit'] = emitUs / 1000;
    phaseMs['city.rebuild.features'] = featUs / 1000;
    phaseMs['city.rebuild.patches'] = patchUs / 1000;
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
  void _syncTraffic(WorldSnapshot snap, FloatingOrigin origin) {
    for (final n in _trafficNodes) {
      _scene.remove(n);
    }
    _trafficNodes.clear();
    if (!traffic) return;

    final byBody = <String, List<RoadSnapshot>>{};
    for (final r in snap.roads) {
      (byBody[r.body] ??= []).add(r);
    }

    for (final entry in byBody.entries) {
      final body = snap.bodies[entry.key];
      if (body == null) continue;
      // Anchor on the first road point: traffic is rebuilt every frame, so it
      // cannot use the structural batches' anchors — but it must share their
      // FRAME, which the body transform below supplies.
      final first = entry.value.firstWhere((r) => r.points.length >= 3,
          orElse: () => entry.value.first);
      if (first.points.length < 3) continue;
      final anchorBF =
          Vector3(first.points[0], first.points[1], first.points[2]);

      final byKind = <VehicleKind, List<vm.Matrix4>>{};
      final trainBody = MeshBuilder();
      final trainGlass = MeshBuilder();
      var placed = 0;

      for (final road in entry.value) {
        if (placed >= _maxVehicles) break;
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

        final cls = RoadClass
            .values[road.roadClassIndex.clamp(0, RoadClass.values.length - 1)];

        // Rail carries a TRAIN, not cars.
        if (!cls.carriesCars) {
          ElevatedStructure.emitTrain(
            trainBody,
            trainGlass,
            pts: pts,
            anchorBF: anchorBF,
            lengthM: total,
            epochS: snap.epoch,
            seed: road.points.length,
          );
          continue;
        }

        // Metres of road per vehicle, and speed, PER CLASS.
        //
        // Both were derived from `cls.index` arithmetic, which happened to
        // work while there were four classes and broke the moment there were
        // seven: the spacing divisor `110 - index*22` reached zero at the
        // elevated tier and went negative at rail. An enum's index is not a
        // quantity — writing the quantity down is both correct and readable.
        final (spacingM, speed) = switch (cls) {
          RoadClass.street => (110.0, 8.0),
          RoadClass.avenue => (88.0, 13.0),
          RoadClass.highway => (66.0, 26.0),
          RoadClass.elevated => (70.0, 24.0),
          RoadClass.alley => (200.0, 4.0),
          RoadClass.path => (150.0, 6.0),
          RoadClass.transit => (0.0, 0.0),
        };
        if (spacingM <= 0) continue;
        final perLane = (total / spacingM * trafficDensity).floor();
        if (perLane <= 0) continue;
        final family =
            road.sealed ? VehicleKind.airless : VehicleKind.road;
        final seed = road.points.length * 2654435761 + entry.key.hashCode;

        for (var lane = 0; lane < 2; lane++) {
          final dirSign = lane == 0 ? 1.0 : -1.0;
          for (var i = 0; i < perLane && placed < _maxVehicles; i++) {
            final h = _hash(seed + lane * 7919 + i * 104729);
            final kind = family[h % family.length];
            // Longer vehicles need more room; spacing them by their own length
            // keeps a semi from sitting inside the car behind it.
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
            // Keep right of the centreline, like everything else does — and
            // ride the DECK on an elevated road rather than the ground its
            // columns stand on.
            final offset =
                side * (road.halfWidthM * 0.5) + up * cls.deckHeightM;
            // Model space is +Y forward, +Z up, so the instance rotation is
            // the basis (side, forward, up) expressed as a quaternion.
            final rot = Quaternion.fromBasis(side, fwd, up);
            (byKind[kind] ??= []).add(vm.Matrix4.compose(
              vm.Vector3(
                  lengthToScene((at.$1 + offset).x),
                  lengthToScene((at.$1 + offset).y),
                  lengthToScene((at.$1 + offset).z)),
              quatToScene(rot),
              // UNIT scale: `VehicleMeshes.emit` already builds its vertices
              // in scene units, unlike the building library which works in
              // metres. Applying the metres-to-scene factor again here made
              // every vehicle a thousand times too small — present, drawn, and
              // far too little to see.
              vm.Vector3.all(1.0),
            ));
            placed++;
          }
        }
      }

      byKind.forEach((kind, transforms) {
        final mesh = _vehicleMesh(kind);
        for (final (geometry, material) in [
          (mesh.solid, CityMaterials.facade),
          (mesh.glazing, CityMaterials.glazing),
        ]) {
          if (geometry == null) continue;
          for (var start = 0;
              start < transforms.length;
              start += _maxPerDraw) {
            final end = math.min(start + _maxPerDraw, transforms.length);
            final instanced =
                fs.InstancedMesh(geometry: geometry, material: material);
            for (var i = start; i < end; i++) {
              instanced.addInstance(transforms[i]);
            }
            final node = fs.Node()
              ..addComponent(fs.InstancedMeshComponent(instanced));
            final bodyWorld = Vector3(body.px, body.py, body.pz);
            final bodyQuat = Quaternion(body.qw, body.qx, body.qy, body.qz);
            node.localTransform = vm.Matrix4.compose(
              origin.worldToScene(bodyWorld + bodyQuat.rotate(anchorBF)),
              quatToScene(bodyQuat),
              vm.Vector3.all(1.0),
            );
            _scene.add(node);
            _trafficNodes.add(node);
          }
        }
      });

      // The train. Built as ordinary geometry rather than instanced: there is
      // at most one set per line and its cars are already one mesh, so an
      // instanced draw would cost a buffer upload to save nothing.
      for (final (builder, material) in [
        (trainBody, CityMaterials.facade),
        (trainGlass, CityMaterials.glazing),
      ]) {
        final mesh = builder.build();
        if (mesh.isEmpty) continue;
        final geometry = _geometryOf(mesh);
        if (geometry == null) continue;
        final node = fs.Node(
          mesh: fs.Mesh.primitives(
              primitives: [fs.MeshPrimitive(geometry, material)]),
        );
        final bodyWorld = Vector3(body.px, body.py, body.pz);
        final bodyQuat = Quaternion(body.qw, body.qx, body.qy, body.qz);
        node.localTransform = vm.Matrix4.compose(
          origin.worldToScene(bodyWorld + bodyQuat.rotate(anchorBF)),
          quatToScene(bodyQuat),
          vm.Vector3.all(1.0),
        );
        _scene.add(node);
        _trafficNodes.add(node);
      }
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
  void _syncCursor(WorldSnapshot snap, FloatingOrigin origin) {
    final existing = _cursorNode;
    if (existing != null) {
      _scene.remove(existing);
      _cursorNode = null;
    }
    final route = pendingRouteBF;
    // The anchor: the cursor when there is one, else the route's first point —
    // a half-drawn road must stay visible while the mouse is off the map.
    final at = cursorBF ?? (route.length >= 2 ? route.first : null);
    if (at == null) return;
    final body = snap.bodies[cursorBodyId];
    if (body == null) return;

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
    final bodyWorld = Vector3(body.px, body.py, body.pz);
    final bodyQuat = Quaternion(body.qw, body.qx, body.qy, body.qz);
    node.localTransform = vm.Matrix4.compose(
      origin.worldToScene(bodyWorld + bodyQuat.rotate(at)),
      quatToScene(bodyQuat),
      vm.Vector3.all(1.0),
    );
    _scene.add(node);
    _cursorNode = node;
  }

  /// Flat ground patches: roads, zoned lots, support decks.
  ///
  /// One mesh for all of them, coloured by a UV into the ground palette. The
  /// mesh format has no vertex-colour channel, and a material per colour would
  /// be five draws for what is a single sheet of ground.
  void _emitPatches(
    WorldSnapshot snap, {
    required String bodyId,
    required Vector3 anchorBF,
  }) {
    final m = MeshBuilder();
    var any = false;
    for (final p in snap.patches) {
      if (p.body != bodyId) continue;
      any = true;
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
    if (!any) return;
    final geometry = _geometryOf(m.build());
    if (geometry == null) return;
    final node = fs.Node(
      mesh: fs.Mesh.primitives(primitives: [
        fs.MeshPrimitive(geometry, CityMaterials.ground),
      ]),
    );
    _scene.add(node);
    _batches.add(_CityBatch(node, bodyId, anchorBF));
    _drawCalls++;
  }

  /// Fences and shop signs, one mesh per colony.
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
  void _emitLotFeatures(
    List<BuildingSnapshot> buildings, {
    required String bodyId,
    required Vector3 anchorBF,
    required Vector3 focusBF,
    required BuildingDetail colonyTier,
  }) {
    if (!lotFeatures) return;
    final solid = MeshBuilder();
    final glow = MeshBuilder();
    final apron = MeshBuilder();
    final cars = MeshBuilder();
    var any = false;
    var carBudget = _maxParkedCars;

    for (final b in buildings) {
      final tier = detailFor(b, focusBF, colonyTier);
      if (tier == BuildingDetail.block) continue;
      final edging = LotFeatures.edgingFor(b.type);
      final sign = LotFeatures.signFor(b.type);
      final spec = specOf(b);
      final spaces = const BuildingMassingRules().parkingSpaces(spec);
      if (edging == LotEdging.none && !sign && spaces <= 0) continue;

      final at = Vector3(b.px, b.py, b.pz) - anchorBF;
      final up = (at + anchorBF).normalized;
      // The building's own facing: its orientation carries the surface basis
      // plus the spin onto its street, so +Y is the way it fronts.
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
        any = true;
      }
      if (sign) {
        LotFeatures.emitSign(solid, glow, at, along, up, halfW, halfD,
            math.max(1.0, b.siteWidthM / 18));
        any = true;
      }
      if (spaces > 0 && carBudget > 0) {
        // Occupancy has no field on the wire yet, so it is DERIVED: a
        // deterministic per-lot fraction, so a district reads as busy or quiet
        // and two clients agree, without pretending to know the real number.
        final h = (b.id.hashCode & 0x7FFFFFFF) % 1000 / 1000.0;
        carBudget -= LotFeatures.emitParking(
          apron, cars, glow, at, along, up, halfW, halfD,
          spaces: spaces,
          occupancy: 0.25 + h * 0.6,
          airless: sealedWorld,
          maxCars: math.min(8, carBudget),
        );
        any = true;
      }
    }
    if (!any) return;

    for (final (builder, material) in [
      (solid, CityMaterials.facade),
      (apron, CityMaterials.road),
      (cars, CityMaterials.facade),
      // The sign face rides the glazing material, so it lights at night the
      // way the windows already do.
      (glow, CityMaterials.glazing),
    ]) {
      final mesh = builder.build();
      if (mesh.isEmpty) continue;
      final geometry = _geometryOf(mesh);
      if (geometry == null) continue;
      final node = fs.Node(
        mesh:
            fs.Mesh.primitives(primitives: [fs.MeshPrimitive(geometry, material)]),
      );
      _scene.add(node);
      _batches.add(_CityBatch(node, bodyId, anchorBF));
      _drawCalls++;
    }
  }

  /// Road ribbons and their street lamps.
  ///
  /// Built as one mesh per colony rather than instanced: a road is a unique
  /// polyline, so there is nothing to share between two of them, and one
  /// stretched ribbon is a single draw either way.
  void _emitRoads(
    WorldSnapshot snap, {
    required String bodyId,
    required Vector3 anchorBF,
  }) {
    final roads = snap.roads.where((r) => r.body == bodyId).toList();
    if (roads.isEmpty) return;

    final ribbon = MeshBuilder();
    final dirtRibbon = MeshBuilder();
    final alleyRibbon = MeshBuilder();
    // Everything in the air: steel, concrete, and the deck it carries.
    final airSolid = MeshBuilder();
    final airDeck = MeshBuilder();
    final airGlow = MeshBuilder();
    // Pavement clutter, budgeted across the colony — a city of ten thousand
    // hydrants is a city nobody can draw.
    final propSolid = MeshBuilder();
    final propGlow = MeshBuilder();
    var propBudget = 2600;
    // Street-tree pits and planter soil lines, collected here and drawn as
    // INSTANCES of the scatter system's props — the same generators,
    // materials and atlas the wild ones use, so a street tree and a forest
    // tree agree about what a tree is. Airless worlds plant nothing.
    final treePits = <(Vector3, double)>[];
    final shrubPits = <(Vector3, double)>[];
    // Every road END, with the point just inside it (for the leg direction).
    // Roads are already SPLIT at their crossings, so an intersection is simply
    // a place where three or more ends meet — the topology is there, it had
    // just never been drawn, which is why crossings read as two ribbons laid
    // over one another.
    final ends = <(Vector3, Vector3, double, bool, int)>[];
    final tubeSolid = MeshBuilder();
    final tubeGlass = MeshBuilder();
    final curbSolid = MeshBuilder();
    final curbGlass = MeshBuilder();
    var curbCars = 240;
    final lampSolid = MeshBuilder();
    final lampGlow = MeshBuilder();
    final walkRibbon = MeshBuilder();

    // Widest carriageway meeting each road END, so a sidewalk can stop short
    // of its crossing instead of bridging the intersecting street. Legs split
    // from one crossing land on (nearly) the same point — the junction pass
    // tolerates 8 m of drift — so a coarse quantised key groups them. The
    // count says whether anything ELSE meets there: a dead end keeps its
    // pavement all the way to the kerb line.
    final endHalf = <int, (double, int)>{};
    int endKey(Vector3 p) => Object.hash(
        (p.x / 10).round(), (p.y / 10).round(), (p.z / 10).round());
    for (final road in roads) {
      final cls = RoadClass
          .values[road.roadClassIndex.clamp(0, RoadClass.values.length - 1)];
      if (cls.isElevated || road.points.length < 6) continue;
      final n = road.points.length;
      for (final p in [
        Vector3(road.points[0], road.points[1], road.points[2]) - anchorBF,
        Vector3(road.points[n - 3], road.points[n - 2], road.points[n - 1]) -
            anchorBF,
      ]) {
        final k = endKey(p);
        final prev = endHalf[k];
        endHalf[k] = prev == null
            ? (road.halfWidthM, 1)
            : (math.max(prev.$1, road.halfWidthM), prev.$2 + 1);
      }
    }
    // How far a sidewalk stops before this end: past the junction plate
    // (r = widest * 1.45) and its zebra (5 m past the bar). Zero at an end
    // nothing else meets.
    double pullAt(Vector3 endPt) {
      final e = endHalf[endKey(endPt)];
      return e == null || e.$2 <= 1 ? 0.0 : e.$1 * 1.45 + 5.5;
    }

    for (final road in roads) {
      final pts = <Vector3>[];
      for (var i = 0; i + 2 < road.points.length; i += 3) {
        pts.add(Vector3(
          road.points[i] - anchorBF.x,
          road.points[i + 1] - anchorBF.y,
          road.points[i + 2] - anchorBF.z,
        ));
      }
      if (pts.length < 2) continue;
      final cls = RoadClass
          .values[road.roadClassIndex.clamp(0, RoadClass.values.length - 1)];
      final paved = cls.paved;

      if (cls.isElevated) {
        // No ground ribbon, no curb, no junction furniture: there is nothing
        // at ground level here but the columns. Drawing the ribbon anyway
        // painted a road stripe along the floor under the viaduct, which read
        // as the structure having fallen down.
        ElevatedStructure.emit(
          airSolid,
          airDeck,
          airGlow,
          pts: pts,
          anchorBF: anchorBF,
          cls: cls,
          halfWidthM: road.halfWidthM,
        );
        continue;
      }

      _ribbonFor(
          cls == RoadClass.alley
              ? alleyRibbon
              : (paved ? ribbon : dirtRibbon),
          pts,
          road.halfWidthM,
          anchorBF);
      // Raised pavements with a curb face, on anything that has a pavement
      // to raise. Not on a sealed world — pedestrians there travel in the
      // tube, and an open sidewalk in vacuum is set dressing for nobody.
      final walked = paved && cls.hasPavement && !road.sealed;
      if (walked) {
        _sidewalksFor(walkRibbon, pts, road.halfWidthM, 3.0, anchorBF,
            pullStart: pullAt(pts.first), pullEnd: pullAt(pts.last));
      }
      // Nobody lights a dirt track, and nobody lights an alley either.
      if (paved && cls.hasPavement) {
        _lampsFor(lampSolid, lampGlow, pts, road, anchorBF,
            liftM: walked ? _walkTopLiftM : 0.0);
      }
      if (propBudget > 0) {
        propBudget -= StreetFurniture.emit(
          propSolid,
          propGlow,
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
          budget: propBudget,
          treesOut: treePits,
          shrubsOut: shrubPits,
        );
      }
      // Only signalised classes contribute junction legs. An alley meeting a
      // street does not get a stop bar and a crossing; it gets a curb cut.
      if (cls.signalised) {
        ends.add((pts.first, pts[1], road.halfWidthM, paved,
            road.roadClassIndex));
        ends.add((pts.last, pts[pts.length - 2], road.halfWidthM, paved,
            road.roadClassIndex));
      }
      // Vacuum outside: pedestrians travel in a pressurised tube, not on a
      // pavement. The glazing builder already exists for dome caps.
      if (paved && cls.hasPavement && onStreetParking && curbCars > 0) {
        curbCars -= _curbParkingFor(curbSolid, curbGlass, pts, road, anchorBF,
            budget: curbCars);
      }
      if (road.sealed) {
        sealedWorld = true;
        PedestrianTube.emit(tubeSolid, tubeGlass,
            pts: pts, halfWidthM: road.halfWidthM, anchorBF: anchorBF);
      }
    }
    // Signal phase comes from sim time: deterministic, stateless, and the
    // same on every client looking at the same tick.
    _junctionsFor(ribbon, lampSolid, lampGlow, ends, anchorBF, snap.epoch);

    for (final (builder, material) in [
      // The ribbon takes the dedicated road strip — on the facade material it
      // rendered as a run of blank concrete with no curbs and no centre line,
      // which from the cockpit read as "roads are missing".
      (ribbon, CityMaterials.road),
      (dirtRibbon, CityMaterials.dirt),
      (alleyRibbon, CityMaterials.alley),
      (walkRibbon, CityMaterials.sidewalk),
      (airDeck, CityMaterials.road),
      (airSolid, CityMaterials.facade),
      (airGlow, CityMaterials.glazing),
      (propSolid, CityMaterials.facade),
      (propGlow, CityMaterials.glazing),
      (lampSolid, CityMaterials.facade),
      (lampGlow, CityMaterials.glazing),
      // The pedestrian tube: a concrete curb carrying a glass barrel.
      (tubeSolid, CityMaterials.facade),
      (tubeGlass, CityMaterials.glazing),
      (curbSolid, CityMaterials.facade),
      (curbGlass, CityMaterials.glazing),
    ]) {
      final mesh = builder.build();
      if (mesh.isEmpty) continue;
      final geometry = _geometryOf(mesh);
      if (geometry == null) continue;
      final node = fs.Node(
        mesh: fs.Mesh.primitives(primitives: [
          fs.MeshPrimitive(geometry, material),
        ]),
      );
      _scene.add(node);
      _roadBatches.add(_CityBatch(node, bodyId, anchorBF));
      _roadDrawCalls++;
    }

    _emitStreetFlora(PropKind.broadleafTree, streetTreeHeightM, treePits,
        bodyId: bodyId, anchorBF: anchorBF);
    _emitStreetFlora(PropKind.shrub, planterShrubHeightM, shrubPits,
        bodyId: bodyId, anchorBF: anchorBF);
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
  /// tree and a forest tree agree about what a tree is. Rides the road pass:
  /// planted off the road polylines, static while a colony grows.
  void _emitStreetFlora(
    PropKind kind,
    double sizeM,
    List<(Vector3, double)> pits, {
    required String bodyId,
    required Vector3 anchorBF,
  }) {
    // A plant stands in vacuum nowhere. The pits are still COLLECTED on a
    // sealed world so the furniture draw sequence stays identical either
    // way; they are simply not planted.
    if (pits.isEmpty || sealedWorld) return;
    final lib = ScatterPropLibrary.instance;
    if (!ScatterPropLibrary.texturesReady) {
      // First colony of a session races the atlas. Skip the planting this
      // build; update() re-keys the road pass when the upload lands.
      unawaited(ScatterPropLibrary.loadTextures());
      _floraPending = true;
      return;
    }

    // Group per pre-grown variant, so a whole colony's planting is at most
    // four solid draws and four foliage draws per kind.
    final byVariant = <int, List<vm.Matrix4>>{};
    for (final (at, yaw) in pits) {
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
        final node = fs.Node()..addComponent(fs.InstancedMeshComponent(instanced));
        _scene.add(node);
        _roadBatches.add(_CityBatch(node, bodyId, anchorBF));
        _roadDrawCalls++;
      }
    });
  }

  /// A flat strip along the centreline, lifted a few centimetres so it wins the
  /// depth test against the graded corridor it sits in instead of z-fighting
  /// the terrain that was levelled for it.
  static void _ribbonFor(
    MeshBuilder m,
    List<Vector3> pts,
    double halfWidth,
    Vector3 anchorBF,
  ) {
    const lift = 0.12;
    var v = 0.0;
    int? prevL, prevR;
    for (var i = 0; i < pts.length; i++) {
      final p = pts[i];
      // Local up is radial at the point itself, not at the anchor: a long road
      // curves with the body, and a single shared up would bury one end.
      final up = (p + anchorBF).normalized;
      final ahead = i + 1 < pts.length ? pts[i + 1] - p : p - pts[i - 1];
      final along = ahead.length > 1e-6 ? ahead.normalized : Vector3.unitX;
      final side = along.cross(up).normalized;
      if (i > 0) v += (p - pts[i - 1]).length / (halfWidth * 2);
      final l = m.vertex(_scenePos(p + side * -halfWidth + up * lift), up, 0, v);
      final r = m.vertex(_scenePos(p + side * halfWidth + up * lift), up, 1, v);
      if (prevL != null && prevR != null) {
        m.quad(prevL, prevR, r, l);
      }
      prevL = l;
      prevR = r;
    }
  }

  /// Raised pavements with a real curb face, one strip each side.
  ///
  /// The walk rides [kCurbHeightM] above the carriageway ribbon, a vertical
  /// curb face closes the step, and both ends pull back so the strip stops
  /// at its crossing instead of bridging the intersecting street — the gap
  /// is where the curb cut and the zebra live. U samples the sidewalk tile
  /// across the walk (curb stones under 0.06, flags above); the curb face
  /// wraps the same curb band down its vertical.
  static void _sidewalksFor(
    MeshBuilder m,
    List<Vector3> pts,
    double halfWidth,
    double pavementM,
    Vector3 anchorBF, {
    double pullStart = 0,
    double pullEnd = 0,
  }) {
    var total = 0.0;
    for (var i = 1; i < pts.length; i++) {
      total += (pts[i] - pts[i - 1]).length;
    }
    // Keep a real run of pavement mid-block or draw none at all.
    pullStart = math.min(pullStart, total * 0.45);
    pullEnd = math.min(pullEnd, total * 0.45);
    if (total - pullStart - pullEnd < 5.0) return;

    // Trim the centreline to the kept span, interpolating the cut points.
    final kept = <Vector3>[];
    final endAt = total - pullEnd;
    if (pullStart <= 0) kept.add(pts.first);
    var d = 0.0;
    for (var i = 1; i < pts.length; i++) {
      final seg = pts[i] - pts[i - 1];
      final len = seg.length;
      if (len < 1e-6) continue;
      final d0 = d;
      d += len;
      if (d0 < pullStart && d > pullStart) {
        kept.add(pts[i - 1] + seg * ((pullStart - d0) / len));
      }
      if (d > pullStart && d < endAt) {
        kept.add(pts[i]);
      } else if (d0 < endAt && d >= endAt) {
        kept.add(pts[i - 1] + seg * ((endAt - d0) / len));
        break;
      }
    }
    if (kept.length < 2) return;

    for (final s in const [-1.0, 1.0]) {
      int? pIn, pOut, pCurbT, pCurbB;
      var v = 0.0;
      for (var i = 0; i < kept.length; i++) {
        final p = kept[i];
        final up = (p + anchorBF).normalized;
        final ahead = i + 1 < kept.length ? kept[i + 1] - p : p - kept[i - 1];
        final along = ahead.length > 1e-6 ? ahead.normalized : Vector3.unitX;
        final side = along.cross(up).normalized;
        if (i > 0) v += (p - kept[i - 1]).length / 9.6; // four flags a tile
        final inner = p + side * (halfWidth * s);
        final outer = p + side * ((halfWidth + pavementM) * s);
        // The face looks at the carriageway.
        final curbN = side * -s;
        final iIn = m.vertex(_scenePos(inner + up * _walkTopLiftM), up, 0.03, v);
        final iOut = m.vertex(_scenePos(outer + up * _walkTopLiftM), up, 0.97, v);
        final iCt = m.vertex(_scenePos(inner + up * _walkTopLiftM), curbN, 0.03, v);
        final iCb = m.vertex(_scenePos(inner + up * _ribbonLiftM), curbN, 0.055, v);
        if (pIn != null) {
          // Winding follows [_ribbonFor]'s convention; the s < 0 strip runs
          // its edges the other way round, so the order flips with it.
          if (s > 0) {
            m.quad(pIn, pOut!, iOut, iIn);
            m.quad(pCurbB!, pCurbT!, iCt, iCb);
          } else {
            m.quad(pOut!, pIn, iIn, iOut);
            m.quad(pCurbT!, pCurbB!, iCb, iCt);
          }
        }
        pIn = iIn;
        pOut = iOut;
        pCurbT = iCt;
        pCurbB = iCb;
      }
    }
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

  /// Junction plates and stop bars where roads meet.
  ///
  /// A crossing had no visual hallmark at all: two carriageways simply
  /// overlapped, with the lower one's centre line running through the other.
  /// A real intersection reads as one piece of shared paving that the lane
  /// markings stop AT — so that is what this draws: a plate covering the
  /// meeting, and a bar across each leg where its markings should end.
  static void _junctionsFor(
    MeshBuilder m,
    MeshBuilder poles,
    MeshBuilder lights,
    List<(Vector3, Vector3, double, bool, int)> ends,
    Vector3 anchorBF,
    double epoch,
  ) {
    final used = List<bool>.filled(ends.length, false);
    for (var i = 0; i < ends.length; i++) {
      if (used[i]) continue;
      final at = ends[i].$1;
      final group = <int>[i];
      used[i] = true;
      var radius = ends[i].$3;
      var anyPaved = ends[i].$4;
      var topClass = ends[i].$5;
      for (var j = i + 1; j < ends.length; j++) {
        if (used[j]) continue;
        // Ends that split from one crossing sit on the same point; the
        // tolerance covers the sampling step they were rebuilt from.
        if ((ends[j].$1 - at).length > 8.0) continue;
        used[j] = true;
        group.add(j);
        if (ends[j].$3 > radius) radius = ends[j].$3;
        anyPaved = anyPaved || ends[j].$4;
        if (ends[j].$5 > topClass) topClass = ends[j].$5;
      }
      // Two ends meeting is a road carrying on round a corner, not a junction.
      if (group.length < 3 || !anyPaved) continue;

      final up = (at + anchorBF).normalized;
      final lift = up * 0.16; // just over the ribbons' own 0.12
      // An octagonal plate: round enough to serve any number of legs at any
      // angle, cheap enough to draw one per crossing.
      final seed = up.cross(Vector3.unitZ).lengthSquared > 1e-9
          ? up.cross(Vector3.unitZ)
          : up.cross(Vector3.unitX);
      final t1 = seed.normalized;
      final t2 = up.cross(t1);
      const u = 0.5 / kGroundSwatches; // the road surface swatch
      final r = radius * 1.45;
      final centre = m.vertex(_scenePos(at + lift), up, u, 0.5);
      final rim = <int>[];
      for (var k = 0; k < 8; k++) {
        final a = 2 * math.pi * k / 8;
        rim.add(m.vertex(
            _scenePos(at + t1 * (math.cos(a) * r) + t2 * (math.sin(a) * r) + lift),
            up,
            u,
            0.5));
      }
      for (var k = 0; k < 8; k++) {
        m.triangle(centre, rim[k], rim[(k + 1) % 8]);
      }

      // A stop bar across each leg, at the plate's edge: the mark that says a
      // driver yields here, and the reason the crossing reads as controlled
      // rather than as an accident of geometry.
      for (final g in group) {
        final inward = ends[g].$2 - ends[g].$1;
        if (inward.length < 1e-6) continue;
        final dir = inward.normalized;
        final side = dir.cross(up).normalized;
        final hw = ends[g].$3 * 0.92;
        final near = at + dir * (r * 0.92);
        final far = at + dir * (r * 0.92 + 1.4);
        const bu = 5.5 / kGroundSwatches; // pale, so it reads as paint
        final q = [
          m.vertex(_scenePos(near - side * hw + lift * 1.1), up, bu, 0.5),
          m.vertex(_scenePos(near + side * hw + lift * 1.1), up, bu, 0.5),
          m.vertex(_scenePos(far + side * hw + lift * 1.1), up, bu, 0.5),
          m.vertex(_scenePos(far - side * hw + lift * 1.1), up, bu, 0.5),
        ];
        m.quad(q[0], q[1], q[2], q[3]);

        // Zebra crossing OUTSIDE the stop bar: bars run along the direction of
        // travel, which is what makes a crossing read as a crossing rather
        // than as a ladder painted across the road.
        const stripes = 5;
        for (var k = 0; k < stripes; k++) {
          final o = (k / (stripes - 1) - 0.5) * 2 * hw * 0.82;
          final a0 = at + dir * (r * 0.92 + 2.2) + side * o;
          final a1 = at + dir * (r * 0.92 + 5.0) + side * o;
          final sw = hw * 0.11;
          final z = [
            m.vertex(_scenePos(a0 - side * sw + lift * 1.1), up, bu, 0.5),
            m.vertex(_scenePos(a0 + side * sw + lift * 1.1), up, bu, 0.5),
            m.vertex(_scenePos(a1 + side * sw + lift * 1.1), up, bu, 0.5),
            m.vertex(_scenePos(a1 - side * sw + lift * 1.1), up, bu, 0.5),
          ];
          m.quad(z[0], z[1], z[2], z[3]);
        }

        // Control. An avenue or bigger gets SIGNALS, a plain street crossing
        // gets a sign — the same rule a traffic engineer would apply, and it
        // means the two read differently from the cockpit.
        final corner = at + dir * (r * 0.98) + side * (hw + 1.6);
        if (topClass > 0) {
          _column(poles, corner, up, dir, 4.6);
          // The heads CYCLE. Derived from the epoch rather than stored: it is
          // deterministic, costs no state, and opposing legs are out of phase
          // because their inbound directions differ by a quarter turn.
          final axis = (dir.dot(t1).abs() > dir.dot(t2).abs()) ? 0 : 1;
          final green = ((epoch / 12.0).floor() + axis).isEven;
          final head = corner + up * 4.6;
          _head(lights, head + up * (green ? 0.0 : 0.55), up, dir);
        } else {
          // A sign: a small plate on a short post, facing the driver.
          _column(poles, corner, up, dir, 2.2);
          final plate = corner + up * 2.2;
          final ps = 0.42;
          final pv = [
            poles.vertex(_scenePos(plate - side * ps - up * ps), dir * -1, 0, 0),
            poles.vertex(_scenePos(plate + side * ps - up * ps), dir * -1, 1, 0),
            poles.vertex(_scenePos(plate + side * ps + up * ps), dir * -1, 1, 1),
            poles.vertex(_scenePos(plate - side * ps + up * ps), dir * -1, 0, 1),
          ];
          poles.quad(pv[0], pv[1], pv[2], pv[3]);
        }
      }
    }
  }

  /// Lamp columns down the verge, spaced by road class.
  ///
  /// Derived on the client from the road itself rather than shipped: the rule
  /// is deterministic, and a thousand lamp positions per colony is a lot of
  /// wire for something both ends can compute.
  static void _lampsFor(
    MeshBuilder solid,
    MeshBuilder glow,
    List<Vector3> pts,
    RoadSnapshot road,
    Vector3 anchorBF, {
    double liftM = 0,
  }) {
    final scale = road.halfWidthM / 4.0; // street half-width is 4 m
    final spacing = 34.0 * math.sqrt(math.max(scale, 0.25));
    final height = 9.0 * math.sqrt(math.max(scale, 0.25));
    final both = road.roadClassIndex > 0;
    var travelled = 0.0;
    var next = spacing * 0.5;
    var flip = 1.0;

    for (var i = 1; i < pts.length; i++) {
      travelled += (pts[i] - pts[i - 1]).length;
      if (travelled < next) continue;
      next += spacing;
      final p = pts[i];
      final up = (p + anchorBF).normalized;
      final along = (pts[i] - pts[i - 1]).normalized;
      final side = along.cross(up).normalized;
      final offset = road.halfWidthM + 1.2;
      for (final s in both ? const [1.0, -1.0] : [flip]) {
        // On the raised walk when there is one — a column standing on the
        // old bare-drape height would float a curb's worth over the flags.
        final base = p + side * (offset * s) + up * (0.1 + liftM);
        _column(solid, base, up, along, height);
        _head(glow, base + up * height, up, along);
      }
      flip = -flip;
    }
  }

  static void _column(
      MeshBuilder m, Vector3 base, Vector3 up, Vector3 along, double h) {
    final side = along.cross(up).normalized;
    const r = 0.14;
    final corners = [
      base + side * -r + along * -r,
      base + side * r + along * -r,
      base + side * r + along * r,
      base + side * -r + along * r,
    ];
    for (var i = 0; i < 4; i++) {
      final a = corners[i], b = corners[(i + 1) % 4];
      final n = ((a + b) * 0.5 - base).normalized;
      final i0 = m.vertex(_scenePos(a), n, 0, 1);
      final i1 = m.vertex(_scenePos(b), n, 1, 1);
      final i2 = m.vertex(_scenePos(b + up * h), n, 1, 0);
      final i3 = m.vertex(_scenePos(a + up * h), n, 0, 0);
      m.quad(i0, i1, i2, i3);
    }
  }

  static void _head(MeshBuilder m, Vector3 at, Vector3 up, Vector3 along) {
    final side = along.cross(up).normalized;
    const hw = 0.55, hd = 0.22;
    final a = at + side * -hw + along * -hd;
    final b = at + side * hw + along * -hd;
    final c = at + side * hw + along * hd;
    final d = at + side * -hw + along * hd;
    // Downward-facing lens: it is the lit surface, so it points at the road.
    final n = up * -1;
    final i0 = m.vertex(_scenePos(a), n, 0, 0);
    final i1 = m.vertex(_scenePos(b), n, 1, 0);
    final i2 = m.vertex(_scenePos(c), n, 1, 1);
    final i3 = m.vertex(_scenePos(d), n, 0, 1);
    m.quad(i0, i3, i2, i1);
  }

  void _emit(
    Map<BuildingArchetype, List<vm.Matrix4>> groups, {
    required String bodyId,
    required Vector3 anchorBF,
  }) {
    groups.forEach((key, transforms) {
      final mesh = _uploaded[key];
      if (mesh == null) return;
      // Walls take the stone material (concrete is closer to rock than bark);
      // glazing takes the foliage one, which is the alpha-capable pass and is
      // where the night lighting hooks in.
      for (final (geometry, material) in [
        (mesh.solid, mesh.lod ? CityMaterials.ground : CityMaterials.facade),
        (mesh.glazing, CityMaterials.glazing),
      ]) {
        if (geometry == null) continue;
        for (var start = 0; start < transforms.length; start += _maxPerDraw) {
          final end = math.min(start + _maxPerDraw, transforms.length);
          final instanced =
              fs.InstancedMesh(geometry: geometry, material: material);
          for (var i = start; i < end; i++) {
            instanced.addInstance(transforms[i]);
          }
          final node = fs.Node()
            ..addComponent(fs.InstancedMeshComponent(instanced));
          _scene.add(node);
          _batches.add(_CityBatch(node, bodyId, anchorBF));
          _drawCalls++;
        }
      }
    });
  }

  /// Per-frame: put each batch's anchor where its body currently is.
  void _placeAnchors(WorldSnapshot snap, FloatingOrigin origin) {
    for (final list in [_roadBatches, _batches]) {
      for (final batch in list) {
        final body = snap.bodies[batch.bodyId];
        if (body == null) continue;
        final bodyWorld = Vector3(body.px, body.py, body.pz);
        final bodyQuat = Quaternion(body.qw, body.qx, body.qy, body.qz);
        batch.node.localTransform = vm.Matrix4.compose(
          origin.worldToScene(bodyWorld + bodyQuat.rotate(batch.anchorBF)),
          quatToScene(bodyQuat),
          vm.Vector3.all(1.0),
        );
      }
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

  /// Drop the building-side batches only; the road pass keeps its own.
  void _clearDynamic() {
    for (final batch in _batches) {
      _scene.remove(batch.node);
    }
    _batches.clear();
    _drawCalls = 0;
  }

  /// Drop everything, and the keys with it — an emptied scene with a stale
  /// key would skip the rebuild that repopulates it.
  void _clear() {
    _clearDynamic();
    for (final batch in _roadBatches) {
      _scene.remove(batch.node);
    }
    _roadBatches.clear();
    _roadDrawCalls = 0;
    _builtKey = '';
    _roadsBuiltKey = '';
  }

  void dispose() {
    _clear();
    _uploaded.clear();
    _library.clear();
    _libraryCoarse.clear();
    if (debugLine.isNotEmpty) debugPrint('cityNodes disposed');
  }
}

/// One instanced draw, pinned to a body-fixed anchor.
class _CityBatch {
  _CityBatch(this.node, this.bodyId, this.anchorBF);
  final fs.Node node;
  final String bodyId;
  final Vector3 anchorBF;
}
