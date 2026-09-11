// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/traffic/lane_graph_builder.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_rng.dart';
import 'package:flutter_test/flutter_test.dart';

import 'movement_fixture.dart';
import 'routing_fixture.dart';
import 'traffic_fixture.dart';

/// Lanes change only at nodes (docs/plans/agent-traffic.md §5.5; §17.2
/// and §17.3 #6): a vehicle's element changes only as it hands over to the
/// next element of its own route, and consecutive elements are joined by a
/// connector — so it never moves sideways onto a sibling lane of the edge
/// it is on. The one other lane choice is the access point it pulls out of,
/// which is where a vehicle is first seen. The lists stay in order and
/// nothing overlaps, after every sub-step (§17.2 occupancy consistency).
void main() {
  test('500 agents, 2000 sub-steps: every element change follows the route '
      'through a connector, and the lists stay whole', () {
    final d = Drive(lanesOf(mixedGrid()), capacity: 1024);
    final rng = TrafficRng(0x1A4E5);
    final watch = LaneWatch();
    final bad = <String>[];
    var peak = 0;
    for (var k = 0; k < 2000 && bad.length < 20; k++) {
      d.topUp(rng, 500, perStep: 12);
      d.step();
      bad.addAll(watch.check(d));
      bad.addAll(occupancyErrors(d.table));
      if (d.table.liveCount > peak) peak = d.table.liveCount;
    }
    expect(bad, isEmpty);
    expect(peak, greaterThanOrEqualTo(480));
    expect(watch.laneChanges, greaterThan(1000),
        reason: 'lanes changed often enough to prove something');
    // 500 cars on a 1.1 km grid of lights and all-way stops every 220 m run
    // at about a quarter of the limit: trips end, slowly.
    expect(d.mover.arrivals, greaterThan(300));
  });

  test('the starter crossroads, 10 agent-minutes of traffic', () {
    final d = Drive(LaneGraphBuilder.build(starterKit().roadGraph));
    final rng = TrafficRng(6);
    final watch = LaneWatch();
    final bad = <String>[];
    d.run(600, () {
      if (bad.length > 20) return;
      d.topUp(rng, 40, perStep: 2);
      bad.addAll(watch.check(d));
      bad.addAll(occupancyErrors(d.table));
    });
    expect(bad, isEmpty);
    expect(d.mover.arrivals, greaterThan(100));
  });
}
