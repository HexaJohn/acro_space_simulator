// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/traffic/agent_kind.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/junction_arbiter.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_connectors.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_graph_builder.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/node_control.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_rng.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/vehicle_table.dart';
import 'package:flutter_test/flutter_test.dart';

import 'movement_fixture.dart';
import 'traffic_fixture.dart';

/// Signals obeyed as drawn (docs/plans/agent-traffic.md §5.4; §17.3 #11),
/// on the `signalised()` crossing: for every head, at every sub-step, no
/// connector of that head is cleared while it shows red or all-red, and on
/// amber only by the dilemma rule — too close to stop — or for a left-turner
/// already waiting at the line. The light is the one `SignalPlan.stateAt`
/// gives the renderer, so a car stops at the light the player sees.
void main() {
  test('no pass on red or all-red; amber only by the dilemma or a waiting '
      'left; nothing enters a connector without one', () {
    final lg = LaneGraphBuilder.build(signalised().roadGraph);
    final ctl = lg.controls;
    var node = -1;
    for (var n = 0; n < lg.nodeCount; n++) {
      if (lg.kindOf(n) == NodeControlKind.signals) node = n;
    }
    expect(node, greaterThanOrEqualTo(0));
    final plan = ctl.planOf(node)!;
    final d = Drive(lg)..logCommits = true;
    final rng = TrafficRng(11);
    final nL = lg.laneCount;

    // Every entry into one of the crossing's connectors, and the pass the
    // vehicle held for it.
    final lastCommit = <int, Commit>{};
    var entries = 0, waited = 0;
    final bad = <String>[];
    var seen = 0;
    final before = <int, int>{};
    d.run(600, () {
      d.topUp(rng, 50, perStep: 2);
      for (; seen < d.commits.length; seen++) {
        lastCommit[d.commits[seen].handle] = d.commits[seen];
      }
      for (var sl = 0; sl < d.table.highWater; sl++) {
        if (!d.table.isSlotLive(sl)) continue;
        final h = d.table.handleOf(sl);
        final el = d.table.elem[sl];
        final was = before[h];
        before[h] = el;
        if (d.table.waitUs[sl] > 0 && d.table.v[sl] < 0.1) waited++;
        if (was == null || was >= nL || el < nL) continue;
        final c = el - nL;
        if (lg.conNode[c] != node) continue;
        entries++;
        final pass = lastCommit[h];
        if (pass == null || pass.connector != c) {
          bad.add('handle $h entered connector $c without a pass for it');
        }
      }
    });

    var green = 0, amber = 0;
    final phases = <int>{};
    for (final p in d.commits) {
      if (lg.conNode[p.connector] != node) continue;
      final from = lg.conFromEdge(p.connector);
      final phase = ctl.edgePhase[from];
      final st = plan.stateAt(phase, p.nowUs);
      // Judged by the vehicle's own comfortable braking: a lorry's is
      // gentler than a car's, so it is too close to stop sooner.
      final b = VehicleKinds.brake[p.kind];
      switch (st) {
        case SignalState.red:
        case SignalState.allRed:
          bad.add('a pass into ${p.connector} on $st at ${p.nowUs} µs');
        case SignalState.amber:
          amber++;
          final dilemma = p.reason == GrantReason.amberDilemma &&
              p.speed * p.speed > 2 * b * p.dist - 1e-6;
          final left = p.reason == GrantReason.amberLeftClear &&
              p.dist <= kAtLineM &&
              p.speed < kRestMps &&
              lg.turnOf(p.connector) == TurnClass.left;
          if (!dilemma && !left) {
            bad.add('an amber pass into ${p.connector}: ${p.reason}, '
                '${p.dist} m at ${p.speed} m/s');
          }
        case SignalState.green:
          green++;
          phases.add(phase);
      }
    }
    expect(bad, isEmpty);
    // The rules were exercised: both phases went, and cars waited at red.
    expect(phases, {0, 1});
    expect(green, greaterThan(100));
    expect(entries, greaterThan(100));
    expect(waited, greaterThan(100));
    // ignore: avoid_print
    print('signals: $green green passes, $amber amber, $entries entries');
  });
}
