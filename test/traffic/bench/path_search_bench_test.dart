// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/road_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_graph_builder.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_state_search.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/path_search.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/route_cost.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_rng.dart';
import 'package:flutter_test/flutter_test.dart';

import 'bench_support.dart';

/// §15.5 benchmark 2 (docs/plans/agent-traffic.md §4.3–4.5, §15.1): 1,000
/// random origin–destination pairs on the 30 × 30 grid, planned by the edge
/// A* every new trip takes and by the (edge, lane) state search every
/// fixed-start plan takes. Reported: expansions per request, time per
/// expansion and per request.
///
/// §15.1 budgets the path pump at 4,000 expansions a sub-step at about
/// 150 ns each, 0.6 ms. Held under ACRO_PERF: the edge A* at no more than
/// that per expansion.
void main() {
  test('bench: path search, edge A* and (edge, lane) states (§15.5 #2)', () {
    final lg = LaneGraphBuilder.build(RoadGraph.of(gridLayout(30)));
    final cost = RouteCost(lg);
    final rng = TrafficRng(2);
    final pairs = <(int, double, int, double)>[];
    while (pairs.length < 1200) {
      final o = rng.nextInt(lg.edgeCount), g = rng.nextInt(lg.edgeCount);
      if (o == g) continue;
      pairs.add((
        o,
        _arc(lg, o, rng.nextUnit()),
        g,
        _arc(lg, g, rng.nextUnit()),
      ));
    }
    final ends = PathEnds();

    ({double usPerRequest, double nsPerExpansion, double expansions, int found})
        measure(bool byState) {
      final edge = SearchContext();
      final state = LaneStateSearch();
      var found = 0, expansions = 0;
      final us = <double>[];
      // The first 200 warm the JIT, and are not counted.
      for (var i = 0; i < pairs.length; i++) {
        final (o, t0, g, t1) = pairs[i];
        ends
          ..clear()
          ..addOrigin(o, t0, lane: byState ? lg.laneOf(o, 0) : -1)
          ..addGoal(g, t1, laneMask: 1);
        final sw = Stopwatch()..start();
        SearchStatus status;
        int n;
        if (byState) {
          state.begin(cost, ends);
          status = state.step(1 << 30);
          n = state.expansions;
        } else {
          edge.begin(cost, ends);
          status = edge.step(1 << 30);
          n = edge.expansions;
        }
        final t = sw.elapsedMicroseconds.toDouble();
        if (i < 200) continue;
        us.add(t);
        expansions += n;
        if (status == SearchStatus.found) found++;
      }
      final total = us.fold(0.0, (a, b) => a + b);
      return (
        usPerRequest: total / us.length,
        nsPerExpansion: total * 1000 / expansions,
        expansions: expansions / us.length,
        found: found,
      );
    }

    final edge = measure(false), state = measure(true);
    report('path search on the 30 x 30 grid (${lg.edgeCount} edges, '
        '${lg.laneCount} lanes), 1,000 random pairs:\n'
        '  edge A*:      ${f(edge.expansions, 0)} expansions a request, '
        '${f(edge.nsPerExpansion, 0)} ns an expansion, '
        '${f(edge.usPerRequest, 1)} us a request; ${edge.found} found\n'
        '  (edge, lane): ${f(state.expansions, 0)} expansions a request, '
        '${f(state.nsPerExpansion, 0)} ns an expansion, '
        '${f(state.usPerRequest, 1)} us a request; ${state.found} found\n'
        '  a sub-step\'s 4,000 expansions: ${f(4 * edge.nsPerExpansion / 1000)} '
        'ms by edge, ${f(4 * state.nsPerExpansion / 1000)} ms by state');
    expect(edge.found, 1000, reason: 'the grid joins everything');
    expect(state.found, 1000);
    if (kPerf) {
      expect(edge.nsPerExpansion, lessThanOrEqualTo(150),
          reason: '§15.1: about 150 ns an expansion');
    }
  }, skip: benchSkip, timeout: benchTimeout);
}

/// A travel arc [u] of the way along [e]'s lanes.
double _arc(LaneGraph lg, int e, double u) =>
    lg.edgeLaneS0[e] + (lg.edgeLaneS1[e] - lg.edgeLaneS0[e]) * u;
