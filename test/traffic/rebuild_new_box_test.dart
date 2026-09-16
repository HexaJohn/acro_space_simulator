// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/building_table.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/city_agents.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/slot_pool.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_time.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_tuning.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/vehicle_mover.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/vehicle_table.dart';
import 'package:flutter_test/flutter_test.dart';

import 'movement_fixture.dart';
import 'routing_fixture.dart';
import 'traffic_fixture.dart';

/// A street drawn across a road where cars stand (docs/plans/agent-traffic.md
/// §3.9, §4.6, D36): the edit puts a junction's box where they are.
///
/// A lane now stops at the new stop line and the next piece's lane starts
/// the far side of the box, so a car that stood between the two has no
/// place on a lane that is where it was. Clamping it onto one drags it up to
/// the box's depth — onto the car behind, or the one ahead. It is carried
/// instead onto the connector of its own movement straight through the new
/// box, as far through it as it stands: past the new stop line, on its
/// route's connector; past the new node, on the connector into its lane.
/// Nothing is re-planned, nothing taken off, nothing overlaps, and no car
/// moves a metre.
///
/// Where a remap still leaves one car on another, the rebuild moves the one
/// behind back until it clears, and counts it (`remapNudges`).
///
/// And a trip whose building the edit re-hung on the network — its lot
/// re-cut along the kerb, or a hand-drawn lot now nearer the new street —
/// drives its locked route to the old stop, finds the building met
/// elsewhere, and goes on to it by one appended leg (`siteRetarget`), never
/// a re-plan.
void main() {
  setUp(() => AgentTuning.commuteRatePerResident = 0);
  tearDown(AgentTuning.reset);

  test('a car past where the new stop line will be goes on through the box '
      'on its movement, where it stood, and drives on to arrive', () {
    final s = _Street();
    final car = s.carTo(from: -400, to: 400);
    s.standAt(car, -2.5);
    final was = s.placeOf(car);

    s.drawCrossing();
    final lg = s.a.laneGraph!;
    final e = s.edgeAt(-20);
    expect(s.xOf(e, lg.edgeLen[e]), closeTo(0, 1e-6),
        reason: 'the west piece ends at the new node');
    expect(s.xOf(e, lg.edgeLaneS1[e]), lessThan(-2.5),
        reason: 'and the car stands past its new stop line');
    final sl = SlotPool.slotOf(car);
    final t = s.a.vehicles!;
    final c = s.connectorOf(car);
    expect(lg.conFromEdge(c), e, reason: 'from the west piece');
    expect(lg.conToEdge(c), s.edgeAt(20), reason: 'straight into the east');
    expect(t.routeCur[sl], 1);
    expect(t.s[sl], closeTo(lg.edgeLen[e] - lg.edgeLaneS1[e] - 2.5, 0.05),
        reason: 'as far into the box as it stood past the line');
    expect(s.placeOf(car).distanceTo(was), lessThan(1));
    s.expectClean();

    s.driveOut([car]);
    expect(s.a.stats.arrived, 1);
    expect(s.a.stats.replans, 0);
    expect(s.a.stats.despawnEdit, 0);
  });

  test('a car just past the new node, short of where the next piece\'s lane '
      'starts, is on the connector into its lane, where it stood', () {
    final s = _Street();
    final car = s.carTo(from: -400, to: 400);
    s.standAt(car, 2.5);
    final was = s.placeOf(car);

    s.drawCrossing();
    final lg = s.a.laneGraph!;
    final east = s.edgeAt(20);
    expect(lg.edgeLaneS0[east], greaterThan(2.5),
        reason: 'the east piece\'s lane starts past the car');
    final sl = SlotPool.slotOf(car);
    final t = s.a.vehicles!;
    final c = s.connectorOf(car);
    expect(lg.conToLane[c], lg.laneOf(east, 0), reason: 'into its own lane');
    expect(lg.conFromEdge(c), s.edgeAt(-20), reason: 'from the piece behind');
    expect(t.routeCur[sl], 1);
    expect(t.laneOfRouteEdge(sl, 0), lg.conFromLane[c],
        reason: 'its route starts on the lane the connector leaves');
    expect(t.s[sl], closeTo(lg.conLen[c] - (lg.edgeLaneS0[east] - 2.5), 0.05));
    expect(s.placeOf(car).distanceTo(was), lessThan(1));
    s.expectClean();

    s.driveOut([car]);
    expect(s.a.stats.arrived, 1);
    expect(s.a.stats.replans, 0);
  });

  test('two cars nose to tail across the new stop line keep their places '
      'and their gap: neither is dragged onto the other', () {
    final s = _Street();
    final ahead = s.carTo(from: -400, to: 400);
    final behind = s.carTo(from: -376, to: 424);
    s.standAt(ahead, -1.0);
    s.standAt(behind, -7.5);
    final wasAhead = s.placeOf(ahead), wasBehind = s.placeOf(behind);

    s.drawCrossing();
    final lg = s.a.laneGraph!;
    final t = s.a.vehicles!;
    final a = SlotPool.slotOf(ahead), b = SlotPool.slotOf(behind);
    expect(t.elem[a], greaterThanOrEqualTo(lg.laneCount),
        reason: 'the car past the stop line is in the box');
    expect(t.elem[b], lessThan(lg.laneCount),
        reason: 'the car short of it is still on its lane');
    expect(s.placeOf(ahead).distanceTo(wasAhead), lessThan(1));
    expect(s.placeOf(behind).distanceTo(wasBehind), lessThan(1));
    // Bumper to bumper across the stop line: the lane's rest ahead of the
    // car behind, and the part of the car ahead still back over the lane.
    final gap = lg.laneLength(t.elem[b]) - t.s[b] + t.s[a] - t.len[a];
    expect(gap, closeTo(1.6, 0.1), reason: 'the gap they had');
    s.expectClean();

    s.driveOut([ahead, behind]);
    expect(s.a.stats.arrived, 2);
    expect(s.a.stats.replans, 0);
  });

  test('a trip to a lot the re-cut moved along the kerb stops where its '
      'route stops, then drives on to the lot by one appended leg', () {
    // A crossing 3 m off the lot grid: every lot beyond it is re-cut 3 m
    // further along its piece, and keeps its building (E12).
    final s = _Street();
    final to = lotNearest(s.city, const Vec2(24, -20)).id;
    final car = s.carTo(from: -400, toSite: to);
    s.standAt(car, -150);
    s.drawCrossing(atX: 3);
    final b = s.a.buildings!;
    final dest = s.a.commutes!.destOfVehicle(car);
    expect(b.siteOf(dest), isNot(to), reason: 're-cut and renamed');
    expect(s.a.stats.appendedLegs, 0);

    final last = s.driveOut([car]);
    // One leg on from the old stop, and — from T4a — the parking leg every
    // arrival appends after it (D17 step 2).
    expect(s.a.siteStats.siteRetargets, 1,
        reason: 'one leg on, at the old stop');
    expect(s.a.stats.appendedLegs, greaterThanOrEqualTo(1));
    expect(s.a.stats.replans, 0, reason: 'never a re-plan');
    expect(s.a.stats.arrived, 1);
    expect(s.a.stats.arrivedGone, 0);
    expect(s.a.stats.noRoute, 0);
    s.expectArrivedAtAccess(last, dest);
  });

  test('a trip to a hand-drawn lot the new street now hangs on goes on from '
      'the old stop to the new street by one appended leg', () {
    final s = _Street(handDrawn: const [
      Vec2(-24, 50),
      Vec2(-8, 50),
      Vec2(-8, 70),
      Vec2(-24, 70),
    ]);
    final site = s.city.layout.manualParcels.single.id;
    final car = s.carTo(from: -400, toSite: site);
    final lg0 = s.a.laneGraph!;
    final b = s.a.buildings!;
    final dest = b.handleOfSite(site)!;
    final before = b.accEdge[BuildingTable.accRow0(SlotPool.slotOf(dest))];
    expect(lg0.graph.roads[lg0.edgeRoad[before]].id, s.mainRoad,
        reason: 'hung on the main road while it is the only one');
    s.standAt(car, -200);

    s.drawCrossing();
    final lg = s.a.laneGraph!;
    final now = b.accEdge[BuildingTable.accRow0(SlotPool.slotOf(dest))];
    expect(lg.graph.roads[lg.edgeRoad[now]].id, startsWith(s.crossing!),
        reason: 'the new street is nearer now');

    final last = s.driveOut([car]);
    expect(s.a.siteStats.siteRetargets, 1, reason: 'one leg on');
    expect(s.a.stats.appendedLegs, greaterThanOrEqualTo(1));
    expect(s.a.stats.replans, 0);
    expect(s.a.stats.arrived, 1);
    expect(s.a.stats.noRoute, 0);
    s.expectArrivedAtAccess(last, dest);
  });

  test('a remap that leaves a car on the one ahead moves it back clear, '
      'never behind its element\'s start, and counts it', () {
    final s = _Street();
    final lead = s.carTo(from: -500, to: 400);
    final onIt = s.carTo(from: -476, to: 424);
    final first = s.carTo(from: -400, to: 448);
    final tooClose = s.carTo(from: -424, to: 472);
    // Far from the edit, overlapping by 2.9 m.
    s.standAt(lead, -300);
    s.standAt(onIt, -302);
    // Just past the new node's box on the east piece: too near its lane's
    // start for the car behind to clear.
    s.standAt(first, 7);
    s.standAt(tooClose, 6.5);
    expect(occupancyErrors(s.a.vehicles!), hasLength(2),
        reason: 'both pairs overlap before the edit');

    s.drawCrossing();
    final t = s.a.vehicles!;
    expect(s.a.stats.remapNudges, 2);
    final l = SlotPool.slotOf(lead), o = SlotPool.slotOf(onIt);
    expect(t.elem[o], t.elem[l]);
    expect(t.s[o], closeTo(t.s[l] - t.len[l] - kStopShortM, 1e-3),
        reason: 'moved back to clear the car ahead');
    final f = SlotPool.slotOf(first), c = SlotPool.slotOf(tooClose);
    expect(t.elem[c], t.elem[f]);
    expect(t.elem[c], lessThan(s.a.laneGraph!.laneCount));
    expect(t.s[c], 0, reason: 'no further back than its lane\'s start');
    final errs = occupancyErrors(t);
    expect(errs, hasLength(1), reason: '$errs');
    expect(errs.single, contains('slot $c overlaps $f'));
    expect(s.a.stats.replans, 0);
    expect(s.a.stats.despawnEdit, 0);
  });
}

