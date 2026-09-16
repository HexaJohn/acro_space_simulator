// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A8 (docs/plans/site-access.md §7.9, §7.6; agent-traffic.md D36): a site's
/// plan changes under the cars using it.
///
/// The three rows of §7.6, each with a car in the middle of it:
///
/// - **growth** — the `rev` moves and the joins do not: the road routes stay
///   locked (`replans == 0`), every parked car keeps its `stallKey`, and the
///   car driving the site snaps onto the new plan's lanes;
/// - **a stall taken out** — the car standing on it follows its key, and
///   where the key is gone it is relocated to the nearest free stall, or
///   garaged; both are counted;
/// - **demolition** — the plan goes: its parked cars are garaged at once, the
///   old plan is held in limbo while a car is still inside it, and a trip
///   that was on its way arrives to find the building gone (`arrivedGone`).
library;

import 'package:acro_space_simulator/domain/colony/city/traffic/city_agents.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/parked_cars.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/site_table.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/site_vehicles.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/slot_pool.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_time.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_tuning.dart';
import 'package:flutter_test/flutter_test.dart';

import '../colony/site_access/site_plan_fixtures.dart';
import 'site_fixture.dart';
import 'traffic_fixture.dart';

void main() {
  setUp(() => AgentTuning.commuteRatePerResident = 0);
  tearDown(AgentTuning.reset);

  test('growth: the rev moves, the routes stay locked, the keys are kept and '
      'the mover snaps onto the new lanes', () {
    // Validation off: a plan that republishes a new `rev` over the very same
    // geometry is not something a generator emits, and it is the only way to
    // put §7.6 row 1 — "`rev` changes, joins unchanged" — under a car with
    // every stall key provably untouched.
    final w = _World(SyntheticTemplate.strip, validate: false);
    // One car parked on a stall, and one driving the site behind it.
    final parked = w.parkOne();
    final driving = w.driveIn();
    final sites = w.a.sites!;
    final was = w.row;
    final keys = [
      for (var i = 0; i < sites.plan[was]!.stallCount; i++)
        sites.plan[was]!.stallKey(i),
    ];
    final replans = w.a.stats.replans;
    final snaps = w.a.siteStats.snaps;
    final route = routeHash(w.a, driving);

    // A plan republished with a new revision and the same geometry: growth,
    // as traffic sees it — the `rev` moved, the joins and the stalls did not
    // (§7.6 row 1).
    w.plans.edit(w.lot, (d) => d.revOverride = 0x51A11);
    w.a.advance(kStepS);

    final now = w.row;
    expect(now, isNot(was), reason: 'a new row: both halves readable at once');
    expect(sites.isRowLive(was), isFalse,
        reason: 'and nothing left inside the old one, so it was freed at the '
            'end of the very sub-step that opened the new one');
    expect(w.a.stats.replans, replans, reason: 'D36: no road route re-planned');
    expect(routeHash(w.a, driving), route, reason: 'its route is untouched');
    expect([
      for (var i = 0; i < sites.plan[now]!.stallCount; i++)
        sites.plan[now]!.stallKey(i),
    ], keys, reason: 'every key kept');

    // The parked car moved row and kept its key and its place.
    final cars = w.a.parkedCars!;
    final i = SlotPool.slotOf(parked);
    expect(cars.row[i], now);
    expect(cars.stallKey[i], keys[cars.stall[i]]);
    expect(sites.stallCar[sites.stallBase[now] + cars.stall[i]], parked);
    expect(cars.garagedCars, 0);
    expect(w.a.siteStats.siteGarages, 0);

    // And the mover snapped: the car inside is on the NEW row's lanes.
    expect(w.a.siteStats.snaps, greaterThan(snaps));
    final sl = SlotPool.slotOf(driving);
    expect(w.a.siteVehicles!.row[sl], now);
    expect(w.a.siteVehicles!.lane[sl], greaterThanOrEqualTo(0));

    // It carries on and parks all the same.
    w.run(120, until: () => !w.a.vehicles!.isLive(driving));
    expect(w.a.vehicles!.isLive(driving), isFalse);
    expect(cars.lotCars, 2);
  });

  test('a stall taken out: the car standing on it is relocated, counted', () {
    final w = _World(SyntheticTemplate.homeTandem, validate: false);
    final sites = w.a.sites!;
    final was = w.row;
    expect(sites.plan[was]!.stallCount, 2);
    // A car on the OUTER stall, which the re-plan then takes away.
    final outer = w.parkOn(0);
    final cars = w.a.parkedCars!;
    expect(cars.stall[SlotPool.slotOf(outer)], 0);
    final relocates = w.a.siteStats.relocates;

    w.plans.edit(w.lot, (d) => d.stalls.removeAt(0));
    w.a.advance(kStepS);

    final now = w.row;
    expect(sites.plan[now]!.stallCount, 1);
    final i = SlotPool.slotOf(outer);
    expect(cars.isLive(outer), isTrue, reason: 'the car itself stands');
    expect(CarWhere.values[cars.where[i]], CarWhere.lot);
    expect(cars.row[i], now);
    expect(cars.stall[i], 0, reason: 'the stall that survived');
    expect(cars.stallKey[i], sites.plan[now]!.stallKey(0));
    expect(w.a.siteStats.relocates, relocates + 1,
        reason: 'a key that went is a counted relocation (§7.6)');
    expect(sites.stallCar[sites.stallBase[now]], outer);
    expect(sites.lotUsed[now], 1);
  });

  test('a stall taken out with nowhere left to stand garages the car', () {
    final w = _World(SyntheticTemplate.homeTandem, validate: false);
    final sites = w.a.sites!;
    final was = w.row;
    final outer = w.parkOn(0);
    final deep = w.parkOn(1);
    expect(sites.lotUsed[was], 2);
    final garages = w.a.siteStats.siteGarages;

    // Both stalls gone but one: one car keeps a place, the other has none.
    w.plans.edit(w.lot, (d) => d.stalls.removeAt(0));
    w.a.advance(kStepS);

    final cars = w.a.parkedCars!;
    expect(cars.garagedCars, 1);
    expect(w.a.siteStats.siteGarages, garages + 1);
    expect(cars.lotCars, 1);
    // The deep stall's key survived, so its car kept it; the outer one had
    // nowhere to go.
    expect(CarWhere.values[cars.where[SlotPool.slotOf(deep)]], CarWhere.lot);
    expect(CarWhere.values[cars.where[SlotPool.slotOf(outer)]],
        CarWhere.garaged);
    expect(sites.lotUsed[w.row], 1);
  });

  test('demolition: the parked cars are garaged at once, and the old plan is '
      'held in limbo while a car is still inside it', () {
    final w = _World(SyntheticTemplate.strip);
    final parked = w.parkOne();
    final inside = w.driveIn();
    final sites = w.a.sites!;
    final was = w.row;

    // The lot is cleared: the building goes at once (E14) and its plan with
    // it (§7.6 row 3).
    w.city.clearParcel(w.lot);
    w.plans.replace(w.lot, null);
    w.a.advance(kStepS);

    final cars = w.a.parkedCars!;
    expect(CarWhere.values[cars.where[SlotPool.slotOf(parked)]],
        CarWhere.garaged, reason: 'garaged at once');
    expect(w.a.siteStats.siteGarages, greaterThan(0));
    expect(sites.isRowLive(was), isTrue);
    expect(sites.rowFlags[was] & kRowLimbo, kRowLimbo,
        reason: 'the old plan is held while a car still uses it');
    expect(sites.lotCap[was], 0, reason: 'and it takes nobody new');
    expect(w.a.siteVehicles!.row[SlotPool.slotOf(inside)], was);

    // The car inside drops its reservation, drives out by an out-join, and
    // the limbo row is freed in the sub-step it left.
    w.run(600, until: () => !sites.isRowLive(was));
    expect(sites.isRowLive(was), isFalse, reason: 'limbo freed once empty');
    expect(w.a.stats.replans, 0, reason: 'D36: a site change re-plans no road');
  });

  test('demolition: a trip already on the road arrives to find it gone', () {
    final w = _World(SyntheticTemplate.strip);
    final car = w.driveOut();
    final gone = w.a.stats.arrivedGone;

    w.city.clearParcel(w.lot);
    w.plans.replace(w.lot, null);

    w.run(600, until: () => !w.a.vehicles!.isLive(car));
    expect(w.a.vehicles!.isLive(car), isFalse);
    expect(w.a.stats.arrivedGone, gone + 1);
    expect(w.a.stats.replans, 0, reason: 'D36: a site change re-plans no road');
  });
}

