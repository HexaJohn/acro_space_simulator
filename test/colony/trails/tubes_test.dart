// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';

import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/trails/trail_network.dart';
import 'package:acro_space_simulator/domain/colony/city/trails/trail_router.dart';
import 'package:flutter_test/flutter_test.dart';

/// docs/plans/desire-paths.md §9: a short walk wears a foot track, and a
/// beaten one becomes a tube, joined at both ends: never an island.
void main() {
  List<Vec2> box(double e, double n, double w, double d) =>
      [Vec2(e, n), Vec2(e + w, n), Vec2(e + w, n + d), Vec2(e, n + d)];

  /// Two dorms and a workshop on flat, airless ground; the walks between
  /// them are under [kWalkMaxM].
  TrailNetwork colony() {
    final net = TrailNetwork();
    net.sync(
      shapeKey: 1,
      dtS: 0,
      sites: () => [
        TrailSite('dorm-a', box(-150, -20, 40, 40), built: true),
        TrailSite('dorm-b', box(-150, 60, 40, 40), built: true),
        TrailSite('shop', box(60, 0, 50, 50), built: true),
      ],
      roads: () => const [],
      heightAt: (e, n) => 0,
    );
    return net;
  }

  void resync(TrailNetwork net, {double dtS = 0}) => net.sync(
        shapeKey: 1,
        dtS: dtS,
        sites: () => [
          TrailSite('dorm-a', box(-150, -20, 40, 40), built: true),
          TrailSite('dorm-b', box(-150, 60, 40, 40), built: true),
          TrailSite('shop', box(60, 0, 50, 50), built: true),
        ],
        roads: () => const [],
        heightAt: (e, n) => 0,
      );

  test('near doors are walked, far ones driven', () {
    final net = colony();
    final t = net.trip('dorm-a', 'shop',
        walkMps: kWalkSuitMps, vehicles: true)!;
    expect(t.walk, isTrue);
    expect(t.route.timeS, greaterThan(t.route.lengthM / kTubeMps));
    // Banned vehicles do not stop a walk.
    expect(net.trip('dorm-a', 'shop', walkMps: kWalkSuitMps, vehicles: false),
        isNotNull);
  });

  test('a beaten walk becomes a tube from door to door, and is quicker', () {
    final net = colony();
    final before =
        net.trip('dorm-a', 'shop', walkMps: kWalkSuitMps, vehicles: true)!;
    for (var k = 0; k < 12; k++) {
      final t =
          net.trip('dorm-a', 'shop', walkMps: kWalkSuitMps, vehicles: true)!;
      net.lay(t.route, foot: true);
    }
    // The look comes on its own cadence.
    resync(net, dtS: 61);
    final due = net.dueTubes();
    expect(due, hasLength(1));
    net.addTube(due.single);
    resync(net);
    expect(net.tubes, hasLength(1));
    // Walking it is the tube's pace, level and quick.
    final after =
        net.trip('dorm-a', 'shop', walkMps: kWalkSuitMps, vehicles: true)!;
    expect(after.route.timeS, lessThan(before.route.timeS * 0.75));
    // And it is saved.
    final back = TrailNetwork.fromJson(
        jsonDecode(jsonEncode(net.toJson())) as Map<String, dynamic>);
    expect(back.tubes, hasLength(1));
    expect(back.tubes.single.length, net.tubes.single.length);
  });

  test('a beaten stretch joined to nothing at one end is no tube', () {
    final net = colony();
    final t =
        net.trip('dorm-a', 'shop', walkMps: kWalkSuitMps, vehicles: true)!;
    final f = net.field!;
    // Wear only the middle of the walk: beaten, but leading nowhere.
    final cells = t.route.cells;
    final middle = cells.sublist(cells.length ~/ 3, 2 * cells.length ~/ 3);
    for (var k = 0; k < 12; k++) {
      f.lay(middle, foot: true);
    }
    net.lay(t.route, foot: true);
    resync(net, dtS: 61);
    expect(net.dueTubes(), isEmpty);
  });

  test('a second walk joins the first tube rather than standing alone', () {
    final net = colony();
    for (var k = 0; k < 12; k++) {
      net.lay(
          net.trip('dorm-a', 'shop', walkMps: kWalkSuitMps, vehicles: true)!
              .route,
          foot: true);
    }
    resync(net, dtS: 61);
    net.addTube(net.dueTubes().single);
    resync(net);
    // Dorm B's walk to the shop now runs onto the tube as soon as it can:
    // only its own stretch, from its door to the tube, is left to wear.
    for (var k = 0; k < 12; k++) {
      net.lay(
          net.trip('dorm-b', 'shop', walkMps: kWalkSuitMps, vehicles: true)!
              .route,
          foot: true);
    }
    resync(net, dtS: 61);
    final due = net.dueTubes();
    expect(due, isNotEmpty);
    final f = net.field!;
    for (final line in due) {
      // Each end at a door or on the first tube.
      for (final end in [line.first, line.last]) {
        final i = f.cellAt(end.e, end.n);
        final atDoor = ['dorm-a', 'dorm-b', 'shop'].any((s) {
          final d = net.doors[s]!;
          return f.cellAt(d.e, d.n) == i;
        });
        expect(atDoor || f.nearTube(i), isTrue,
            reason: 'an end at $end leads nowhere');
      }
    }
  });
}
