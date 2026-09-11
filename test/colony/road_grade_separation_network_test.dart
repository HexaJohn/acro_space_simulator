// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Connectivity and the road tool's decks: a road that passes over or under
/// another is not joined to it, so a viaduct does not serve the street it
/// crosses and a tunnel does not join the road above it.
library;

import 'package:acro_space_simulator/domain/colony/city/city_layout.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel_network.dart';
import 'package:acro_space_simulator/domain/colony/city/spatial_index.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const main = RoadSpline(id: 'main', controls: [Vec2(0, -150), Vec2(0, 150)]);
  // A spur from a point on `main`, 300 m east.
  const spurLine = [Vec2(0, 100), Vec2(300, 100)];
  RoadDeck level(double h, {bool piers = true, bool tunnel = false}) =>
      RoadDeck(
          startM: h,
          endM: h,
          startOffsetM: h,
          endOffsetM: h,
          structures: piers && !tunnel ? const [(0, 300)] : const [],
          tunnels: tunnel ? const [(0, 300)] : const []);

  bool rooted(RoadDeck? deck) {
    final layout = CityLayout()
      ..addRoad(main)
      ..addRoad(RoadSpline(id: 'spur', controls: spurLine, deck: deck));
    return ParcelNetwork.of(layout).roadRooted('spur');
  }

  test('a road that meets a street on its piers is not joined to it', () {
    expect(rooted(level(12)), isFalse);
    expect(rooted(null), isTrue, reason: 'the same road on the ground');
  });

  test('a tunnel does not join the road above it', () {
    expect(rooted(level(-12, tunnel: true)), isFalse);
  });

  test('a raised road whose end comes down to grade joins what it lands on',
      () {
    expect(
        rooted(const RoadDeck(
            startM: 0, endM: 12, endOffsetM: 12, structures: [(60, 300)])),
        isTrue);
  });

  test('the rule, point by point', () {
    final l = CityLayout()
      ..addRoad(const RoadSpline(id: 'flat', controls: [Vec2(0, 0), Vec2(100, 0)]))
      ..addRoad(RoadSpline(
          id: 'd12', controls: const [Vec2(0, 50), Vec2(100, 50)], deck: level(12)))
      ..addRoad(RoadSpline(
          id: 'd12b',
          controls: const [Vec2(0, 60), Vec2(100, 60)],
          deck: level(12)))
      ..addRoad(RoadSpline(
          id: 'd24', controls: const [Vec2(0, 70), Vec2(100, 70)], deck: level(24)))
      ..addRoad(RoadSpline(
          id: 'low',
          controls: const [Vec2(0, 80), Vec2(100, 80)],
          deck: level(1, piers: false)))
      ..addRoad(RoadSpline(
          id: 'piers3',
          controls: const [Vec2(0, 90), Vec2(100, 90)],
          deck: level(3)))
      ..addRoad(RoadSpline(
          id: 'cutting',
          controls: const [Vec2(0, 100), Vec2(100, 100)],
          deck: level(-4.6, piers: false)));
    IndexedRoad r(String id) => l.roadIndex.byId(id)!;
    bool apart(String a, String b) =>
        ParcelNetwork.gradeSeparated(r(a), 50, r(b), 50);
    expect(apart('flat', 'flat'), isFalse, reason: 'two roads on the ground');
    expect(apart('d12', 'd12b'), isFalse,
        reason: 'two decks at one height are one junction in the air');
    expect(apart('d12', 'd24'), isTrue);
    expect(apart('d12', 'flat'), isTrue, reason: 'on its piers');
    expect(apart('flat', 'd12'), isTrue, reason: 'either way round');
    expect(apart('low', 'flat'), isFalse, reason: 'a metre up is at grade');
    expect(apart('piers3', 'flat'), isTrue, reason: 'on piers, however low');
    expect(apart('cutting', 'flat'), isFalse,
        reason: 'a cutting is dug to the deck: the ground road meets it');
  });

  test('the network joins exactly the roads the layout gave a junction', () {
    // Laid through the layout's own crossing rule, each deck either cut
    // the street into a junction or passed it by; the network agrees.
    for (final (what, deck, meets) in [
      ('on low piers: passed over', level(3), false),
      ('in a cutting: a junction', level(-4.6, piers: false), true),
      ('in a tunnel: passed under', level(-12, tunnel: true), false),
      ('on the ground: a junction', null, true),
    ]) {
      final l = CityLayout()
        ..commitRoad(
            controls: const [Vec2(150, -150), Vec2(150, 150)],
            regenerateLots: false);
      final r = l.commitRoad(
          controls: const [Vec2(0, 0), Vec2(300, 0)],
          deck: deck,
          regenerateLots: false);
      expect(r.crossings.single.bridged, !meets, reason: what);
      expect(l.roads.length, meets ? 4 : 2, reason: what);
      // Rooted at the street's far end: the new road is served only
      // through the junction, if it has one.
      final net = ParcelNetwork.of(l, root: const Vec2(150, -150));
      final laid = l.roads.where((x) => x.id.startsWith('r1')).toList();
      expect(laid, isNotEmpty);
      for (final road in laid) {
        expect(net.roadRooted(road.id), meets, reason: '${road.id}, $what');
      }
    }
  });
}
