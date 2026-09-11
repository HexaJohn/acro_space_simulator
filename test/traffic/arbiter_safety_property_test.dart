// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/traffic/agent_kind.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_graph_builder.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_rng.dart';
import 'package:flutter_test/flutter_test.dart';

import 'movement_fixture.dart';
import 'routing_fixture.dart';
import 'traffic_fixture.dart';

/// Arbiter safety (docs/plans/agent-traffic.md §5.4; §17.2): two vehicles
/// are never both on connectors that cross, each short of the point where
/// they cross — checked after every sub-step from positions and routes
/// alone, never from the arbiter's own books. Forced clearances waive only
/// the courtesy rules, so they are held to it too.
void main() {
  /// Runs [d] for [steps] sub-steps with [target] vehicles topped up from
  /// [rng], collecting every crossing violation.
  List<String> drive(Drive d, TrafficRng rng, int steps, int target) {
    final bad = <String>[];
    for (var k = 0; k < steps && bad.length < 20; k++) {
      d.topUp(rng, target, perStep: 3);
      d.step();
      bad.addAll(crossingViolations(d));
    }
    return bad;
  }

  test('on random towns, no two crossing movements are ever both short of '
      'their crossing point', () {
    var commits = 0, arrivals = 0, forced = 0, kinds = 0;
    final bad = <String>[];
    for (var seed = 1; seed <= 8 && bad.isEmpty; seed++) {
      final rng = TrafficRng(0xA5B1 + 97 * seed);
      final lg = lanesOf(randomTownLayout(rng));
      final d = Drive(lg);
      bad.addAll(drive(d, rng, 900, 120).map((s) => 'seed $seed: $s'));
      commits += d.arbiter.commits;
      arrivals += d.mover.arrivals;
      forced += d.arbiter.forcedGrants;
      final seen = <NodeControlKind>{};
      for (var n = 0; n < lg.nodeCount; n++) {
        seen.add(lg.kindOf(n));
      }
      kinds += seen.length;
      // ignore: avoid_print
      print('seed $seed: ${lg.edgeCount} edges, ${d.arbiter.commits} passes, '
          '${d.mover.arrivals} arrivals, ${d.mover.despawnStuck} stuck, '
          '${d.mover.despawnWedge} wedged, ${d.arbiter.forcedGrants} forced, '
          '${d.mover.lineStops} line stops, ${d.table.liveCount} live, '
          'kinds ${seen.map((k) => k.name).toList()..sort()}');
    }
    // ignore: avoid_print
    print('arbiter safety on random towns: $commits passes, $arrivals '
        'arrivals, $forced forced, $kinds node kinds over the towns');
    expect(bad, isEmpty);
    // It proved something: traffic crossed, and trips ended.
    expect(commits, greaterThan(2000));
    expect(arrivals, greaterThan(200));
  });

  test('on a grid of every class, and at the signalised crossing, the same '
      'holds', () {
    final grid = Drive(lanesOf(mixedGrid()));
    final kinds = <NodeControlKind>{
      for (var n = 0; n < grid.lg.nodeCount; n++) grid.lg.kindOf(n),
    };
    expect(kinds, containsAll([
      NodeControlKind.signals,
      NodeControlKind.allWayStop,
      NodeControlKind.deadEnd,
    ]));
    expect(drive(grid, TrafficRng(20260911), 1500, 300), isEmpty);
    expect(grid.arbiter.commits, greaterThan(2000));

    final lights =
        Drive(LaneGraphBuilder.build(signalised().roadGraph));
    expect(drive(lights, TrafficRng(7), 1500, 60), isEmpty);
    expect(lights.mover.arrivals, greaterThan(50));
  });
}
