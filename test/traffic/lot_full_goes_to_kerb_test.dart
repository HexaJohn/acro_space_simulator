// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A7 at harness level (docs/plans/site-access.md §7.9 A7; agent-traffic.md
/// §7.3 D17 steps 1–2): two stalls, three arrivals. Two park on the lot, and
/// the third — which never enters it — reserves an UNMASKED kerb slot ahead
/// on its arrival edge.
///
/// This is the parking half of A7 on the tables package D owns: a real road,
/// a real home plan from the road side's fixtures, real kerb slots and real
/// cut masks, with the lot's stalls stood in for while the site table is
/// package B's. The full trip version — a car that drives in, is held at the
/// gate and gives up — is package E's `drive_in_and_park_test` and the
/// A7 it owns.
library;

import 'package:acro_space_simulator/domain/colony/city/city_layout.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_constants.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/kerb_mask.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/kerb_slots.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_graph_builder.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/parked_cars.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/site_table.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/slot_pool.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_tuning.dart';
import 'package:flutter_test/flutter_test.dart';

import '../colony/site_access/site_plan_fixtures.dart';
import 'site_fixture.dart';

/// The lot's stalls, while `SiteTable` is a stub: a binding reservation or a
/// parked car per stall, and `firstFreeStall` over them in order — what
/// package B builds from the plan's `stallOrder` (§7.3 step 1).
class _Stalls {
  _Stalls(int capacity)
      : res = List<int>.filled(capacity, -1),
        car = List<int>.filled(capacity, -1);

  final List<int> res, car;

  int get capacity => res.length;

  int get used {
    var n = 0;
    for (var i = 0; i < capacity; i++) {
      if (res[i] >= 0 || car[i] >= 0) n++;
    }
    return n;
  }

  int firstFree() {
    for (var i = 0; i < capacity; i++) {
      if (res[i] < 0 && car[i] < 0) return i;
    }
    return -1;
  }

  bool reserve(int stall, int vehicle) {
    if (res[stall] >= 0 || car[stall] >= 0) return false;
    res[stall] = vehicle;
    return true;
  }

  void occupy(int stall, int parked) {
    res[stall] = -1;
    car[stall] = parked;
  }
}

/// Where an arrival ended up.
typedef Arrival = ({int stall, int slot, int car});

