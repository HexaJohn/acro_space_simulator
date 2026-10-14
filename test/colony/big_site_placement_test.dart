// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:flutter_test/flutter_test.dart';

import 'factory_integration/factory_colony_fixture.dart';

/// Big-plant placement (found in the 2026-10-13 real-input playtest): a
/// Steel Mill's 1100 x 800 m site could not be placed ANYWHERE in the
/// starter town — near the streets it crossed one or a starter plot, and
/// further out the corners-only reach test called it unserved. These pin
/// the two fixes: the claim measures reach from the same probes the road
/// network serves by (edge midpoints included), and the ghost snaps a big
/// site's edge to a nearby curb.
/// Whether [l] holds a point within a micrometre of [v] (Vec2 has no ==).
bool _has(List<Vec2> l, Vec2 v) => l.any((p) => (p - v).length < 1e-6);

void main() {
  /// Every big plant the build menu offers can be staked in the starter
  /// town by pointing near its centre, the way a player places one.
  test('every big plant snaps to a placeable site in the starter town', () {
    for (final type in const [
      'steelmill', 'refinery', 'electronics', 'rocketfactory',
      'gunfactory', 'missilefactory', 'rationsfactory',
    ]) {
      final sim = foundedColony()..stock['ore'] = 1e4;
      final spec = specOf(type);
      Vec2? at;
      for (final cursor in const [
        Vec2(0, 0), Vec2(-400, 0), Vec2(400, 0), Vec2(0, 400), Vec2(0, -400),
      ]) {
        at = sim.snapSiteCentre(spec, cursor);
        if (at != null) break;
      }
      expect(at, isNotNull, reason: '$type found no site');
      final parcel = sim.claimSite(spec, at!);
      expect(parcel, isNotNull, reason: '$type: ${sim.blocked}');
      // What the claim accepts, the network serves: a plant staked as
      // reachable must not then read as cut off.
      expect(sim.parcelNetwork().lotServed(parcel!.id), isTrue,
          reason: '$type staked but unserved');
    }
  });

  /// The claim's reach probes are the network's: centre, corners and edge
  /// midpoints. A long edge flush along a street is in reach though every
  /// corner is far from the road's ends — the case corners-only refused.
  test('reach is probed from centre, corners and edge midpoints', () {
    const poly = [Vec2(0, 0), Vec2(1100, 0), Vec2(1100, 800), Vec2(0, 800)];
    final probes = CitySim.siteServeProbes(poly);
    expect(probes, hasLength(9));
    expect(_has(probes, const Vec2(550, 400)), isTrue, reason: 'centre');
    for (final m in const [
      Vec2(550, 0), Vec2(1100, 400), Vec2(550, 800), Vec2(0, 400),
    ]) {
      expect(_has(probes, m), isTrue, reason: 'edge midpoint $m');
    }
  });

  /// A cursor already on a placeable spot is not moved.
  test('a placeable cursor is kept as is', () {
    final sim = foundedColony();
    final spec = specOf('steelmill');
    final at = sim.snapSiteCentre(spec, const Vec2(-400, 0))!;
    expect(_has([sim.snapSiteCentre(spec, at)!], at), isTrue);
  });

  /// Same colony, same cursor, same plot: no hash order or float drift.
  test('the snap is deterministic', () {
    final a = foundedColony(), b = foundedColony();
    final spec = specOf('steelmill');
    final pa = a.snapSiteCentre(spec, const Vec2(-350, 120))!;
    final pb = b.snapSiteCentre(spec, const Vec2(-350, 120))!;
    expect([pa.e, pa.n], [pb.e, pb.n]);
  });
}
