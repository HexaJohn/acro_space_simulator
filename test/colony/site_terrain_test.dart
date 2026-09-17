// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/city_starter_kit.dart';
import 'package:acro_space_simulator/domain/colony/city/city_terrain_shaper.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_plan.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_grade.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/terrain/terrain_brush.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

import 'site_access/site_plan_fixtures.dart';

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

  test('the capture is told which sites were cut, and at which revision', () {
    final city = kit();
    flatPending(city);
    // The four utility sites, each at its plan's own revision: what a
    // rebuilt chunk tests before it builds a corridor run at all (§6.4).
    final cut = city.siteCutRev;
    expect(cut.keys.toList()..sort(), ['lot-m0', 'lot-m1', 'lot-m2', 'lot-m3']);
    for (final id in cut.keys) {
      expect(cut[id], city.siteAccess.planOf(id)!.rev, reason: id);
    }
    // And no house lot with a driveway: on flat ground its drive crosses
    // only its pavement, and nothing was cut for it.
    for (final p in city.layout.autoParcels) {
      expect(cut.containsKey(p.id), isFalse, reason: p.id);
    }
  });

  test('the pad re-cut leaves no entry in padDatums but the pad itself does',
      () {
    final city = kit();
    record(city, flatPending(city));
    expect(
        [for (final k in city.padDatums.keys) if (!k.startsWith('pad:')) k],
        isEmpty,
        reason: 'the site section re-cuts the same platform under a key of '
            'its own, and nothing reads it back');
    for (final id in ['lot-m0', 'lot-m1', 'lot-m2', 'lot-m3']) {
      expect(city.padDatums[SiteGrade.padKey(id)], isNotNull, reason: id);
    }
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

  group('the corridor run', () {
    final city = SyntheticSites.starterCity();
    final graph = city.roadGraph;

    test('takes its kerb end from the ramp, whichever way the plan stores '
        'its drive', () {
      // The shaper asks the ground for the corridor's KERB datum at this
      // point (§6.3 as built). A plan is free to store a drive running from
      // its pad out to the street — nothing in §2.3 fixes the direction —
      // and the ground under the wrong end would grade the whole corridor
      // backwards, by the depth of the platform.
      final draft =
          SyntheticSites.draftAt(graph, 'lot-m3', SyntheticTemplate.utility);
      final forward = SiteCorridorRun.of(
          SyntheticSites.chunkOf(graph, [draft], validate: false).plan(0))!;
      final plan =
          SyntheticSites.chunkOf(graph, [draft], validate: false).plan(0);
      final kerbNode = plan.joinKerbNode(0);
      final kerbPt = plan.nodePt(kerbNode);
      expect(forward.kerbAt.e, closeTo(plan.ptE(kerbPt), 1e-9));
      expect(forward.kerbAt.n, closeTo(plan.ptN(kerbPt), 1e-9));

      // The same drive, stored the other way about.
      for (final seg in draft.segs) {
        if (seg.kind != SiteSegmentKind.driveway &&
            seg.kind != SiteSegmentKind.accessRoad) {
          continue;
        }
        final from = seg.from;
        seg.from = seg.to;
        seg.to = from;
        seg.vias = seg.vias.reversed.toList();
      }
      final back = SiteCorridorRun.of(
          SyntheticSites.chunkOf(graph, [draft], validate: false).plan(0))!;
      expect(back.kerbAt.e, closeTo(forward.kerbAt.e, 1e-9),
          reason: 'the kerb end is the kerb end either way');
      expect(back.kerbAt.n, closeTo(forward.kerbAt.n, 1e-9));
      // And the grade still runs from the kerb down to the pad.
      final (d0, d1) = back.datumsOf(0, 100, 180);
      final (f0, f1) = forward.datumsOf(0, 100, 180);
      expect(d0, closeTo(f1, 1e-9));
      expect(d1, closeTo(f0, 1e-9));
    });

    test("§6.3's off-parcel clause is measured per segment, not summed over "
        'the run', () {
      // A through drive that leaves its lot in two short stubs — three
      // metres each, the pavement it crosses — and nothing between them.
      // Summed, that is six metres and over the clause; §6.3 asks it of
      // "the segment", and neither stub is.
      final chunk =
          SyntheticSites.placeAt(graph, 'lot-r0x1-r0', SyntheticTemplate.loop);
      const lot = Parcel(
        id: 'stub-lot',
        polygon: [Vec2(-7, 7), Vec2(-7, 60), Vec2(-40, 60), Vec2(-40, 7)],
        manual: true,
      );
      final run = SiteCorridorRun.of(chunk.plan(0), parcel: lot)!;
      expect(run.length, 2);
      for (final off in run.segOffParcelM) {
        expect(off, closeTo(3.0, 0.3));
      }
      expect(run.segOffParcelM.reduce((a, b) => a + b), greaterThan(3.5),
          reason: 'summed, this run would be cut');
      // What `CityTerrainShaper._siteCorridors` tests against
      // max(sidewalkM + 0.5, 3.0) = 3.5 m on the kit's streets.
      expect(run.maxSegOffParcelM, lessThanOrEqualTo(3.5),
          reason: 'per segment, it is not');
    });
  });
}
