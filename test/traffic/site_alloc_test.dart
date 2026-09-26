// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A13 (docs/plans/site-access.md §7.9; agent-traffic.md §15.2): a town
/// whose cars are turning into lots, parking, and driving out of them again
/// runs 1,000 sub-steps and reallocates NOTHING.
///
/// This is the structural half of §15.2 for the site half of T4a, and it is
/// the gate the slice merges on (the weighed half is slice 11's). The rule
/// it pins is the one every site file was written to: a SYNC may allocate —
/// it runs on a site change and nowhere else — and a sub-step may not. So
/// the window below holds the plans still, and every column of the site
/// table, the site vehicle rows, the access-event log, the parked cars, the
/// kerb slots and the mover's own scratch must be the very buffers the
/// warm-up left behind.
library;

import 'package:acro_space_simulator/domain/colony/city/traffic/city_agents.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_time.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_tuning.dart';
import 'package:flutter_test/flutter_test.dart';

import 'traffic_fixture.dart';

void main() {
  // Ten times the design's demand, so cars are arriving at lots, being held
  // at gates and pulling out of stalls on every sub-step weighed.
  setUp(() => AgentTuning.commuteRatePerResident = 0.004);
  tearDown(AgentTuning.reset);

  test('1,000 sub-steps of cars cycling the lots reallocate no buffer of the '
      'sites, the cars, the kerbs or the mover', () {
    // The colony's own agents, on its own site book: the plans are generated
    // while the town warms up, and stand still afterwards, because nothing
    // below ticks `CitySim.advance` again.
    //
    // Its homes are settled before it warms up (slice 3): the colony's own
    // migration would fill them over colony minutes, and what the window
    // needs is a town already commuting, with a car on every other stall.
    final city = town(agentTraffic: true);
    city.agents.debugSettle(share: kSettled);
    run(city, 120);
    final a = city.agents;
    expect(a.sites!.highWater, greaterThan(10), reason: 'lots with plans');

    // Warm up on the agents alone, until enough cars have parked for the
    // window to be about cars cycling rather than about the first of them.
    for (var i = 0; i < 6000 && a.parkedCars!.count < 50; i++) {
      a.advance(kStepS);
    }
    final cars = a.parkedCars!;
    expect(cars.count, greaterThanOrEqualTo(50),
        reason: '50 cars standing in lots and at kerbs');
    final sitesRev = a.sites!.syncedSitesRev;
    final graphRev = a.graphRev;
    final parkedLot = a.siteStats.parkedLot;
    final enters = a.siteStats.enters;
    final exits = a.siteStats.exits;
    final spawned = a.stats.spawned;

    final before = _buffers(a);
    for (var i = 0; i < 1000; i++) {
      a.advance(kStepS);
    }
    final after = _buffers(a);

    // The window did the work it claims to: cars turned in, parked and left.
    expect(a.sites!.syncedSitesRev, sitesRev, reason: 'no site sync');
    expect(a.graphRev, graphRev, reason: 'no rebuild');
    expect(a.siteStats.enters - enters, greaterThan(5), reason: 'cars turned in');
    expect(a.siteStats.exits - exits, greaterThan(0), reason: 'and came out');
    expect(a.siteStats.parkedLot - parkedLot, greaterThan(5));
    expect(a.stats.spawned - spawned, greaterThan(20));
    expect(cars.count, greaterThanOrEqualTo(50));

    expect(after.keys.toList(), before.keys.toList(),
        reason: 'no buffer made in steady state');
    final warm = Set<Object>.identity()..addAll(before.values);
    for (final name in after.keys) {
      expect(warm.contains(after[name]), isTrue,
          reason: '$name was reallocated');
    }
  });
}

/// Every buffer the site half keeps from one sub-step to the next, by name —
/// and, from slice 3, the citizen half's, which is written in the same
/// sub-step and under the same rule (§15.2): the citizen table's columns, its
/// wheel and per-building lists, the matching's scratch, and the activity
/// loop's wake batch and roll-over queue.
Map<String, Object> _buffers(CityAgents a) {
  final out = <String, Object>{};
  a.collectSiteBuffers(out);
  a.collectCitizenBuffers(out);
  a.planner!.collectBuffers(out, 'planner');
  return out;
}
