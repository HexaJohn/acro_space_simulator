// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/agent_kind.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_time.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_tuning.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/vehicle_mover.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/vehicle_table.dart';
import 'package:flutter_test/flutter_test.dart';

import 'routing_fixture.dart';
import 'traffic_fixture.dart';

/// §17.3 #33, `destination_demolished` (docs/plans/agent-traffic.md §4.6,
/// §4.7, D36, E14): a commuter's workplace is cleared while it drives there,
/// and nothing changes on the way.
///
/// It keeps its route and its lanes to the old access point. There it finds
/// the building gone, counted in `arrivedGone`, and only then is a leg
/// appended: planned from the lane it stopped in, home. Nothing is ever
/// re-planned, because a building torn down is not a network edit.
///
/// A real commute, not a forced one-way trip: the colony's own demand sends
/// it, and a forced trip that finds its building gone simply ends there.
/// The lot is cleared the way the player clears one (`CitySim.clearParcel`,
/// whose E14 hook tells the agents at once).
void main() {
  tearDown(AgentTuning.reset);

  test('its workplace cleared mid-trip, it drives on, finds out on arrival, '
      'and an appended leg takes it home', () {
    final city = foundFlat(
        roads: const [FixtureRoad([Vec2(-600, 0), Vec2(600, 0)])]);
    final home = lotNearest(city, const Vec2(-400, -20)).id;
    final work = lotNearest(city, const Vec2(400, -20)).id;
    city.layout
      ..setUse(home, ParcelUse.residential)
      ..setUse(work, ParcelUse.industrial);
    buildAll(city);
    // ONE citizen, who drives and who does nothing but commute: the colony
    // has one home and one job, so they take that job at the first building
    // sync and set off for it (§6.3, §6.4 row 1). The idle dwell is cut to a
    // second or two so the wait between moving in and being hired is not a
    // wait of minutes; the errand rows are off so the one trip this test is
    // about is the only trip there is.
    AgentTuning.carOwnership = 1;
    AgentTuning.errandFromHome = 0;
    AgentTuning.errandFromIdle = 0;
    AgentTuning.errandFromWork = 0;
    AgentTuning.idleDwellMinS = 1;
    AgentTuning.idleDwellMaxS = 2;
    AgentTuning.commuteRatePerResident = 0.6;
    final a = city.agents..enabled = true;
    a.debugSettle(people: 1);
    a.advance(kStepS);
    final b = a.buildings!;
    final workB = b.handleOfSite(work)!;

    // One commute: theirs, and no other after it.
    for (var i = 0; i < 200 && a.commutes!.sent == 0; i++) {
      a.advance(kStepS);
    }
    AgentTuning.commuteRatePerResident = 0;
    expect(a.commutes!.sent, 1);
    for (var i = 0; i < 100 && a.liveVehicles == 0; i++) {
      a.advance(kStepS);
    }
    expect(a.liveVehicles, 1);
    final t = a.vehicles!;
    var sl = 0;
    while (!t.isSlotLive(sl)) {
      sl++;
    }
    final h = t.handleOf(sl);
    expect(a.describe(h)!['to'], work);
    expect(t.purpose[sl], TripPurpose.commute.index);

    // A little way along, its workplace goes.
    runAgents(a, 10, dt: kStepS);
    final hash = routeHash(a, h);
    final words = routeOf(a, h);
    final rev = a.graphRev;
    city.clearParcel(work);
    expect(b.handleOfSite(work), isNull, reason: 'gone at once (E14)');
    expect(b.isLive(workB), isFalse);
    expect(t.isLive(h), isTrue, reason: 'the car drives on');

    // To the old access point, on the route and in the lanes it had.
    var steps = 0;
    while (a.stats.arrivedGone == 0) {
      expect(t.isLive(h), isTrue);
      if (a.graphRev == rev) {
        expect(routeHash(a, h), hash, reason: 'its connectors, at ${a.timeUs}');
      }
      final now = routeOf(a, h);
      expect(now, words.sublist(words.length - now.length),
          reason: 'its lanes, at ${a.timeUs}');
      expect(a.stats.appendedLegs, 0, reason: 'nothing appended en route');
      expect(a.stats.replans, 0);
      a.advance(kStepS);
      expect(++steps, lessThan(1500), reason: 'it should have arrived');
    }
    expect(a.stats.arrivedGone, 1, reason: 'it found the building gone');
    expect(a.stats.appendedLegs, 1, reason: 'and a leg was appended then');
    expect(t.isLive(h), isTrue, reason: 'the same car carries on');
    final stoppedIn = t.elem[sl];
    expect(stoppedIn, lessThan(a.laneGraph!.laneCount));
    expect(t.s[sl], greaterThanOrEqualTo(t.destLaneS(sl) - kArriveM - 1e-3),
        reason: 'it stopped at the old access point');

    // The appended leg: planned from where it stopped, home.
    a.advance(kStepS);
    expect(t.state[sl], VehicleState.driving.index);
    expect(t.purpose[sl], TripPurpose.homeward.index);
    expect(a.describe(h)!['to'], home);
    final leg = [
      for (var i = 0; i < t.routeLen[sl]; i++) t.arena.data[t.routeOff[sl] + i],
    ];
    expect(leg.first, stoppedIn, reason: 'from the lane it stopped in');
    expectDrivable(a.laneGraph!, leg);

    for (var i = 0; i < 2400 && t.isLive(h); i++) {
      a.advance(0.5);
    }
    expect(t.isLive(h), isFalse);
    expect(a.stats.arrived, 2, reason: 'at the building gone, then home');
    expect(a.stats.arrivedGone, 1);
    expect(a.stats.replans, 0, reason: 'never re-planned');
    expect(a.stats.noRoute, 0);
    expect(a.stats.despawnStuck + a.stats.despawnWedge + a.stats.despawnEdit,
        0);
    expect(a.commutes!.liveCount, 0, reason: 'home, and the day done');
  });
}