/// A straight street from x = −600 to 600 along y = 0 (its forward edge runs
/// east), every lot beside it a built home, the colony's own agents on and
/// ticked by the test — so the re-plat's renames reach them (E12) — and no
/// demand of their own.
class _Street {
  _Street({List<Vec2>? handDrawn}) {
    city = foundFlat(
        roads: const [FixtureRoad([Vec2(-600, 0), Vec2(600, 0)])]);
    if (handDrawn != null) {
      final lot = city.layout.addManualParcel(handDrawn)!;
      city.placeOnParcel(
          lot.id, kZoneSpecs['industrial']![Density.low]!);
    }
    zoneAll(city, const [ParcelUse.residential]);
    buildAll(city);
    a = city.agents..enabled = true;
    a.advance(kStepS);
    mainRoad = a.laneGraph!.graph.roads.single.id;
  }

  late final CitySim city;
  late final CityAgents a;
  late final String mainRoad;

  /// The crossing street's id, once drawn.
  String? crossing;

  /// A car trip from the home at x = [from] south of the street to the one
  /// at x = [to] (or to [toSite]), driving east: its vehicle's handle, once
  /// it has pulled out.
  int carTo({required double from, double to = 0, String? toSite}) {
    final home = lotNearest(city, Vec2(from, -20)).id;
    final dest = toSite ?? lotNearest(city, Vec2(to, -20)).id;
    final trip = forceTrip(a, home, dest);
    expect(trip, isNot(SlotPool.none));
    var h = -1;
    for (var i = 0; i < 400 && h < 0; i++) {
      a.advance(kStepS);
      h = vehicleOfTrip(a, trip);
    }
    expect(h, greaterThanOrEqualTo(0), reason: 'pulled out');
    return h;
  }