void main() {
  tearDown(AgentTuning.reset);

  test('two stalls, three arrivals: the third takes a kerb slot ahead', () {
    // A 400 m street with a home driveway on its first lot: two stalls, and
    // the back-out swing masking the kerb around the join.
    final layout = CityLayout()
      ..commitRoad(
          controls: const [Vec2(0, 0), Vec2(400, 0)],
          roadClass: RoadClass.street);
    final g = RoadGraph.of(layout);
    final src = FixturePlanSource(
        g, {g.lotIds.first: SyntheticTemplate.home});
    final lg = LaneGraphBuilder.build(g);
    final ids = [for (final road in g.roads) road.id];
    final mask = CutKerbMask.of(lg, src,
        roadIdsAt: (stamp) => stamp == 0 ? ids : null);

    final chunk = src.chunks.first;
    final join = chunk.joinStart(0);
    final cut = chunk.joinRoadS(join);
    final stalls = _Stalls(chunk.stallCountOf(0));
    expect(stalls.capacity, 2, reason: 'a home pad holds two');

    // The arrival edge is the one whose right kerb is the lot's: the join
    // is on the left of the road's own line, so it is the backward edge.
    final edge = chunk.joinRight(join) ? 0 : 1;
    final lane = lg.laneOf(edge, 0);
    final destT = lg.travelArc(edge, cut);

    final kerbs = KerbTable()..bind(lg);
    kerbs.applyMasks(SiteTable(), lg, mask);
    final cars = ParkedCarTable(capacity: 16);

    /// D17 steps 1 and 2 for one arrival, as `CityAgents.arrived` runs them
    /// (§7.3): the destination's own stalls, then a kerb slot ahead.
    Arrival arrive(int vehicle) {
      final stall = stalls.firstFree();
      if (stall >= 0) {
        expect(stalls.reserve(stall, vehicle), isTrue);
        final car = cars.parkLot(
            building: 1,
            row: 0,
            stall: stall,
            stallKey: 100 + stall,
            ownerKind: CarOwnerKind.homePool,
            owner: vehicle,
            kind: 0,
            variant: 0);
        stalls.occupy(stall, car);
        return (stall: stall, slot: -1, car: car);
      }
      final slot = kerbs.reserveAhead(lane, destT, vehicle);
      if (slot < 0) {
        return (
          stall: -1,
          slot: -1,
          car: cars.garage(
              building: 1,
              ownerKind: CarOwnerKind.homePool,
              owner: vehicle,
              kind: 0,
              variant: 0)
        );
      }
      final car = cars.parkKerb(
          building: 1,
          edge: kerbs.slotEdge(slot),
          slot: slot,
          side: kerbs.slotSide(slot),
          ownerKind: CarOwnerKind.homePool,
          owner: vehicle,
          kind: 0,
          variant: 0);
      kerbs.occupy(slot, car);
      return (stall: -1, slot: slot, car: car);
    }

    final first = arrive(201);
    final second = arrive(202);
    expect(first.stall, 0);
    expect(second.stall, 1);
    expect(stalls.used, 2, reason: 'lotUsed counts cars and reservations');
    expect(cars.lotCars, 2);
    expect(cars.kerbCars, 0, reason: 'a lot with room never reaches step 2');

    // The third arrival: no stall, so a kerb slot AHEAD on its own edge.
    final third = arrive(203);
    expect(third.stall, -1, reason: 'it never enters the lot');
    expect(third.slot, greaterThanOrEqualTo(0));
    expect(cars.kerbCars, 1);
    expect(stalls.used, 2, reason: 'and it reserved no stall on the way');

    final at = kerbs.slotT(third.slot);
    expect(kerbs.slotEdge(third.slot), edge, reason: 'the arrival edge');
    expect(kerbs.slotLane(third.slot), lane, reason: 'the kerb its lane serves');
    expect(at, greaterThanOrEqualTo(destT), reason: 'ahead of the car');
    expect(at - destT, lessThanOrEqualTo(AgentTuning.kerbAheadM));
    expect(kerbs.isMasked(third.slot), isFalse);
    expect(at, greaterThan(destT + kHomeCutHalfM + kHomeSwingDownM),
        reason: 'past the back-out swing: a car in it would block every '
            'departure from the pad');
    expect(kerbs.carOf(third.slot), third.car);
    expect(kerbs.isFree(third.slot), isFalse);

    // A fourth arrival gets its own slot, never the third's.
    final fourth = arrive(204);
    expect(fourth.slot, isNot(third.slot));
    expect(kerbs.slotT(fourth.slot), greaterThan(at));

    // The mask is what moved the third car along: without it, the nearest
    // slot ahead is the one in the swing path.
    final open = KerbTable()..bind(lg);
    final unmasked = open.reserveAhead(lane, destT, 205);
    expect(unmasked, greaterThanOrEqualTo(0));
    expect(open.slotT(unmasked), lessThan(at));
    expect(
        mask.parkingBlocked(open.slotEdge(unmasked), open.slotT(unmasked),
            open.slotSide(unmasked) == 1),
        isTrue);
  });

  test('a full lot and a full kerb garages the car (T4a stops at step 2)',
      () {
    final layout = CityLayout()
      ..commitRoad(
          controls: const [Vec2(0, 0), Vec2(400, 0)],
          roadClass: RoadClass.street);
    final g = RoadGraph.of(layout);
    final lg = LaneGraphBuilder.build(g);
    final kerbs = KerbTable()..bind(lg);
    final cars = ParkedCarTable(capacity: 16);
    final lane = lg.laneOf(0, 0);

    // Every slot within reach taken, and nothing beyond it: D17 steps 3–5
    // are T4b's, so what step 2 cannot place is garaged (§7.3 staging).
    const destT = 300.0;
    for (var s = 0; s < kerbs.slotCount; s++) {
      if (kerbs.slotEdge(s) == 0) kerbs.occupy(s, 1000 + s);
    }
    expect(kerbs.reserveAhead(lane, destT, 301), -1);
    final garaged = cars.garage(
        building: 1,
        ownerKind: CarOwnerKind.commuter,
        owner: 301,
        kind: 0,
        variant: 0);
    expect(garaged, isNot(SlotPool.none));
    expect(cars.garagedCars, 1);
    expect(CarWhere.values[cars.where[SlotPool.slotOf(garaged)]],
        CarWhere.garaged);
  });
}
