// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_layout.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel_network.dart';
import 'package:flutter_test/flutter_test.dart';

/// Connectivity on the road graph replaces the cell flood fill: roads join
/// where their carriageways touch, the network roots at the landing site, and
/// a lot is served when its frontage road traces back to the root.
void main() {
  test('a road through the landing site roots itself and serves its lots', () {
    final layout = CityLayout()
      ..addRoad(const RoadSpline(
          id: 'main', controls: [Vec2(0, -150), Vec2(0, 150)]));
    final net = ParcelNetwork.of(layout);

    expect(net.roadRooted('main'), isTrue);
    for (final lot in layout.autoParcels) {
      expect(net.lotServed(lot.id), isTrue);
    }
  });

  test('a detached road is not rooted and serves nothing', () {
    final layout = CityLayout()
      ..addRoad(const RoadSpline(
          id: 'main', controls: [Vec2(0, -150), Vec2(0, 150)]))
      ..addRoad(const RoadSpline(
          id: 'island', controls: [Vec2(2000, 2000), Vec2(2000, 2300)]));
    final net = ParcelNetwork.of(layout);

    expect(net.roadRooted('main'), isTrue);
    expect(net.roadRooted('island'), isFalse);
    for (final lot in layout.autoParcels.where((p) => p.roadId == 'island')) {
      expect(net.lotServed(lot.id), isFalse);
    }
  });

  test('a branch touching a rooted road roots transitively', () {
    final layout = CityLayout()
      ..addRoad(const RoadSpline(
          id: 'main', controls: [Vec2(0, -150), Vec2(0, 150)]))
      // Starts ON main's northern end, runs east.
      ..addRoad(const RoadSpline(
          id: 'branch', controls: [Vec2(0, 150), Vec2(200, 150)]))
      // And a third off the branch.
      ..addRoad(const RoadSpline(
          id: 'twig', controls: [Vec2(200, 150), Vec2(200, 300)]));
    final net = ParcelNetwork.of(layout);

    expect(net.roadRooted('branch'), isTrue);
    expect(net.roadRooted('twig'), isTrue);
  });

  test('with no road at the site, the nearest becomes the trunk', () {
    // The generous rule: a colony whose first road was drawn out in a field
    // must still root SOMETHING, or nothing it builds will ever work.
    final layout = CityLayout()
      ..addRoad(const RoadSpline(
          id: 'far', controls: [Vec2(500, 500), Vec2(500, 800)]));
    final net = ParcelNetwork.of(layout);
    expect(net.roadRooted('far'), isTrue);
  });

  test('manual lots are served by a rooted road passing near them', () {
    final layout = CityLayout()
      ..addRoad(const RoadSpline(
          id: 'main', controls: [Vec2(0, -150), Vec2(0, 400)]));
    final near = layout.addManualParcel(const [
      Vec2(50, 200),
      Vec2(130, 200),
      Vec2(130, 280),
      Vec2(50, 280),
    ])!;
    final far = layout.addManualParcel(const [
      Vec2(3000, 3000),
      Vec2(3100, 3000),
      Vec2(3100, 3100),
      Vec2(3000, 3100),
    ])!;
    final net = ParcelNetwork.of(layout);

    expect(net.lotServed(near.id), isTrue);
    expect(net.lotServed(far.id), isFalse);
  });

  test('an empty layout serves nothing and does not throw', () {
    final net = ParcelNetwork.of(CityLayout());
    expect(net.rootedRoads, isEmpty);
    expect(net.servedLots, isEmpty);
  });
}
