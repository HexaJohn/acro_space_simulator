// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/city_terrain_shaper.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

/// The shaper's brushes have to reach the GROUND.
///
/// Every [TerrainBrush] culls samples outside its own bounding radius, which
/// for a building pad is tens of metres. A body's ground sits hundreds of
/// metres off its datum sphere — 885 m below it at a typical lunar site — so a
/// brush anchored on the datum had every ground sample fall outside that bound.
/// `apply` returned the density untouched and the brush did nothing at all:
/// pads never levelled their lots, road corridors were never graded, and the
/// colony sat on raw relief with its roads clipping through it.
///
/// These tests assert the OUTCOME on real terrain, not the anchoring, so they
/// stay true however the brushes are later reshaped.
void main() {
  final system = SampleWorld.realSystem();
  final moon = system.body(const BodyId('moon'))!;

  ({CitySim city, InMemoryTerrainEditsRepository repo}) colonyOnRelief() {
    final city = CitySim.found(
      const CityConfig(
          bodyId: 'moon', gridSize: 20, latitude: 12.5, longitude: 41.3),
      bodies: system.all.where((b) => !b.isStar).toList(),
      id: 'shape',
    );
    city.commitRoad(const [Vec2(-200, 0), Vec2(200, 0)], RoadClass.street);
    return (city: city, repo: InMemoryTerrainEditsRepository());
  }

  double groundWith(InMemoryTerrainEditsRepository repo, Vector3 dir) {
    final f = moon.terrainFieldWith(repo.forBody(moon.id));
    return f == null ? moon.radius : f.groundRadiusAt(dir.x, dir.y, dir.z);
  }

  void shape(CitySim city, InMemoryTerrainEditsRepository repo) {
    const shaper = CityTerrainShaper();
    for (final p in shaper.pending(city,
        bodyRadiusM: moon.radius,
        groundRadiusAt: (d) => groundWith(repo, d))) {
      repo.record(moon.id, p.brush);
      city.shapedTerrain.add(p.key);
    }
  }

  test('the site really does sit far off the datum sphere', () {
    // The premise the bug turned on. If a body's ground ever coincided with its
    // datum the fault would have been invisible.
    final c = colonyOnRelief();
    final dir = c.city
        .localToBodyFixed(const Vec2(0, 0), bodyRadiusM: moon.radius)
        .normalized;
    expect((groundWith(c.repo, dir) - moon.radius).abs(), greaterThan(100),
        reason: 'ground is hundreds of metres off the datum here');
  });

  test('a built lot is levelled across its WHOLE area', () {
    final c = colonyOnRelief();
    shape(c.city, c.repo); // roads first, as the player draws them
    final lot = c.city.layout.autoParcels
        .firstWhere((l) => l.centroid.e.abs() < 70);
    c.city.parcelBuildings[lot.id] =
        kUtilCatalog.firstWhere((s) => s.label == 'Clinic');

    Vector3 dirOf(Vec2 p) =>
        c.city.localToBodyFixed(p, bodyRadiusM: moon.radius).normalized;

    // Real relief across the lot before anything is cut.
    var lo = double.infinity, hi = -double.infinity;
    for (final v in lot.polygon) {
      final r = groundWith(c.repo, dirOf(v));
      if (r < lo) lo = r;
      if (r > hi) hi = r;
    }
    final relief = hi - lo;
    expect(relief, greaterThan(2),
        reason: 'the lot must straddle real relief for this to mean anything');

    shape(c.city, c.repo); // now the pad

    final centre = groundWith(c.repo, dirOf(lot.centroid));
    for (final v in lot.polygon) {
      expect((groundWith(c.repo, dirOf(v)) - centre).abs(), lessThan(0.05),
          reason: 'lot corner still ${relief.toStringAsFixed(1)} m of relief '
              'away from its own centre — the pad did not level it');
    }
  });

  test('a road corridor is actually graded', () {
    final c = colonyOnRelief();
    Vector3 dirOf(Vec2 p) =>
        c.city.localToBodyFixed(p, bodyRadiusM: moon.radius).normalized;
    final probes = <Vec2>[
      for (var e = -60.0; e <= 60.0; e += 20.0) Vec2(e, 0.0)
    ];
    final natural = [for (final p in probes) groundWith(c.repo, dirOf(p))];

    shape(c.city, c.repo);

    // The graded surface must DIFFER from the raw hillside somewhere along the
    // corridor; a no-op brush leaves it identical.
    var moved = 0.0;
    for (var i = 0; i < probes.length; i++) {
      final d = (groundWith(c.repo, dirOf(probes[i])) - natural[i]).abs();
      if (d > moved) moved = d;
    }
    // A no-op brush leaves `moved` at exactly 0, so the bound only needs to
    // clear float noise — not pin how hilly this particular site happens to
    // be. The natural relief here shifts whenever the procedural crater field
    // is corrected (it did when the crater lattice window and complex-crater
    // rims were fixed), and a site-hilliness pin broke on exactly that.
    expect(moved, greaterThan(0.1), reason: 'the road corridor was not graded');
  });

  test('a building stands on FLAT ground even with neighbours either side', () {
    // The symptom this whole area is about. A lot pad used to be a disc
    // circumscribing the lot — 26 m across a 24 m lot spacing — so every pad
    // re-levelled its neighbours to its own datum and the last one emitted
    // won. A building then spanned a patchwork 5-7 m deep: flush at its
    // centre, buried at one corner, hanging in the air at another. Roads
    // looked fine throughout because a ribbon drapes over its own per-point
    // heights; a building is rigid and has to sit on one plane.
    final c = colonyOnRelief();
    shape(c.city, c.repo);
    final lots = c.city.layout.autoParcels
        .where((l) => l.centroid.e.abs() < 70)
        .take(4)
        .toList();
    expect(lots.length, 4, reason: 'need neighbours either side');
    for (final l in lots) {
      c.city.parcelBuildings[l.id] =
          kUtilCatalog.firstWhere((s) => s.label == 'Clinic');
    }
    shape(c.city, c.repo);

    final snap = WorldSnapshot.capture(
      1,
      InMemoryVesselRepository(const []),
      system: system,
      cities: InMemoryCityRepository([c.city]),
      terrainEdits: c.repo,
    );

    for (final lot in lots) {
      final b = snap.buildings['${c.city.id}/${lot.id}']!;
      final base = Vector3(b.px, b.py, b.pz).length;
      // Sample the ground under the building's own FOOTPRINT corners, which is
      // the rectangle it actually stands on.
      final f = lot.frontage;
      final along =
          f == null ? const Vec2(1, 0) : (f.$2 - f.$1).normalized;
      final away = along.perp;
      for (final sw in [-1.0, 1.0]) {
        for (final sd in [-1.0, 1.0]) {
          final corner = Vec2(
            lot.centroid.e +
                along.e * sw * b.siteWidthM / 2 +
                away.e * sd * b.siteDepthM / 2,
            lot.centroid.n +
                along.n * sw * b.siteWidthM / 2 +
                away.n * sd * b.siteDepthM / 2,
          );
          final dir = c.city
              .localToBodyFixed(corner, bodyRadiusM: moon.radius)
              .normalized;
          expect((groundWith(c.repo, dir) - base).abs(), lessThan(0.05),
              reason: 'lot ${lot.id}: a footprint corner is off its own pad');
        }
      }
    }
  });
}
