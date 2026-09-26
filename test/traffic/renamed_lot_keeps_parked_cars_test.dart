// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A10, the traffic half (docs/plans/site-access.md §7.9; agent-traffic.md
/// E12, §14.1). The road half is `renamed_lot_keeps_plan_test`.
///
/// - **A re-cut renames the lots** a new road re-hangs. Their buildings keep
///   their handles (E12), their plans keep their `rev` and their stall keys
///   (the book re-keys a rename without touching geometry), so every car
///   parked on them is still parked on them afterwards — and trips to them
///   still arrive.
/// - **A save and a load** put the lot cars back on the very stalls they
///   stood on, by `(siteId, stallKey)` and never by stall index (C-19,
///   §14.1). Agents in flight are not saved, so a loaded colony starts its
///   spawn ramp afresh with its cars where they were parked.
library;

import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/city_agents.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/parked_cars.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/slot_pool.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_tuning.dart';
import 'package:flutter_test/flutter_test.dart';

import 'traffic_fixture.dart';

void main() {
  // No demand and no arrivals: every car in these colonies is one this file
  // parked by hand, so a count of them is a statement about the re-cut and
  // the load, not about how many people moved in while the test ran (§6.6
  // mints a car for each of them).
  setUp(() {
    AgentTuning.commuteRatePerResident = 0;
    noArrivals();
  });
  tearDown(AgentTuning.reset);

  test('a re-cut renames the lots and every parked car stays where it stood, '
      'with trips still arriving there', () {
    // A GROWN town: its buildings are the plat's own, which a save and a
    // load both carry whole.
    final city = town(grown: true, agentTraffic: true);
    run(city, 30);
    final a = city.agents;
    final parked = _parkOnEveryLot(a);
    expect(parked.length, greaterThan(3), reason: 'lots with stalls to park on');
    final was = {for (final p in parked) p.car: a.buildings!.siteOf(p.building)};

    // A street across the town's north arm: every lot along the roads it
    // splits is re-cut and renamed (E12, `_carryRenamedLots`).
    commit(city, const FixtureRoad([Vec2(-250, 150), Vec2(250, 150)]));
    run(city, 5);

    final cars = a.parkedCars!;
    final sites = a.sites!;
    final renamed = <int>[];
    var kept = 0;
    for (final p in parked) {
      final id = a.buildings!.siteOf(p.building);
      final i = SlotPool.slotOf(p.car);
      expect(cars.isLive(p.car), isTrue, reason: 'no car was lost');
      if (id == null) {
        // The new road took the lot itself, building and all: §7.6 row 3
        // garages its cars rather than leaving them on a stall that is gone.
        expect(CarWhere.values[cars.where[i]], isNot(CarWhere.lot));
        continue;
      }
      if (id != was[p.car]) renamed.add(p.car);
      // Where the site still offers that key, the car is still on it and
      // nowhere else. A lot the re-cut left kerbside has no stall to offer:
      // §7.6 row 2 puts its car at the kerb, or garages it, and counts it.
      final row = sites.rowOfBuilding(SlotPool.slotOf(p.building));
      if (row < 0 || sites.stallIndexOfKey(row, p.key) < 0) continue;
      kept++;
      expect(CarWhere.values[cars.where[i]], CarWhere.lot);
      expect(cars.row[i], row);
      expect(cars.stallKey[i], p.key, reason: 'its key came across');
      expect(sites.plan[row]!.stallKey(cars.stall[i]), p.key);
      expect(sites.stallCar[sites.stallBase[row] + cars.stall[i]], p.car,
          reason: 'and the stall knows it');
    }
    expect(renamed, isNotEmpty, reason: 'the re-cut renamed some of them');
    expect(kept, greaterThan(parked.length ~/ 2),
        reason: 'a rename moves no stall: most lots keep their cars exactly');
    expect(cars.count, parked.length, reason: 'every car is still somewhere');

    // And trips to the renamed lots still arrive: their buildings kept
    // their handles, so the demand never lost its destination (E12).
    final b = a.buildings!;
    final targets = [
      for (final p in parked)
        if (renamed.contains(p.car) &&
            b.isLive(p.building) &&
            b.reachable(SlotPool.slotOf(p.building)))
          b.siteOf(p.building)!,
    ];
    expect(targets, isNotEmpty, reason: 'a renamed lot a trip can reach');
    final before = a.stats.arrived;
    var sent = 0;
    for (final site in targets.take(4)) {
      final trip = a.forceTrip(_anyOther(a, site), site);
      if (trip != SlotPool.none) sent++;
    }
    expect(sent, greaterThan(0));
    for (var i = 0; i < 600 && a.stats.arrived == before; i++) {
      city.advance(0.5);
    }
    expect(a.stats.arrived, greaterThan(before),
        reason: 'a trip to a renamed lot still arrives');
  });

  test('a save and a load put every lot car back on the stall it stood on',
      () {
    final city = town(grown: true, agentTraffic: true);
    run(city, 30);
    final a = city.agents;
    final parked = _parkOnEveryLot(a);
    expect(parked.length, greaterThan(3));
    final want = <String, int>{
      for (final p in parked)
        '${a.buildings!.siteOf(p.building)}': p.key,
    };
    expect(want.length, parked.length, reason: 'one car per site here');

    final json = city.toJson();
    expect((json['agents']! as Map)['v'], 2, reason: 'the block carries cars');
    final back = CitySim.fromJson(json, bodies: fixtureBodies);
    expect(back.agents.enabled, isTrue);
    back.advance(0.5);

    final cars = back.agents.parkedCars!;
    final sites = back.agents.sites!;
    expect(cars.lotCars, parked.length, reason: 'every car came back to a lot');
    expect(cars.garagedCars, 0);
    expect(cars.kerbCars, 0);
    for (var i = 0; i < cars.pool.highWater; i++) {
      if (!cars.pool.isSlotLive(i)) continue;
      final id = back.agents.buildings!.siteId[cars.building[i]];
      expect(want, contains(id));
      expect(cars.stallKey[i], want[id], reason: 'the same stall, by key');
      final row = cars.row[i];
      expect(sites.plan[row]!.stallKey(cars.stall[i]), want[id]);
      expect(sites.stallCar[sites.stallBase[row] + cars.stall[i]],
          cars.pool.handleOf(i));
      expect(cars.variant[i], 7, reason: 'kind and variant are saved too');
    }
  });
}

