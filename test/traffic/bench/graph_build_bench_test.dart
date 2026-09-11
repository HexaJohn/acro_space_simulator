// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:typed_data';

import 'package:acro_space_simulator/domain/colony/city/city_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/graph_lineage.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_graph_builder.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_rng.dart';
import 'package:flutter_test/flutter_test.dart';

import '../routing_fixture.dart';
import '../traffic_fixture.dart';
import 'bench_support.dart';

/// §15.5 benchmark 1 (docs/plans/agent-traffic.md §3.8, §3.9, §15.1): what
/// deriving the lane graph from the road agent's `RoadGraph` costs, on the
/// starter kit, a four-block generated core, the 30 × 30 grid and the roads
/// of a two-mile sprawl; and what carrying 4,096 live routes across an edit
/// costs.
///
/// The §15.1 targets, held under ACRO_PERF: derivation ≤ 5 ms for about
/// 2,000 roads (the grid's 1,860 pieces), and the remap ≤ 4 ms at 4,096
/// vehicles. `RoadGraph.of`'s own cost is the road agent's, paid on every
/// edit with or without agents, and is not timed here.
void main() {
  test('bench: lane-graph derivation and remap (§15.5 #1)', () {
    final core = const CityGenerator()
        .generate(const CityGenSpec(blocksAcross: 4, seed: 5),
            bodies: fixtureBodies)
        .roadGraph;
    final sprawl = const CityGenerator()
        .generate(const CityGenSpec(blocksAcross: 4, seed: 5, sprawlMiles: 2),
            bodies: fixtureBodies)
        .roadGraph;
    final grid = gridLayout(30);
    final gridGraph = RoadGraph.of(grid);
    final nets = <(String, RoadGraph)>[
      ('starter kit', starterKit().roadGraph),
      ('4-block core', core),
      ('30 x 30 grid', gridGraph),
      ('2-mile sprawl', sprawl),
    ];
    var gridMs = 0.0;
    for (final (name, g) in nets) {
      for (var i = 0; i < 3; i++) {
        LaneGraphBuilder.build(g);
      }
      final ms = <double>[];
      late LaneGraph lg;
      for (var i = 0; i < 9; i++) {
        final sw = Stopwatch()..start();
        lg = LaneGraphBuilder.build(g);
        ms.add(sw.elapsedMicroseconds / 1000);
      }
      final median = percentile(ms, 0.5);
      if (identical(g, gridGraph)) gridMs = median;
      report('graph build, $name: ${g.roadCount} roads, ${g.nodeCount} '
          'nodes, ${lg.edgeCount} edges, ${lg.laneCount} lanes, '
          '${lg.connectorCount} connectors: derivation median '
          '${f(median)} ms, best ${f(percentile(ms, 0))} ms');
      expect(lg.edgeCount, g.edgeCount);
    }

    // 4,096 routes planned on the grid, then a street drawn across it at
    // y = 0, between the rows at y = ±100: it cuts all thirty north–south
    // streets.
    final lg0 = LaneGraphBuilder.build(gridGraph);
    final rng = TrafficRng(15);
    const vehicles = 4096;
    final routes = <Int32List>[];
    final atS = <double>[], destS = <double>[];
    while (routes.length < vehicles) {
      final o = rng.nextInt(lg0.edgeCount), g = rng.nextInt(lg0.edgeCount);
      if (o == g) continue;
      final t0 = lg0.edgeLaneS0[o] + 1.0, t1 = lg0.edgeLaneS1[g] - 1.0;
      final trip = planTrip(lg0, o, t0, g, t1, destMask: 1);
      if (trip == null || trip.route.length > 1024) continue;
      routes.add(Int32List.fromList(trip.route));
      atS.add(1.0);
      destS.add(t1);
    }
    final lengths = [for (final r in routes) r.length];
    final data = Int32List(lengths.fold(0, (a, b) => a + b));
    final offs = Int32List(vehicles);
    var at = 0;
    for (var i = 0; i < vehicles; i++) {
      offs[i] = at;
      data.setRange(at, at + lengths[i], routes[i]);
      at += lengths[i];
    }
    final half = 29 * 200 / 2 + 100;
    grid.commitRoad(
        controls: [Vec2(-half, 0), Vec2(half, 0)], regenerateLots: false);
    final lg1 = LaneGraphBuilder.build(RoadGraph.of(grid));

    ({double lineageMs, double remapMs, List<int> counts}) remapAll() {
      final sw = Stopwatch()..start();
      final rm = RouteRemapper(EdgeLineage(lg0, lg1));
      final lineageMs = sw.elapsedMicroseconds / 1000;
      final counts = List<int>.filled(RemapStatus.values.length, 0);
      for (var i = 0; i < vehicles; i++) {
        final st = rm.remap(data, offs[i], lengths[i],
            s: atS[i], destS: destS[i]);
        counts[st.index]++;
      }
      return (
        lineageMs: lineageMs,
        remapMs: sw.elapsedMicroseconds / 1000,
        counts: counts,
      );
    }

    for (var i = 0; i < 3; i++) {
      remapAll();
    }
    final runs = [for (var i = 0; i < 7; i++) remapAll()];
    final remapMs = percentile([for (final r in runs) r.remapMs], 0.5);
    final lineageMs = percentile([for (final r in runs) r.lineageMs], 0.5);
    final counts = runs.first.counts;
    final crossed = [
      for (var i = 0; i < vehicles; i++)
        if (_crossesY0(lg0, routes[i])) i,
    ].length;
    report('remap on the grid, a street drawn across it: $vehicles routes '
        '($crossed crossing the new street) in median ${f(remapMs)} ms, '
        'the lineage ${f(lineageMs)} ms of it; kept '
        '${counts[RemapStatus.kept.index]}, re-plan '
        '${counts[RemapStatus.replan.index]}, despawn '
        '${counts[RemapStatus.despawn.index]}');
    expect(counts[RemapStatus.kept.index], vehicles,
        reason: 'a crossing street makes no route impossible');
    expect(crossed, greaterThan(vehicles ~/ 10),
        reason: 'the edit touched a good share of the routes');

    // Both gates are held together, so one reading reports every miss.
    expect(
        [
          if (kPerf && gridMs > 5.0)
            'derivation ${f(gridMs)} ms for the grid\'s ${gridGraph.roadCount} '
                'roads (§15.1: ≤ 5 ms for about 2,000)',
          if (kPerf && remapMs > 4.0)
            'remap ${f(remapMs)} ms for $vehicles routes (§15.1: ≤ 4 ms)',
        ],
        isEmpty);
  }, skip: benchSkip, timeout: benchTimeout);
}

/// Whether [route] runs along a north–south street across y = 0.
bool _crossesY0(LaneGraph lg, Int32List route) {
  for (final l in lanesAlong(lg, route)) {
    final e = lg.laneEdge[l];
    final a = lg.graph.nodes[lg.edgeFrom[e]].at;
    final b = lg.graph.nodes[lg.edgeTo[e]].at;
    if (a.n * b.n < 0 && (a.e - b.e).abs() < 1) return true;
  }
  return false;
}