/// A town with one synthetic site on it, and the agents driving trips to it.
class _World {
  _World(SyntheticTemplate template, {bool validate = true})
      : city = town(),
        lot = lotOf(template) {
    a = agentsOn(city);
    plans = FixturePlanSource(city.roadGraph, {lot: template},
        validate: validate);
    a.debugPlans = plans;
    from = _anyOther(city, lot);
    // One advance to build the graph, the buildings and the site rows.
    a.advance(kStepS);
    expect(row, greaterThanOrEqualTo(0), reason: '$lot has a site row');
  }

  final dynamic city;
  final String lot;
  late final CityAgents a;
  late final FixturePlanSource plans;
  late final String from;

  int get row => a.sites!
      .rowOfBuilding(SlotPool.slotOf(a.buildings!.handleOfSite(lot)!));

  /// A car parked on the first free stall, with no trip at all: what a save
  /// restores, and what a re-plan then has to carry.
  int parkOne() => parkOn(a.sites!.firstFreeStall(row, 0));

  /// A car parked on [stall].
  int parkOn(int stall) {
    final sites = a.sites!;
    final r = row;
    final car = a.parkedCars!.parkLot(
        building: sites.building[r],
        row: r,
        stall: stall,
        stallKey: sites.plan[r]!.stallKey(stall),
        ownerKind: CarOwnerKind.homePool,
        owner: -1,
        kind: 0,
        variant: 3);
    sites.occupy(r, stall, car);
    return car;
  }

