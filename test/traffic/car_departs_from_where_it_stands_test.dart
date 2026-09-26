// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Bug 1 (docs/plans/slice3-implementation.md §3; agent-traffic.md §7.4
/// Departure, §5.6): a trip departs from where its CAR stands, never from
/// where the person is.
///
/// `CityAgents._carOrigin` used to answer for a car at a KERB and for nothing
/// else. A car on a lot stall fell through to `buildings.addOrigins(request
/// .origin, …)`, the ORIGIN BUILDING's access rows, and that held only while
/// every car was parked at a site it belonged to. Slice 3 breaks that the
/// moment it lands: a citizen drives to work and leaves the car there, so the
/// next trip they make from home is a trip whose origin building is their
/// house and whose car is standing in a car park across town.
///
/// What went wrong then was not a wrong lane. `TripPlanner._spawn` looked for
/// the site out-join its route began at, found none — the route began at the
/// HOUSE — removed the parked row and spawned the vehicle at the route's
/// origin: the car teleported across town, and the stall it had been standing
/// on was silently freed behind it, for an arrival to drive into.
///
/// The scenario below is the one §3 names, built out of a town that made it
/// by itself: a citizen of home A drove to B and parked on B's stall, and a
/// trip is then forced whose ORIGIN is A while that car still stands at B.
/// What is pinned is all four halves of the fix:
///
/// 1. the search starts at one of **B's** out-joins, not at A's access;
/// 2. exactly one EXIT is logged, on **B's** row: the car crossed B's kerb
///    once, and crossed nobody else's;
/// 3. B's stall is released by the SITE MOVER, as the car's rear clears the
///    mouth line (§7.4 step 3) — it is still taken in the sub-step the
///    vehicle spawns, which is what tells a release from a teleport;
/// 4. no vehicle is ever placed at A's access point.
///
/// Before the fix the run fails on 1 and 3. With `TripPlanner._spawn`'s
/// refusal in (P0, slice3 §3), the departure is not teleported but simply
/// never made: the trip waits in the pull-out queue for ever, no EXIT is
/// logged, and the stall stays taken.
library;

import 'package:acro_space_simulator/domain/colony/city/traffic/access_events.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/building_table.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/city_agents.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/parked_cars.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/slot_pool.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_time.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_tuning.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/trip_planner.dart';
import 'package:flutter_test/flutter_test.dart';

import 'traffic_fixture.dart';

void main() {
  tearDown(AgentTuning.reset);

  test('a trip whose car stands at another site departs from THAT site, and '
      'leaves its stall by driving off it', () {
    // A settled City Builder town on its own site book, commuting hard
    // enough that somebody has driven to work and left the car on a stall.
    AgentTuning.commuteRatePerResident = 0.004;
    AgentTuning.carOwnership = 1;
    final city = town(agentTraffic: true);
    city.agents.debugSettle(share: kSettled);
    run(city, 150);
    final a = city.agents;
    // The town's own doing, and it takes a while: the book has to plan the
    // lots, people have to be housed and hired, and one of them has to drive
    // to a job with a stall going and leave the car on it.
    var away = _carLeftAwayFromHome(a);
    for (var i = 0; i < 6000 && away == null; i++) {
      a.advance(kStepS);
      away = _carLeftAwayFromHome(a);
    }
    expect(away, isNotNull,
        reason: 'nobody drove to work and left the car on a stall there');
    final home = away!.home, car = away.car;

    // Nobody else moves from here on: the only trip in the window below is
    // the one this test forces, so every vehicle it sees is that one.
    AgentTuning.commuteRatePerResident = 0;

    final cars = a.parkedCars!, sites = a.sites!, b = a.buildings!;
    final carSlot = SlotPool.slotOf(car);
    final row = cars.row[carSlot];
    final stall = cars.stall[carSlot];
    expect(sites.isRowLive(row), isTrue);
    expect(sites.stallCar[sites.stallBase[row] + stall], car,
        reason: 'the stall at B knows the car is on it');

    // Where the two ends are on the road: B's out-joins, which the departure
    // must start at, and A's access, which it must never touch.
    final fromB = _outJoins(a, row);
    expect(fromB, isNotEmpty, reason: 'B has a way out');
    final atA = _accessOf(b, home);
    expect(atA, isNotEmpty, reason: 'A is on the network');

    // The trip §3 names: its ORIGIN building is A, the house; its car is the
    // one standing at B.
    final to = _somewhereElse(a, home, sites.building[row]);
    final trip = a.commutes!.force(b.handleOf(home), to, car: car);
    expect(trip, isNot(SlotPool.none), reason: 'the trip was accepted');

    // The run: one sub-step at a time, watching every exit, every vehicle
    // that appears, and the stall.
    final exits = <({int row, int edge, double t})>[];
    final origins = <({int edge, double t})>[];
    var vehicle = SlotPool.none;
    var takenAtSpawn = false;
    var freedAtUs = -1;
    // The whole window, not only up to the release: the stall goes back as
    // the car's rear clears the MOUTH line, which is inside the site and a
    // few seconds before it crosses the kerb (§7.4 step 3).
    for (var i = 0;
        i < (300 / kStepS).round() &&
            (freedAtUs < 0 || !exits.any((e) => e.row == row));
        i++) {
      a.advance(kStepS);
      final log = a.accessEvents!;
      for (var k = 0; k < log.count; k++) {
        // Both ways a car leaves a site (§7.4): forward out of a throat, and
        // a home pad's back-out crossing the kerb in reverse.
        if (log.kind[k] != AccessEventKind.exit.index &&
            log.kind[k] != AccessEventKind.backOutExit.index) {
          continue;
        }
        exits.add((row: log.row[k], edge: log.edge[k], t: log.t[k].toDouble()));
      }
      final v = a.commutes!.vehicleOf(trip);
      if (v != SlotPool.none && vehicle == SlotPool.none) {
        vehicle = v;
        origins.add(_originOf(a, v));
        // §7.4 step 3: the mover holds the stall until the car's rear clears
        // the mouth line. A departure that freed it here would be a row
        // removed and a vehicle put down somewhere else.
        takenAtSpawn = sites.stallTaken(row, stall);
      }
      if (vehicle != SlotPool.none &&
          freedAtUs < 0 &&
          !sites.stallTaken(row, stall)) {
        freedAtUs = a.timeUs;
      }
    }

    // 1. The search started at one of B's out-joins, and at no access of A's.
    expect(vehicle, isNot(SlotPool.none), reason: 'the car drove away');
    final from = origins.single;
    expect(
        fromB.any((j) =>
            j.edge == from.edge && (j.t - from.t).abs() <= kDepartJoinM),
        isTrue,
        reason: 'the departure began at one of B\'s out-joins $fromB, not at '
            '(${from.edge}, ${from.t.toStringAsFixed(2)})');

    // 2. One EXIT, on B's row: the car crossed B's kerb, once. Nothing else
    // can leave B while the demand is off, so one EXIT there is ours.
    final mine = [for (final e in exits) if (e.row == row) e];
    expect(mine, hasLength(1), reason: 'one car, one kerb crossing: $exits');
    expect(
        fromB.any((j) =>
            j.edge == mine.single.edge &&
            (j.t - mine.single.t).abs() <= kSiteRetargetM),
        isTrue,
        reason: 'it crossed at one of B\'s own joins: ${mine.single}');

    // 3. The stall went back when the car drove off it, not when it spawned.
    expect(takenAtSpawn, isTrue,
        reason: 'the stall is the site mover\'s to release (§7.4 step 3)');
    expect(freedAtUs, greaterThanOrEqualTo(0), reason: 'and it was released');
    expect(cars.isLive(car), isFalse, reason: 'the car IS the vehicle');

    // 4. Nothing was ever put down at A's access point.
    for (final o in origins) {
      expect(
          atA.any((r) => r.edge == o.edge && (r.t - o.t).abs() <= kDepartJoinM),
          isFalse,
          reason: 'a vehicle at A\'s access $atA: '
              '(${o.edge}, ${o.t.toStringAsFixed(2)})');
    }
  });
}

