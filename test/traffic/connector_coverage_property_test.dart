// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_layout.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_graph_builder.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_rng.dart';
import 'package:flutter_test/flutter_test.dart';

/// The promise the connector rules make to the router (docs/plans/
/// agent-traffic.md §3.5, §17.2): a new trip, free to enter any lane of its
/// first edge, can drive ANY sequence of edges the router can return. So
/// there is no lane-infeasible route, and no retry loop to find a feasible
/// one.
///
/// Checked on random towns: grids of random sizes and spacings, every road a
/// random class — streets, avenues, six-lane roads, one-way streets both
/// ways, highways, alleys — dressed at random where the class allows it.
void main() {
  const towns = 25;
  const routesPerTown = 20;

  test('every lane of every movement is fed from the edge before it', () {
    var movements = 0;
    for (var seed = 1; seed <= towns; seed++) {
      final lg = _randomTown(TrafficRng(seed));
      for (var e = 0; e < lg.edgeCount; e++) {
        final base = lg.edgeLaneBase[e], n = lg.edgeLaneCount[e];
        final hasMove = lg.moveStart[e + 1] > lg.moveStart[e];
        // Every in-lane makes some movement when the edge makes any.
        for (var k = 0; k < n; k++) {
          final l = base + k;
          expect(lg.laneConStart[l + 1] > lg.laneConStart[l], hasMove,
              reason: 'town $seed edge $e lane $k');
        }
        for (var i = lg.moveStart[e]; i < lg.moveStart[e + 1]; i++) {
          final o = lg.moveOut[i];
          movements++;
          for (var k = 0; k < lg.edgeLaneCount[o]; k++) {
            final target = lg.laneOf(o, k);
            var fed = false;
            for (var c = lg.laneConStart[base];
                c < lg.laneConStart[base + n] && !fed;
                c++) {
              fed = lg.conToLane[c] == target;
            }
            expect(fed, isTrue,
                reason: 'town $seed: movement $e -> $o leaves lane $k unfed');
          }
        }
      }
    }
    expect(movements, greaterThan(towns * 20));
  });

  test('no route the router could return is undrivable from a free start',
      () {
    var cases = 0;
    for (var seed = 1; seed <= towns; seed++) {
      final rng = TrafficRng(1000 + seed);
      final lg = _randomTown(TrafficRng(seed));
      for (var r = 0; r < routesPerTown; r++) {
        // A random walk along the movements: every sequence a router can
        // return is one of these.
        final route = <int>[rng.nextInt(lg.edgeCount)];
        final len = 1 + rng.nextInt(8);
        while (route.length < len) {
          final e = route.last;
          final m = lg.moveStart[e + 1] - lg.moveStart[e];
          if (m == 0) break;
          route.add(lg.moveOut[lg.moveStart[e] + rng.nextInt(m)]);
        }
        // Arriving at the right kerb, at a left-hand driveway, or passing
        // through.
        final last = route.last;
        final nLast = lg.edgeLaneCount[last];
        final want = switch (rng.nextInt(3)) {
          0 => {0},
          1 => {nLast - 1},
          _ => {for (var k = 0; k < nLast; k++) k},
        };
        // Backwards: the lanes of each edge that reach an acceptable lane of
        // the next.
        var ok = {for (final k in want) lg.laneOf(last, k)};
        for (var i = route.length - 2; i >= 0; i--) {
          final e = route[i];
          final base = lg.edgeLaneBase[e];
          final prev = <int>{};
          for (var k = 0; k < lg.edgeLaneCount[e]; k++) {
            for (var c = lg.laneConStart[base + k];
                c < lg.laneConStart[base + k + 1];
                c++) {
              if (ok.contains(lg.conToLane[c])) prev.add(base + k);
            }
          }
          expect(prev, isNotEmpty,
              reason: 'town $seed route $route: no lane of edge $e reaches '
                  'the lanes needed on ${route[i + 1]}');
          ok = prev;
        }
        cases++;
      }
    }
    expect(cases, towns * routesPerTown);
  });
}

/// A random grid town, seeded by [rng].
LaneGraph _randomTown(TrafficRng rng) {
  const classes = [
    RoadClass.street,
    RoadClass.street,
    RoadClass.avenue,
    RoadClass.boulevard,
    RoadClass.streetOneWay,
    RoadClass.motorway,
    RoadClass.alley,
  ];
  final layout = CityLayout();
  final n = 2 + rng.nextInt(3);
  final spacing = 150.0 + rng.nextInt(120);
  final half = (n - 1) * spacing / 2;
  final lo = -half - spacing / 2, hi = half + spacing / 2;
  for (var i = 0; i < n; i++) {
    final at = -half + i * spacing;
    for (final vertical in [true, false]) {
      final cls = classes[rng.nextInt(classes.length)];
      final deco = cls.supportsDecoration
          ? RoadDecoration.values[rng.nextInt(RoadDecoration.values.length)]
          : RoadDecoration.none;
      layout.commitRoad(
        controls: vertical ? [Vec2(at, lo), Vec2(at, hi)] : [Vec2(lo, at), Vec2(hi, at)],
        roadClass: cls,
        decoration: deco,
        reversed: cls.oneWay && rng.nextInt(2) == 0,
        regenerateLots: false,
      );
    }
  }
  return LaneGraphBuilder.build(RoadGraph.of(layout));
}
