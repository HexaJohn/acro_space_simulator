// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A4 (docs/plans/site-access.md §7.9): one forced trip in the starter
/// colony, on the colony's OWN site access book, drives in at the aquifer
/// pump's kerb cut, up its throat, and parks on the first stall of that
/// join's order.
///
/// The book, not a fixture: `CityStarterKit.found` drains
/// `SiteAccessBook.sync` in full, so the pump's plan is the one the road
/// side generates, with the joins, throat and stalls its own rules chose.
/// What is pinned here is the whole chain the four T4a packages make
/// together — access rows from the plan's joins, a site row, the arrival
/// gate, the site lanes, the stall manoeuvre and the parked car — and it is
/// the only traffic test that runs it end to end on real plans.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_constants.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_plan.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_lane_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/access_events.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/parked_cars.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/site_manoeuvre.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/site_vehicles.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/slot_pool.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_time.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_tuning.dart';
import 'package:flutter_test/flutter_test.dart';

import 'traffic_fixture.dart';

/// The starter kit's aquifer pump and farm, in the order
/// `CityStarterKit.found` adds its manual parcels.
const String _pump = 'lot-m3';
const String _farm = 'lot-m2';

void main() {
  // A forced trip, and nothing else on the road: the demand's own rate is
  // off, so what drives in is the trip the test asked for (A4).
  setUp(() => AgentTuning.commuteRatePerResident = 0);
  tearDown(AgentTuning.reset);

  test('a forced trip to the aquifer pump enters once at its cut, drives the '
      'throat and parks on the first stall of that join\'s order', () {
    final city = starterKit();
    final a = agentsOn(city);
    final trip = a.forceTrip(_farm, _pump);
    expect(trip, isNot(SlotPool.none), reason: 'both sites are built');

    final sites = a.sites!;
    final row = sites.rowOfBuilding(
        SlotPool.slotOf(a.buildings!.handleOfSite(_pump)!));
    expect(row, greaterThanOrEqualTo(0),
        reason: 'the pump has a network plan with stalls');
    final plan = sites.plan[row]!;
    final lanes = sites.lanes[row]!;
    expect(plan.stallCount, greaterThan(0));
    expect(sites.lotCap[row], plan.stallCount);
    expect(sites.lotUsed[row], 0);

    // What it drove, sub-step by sub-step: every access event, the site
    // lanes it was on, and the last pose of its stall manoeuvre.
    final enters = <({int edge, double t, int row, int join})>[];
    final onLanes = <int>{};
    var parkedAtUs = -1;
    var vehicle = SlotPool.none;
    var drove = 0;
    for (var i = 0; i < (90 / kStepS).round() && parkedAtUs < 0; i++) {
      a.advance(kStepS);
      final v = vehicleOfTrip(a, trip);
      if (v != SlotPool.none) vehicle = v;
      final log = a.accessEvents!;
      for (var k = 0; k < log.count; k++) {
        if (log.kind[k] != AccessEventKind.enter.index) continue;
        enters.add((
          edge: log.edge[k],
          t: log.t[k].toDouble(),
          row: log.row[k],
          join: log.join[k]
        ));
      }
      if (vehicle == SlotPool.none) continue;
      final sl = SlotPool.slotOf(vehicle);
      final cols = a.siteVehicles!;
      if (a.vehicles!.isLive(vehicle)) {
        final ph = SitePhase.values[cols.phase[sl]];
        if (ph == SitePhase.inbound) {
          onLanes.add(cols.lane[sl]);
          if (a.vehicles!.s[sl] > 1) drove++;
        }
        continue;
      }
      parkedAtUs = a.timeUs;
    }

    // One ENTER, at the join the plan gave the building, within a metre of
    // its cut (§5.5's own tolerance is 1.5 m; A4 asks for 1).
    expect(enters.length, 1, reason: 'one car, one kerb crossing: $enters');
    final e = enters.single;
    expect(e.row, row);
    final lg = a.laneGraph!;
    final at = lg.travelArc(e.edge, plan.joinRoadS(e.join));
    expect((e.t - at).abs(), lessThanOrEqualTo(1.0),
        reason: 'ENTER at the cut, not somewhere along the kerb');
    expect(plan.joinCanIn(e.join), isTrue);

    // It drove the throat: the in-lane of that join, under its own power.
    final inLane = lanes.inLane(e.join);
    expect(inLane, greaterThanOrEqualTo(0));
    expect(onLanes, contains(inLane), reason: 'up the throat: $onLanes');
    expect(drove, greaterThan(1), reason: 'it moved along the site lanes');

    // Parked, inside 90 s, on the first stall of that join's order.
    expect(parkedAtUs, greaterThanOrEqualTo(0), reason: 'it parked');
    expect(secondsOf(parkedAtUs), lessThanOrEqualTo(90.0));
    final want = sites.stallOrder[sites.orderBase[row] + e.join * plan.stallCount];
    final cars = a.parkedCars!;
    expect(cars.lotCars, 1);
    expect(cars.count, 1);
    final car = cars.pool.handleOf(0);
    final i = SlotPool.slotOf(car);
    expect(CarWhere.values[cars.where[i]], CarWhere.lot);
    expect(cars.row[i], row);
    expect(cars.stall[i], want, reason: 'stallOrder[j][0]');
    expect(cars.stallKey[i], plan.stallKey(want));
    expect(sites.stallCar[sites.stallBase[row] + want], car);
    expect(sites.lotUsed[row], 1);
    expect(a.siteStats.enters, 1);
    expect(a.siteStats.parkedLot, 1);
    expect(a.siteStats.garaged, 0);
    expect(a.siteStats.gateGiveUps, 0);

    // E36 stage 1 (§0 Q4): the pump's parking is the agents' now, at the
    // book's own slot for it, and a slot past the list reads 0.
    final slot = city.siteAccess.slotOf(_pump);
    expect(slot, greaterThanOrEqualTo(0));
    expect(a.agentManaged.length, greaterThan(slot));
    expect(a.agentManaged[slot], 1);
    expect(a.agentManagedRev, greaterThan(0));
    expect(sites.bookSlot[row], slot, reason: 'the wire ordinal is the slot');

    // And it landed ON the stall: the scripted curve's end is the stall
    // pose, within 0.05 m and 2° (§7.4 step 5 — a snap, not a tolerance).
    final entry = sites.laneOfTarget(row, sites.stallTarget(row, want));
    final dir = SiteLaneGraph.isForward(entry) ? kSiteDirFwd : kSiteDirBwd;
    final pose = _pose(plan, want, dir);
    expect(pose.offM, lessThanOrEqualTo(0.05),
        reason: 'the pose ends on the stall');
    expect(pose.cos, greaterThan(_cos2deg),
        reason: 'and facing the way the stall does');
    // ignore: avoid_print
    print('A4: parked on stall $want of $_pump after '
        '${secondsOf(parkedAtUs).toStringAsFixed(1)} s; pose off by '
        '${(pose.offM * 1000).toStringAsFixed(1)} mm, '
        '${_degrees(pose.cos).toStringAsFixed(3)}°; ENTER at T '
        '${e.t.toStringAsFixed(2)} against the cut\'s '
        '${at.toStringAsFixed(2)}');
  });
}

/// The cosine of two degrees: the angle §7.4 step 5 allows.
const double _cos2deg = 0.99939;

/// The angle whose cosine is [cos], in degrees, for the report.
double _degrees(double cos) =>
    math.acos(cos.clamp(-1.0, 1.0)) * 180 / math.pi;

/// How far the end of [stall]'s manoeuvre from direction [dir] lands from
/// the stall itself, and how nearly it faces the same way.
({double offM, double cos}) _pose(SiteAccessPlan plan, int stall, int dir) {
  final out = Float64List(SiteManoeuvre.poseStride);
  SiteManoeuvre.stallPose(plan, stall, dir, 1, out, 0);
  final de = out[0] - plan.stallE(stall);
  final dn = out[1] - plan.stallN(stall);
  return (
    offM: math.sqrt(de * de + dn * dn),
    cos: out[2] * plan.stallDirE(stall) + out[3] * plan.stallDirN(stall),
  );
}