/// A citizen whose own car stands on a LOT STALL at a building that is not
/// their home: the state §3's scenario needs, made by the town itself.
({int citizen, int home, int car})? _carLeftAwayFromHome(CityAgents a) {
  final c = a.citizens, cars = a.parkedCars, sites = a.sites;
  if (c == null || cars == null || sites == null) return null;
  for (var i = 0; i < c.highWater; i++) {
    if (!c.isSlotLive(i)) continue;
    final home = c.home[i], car = c.car[i];
    if (home < 0 || car < 0 || !cars.isLive(car)) continue;
    final sl = SlotPool.slotOf(car);
    if (cars.where[sl] != CarWhere.lot.index) continue;
    if (cars.building[sl] == home) continue;
    if (cars.claim[sl] != ParkedCarTable.unclaimed) continue;
    // Its site must still be one a car can be driven out of, or there is no
    // departure to judge.
    if (!sites.isRowLive(cars.row[sl])) continue;
    return (citizen: c.handleOf(i), home: home, car: car);
  }
  return null;
}

/// The `(edge, travel arc)` of every out-capable join of site [row], as
/// `TripPlanner._outJoinOf` matches them.
List<({int edge, double t})> _outJoins(CityAgents a, int row) {
  final sites = a.sites!, lg = a.laneGraph!;
  final g = lg.graph;
  final p = sites.plan[row];
  final out = <({int edge, double t})>[];
  if (p == null) return out;
  for (var j = 0; j < p.joinCount; j++) {
    if (sites.joinTarget(row, j) < 0) continue;
    final piece = p.joinPiece(j);
    if (piece < 0 || piece >= g.pieceCount) continue;
    for (final e in [g.pieceFwdEdge[piece], g.pieceBwdEdge[piece]]) {
      if (e >= 0) out.add((edge: e, t: lg.travelArc(e, p.joinRoadS(j))));
    }
  }
  return out;
}

/// The `(edge, travel arc)` of every access row of building slot [slot].
List<({int edge, double t})> _accessOf(BuildingTable b, int slot) {
  final base = BuildingTable.accRow0(slot);
  return [
    for (var k = 0; k < b.accCount[slot]; k++)
      if (b.accEdge[base + k] >= 0)
        (edge: b.accEdge[base + k], t: b.accT[base + k].toDouble()),
  ];
}

/// Where vehicle [v]'s route leaves its first edge: the search's own origin,
/// as `TripPlanner` recorded it.
({int edge, double t}) _originOf(CityAgents a, int v) {
  final t = a.vehicles!, lg = a.laneGraph!;
  final sl = SlotPool.slotOf(v);
  final lane = t.arena.data[t.routeOff[sl]];
  return (edge: lg.laneEdge[lane], t: a.originTOf(sl));
}

/// A reachable building that is neither [home] nor [at]: where the forced
/// trip is sent.
int _somewhereElse(CityAgents a, int home, int at) {
  final b = a.buildings!;
  for (var sl = 0; sl < b.highWater; sl++) {
    if (!b.isSlotLive(sl) || !b.reachable(sl)) continue;
    if (sl == home || sl == at) continue;
    return b.handleOf(sl);
  }
  fail('the colony has nowhere else to drive to');
}
