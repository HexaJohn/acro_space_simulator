// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';
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
/// [editResolutionFor] by the CPU mesher, the ground under a point read off
/// the triangles ([radialHitOnCell]).
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

  /// How far the meshed ground stands over road [id]'s drawn centreline at
  /// its worst, sampled every half metre; the share of those samples where
  /// it stands over the ribbon ([ribbonLiftM]) — where grass shows through
  /// the carriageway — and the level and resolution its worst leaf was
  /// meshed at. The mesh is read on the leaf under each point and the
  /// leaves across its edges: their aprons and skirts overlap it.
  ({double over, double shows, int level, int res}) meshOverRoad(
      CitySim city, InMemoryTerrainEditsRepository e, String id) {
    final g = rendered(city, e, 108);
    final cells = <ChunkKey, CellMesh>{};
    int resOf(ChunkKey k) =>
        editResolutionFor(k, g.field.radius, resolution, g.near,
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
    var over = double.negativeInfinity;
    var at = pts.first.normalized;
    var samples = 0, showing = 0;
    for (var k = 0; k + 1 < pts.length; k++) {
      final a = pts[k], b = pts[k + 1];
      final steps = math.max(1, ((b - a).length / 0.5).ceil());
      for (var j = 0; j < steps; j++) {
        final p = a + (b - a) * (j / steps);
        final m = meshR(p.normalized);
        if (m == null) continue;
        samples++;
        if (m - p.length > ribbonLiftM) showing++;
        if (m - p.length > over) {
          over = m - p.length;
          at = p.normalized;
        }
      }
    }
    final leaf = leafCovering(g.leaves, chunkAt(at, 22))!;
    return (
      over: over,
      shows: samples == 0 ? 1.0 : showing / samples,
      level: leaf.level,
      res: resOf(leaf),
    );
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

  test('the live one-way is meshed where it is drawn — as built, and '
      're-laid through the edge of the pump\'s field', () {
    final city = devColony();
    final e = InMemoryTerrainEditsRepository();
    shape(city, e);
    ({double over, double shows, int level, int res})? asBuilt;
    final (_, relaid) = liveRoad(city, e, const CityTerrainShaper(),
        built: (id) => asBuilt = meshOverRoad(city, e, id));
    final after = meshOverRoad(city, e, relaid);
    // Measured: 0.06 m as built and 0.12 m re-laid at their worst, both in
    // level-16 leaves at resolution 96 (1.9 m voxels), and no half metre of
    // either with ground over the ribbon; before, 4.6 m in a level-13 leaf.
    for (final (name, m) in [('as built', asBuilt!), ('re-laid', after)]) {
      expect(m.over, lessThan(0.15),
          reason: '$name: the ground is meshed ${m.over.toStringAsFixed(2)} '
              'm over the road\'s centreline (level ${m.level}, resolution '
              '${m.res})');
      expect(m.shows, lessThanOrEqualTo(0.01),
          reason: '$name: grass over the ribbon along '
              '${(m.shows * 100).toStringAsFixed(1)}% of the road');
    }

    // Its corridor asked for it: finer than the colony's 15 m where it cuts.
    final fine = [
      for (final k in city.fineCorridors)
        if (k.startsWith('road:$relaid:')) k,
    ];
    expect(fine, isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 5)));

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
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

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
