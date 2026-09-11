// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/city_starter_kit.dart';
import 'package:acro_space_simulator/domain/colony/city/city_terrain_shaper.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_build.dart';
import 'package:acro_space_simulator/domain/colony/city/road_catalog.dart';
import 'package:acro_space_simulator/domain/planetary/planet_surface.dart'
    show Biome;
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/terrain/cell_mesher.dart';
import 'package:acro_space_simulator/domain/terrain/cubed_sphere.dart';
import 'package:acro_space_simulator/domain/terrain/mesh_ground_query.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_brush.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_field.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_lod.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/register_baked_dems.dart';

/// The ground a road is drawn on is the terrain MESH, not the field the
/// road is draped on: a road is visible only where that mesh lies under it.
///
/// The live case (the dev colony: the starter kit on earth at -45.03 /
/// 168.66, 479 m above the datum): a one-way laid off the crossroads beside
/// the pump's levelled field, and its end dragged into the field in Adjust
/// Roads, cutting 5 m through its edge. Every drawn point sat on the graded
/// field within centimetres, and the frame drew it in pieces with grass
/// across it between them: the colony's ground was meshed at 15 m voxels
/// (level 13, boosted), which cannot hold an 8 m cut — 4.5 m of hillside
/// over the carriageway, three pieces as built, two once re-laid.
///
/// What the renderer meshes is rebuilt here from the same pure pieces
/// `TerrainNodes` runs: the LOD tree with the edits' merged refinement
/// ([mergedRefinementsFor] at the boosted resolution), each leaf meshed at
/// [colonyEditResolutionFor] by the CPU mesher, the ground under a point
/// read off the triangles ([radialHitOnCell]).
void main() {
  setUpAll(registerBakedDemsForTest);

  final system = SampleWorld.realSystem();
  final bodies = system.all.where((b) => !b.isStar).toList();
  final earth = system.body(const BodyId('earth'))!;

  // TerrainNodes' defaults.
  const resolution = 24, boost = 4, splitPx = 220.0;
  // The road ribbon's lift over its drape (`RoadMesher.ribbonLiftM`): ground
  // meshed higher than this over the drape shows through the carriageway.
  const ribbonLiftM = 0.12;

  CitySim devColony() => CityStarterKit.found(
        bodies: bodies,
        config: const CityConfig(
            bodyId: 'earth',
            latitude: -45.03,
            longitude: 168.66,
            biome: Biome.forest),
        id: 'city-dev',
      )..funds = 1e6;

  double groundRadius(InMemoryTerrainEditsRepository e, CelestialBody body,
      Vector3 dir) {
    final f = body.terrainFieldWith(e.forBody(body.id));
    return f == null ? body.radius : f.groundRadiusAt(dir.x, dir.y, dir.z);
  }

  /// What the world tick does after the colony advances.
  void shape(CitySim city, InMemoryTerrainEditsRepository e,
      [CityTerrainShaper shaper = const CityTerrainShaper()]) {
    final body = system.body(city.body.id)!;
    for (final p in shaper.pending(city,
        bodyRadiusM: body.radius,
        groundRadiusAt: (d) => groundRadius(e, body, d))) {
      e.record(body.id, p.brush);
      CityTerrainShaper.markShaped(city, p.key, p.brush);
    }
  }

  /// The renderer's leaves around an eye [heightM] over the colony's centre.
  ({TerrainField field, Set<ChunkKey> leaves, List<TerrainBrush> near,
      List<TerrainRefinement> targets}) rendered(
      CitySim city, InMemoryTerrainEditsRepository e, double heightM) {
    final body = system.body(city.body.id)!;
    final field = body.terrainFieldWith(e.forBody(body.id))!;
    final r = field.radius;
    final o = city.localToBodyFixed(const Vec2(0, 0), bodyRadiusM: r).normalized;
    final eye = o * (field.groundRadiusAt(o.x, o.y, o.z) + heightM);
    final near = [
      for (final b in field.edits?.all ?? const <TerrainBrush>[])
        if ((b.centreBF - o * r).length <= 20000) b,
    ];
    final targets = mergedRefinementsFor(near, r, resolution * boost,
        voxelsAcrossBrush: 8, maxLevel: 20);
    // A 681 px tall view through 50 degrees: the live shots' window.
    final focal = 681 * 0.5 / math.tan(25 * math.pi / 180);
    double apparent(ChunkKey k) {
      final g = ChunkGeometry(k, r);
      final d = (g.centreBF - eye).length;
      if (d <= g.circumradiusM) return focal * 4;
      return focal * math.tan(math.asin(g.circumradiusM / d));
    }

    final tree = TerrainLodTree(splitPx: splitPx);
    var leaves = tree.leaves;
    for (var i = 0; i < 8; i++) {
      leaves = tree.update(apparent, refine: targets);
    }
    return (field: field, leaves: leaves, near: near, targets: targets);
  }

  /// How far the meshed ground stands over road [id]'s drawn ribbon at its
  /// worst, sampled every half metre along it on its centreline and at
  /// `offsets` of its half width either side: the worst over the centreline;
  /// the share of the samples at each offset where the ground stands over
  /// the ribbon ([ribbonLiftM]) — where grass shows through the carriageway
  /// — and the level and resolution the centreline's worst leaf was meshed
  /// at. The ribbon is flat across (`RoadMesher.ribbon`: the centreline's
  /// point carried sideways), so an offset is compared with the centreline's
  /// height. The mesh is read on the leaf under each point and the leaves
  /// across its edges: their aprons and skirts overlap it.
  ({double over, Map<double, double> shows, int level, int res}) meshOverRoad(
      CitySim city, InMemoryTerrainEditsRepository e, String id) {
    const offsets = [0.0, -0.5, 0.5, -0.9, 0.9];
    final g = rendered(city, e, 108);
    final cells = <ChunkKey, CellMesh>{};
    int resOf(ChunkKey k) =>
        colonyEditResolutionFor(k, g.field.radius, resolution, g.near,
            maxBoost: boost);
    double? meshR(Vector3 dir) {
      final owner = leafCovering(g.leaves, chunkAt(dir, 22))!;
      double? best;
      for (final k in {
        owner,
        for (final edge in ChunkEdge.values)
          ?leafCovering(g.leaves, owner.neighbour(edge)),
      }) {
        final c = cells[k] ??=
            meshTerrainCell(g.field, k, resolution: resOf(k));
        final h = radialHitOnCell(c, dir);
        if (h != null && (best == null || h > best)) best = h;
      }
      return best;
    }

    final road = WorldSnapshot.capture(1, InMemoryVesselRepository(const []),
            system: system,
            cities: InMemoryCityRepository([city]),
            terrainEdits: e)
        .roads
        .singleWhere((r) => r.id == id);
    final pts = [
      for (var k = 0; k + 2 < road.points.length; k += 3)
        Vector3(road.points[k], road.points[k + 1], road.points[k + 2]),
    ];
    final hw = city.layout.roadById(id)!.halfWidth;
    var over = double.negativeInfinity;
    var at = pts.first.normalized;
    final samples = {for (final o in offsets) o: 0};
    final showing = {for (final o in offsets) o: 0};
    for (var k = 0; k + 1 < pts.length; k++) {
      final a = pts[k], b = pts[k + 1];
      final steps = math.max(1, ((b - a).length / 0.5).ceil());
      for (var j = 0; j < steps; j++) {
        final p = a + (b - a) * (j / steps);
        final side = (b - a).cross(p.normalized).normalized;
        for (final o in offsets) {
          final q = p + side * (o * hw);
          final m = meshR(q.normalized);
          if (m == null) continue;
          samples[o] = samples[o]! + 1;
          // Against the ribbon there: the centreline's height carried across.
          final above = m - q.normalized.dot(p);
          if (above > ribbonLiftM) showing[o] = showing[o]! + 1;
          if (o == 0 && above > over) {
            over = above;
            at = p.normalized;
          }
        }
      }
    }
    final leaf = leafCovering(g.leaves, chunkAt(at, 22))!;
    return (
      over: over,
      shows: {
        for (final o in offsets)
          o: samples[o] == 0 ? 1.0 : showing[o]! / samples[o]!,
      },
      level: leaf.level,
      res: resOf(leaf),
    );
  }

  /// TerrainNodes' chunk resolution as it was before a brush was judged on
  /// the ground (df47936): every brush against the chunk's centre on the
  /// datum sphere. Verbatim.
  int datumResolution(ChunkKey k, double radiusM, List<TerrainBrush> near) {
    final centre = k.centreDirection * radiusM;
    final reach = k.circumradiusM(radiusM);
    final chunkVoxelM = reach * 2.0 / resolution;
    var b0 = 1;
    for (final b in near) {
      if ((b.centreBF - centre).length > reach + b.lateralReachM) continue;
      final targetM = math.max(b.radiusM * 2.0 / 8, b.minVoxelM);
      if (chunkVoxelM > targetM * boost) continue;
      while (b0 < boost && chunkVoxelM > targetM * b0) {
        b0 <<= 1;
      }
      if (b0 >= boost) break;
    }
    return resolution * b0;
  }

  double groundAt(CitySim city, InMemoryTerrainEditsRepository e, Vec2 p) =>
      groundRadius(e, earth,
          city.localToBodyFixed(p, bodyRadiusM: earth.radius).normalized) -
      earth.radius;

  /// The live run's road: two clicks, then reversed and its end dragged
  /// into the pump's field. Returns the one-way's id as built and re-laid.
  (String, String) liveRoad(CitySim city, InMemoryTerrainEditsRepository e,
      CityTerrainShaper shaper,
      {void Function(String id)? built}) {
    final id = city
        .buildRoad(
            RoadBuildRequest(controls: const [
              Vec2(-40.53494707193965, 35.79178164252065),
              Vec2(-59.22824161951971, 80.00219601467299),
            ], type: RoadType.byId('one-way')!),
            groundAt: (p) => groundAt(city, e, p))
        .roadId!;
    shape(city, e, shaper);
    built?.call(id);
    expect(city.reverseRoad(id), isTrue);
    final relaid = city
        .moveRoadEnd(id,
            atStart: false,
            to: const Vec2(-89.63, 77.65),
            groundAt: (p) => groundAt(city, e, p))
        .roadId!;
    shape(city, e, shaper);
    return (id, relaid);
  }

  /// A road laid with the tool on the dev colony through [controls], as a
  /// [type] from the catalogue, its corridor cut. Returns its id.
  String toolRoad(CitySim city, InMemoryTerrainEditsRepository e,
      List<Vec2> controls, String type) {
    final id = city
        .buildRoad(
            RoadBuildRequest(controls: controls, type: RoadType.byId(type)!),
            groundAt: (p) => groundAt(city, e, p))
        .roadId!;
    shape(city, e);
    return id;
  }

  /// The steepest grade (m per m) road [id]'s corridor was cut to.
  double steepest(CitySim city, String id) {
    final road = city.layout.roadById(id)!;
    final knots = road.sample(stepM: CityTerrainShaper.corridorStepM);
    final hw = road.halfWidth.toStringAsFixed(2);
    var worst = 0.0;
    for (var i = 1; i < knots.length; i++) {
      final d = city.corridorDatums['road:$id:$hw:$i'];
      final run = knots[i - 1].distanceTo(knots[i]);
      if (d == null || run < 1e-6) continue;
      worst = math.max(worst, (d.$2 - d.$1).abs() / run);
    }
    return worst;
  }

  /// Road [id]'s points as the frame draws them, body-fixed.
  List<Vector3> drawnPoints(
      CitySim city, InMemoryTerrainEditsRepository e, String id) {
    final road = WorldSnapshot.capture(1, InMemoryVesselRepository(const []),
            system: system,
            cities: InMemoryCityRepository([city]),
            terrainEdits: e)
        .roads
        .singleWhere((r) => r.id == id);
    return [
      for (var k = 0; k + 2 < road.points.length; k += 3)
        Vector3(road.points[k], road.points[k + 1], road.points[k + 2]),
    ];
  }

  // Tool roads cut fine that the live one-way did not cover: straight up
  // the levelled lot's edge north-east of the crossroads, and curving down
  // the pump's field's step (the skeptic's candidates C, E and J).
  const twoLaneUp = [Vec2(40, 100), Vec2(90, 130)];
  const fourLaneUp = [Vec2(130, 20), Vec2(140, 80)];
  const oneWayCurve = [Vec2(-40, 36), Vec2(-80, 60), Vec2(-60, 100)];

  test('the live one-way is meshed where it is drawn — as built, and '
      're-laid through the edge of the pump\'s field', () {
    final city = devColony();
    final e = InMemoryTerrainEditsRepository();
    shape(city, e);
    ({double over, Map<double, double> shows, int level, int res})? asBuilt;
    final (_, relaid) = liveRoad(city, e, const CityTerrainShaper(),
        built: (id) => asBuilt = meshOverRoad(city, e, id));
    final after = meshOverRoad(city, e, relaid);
    // Measured: 0.01 m over the centreline as built and 0.07 m re-laid, both
    // in level-16 leaves at resolution 96 (1.9 m voxels), and nowhere across
    // either carriageway with ground over the ribbon. Before, 4.6 m over the
    // centreline in a level-13 leaf; and with round segment starts the
    // re-laid road had grass over its ribbon along 11% of it at half its
    // half width and 16% at nine tenths — a V across it at a knot — and,
    // levelled only to its kerbs, along 2.8% at nine tenths.
    for (final (name, m) in [('as built', asBuilt!), ('re-laid', after)]) {
      // ignore: avoid_print
      print('$name: centreline ${m.over.toStringAsFixed(3)} m over, grass '
          'over the ribbon by offset ${{
        for (final o in m.shows.keys)
          o: '${(m.shows[o]! * 100).toStringAsFixed(1)}%'
      }} (level ${m.level}, resolution ${m.res})');
      expect(m.over, lessThan(0.15),
          reason: '$name: the ground is meshed ${m.over.toStringAsFixed(2)} '
              'm over the road\'s centreline (level ${m.level}, resolution '
              '${m.res})');
      for (final o in m.shows.keys) {
        expect(m.shows[o], lessThanOrEqualTo(0.01),
            reason: '$name: grass over the ribbon along '
                '${(m.shows[o]! * 100).toStringAsFixed(1)}% of the road at '
                '$o of its half width');
      }
    }

    // Its corridor asked for it: finer than the colony's 15 m where it cuts.
    final fine = [
      for (final k in city.fineCorridors)
        if (k.startsWith('road:$relaid:')) k,
    ];
    expect(fine, isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('roads cut fine straight up a levelled lot\'s edge — a two-lane '
      'climbing 186%, a four-lane 130% — are meshed where they are drawn, '
      'the four-lane as finely as a one-way', () {
    for (final (name, controls, type, grade) in const [
      ('two-lane', twoLaneUp, 'two-lane', 1.8),
      ('four-lane', fourLaneUp, 'four-lane', 1.25),
    ]) {
      final city = devColony();
      final e = InMemoryTerrainEditsRepository();
      shape(city, e);
      final id = toolRoad(city, e, controls, type);
      // What makes it a test: cut fine, up a grade steeper than one in one,
      // where the grade turns at the foot and at the top.
      expect(city.fineCorridors.where((k) => k.startsWith('road:$id:')),
          isNotEmpty,
          reason: '$name: not cut fine — the case is gone');
      expect(steepest(city, id), greaterThan(grade), reason: name);
      final m = meshOverRoad(city, e, id);
      // Measured: 0.08 m over the two-lane's centreline and 0.03 m over the
      // four-lane's, nowhere over the ribbon, both in level-16 leaves at
      // resolution 96. Before (56b9ddc): the two-lane 0.34 m over its
      // centreline, grass over the ribbon along 5.8-9.2% of it at every
      // offset — the corridor 0.16 m over its line between two points, the
      // mesh 0.3-0.4 m over its grade's turns; the four-lane cut at 4 m
      // voxels and meshed a level coarser, 0.83 m over, 13.5-14.1%.
      // ignore: avoid_print
      print('$name: centreline ${m.over.toStringAsFixed(3)} m over, grass '
          'over the ribbon by offset ${{
        for (final o in m.shows.keys)
          o: '${(m.shows[o]! * 100).toStringAsFixed(1)}%'
      }} (level ${m.level}, resolution ${m.res})');
      expect(m.over, lessThan(0.15),
          reason: '$name: the ground is meshed ${m.over.toStringAsFixed(2)} '
              'm over the road\'s centreline (level ${m.level}, resolution '
              '${m.res})');
      for (final o in m.shows.keys) {
        expect(m.shows[o], lessThanOrEqualTo(0.01),
            reason: '$name: grass over the ribbon along '
                '${(m.shows[o]! * 100).toStringAsFixed(1)}% of the road at '
                '$o of its half width');
      }
      expect((m.level, m.res), (16, resolution * boost),
          reason: '$name: meshed coarser than a one-way cut fine');
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('a road cut fine is drawn on its corridor between its points, not '
      'only at them — up a lot\'s edge, and curving down the pump\'s field\'s '
      'step', () {
    for (final (name, controls, type) in const [
      ('two-lane up the edge', twoLaneUp, 'two-lane'),
      ('curved one-way down the step', oneWayCurve, 'one-way'),
    ]) {
      final city = devColony();
      final e = InMemoryTerrainEditsRepository();
      shape(city, e);
      final id = toolRoad(city, e, controls, type);
      expect(city.fineCorridors.where((k) => k.startsWith('road:$id:')),
          isNotEmpty,
          reason: '$name: not cut fine — the case is gone');
      final field = earth.terrainFieldWith(e.forBody(earth.id))!;
      final pts = drawnPoints(city, e, id);
      // The corridor over the straight line between each two points.
      var worst = double.negativeInfinity;
      for (var k = 0; k + 1 < pts.length; k++) {
        for (var j = 1; j < 40; j++) {
          final p = pts[k] + (pts[k + 1] - pts[k]) * (j / 40);
          final d = p.normalized;
          worst = math.max(worst, field.groundRadiusAt(d.x, d.y, d.z) - p.length);
        }
      }
      // Measured: 0.02 m for the two-lane, 0.06 m for the one-way. Before
      // (56b9ddc), each span tested at its middle only and halved three
      // times at most: 0.16 m over a 2.6 m span of the two-lane, a quarter
      // of the way along; 1.37 m over a 7.2 m span of the one-way, across
      // a knot at the foot of the step.
      // ignore: avoid_print
      print('$name: the corridor at most ${worst.toStringAsFixed(3)} m over '
          'the line drawn between ${pts.length} points');
      expect(worst, lessThan(ribbonLiftM),
          reason: '$name: the corridor stands ${worst.toStringAsFixed(2)} m '
              'over the road drawn between two of its points');
      // Bounded: its 6 m points, its knots, and no more than four more per
      // 6 m point.
      final road = city.layout.roadById(id)!;
      expect(
          pts.length,
          lessThanOrEqualTo(5 * road.sample(stepM: 6).length +
              road.sample(stepM: CityTerrainShaper.corridorStepM).length),
          reason: '$name: drawn with ${pts.length} points');
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('a road cut fine is known by its own brushes, levelled wider than its '
      'carriageway: freshly cut, its drape asks the ground at none of its '
      'points', () {
    for (final (name, controls, type) in const [
      (
        'the live one-way',
        [
          Vec2(-40.53494707193965, 35.79178164252065),
          Vec2(-59.22824161951971, 80.00219601467299),
        ],
        'one-way'
      ),
      ('a four-lane up a lot\'s edge', fourLaneUp, 'four-lane'),
    ]) {
      final city = devColony();
      final e = InMemoryTerrainEditsRepository();
      shape(city, e);
      final id = toolRoad(city, e, controls, type);
      expect(city.fineCorridors.where((k) => k.startsWith('road:$id:')),
          isNotEmpty,
          reason: '$name: not cut fine — the case is gone');
      drawnPoints(city, e, id);
      expect(city.drapeCache[id]?.dirs, isNotNull,
          reason: '$name: drawn as a corridor not yet cut');
      // A point asked of the ground is held under 'road:<id>:p<i>'. Taken
      // for brushes laid over it, a fine road's own — levelled a voxel past
      // its kerbs (`CityTerrainShaper.fineCoreM`), not to them — were a
      // ground query per point, 8 ms each in a built city.
      final asked = [
        for (final k in city.groundCache.keys)
          if (k.startsWith('road:$id:p')) k,
      ];
      expect(asked, isEmpty,
          reason: '$name: its drape asked the ground at ${asked.length} '
              'points, taking its own corridor for brushes laid over it');
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('a vertical curve turns a fine segment\'s grade steadily from the one '
      'before it to its own, the same all the way across', () {
    final r = earth.radius;
    final dir = const Vector3(0.31, 0.42, -0.85).normalized;
    final seed = dir.x.abs() < 0.9 ? Vector3.unitX : Vector3.unitY;
    final along = seed.cross(dir).normalized;
    final across = dir.cross(along);
    final up = r + 479;
    const g0 = -0.2, g1 = 1.5, len = 20.0, h = 5.0;
    Vector3 at(double x, double side, double lift) =>
        (dir * r + along * x + across * side).normalized * (up + lift);
    final b = TerrainBrush.cutFill(
      startBF: at(0, 0, 0),
      endBF: at(len, 0, g1 * len),
      radiusM: 6,
      datumRadiusM: up,
      datumRadiusEndM: up + g1 * len,
      falloffM: 6,
      minVoxelM: 2,
      squareStart: true,
      curveInGrade: g0,
      curveHalfM: h,
    );
    // The ground the brush levels to under (x, side): at full weight, a
    // density of 0 at a point is replaced by its height over the ground.
    double ground(double x, double side) {
      final p = at(x, side, 3);
      return p.length - b.apply(0, p) - up;
    }

    const e = 5e-3;
    // Meets the grade before it at the curve's start, its own at its end.
    expect(ground(-h, 0), closeTo(g0 * -h, e));
    expect((ground(-h + 0.01, 0) - ground(-h, 0)) / 0.01, closeTo(g0, 0.01));
    expect(ground(h, 0), closeTo(g1 * h, e));
    expect((ground(h, 0) - ground(h - 0.01, 0)) / 0.01, closeTo(g1, 0.01));
    expect(ground(12, 0), closeTo(g1 * 12, e));
    // Turning at one rate all along it: (g1 - g0) / 2h per metre.
    for (final x in [-4.0, -1.5, 0.0, 2.5, 4.0]) {
      final bend = ground(x + 1, 0) - 2 * ground(x, 0) + ground(x - 1, 0);
      expect(bend, closeTo((g1 - g0) / (2 * h), 0.01), reason: 'at $x m');
      // And flat across the carriageway, as the ribbon is.
      for (final side in [-3.6, 3.6]) {
        expect(ground(x, side), closeTo(ground(x, 0), 0.01),
            reason: 'at $x m, $side m across');
      }
    }
    // Behind the curve, the grade before it carried on, eased out over the
    // curve's half length: 2 m past it, at the smoothstep's weight there.
    final p = at(-h - 2, 0, 3);
    final w = TerrainBrush.falloffWeight(2, 0, h);
    expect(w, inExclusiveRange(0.1, 0.9));
    expect(b.apply(0, p), closeTo((p.length - (up + g0 * (-h - 2))) * w, e));
    expect(b.apply(0, at(-2 * h - 0.1, 0, 3)), 0,
        reason: 'reaches past twice its half length behind its start');
  });

  test('what makes it a test: meshed at the colony\'s voxel, the same road '
      'is buried metres deep', () {
    // The shaper that never asks for a finer mesh — dev before the fix.
    const coarse = CityTerrainShaper(
        corridorReliefTolM: double.infinity,
        corridorCrossFallTolM: double.infinity);
    final city = devColony();
    final e = InMemoryTerrainEditsRepository();
    shape(city, e, coarse);
    final (_, relaid) = liveRoad(city, e, coarse);
    final m = meshOverRoad(city, e, relaid);
    expect(m.over, greaterThan(2.0),
        reason: 'the case is gone: meshed coarse, the ground stands only '
            '${m.over.toStringAsFixed(2)} m over the road');
    expect(m.level, lessThanOrEqualTo(13));
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('saved and loaded, the road is still cut to be meshed fine — though '
      'a load grades the colony in one call, where the pump\'s field is '
      'levelled beside it unseen', () {
    final city = devColony();
    final e = InMemoryTerrainEditsRepository();
    shape(city, e);
    final (built, relaid) = liveRoad(city, e, const CityTerrainShaper());
    // Held for the road as built and for the road it was re-laid as; only
    // the road still standing is saved.
    expect(city.fineCorridors.where((k) => k.startsWith('road:$built:')),
        isNotEmpty);
    final saved = {
      for (final k in city.fineCorridors)
        if (k.startsWith('road:$relaid:')) k,
    };
    expect(saved, isNotEmpty);

    final loaded = CitySim.fromJson(
        jsonDecode(jsonEncode(city.toJson())) as Map<String, dynamic>,
        bodies: bodies);
    expect(loaded.fineCorridors, saved,
        reason: 'the road re-laid over is gone; its segments are not saved');
    final fresh = InMemoryTerrainEditsRepository();
    shape(loaded, fresh);
    final corridors = [
      for (final b in fresh.forBody(earth.id)!.all)
        if (b.kind == TerrainBrushKind.cutFill && b.minVoxelM < 15) b,
    ];
    expect(corridors.length, saved.length,
        reason: 'every segment the road was cut fine through is cut fine '
            'again');
    expect(loaded.layout.roadById(relaid), isNotNull);

    // Without the saved judgement a one-call grading sees pristine ground
    // under the road and would mesh it at the colony's voxel.
    final forgot = CitySim.fromJson(
        (jsonDecode(jsonEncode(city.toJson())) as Map<String, dynamic>)
          ..remove('fineCorridors'),
        bodies: bodies);
    final again = InMemoryTerrainEditsRepository();
    shape(forgot, again);
    expect(
        again
            .forBody(earth.id)!
            .all
            .where((b) => b.kind == TerrainBrushKind.cutFill && b.minVoxelM < 15),
        isEmpty,
        reason: 'the case is gone: a load sees the relief without being told');
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('a colony laid in one call keeps the colony\'s voxel on every road: '
      'the starter kit and generated towns, brushes and refinement as '
      'before', () {
    for (final (name, city) in [
      ('starter kit', devColony()),
      for (final blocks in [2, 4])
        (
          'generated, $blocks blocks',
          const CityGenerator().generate(
              CityGenSpec(seed: 2, blocksAcross: blocks),
              bodies: bodies),
        ),
    ]) {
      final e = InMemoryTerrainEditsRepository();
      shape(city, e);
      final body = system.body(city.body.id)!;
      final corridors = [
        for (final b in e.forBody(body.id)!.all)
          if (b.kind == TerrainBrushKind.cutFill) b,
      ];
      expect(corridors, isNotEmpty, reason: name);
      expect(corridors.where((b) => b.minVoxelM != 15), isEmpty,
          reason: '$name: a road cut fine');
      expect(city.fineCorridors, isEmpty, reason: name);

      // The work the renderer is asked for is what it was: the same
      // merged targets as the shaper that never refines a road.
      final plain = InMemoryTerrainEditsRepository();
      final twin = name == 'starter kit'
          ? devColony()
          : const CityGenerator().generate(
              CityGenSpec(
                  seed: 2, blocksAcross: name.contains('4') ? 4 : 2),
              bodies: bodies);
      shape(
          twin,
          plain,
          const CityTerrainShaper(
              corridorReliefTolM: double.infinity,
              corridorCrossFallTolM: double.infinity));
      final a = rendered(city, e, 108), b = rendered(twin, plain, 108);
      expect(a.targets.length, b.targets.length, reason: name);
      expect(a.leaves.length, b.leaves.length, reason: name);

      // And each leaf is meshed at the resolution it always was: a
      // colony's brushes at its own voxel are still judged on the datum
      // ([colonyEditResolutionFor], the one call TerrainNodes meshes a leaf
      // at). Judged on the ground, the generated towns' leaves were boosted
      // — 38 and 47 of them — and their triangles in view doubled.
      final r = a.field.radius;
      var boosted = 0;
      for (final k in a.leaves) {
        final res =
            colonyEditResolutionFor(k, r, resolution, a.near, maxBoost: boost);
        expect(res, datumResolution(k, r, a.near),
            reason: '$name: leaf $k meshed at a new resolution');
        if (res > resolution) boosted++;
      }
      // ignore: avoid_print
      print('$name: ${a.targets.length} targets, ${a.leaves.length} leaves, '
          '$boosted boosted');
    }

    // And that is the renderer's choice, not a copy of it: TerrainNodes
    // meshes every leaf at colonyEditResolutionFor and makes no call of its
    // own — one that judged every brush on the ground passed every test
    // here while the renderer doubled a town's triangles.
    final nodes =
        File('lib/infrastructure/flutter_scene/terrain/terrain_nodes.dart');
    expect(nodes.existsSync(), isTrue, reason: 'run from the package root');
    final src = nodes.readAsStringSync();
    expect(src.contains('colonyEditResolutionFor('), isTrue,
        reason: 'TerrainNodes no longer meshes at colonyEditResolutionFor');
    expect(RegExp(r'(?<![A-Za-z])editResolutionFor\(').hasMatch(src), isFalse,
        reason: 'TerrainNodes chooses a leaf\'s resolution by a call of its '
            'own, which no test holds');
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('a colony graded at a finer voxel than the world tick\'s — the city '
      'studio\'s slider — draws its streets on their 6 m points: fine is the '
      'shaper\'s judgement, not the voxel its brushes ask for', () {
    const studio = CityTerrainShaper(voxelM: 5);
    final city = devColony();
    final e = InMemoryTerrainEditsRepository();
    shape(city, e, studio);
    final corridors = [
      for (final b in e.forBody(earth.id)!.all)
        if (b.kind == TerrainBrushKind.cutFill) b,
    ];
    expect(corridors, isNotEmpty);
    expect(corridors.every((b) => b.minVoxelM == 5 && !b.squareStart), isTrue);
    expect(city.fineCorridors, isEmpty);
    final snap = WorldSnapshot.capture(1, InMemoryVesselRepository(const []),
        system: system,
        cities: InMemoryCityRepository([city]),
        terrainEdits: e);
    expect(snap.roads, isNotEmpty);
    for (final r in snap.roads) {
      expect(r.points.length ~/ 3,
          city.layout.roadById(r.id!)!.sample(stepM: 6).length,
          reason: '${r.id} drawn as a fine corridor');
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('behind a square start the ground is eased the same all the way '
      'across the carriageway; behind a round one it rises to the kerbs', () {
    final r = earth.radius;
    final dir = const Vector3(0.31, 0.42, -0.85).normalized;
    final seed = dir.x.abs() < 0.9 ? Vector3.unitX : Vector3.unitY;
    final along = seed.cross(dir).normalized;
    final across = dir.cross(along);
    final up = r + 479;
    TerrainBrush corridor({required bool square}) => TerrainBrush.cutFill(
          startBF: dir * up,
          endBF: (dir * r + along * 24).normalized * up,
          radiusM: 6,
          datumRadiusM: up,
          datumRadiusEndM: up + 2,
          falloffM: 6,
          minVoxelM: 2,
          squareStart: square,
        );
    // The ground 8 m behind the start, 2 m under its datum (a segment
    // climbing into it), on the centreline and 0.9 of the core out: in the
    // easing, where a round start's weight falls with distance from its
    // start and a square one's with distance behind it.
    double ground(TerrainBrush b, double side) {
      final p = (dir * r + along * -8 + across * side).normalized * (up - 2);
      // A density of 0 at the point: the ground runs through it.
      return b.apply(0, p);
    }

    final square = corridor(square: true), round = corridor(square: false);
    expect(ground(square, 5.4), closeTo(ground(square, 0), 1e-6));
    expect(ground(square, -5.4), closeTo(ground(square, 0), 1e-6));
    expect((ground(round, 5.4) - ground(round, 0)).abs(), greaterThan(0.05),
        reason: 'the case is gone: a round start is flat across too');
    // Ahead of its start the two are the same corridor.
    final p = (dir * r + along * 10 + across * 3).normalized * (up - 1);
    expect(square.apply(0, p), round.apply(0, p));
  });

  test('the tool roads\' refinement is bounded: a handful of targets and '
      'leaves over the town without them', () {
    final city = devColony();
    final e = InMemoryTerrainEditsRepository();
    shape(city, e);
    final before = rendered(city, e, 108);
    liveRoad(city, e, const CityTerrainShaper());
    final after = rendered(city, e, 108);
    // Measured: 2 -> 5 targets, 819 -> 858 leaves, none deeper than 16.
    expect(after.targets.length - before.targets.length, lessThanOrEqualTo(12));
    expect(after.leaves.length - before.leaves.length, lessThanOrEqualTo(80));
    expect(after.leaves.map((k) => k.level).reduce(math.max),
        lessThanOrEqualTo(17),
        reason: 'refined no deeper than a road needs');
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('a deep chunk under a brush on a site hundreds of metres above its '
      'datum is meshed at the brush\'s voxel', () {
    // The renderer's boost test measured a brush against the chunk's
    // centre on the DATUM sphere: from a site 479 m up, every chunk
    // smaller than that — a road's level-16 leaf, ~90 m — was "not under"
    // the brush on it, and was meshed at a quarter of the resolution its
    // refinement had been sized for.
    final r = earth.radius;
    final dir = const Vector3(0.31, 0.42, -0.85).normalized;
    final up = r + 479;
    final road = TerrainBrush.cutFill(
      startBF: dir * up,
      endBF: (dir + Vector3(0, 0.000002, 0)).normalized * up,
      radiusM: 4,
      datumRadiusM: up,
      datumRadiusEndM: up,
      falloffM: 6,
      minVoxelM: 2,
    );
    final level = levelForVoxelSize(dir, r, resolution * boost, 2);
    final leaf = chunkAt(dir, level);
    expect(leaf.circumradiusM(r), lessThan(479),
        reason: 'the case needs a chunk smaller than the site\'s height');
    expect(editResolutionFor(leaf, r, resolution, [road], maxBoost: boost),
        resolution * boost);
    // The same brush on the datum answers the same.
    final onDatum = TerrainBrush.cutFill(
      startBF: dir * r,
      endBF: (dir + Vector3(0, 0.000002, 0)).normalized * r,
      radiusM: 4,
      datumRadiusM: r,
      datumRadiusEndM: r,
      falloffM: 6,
      minVoxelM: 2,
    );
    expect(editResolutionFor(leaf, r, resolution, [onDatum], maxBoost: boost),
        resolution * boost);
  });
}