  /// Puts [car], standing still and driving, with its front at x = [x] on
  /// its eastbound lane.
  void standAt(int car, double x) {
    final t = a.vehicles!, lg = a.laneGraph!;
    final sl = SlotPool.slotOf(car);
    final el = t.elem[sl];
    expect(el, lessThan(lg.laneCount));
    final e = lg.laneEdge[el];
    expect(lg.edgeForward[e], 1, reason: 'driving east');
    t.s[sl] = arcNear(lg, e, Vec2(x, 0)) - lg.edgeLaneS0[e];
    t.v[sl] = 0;
    t.state[sl] = VehicleState.driving.index;
    t.relinkAll();
  }

  /// A street north–south across the main road at x = [atX], and the poll
  /// that rebuilds the lane graph under the cars — no sub-step run.
  void drawCrossing({double atX = 0}) {
    final rev = a.graphRev;
    crossing = commit(city, FixtureRoad([Vec2(atX, -200), Vec2(atX, 200)]));
    a.advance(0);
    expect(a.graphRev, rev + 1, reason: 'rebuilt');
  }

  /// The eastbound edge of the main road at x = [x].
  int edgeAt(double x) =>
      edgeNear(a.laneGraph!, Vec2(x, 0), const Vec2(1, 0));

  /// Where travel arc [t] of [edge] is, east.
  double xOf(int edge, double t) => pointOnEdge(a.laneGraph!, edge, t).e;

