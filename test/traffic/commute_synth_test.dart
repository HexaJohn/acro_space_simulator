// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/traffic/agent_kind.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/site_vehicles.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/slot_pool.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_tuning.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/trip_planner.dart';
import 'package:flutter_test/flutter_test.dart';

import 'movement_fixture.dart';
import 'traffic_fixture.dart';

/// Slice 1's demand on the headless City Builder town
/// (docs/plans/agent-traffic.md §6.5, §6.7): commuters leave their homes at
/// the design's rate, drive locked routes to jobs drawn by jobs, and come
/// home after their day; the caps defer a trip at its origin and never
/// drop one onto the road; and what they measured is what staffing reads.
void main() {
  tearDown(AgentTuning.reset);

  test('commuters leave home, reach work, and come home again', () {
    final a = agentsOn(town());
    var sawAtWork = false, sawHomeward = false;
    var checks = 0;
    final errors = <String>[];
    runAgents(a, 900, each: () {
      final t = a.vehicles!;
      for (var sl = 0; sl < t.highWater; sl++) {
        if (t.isSlotLive(sl) &&
            t.purpose[sl] == TripPurpose.homeward.index) {
          sawHomeward = true;
        }
      }
      if (a.commutes!.atWork > 0) sawAtWork = true;
      if (++checks % 20 == 0) errors.addAll(occupancyErrors(t));
    });
    final s = a.stats;
    expect(errors, isEmpty);
    expect(a.commutes!.sent, greaterThan(20));
    expect(s.spawned, greaterThan(20));
    expect(s.arrived, greaterThan(10));
    expect(sawAtWork, isTrue, reason: 'commuters reached work and stayed');
    expect(sawHomeward, isTrue, reason: 'and set off home at the day\'s end');
    expect(s.tripsDone, greaterThan(10));
    expect(s.tripRatio, inInclusiveRange(0.8, kTripRatioCapForTest));
    expect(s.commuteEff, inInclusiveRange(0.6, 1.0));
    expect(s.despawnStuck + s.despawnWedge, lessThanOrEqualTo(s.spawned ~/ 10),
        reason: 'a quiet town does not jam');
    expect(s.replans, 0, reason: 'nothing was edited');
  });

  test('the demand runs at the design rate: 0.00042 trips per resident per '
      'second', () {
    final a = agentsOn(town());
    const seconds = 600.0;
    runAgents(a, seconds);
    final b = a.buildings!;
    var expected = 0.0;
    var homes = 0;
    for (var sl = 0; sl < b.highWater; sl++) {
      if (!b.isSlotLive(sl) || b.housing[sl] <= 0 || !b.reachable(sl)) continue;
      expected +=
          b.housing[sl] * AgentTuning.commuteRatePerResident * seconds;
      homes++;
    }
    expect(homes, greaterThan(5));
    // Each home sends the whole trips its owed fraction has reached: its
    // share, less at most the one trip still owed.
    expect(a.stats.deferred, 0);
    expect((a.commutes!.sent - expected).abs(), lessThanOrEqualTo(homes));
  });

  test('past a cap a trip waits at home: never dropped onto the road, never '
      'lost', () {
    AgentTuning.maxVehicles = 20;
    AgentTuning.commuteRatePerResident = 0.01;
    final a = agentsOn(town());
    final cap = TripPlanner.carCap;
    expect(cap, 18, reason: '10% of the table is the service reserve');
    var peak = 0;
    runAgents(a, 300, each: () {
      if (a.liveVehicles > peak) peak = a.liveVehicles;
    });
    final s = a.stats;
    expect(peak, lessThanOrEqualTo(cap));
    expect(peak, greaterThan(cap ~/ 2));
    expect(s.deferred, greaterThan(0));
    // From T4a a car keeps its vehicle row past its arrival while it parks
    // (§7.3 D17): held at a gate, driving the site, or on the one-element
    // leg to a kerb slot ahead. Such a car is counted BOTH in `arrived` and
    // among the live, so it is the slack in the accounting.
    var parking = 0;
    final cols = a.siteVehicles!;
    final t = a.vehicles!;
    for (var sl = 0; sl < t.highWater; sl++) {
      if (!t.isSlotLive(sl)) continue;
      final ph = SitePhase.values[cols.phase[sl]];
      if (ph == SitePhase.gateHeld ||
          ph == SitePhase.kerbBound ||
          ph == SitePhase.inbound ||
          ph == SitePhase.stallIn) {
        parking++;
      }
    }
    expect(s.spawned,
        s.arrived + s.despawnStuck + s.despawnWedge + s.despawnEdit +
            a.liveVehicles - parking,
        reason: 'every vehicle that went on the road is on it, arrived, or '
            'was counted off it');
  });

  test('describe tells the inspector who, why, from where to where, and the '
      'way', () {
    AgentTuning.commuteRatePerResident = 0.004;
    final a = agentsOn(town());
    runAgents(a, 120);
    final t = a.vehicles!;
    var sl = 0;
    while (!t.isSlotLive(sl)) {
      sl++;
    }
    final h = t.handleOf(sl);
    final d = a.describe(h)!;
    expect(d['handle'], h);
    expect(d['kind'], 'car');
    expect(d['purpose'], anyOf('commute', 'homeward'));
    expect(a.buildings!.handleOfSite(d['from']! as String), isNotNull);
    expect(a.buildings!.handleOfSite(d['to']! as String), isNotNull);
    expect(d['freeFlowS']! as double, greaterThan(0));
    expect(d['tripS']! as double, greaterThanOrEqualTo(0));
    final route = d['route']! as List<Map<String, Object?>>;
    expect(route, isNotEmpty);
    final lane = t.laneOfRouteEdge(sl, t.routeCur[sl]);
    expect(route.first['lane'], a.laneGraph!.laneIdx[lane],
        reason: 'the first step of the remaining route is the lane it is in');
    expect(route.length, t.routeLen[sl] - t.routeCur[sl]);
    expect(a.describe(SlotPool.none), isNull);
  });
}

/// The trip ratio's cap (traffic_stats.dart), which no average can pass.
const double kTripRatioCapForTest = 3.0;