  /// A forced trip driven only as far as the road: its vehicle, still well
  /// short of the site.
  int driveOut() {
    final trip = a.forceTrip(from, lot);
    expect(trip, isNot(SlotPool.none));
    for (var i = 0; i < (120 / kStepS).round(); i++) {
      a.advance(kStepS);
      final h = vehicleOfTrip(a, trip);
      if (h != SlotPool.none && a.vehicles!.isLive(h)) return h;
    }
    fail('no car pulled out for $lot');
  }

  /// A forced trip driven until its car is INSIDE the site: its vehicle.
  int driveIn() {
    final trip = a.forceTrip(from, lot);
    expect(trip, isNot(SlotPool.none));
    var v = SlotPool.none;
    for (var i = 0; i < (200 / kStepS).round(); i++) {
      a.advance(kStepS);
      final h = vehicleOfTrip(a, trip);
      if (h != SlotPool.none) v = h;
      if (v == SlotPool.none || !a.vehicles!.isLive(v)) continue;
      final ph = SitePhase.values[a.siteVehicles!.phase[SlotPool.slotOf(v)]];
      if (ph == SitePhase.inbound) return v;
    }
    fail('no car reached the inside of $lot');
  }

  void run(double seconds, {required bool Function() until}) {
    for (var i = 0; i < (seconds / kStepS).round(); i++) {
      a.advance(kStepS);
      if (until()) return;
    }
  }
}

/// A built lot of [city] that is not [except].
String _anyOther(dynamic city, String except) {
  for (final lot in city.layout.autoParcels) {
    final id = lot.id as String;
    if (id != except && city.parcelBuildings.containsKey(id)) return id;
  }
  throw StateError('no other built lot');
}