  /// Where [car]'s front is drawn.
  Vec2 placeOf(int car) {
    final t = a.vehicles!;
    final sl = SlotPool.slotOf(car);
    return elementPoint(a.laneGraph!, t.elem[sl], t.s[sl].toDouble());
  }

  /// The connector [car] is on; fails when it is on a lane.
  int connectorOf(int car) {
    final lg = a.laneGraph!;
    final el = a.vehicles!.elem[SlotPool.slotOf(car)];
    expect(el, greaterThanOrEqualTo(lg.laneCount), reason: 'on a connector');
    return el - lg.laneCount;
  }

  /// Nothing re-planned, taken off, overlapping or moved off another.
  void expectClean() {
    expect(a.stats.replans, 0);
    expect(a.stats.despawnEdit, 0);
    expect(a.stats.remapNudges, 0);
    expect(occupancyErrors(a.vehicles!), isEmpty);
  }

  /// Drives until every one of [cars] has left the road; returns where the
  /// last of them last stood — its lane, and its travel arc along its edge.
  (int, double) driveOut(List<int> cars) {
    final t = a.vehicles!;
    var last = (-1, 0.0);
    for (var i = 0; i < 6000 && cars.any(t.isLive); i++) {
      for (final h in cars) {
        if (!t.isLive(h)) continue;
        final sl = SlotPool.slotOf(h);
        final el = t.elem[sl];
        final lg = a.laneGraph!;
        if (el < lg.laneCount) {
          last = (el, lg.edgeLaneS0[lg.laneEdge[el]] + t.s[sl]);
        }
      }
      a.advance(kStepS);
    }
    expect(cars.where(t.isLive), isEmpty, reason: 'all arrived');
    expect(a.stats.despawnStuck + a.stats.despawnWedge + a.stats.despawnEdit,
        0);
    return last;
  }

  /// Checks that [last], where a car last stood, is building [dest]'s
  /// access as the table has it now: on a serving edge, within a car's
  /// arrival reach of its arc.
  void expectArrivedAtAccess((int, double) last, int dest) {
    final (lane, at) = last;
    final lg = a.laneGraph!;
    final b = a.buildings!;
    expect(b.isLive(dest), isTrue);
    final e = lg.laneEdge[lane];
    expect(b.meetsAt(dest, e, at, kArriveM + kSiteRetargetM), isTrue,
        reason: 'stopped on ${_roadOf(lg, e)} at $at');
  }

  static String _roadOf(LaneGraph lg, int e) =>
      lg.graph.roads[lg.edgeRoad[e]].id;
}