/// One car parked on the first free stall of every site row that has one.
List<({int car, int building, int key})> _parkOnEveryLot(CityAgents a) {
  a.forceTrip('nowhere', 'nowhere'); // primes the tables
  final sites = a.sites!;
  final cars = a.parkedCars!;
  final out = <({int car, int building, int key})>[];
  for (var r = 0; r < sites.highWater; r++) {
    if (!sites.isRowLive(r) || sites.lotCap[r] <= 0) continue;
    final stall = sites.firstFreeStall(r, 0);
    if (stall < 0) continue;
    final key = sites.plan[r]!.stallKey(stall);
    final car = cars.parkLot(
        building: sites.building[r],
        row: r,
        stall: stall,
        stallKey: key,
        ownerKind: CarOwnerKind.homePool,
        owner: -1,
        kind: 0,
        variant: 7);
    if (car == SlotPool.none) continue;
    sites.occupy(r, stall, car);
    out.add((car: car, building: a.buildings!.handleOf(sites.building[r]),
        key: key));
  }
  return out;
}

/// A reachable building of [a]'s table that is not [except]: where the trip
/// comes from.
String _anyOther(CityAgents a, String except) {
  final b = a.buildings!;
  for (var sl = 0; sl < b.highWater; sl++) {
    if (!b.isSlotLive(sl) || !b.reachable(sl)) continue;
    if (b.siteId[sl] != except) return b.siteId[sl];
  }
  throw StateError('no other reachable building');
}
