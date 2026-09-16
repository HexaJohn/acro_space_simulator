// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/city_starter_kit.dart';
import 'package:acro_space_simulator/domain/colony/city/city_terrain_shaper.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_grade.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_brush.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

/// The shaper's site access corridors (docs/plans/site-access.md §6.3, the
/// §8.3 R5 list): a site's drive is cut into the ground the way a road
/// corridor is, at the plan's own heights, once, keyed, and only where there
/// is something to cut.
///
/// Flat ground here on purpose — the numbers below are about WHICH sites
/// get a corridor, not how deep it is. The heights are the probe's
/// (test/application/site_ground_probe_test.dart), on the dev colony's real
/// hillside.
void main() {
  final system = SampleWorld.realSystem();
  final earth = system.body(const BodyId('earth'))!;
  final bodies = system.all.where((b) => !b.isStar).toList();
  const shaper = CityTerrainShaper();

  CitySim kit() => CityStarterKit.found(
        bodies: bodies,
        config: const CityConfig(
            bodyId: 'earth', latitude: -45.03, longitude: 168.66),
        id: 'city-kit',
      );

  /// [pending] over ground that is flat at the datum, so nothing is cut for
  /// relief and only the geometric rules of §6.3 decide.
  List<({String key, TerrainBrush brush})> flatPending(CitySim city,
      {void Function(Vector3)? onAsk}) {
    return shaper.pending(city, bodyRadiusM: earth.radius, groundRadiusAt: (d) {
      onAsk?.call(d);
      return earth.radius;
    });
  }

  void record(CitySim city, List<({String key, TerrainBrush brush})> ps) {
    for (final p in ps) {
      CityTerrainShaper.markShaped(city, p.key, p.brush);
    }
  }

  List<String> corridorKeys(List<({String key, TerrainBrush brush})> ps) =>
      [for (final p in ps) if (p.key.startsWith('site:')) p.key];

  List<String> siteKeys(List<({String key, TerrainBrush brush})> ps) => [
        for (final p in ps)
          if (p.key.startsWith('site:') || p.key.startsWith('sitepad:')) p.key,
      ];

  test('the starter kit adds exactly four corridor runs, one per utility site',
      () {
    final city = kit();
    final ps = flatPending(city);
    final runs = corridorKeys(ps);
    expect(runs.length, 4, reason: 'one throat per utility site: $runs');
    expect(
        [for (final k in runs) k.split(':')[1]]..sort(),
        ['lot-m0', 'lot-m1', 'lot-m2', 'lot-m3'],
        reason: 'the spaceport, the solar farm, the farm and the pump');
    // Each is keyed by its plan revision and its segment (§6.3).
    for (final k in runs) {
      final parts = k.split(':');
      expect(parts.length, 4, reason: k);
      expect(parts[2], matches(RegExp(r'^[0-9a-f]{8}$')), reason: k);
      final plan = city.siteAccess.planOf(parts[1])!;
      expect(parts[2], SiteGrade.corridorKey(parts[1], plan.rev, 0).split(':')[2],
          reason: 'keyed by the plan revision: $k');
    }
  });

  test('a corridor is emitted once and re-shaping the same site changes nothing',
      () {
    final city = kit();
    final first = flatPending(city);
    expect(corridorKeys(first), hasLength(4));
    record(city, first);
    expect(flatPending(city), isEmpty, reason: 'nothing is cut twice');
    // Idempotent even with the O(1) gate forced open.
    city.siteShapedRev = -1;
    expect(corridorKeys(flatPending(city)), isEmpty);
    // And with the settled set dropped too: the keys are already shaped.
    city.shapedSites.clear();
    expect(corridorKeys(flatPending(city)), isEmpty);
  });

  test('the datums the capture reads are recorded', () {
    final city = kit();
    final ps = flatPending(city);
    record(city, ps);
    for (final id in ['lot-m0', 'lot-m1', 'lot-m2', 'lot-m3']) {
      expect(city.padDatums[SiteGrade.padKey(id)], isNotNull,
          reason: '$id has a pad datum');
      final plan = city.siteAccess.planOf(id)!;
      final key = SiteGrade.corridorKey(id, plan.rev, 0);
      final datums = city.corridorDatums[key];
      expect(datums, isNotNull, reason: '$id has corridor datums');
      // Flat ground: the whole ramp is one height, the pad's.
      expect(datums!.$1, closeTo(earth.radius, 1e-6));
      expect(datums.$2, closeTo(earth.radius, 1e-6));
      expect(city.padDatums[SiteGrade.padKey(id)], closeTo(earth.radius, 1e-6));
    }
  });

  test('a corridor asks the ground at most twice per new segment', () {
    final city = kit();
    // Settle the pads and the roads first, with every site held back.
    for (final chunk in city.siteAccess.chunks) {
      for (var k = 0; k < chunk.siteCount; k++) {
        city.shapedSites.add(SiteGrade.runKey(chunk.siteId(k), chunk.rev(k)));
      }
    }
    record(city, flatPending(city));
    // Now let the sites through, and count what they ask.
    city.shapedSites.clear();
    city.siteShapedRev = -1;
    final asked = <Vector3>{};
    final ps = flatPending(city, onAsk: asked.add);
    final segs = corridorKeys(ps).length;
    expect(segs, 4);
    expect(asked.length, lessThanOrEqualTo(2 * segs),
        reason: 'at most two ground reads per new segment (§6.3): '
            '${asked.length} for $segs');
  });

  test('a draped lot and the sprawl add nothing', () {
    final city = kit();
    // Every auto lot in the kit is graded; make them draped and the site
    // section must have nothing left but the manual parcels.
    for (final p in city.layout.autoParcels) {
      expect(p.graded, isTrue, reason: 'the kit plats graded lots');
    }
    final town = const CityGenerator().generate(
        const CityGenSpec(blocksAcross: 2, seed: 1, sprawlMiles: 2),
        bodies: bodies);
    town.siteAccess.sync(town, town.roadGraph,
        maxUnits: 1 << 30, maxChecks: 1 << 30);
    final ps = flatPending(town);
    for (final k in siteKeys(ps)) {
      final id = k.split(':')[1];
      final parcel = town.layout.parcelById(id);
      expect(parcel?.graded, isTrue,
          reason: 'only a graded lot is cut for: $k');
    }
    // No sprawl lot is cut: they are draped.
    expect(
        [
          for (final k in siteKeys(ps))
            if (town.layout.parcelById(k.split(':')[1])?.graded != true) k,
        ],
        isEmpty);
  });

  test('a generated graded downtown block on flat ground adds no site brushes',
      () {
    final town = const CityGenerator().generate(
        const CityGenSpec(blocksAcross: 2, seed: 1, sprawlMiles: 2),
        bodies: bodies);
    town.siteAccess.sync(town, town.roadGraph,
        maxUnits: 1 << 30, maxChecks: 1 << 30);
    final ps = flatPending(town);
    final platted = {for (final p in town.layout.autoParcels) p.id};
    expect(platted, isNotEmpty);
    expect([for (final k in siteKeys(ps)) if (platted.contains(k.split(':')[1])) k],
        isEmpty,
        reason: 'a downtown drive crosses only its pavement, and on flat '
            'ground its pad and its kerb are one height (§6.3)');
    // What IS cut is only set-back manual sites, whose throats cross a whole
    // row of lots (§3.7a) — the same rule the starter kit's four meet.
    for (final k in corridorKeys(ps)) {
      final id = k.split(':')[1];
      expect(platted.contains(id), isFalse, reason: k);
      expect(town.layout.parcelById(id)?.graded, isTrue, reason: k);
    }
  });
}
