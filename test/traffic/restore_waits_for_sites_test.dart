// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A load that arrives before its sites do (docs/plans/agent-traffic.md
/// §14.1 as built; site-access.md §4.1, §7.6).
///
/// The defect these pin: `_placeSavedCars` ran ONCE, at the first prime with
/// a lane graph, and `takeSaved()` was consumed there. A site the colony had
/// not planned by that instant answers −1 to `rowOfSite` exactly as a site
/// that is gone does, so its cars were garaged — for good, because no later
/// tick ever looked at the block again. The book plans on a budget (about
/// 500 sites a tick, and a road edit leaves the 127k-site stand-in
/// re-planning for some 260 ticks), so a large colony that loads with a
/// backlog in flight lost lot cars, silently.
///
/// The rule as built:
///
/// - a saved lot car whose site has no row yet, but whose building stands and
///   whose plans may still arrive, is HELD — placed nowhere, not garaged;
/// - it is tried again whenever the site table SYNCS, never on a timer;
/// - the waiting ends at the first prime where the plan source says it has
///   nothing left to plan, or [kRestoreHoldS] of agent time has passed;
///   whatever is still waiting is then resolved exactly as this build
///   resolved it at the first prime — garaged at its building, dropped
///   without one — and counted;
/// - a save taken while cars are waiting writes them back out, so a save, a
///   load and a save again carry the same cars.
library;

import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/road_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_plan.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/city_agents.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/parked_cars.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/site_plan_source.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/slot_pool.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_tuning.dart';
import 'package:flutter_test/flutter_test.dart';

import 'traffic_fixture.dart';

void main() {
  // The quiet load the fixture test uses: a colony that spawned a commute in
  // the same tick would park a car no save here ever held — and, from slice
  // 3, one that settled a citizen would MINT one (§6.6). Both are off here,
  // so every car in these colonies is a car this file put there.
  setUp(() {
    AgentTuning.commuteRatePerResident = 0;
    noArrivals();
  });
  tearDown(AgentTuning.reset);

  test('a load whose sites are still being planned keeps every lot car, and '
      'puts it on its own (siteId, stallKey) once the backlog drains', () {
    final saved = _savedTown();
    final back = CitySim.fromJson(saved.json, bodies: fixtureBodies);
    // Half the sites the save parked on, not planned yet: exactly what the
    // book looks like part way through a re-plan (site-access §4.1).
    final ids = saved.keys.keys.toList()..sort();
    final late = <String>[for (var i = 0; i < ids.length; i += 2) ids[i]];
    expect(late, isNotEmpty);
    final plans = _Backlogged(BookPlanSource(back.siteAccess), late);
    back.agents.debugPlans = plans;

    back.advance(0.5);
    final a = back.agents;
    // Mid-restore, and this is the whole of the defect: a car whose site has
    // not arrived is placed NOWHERE. Garaging it here — what this build did,
    // once, at the first prime — is a decision no later tick could undo.
    expect(a.parkedCars!.garagedCars, 0,
        reason: 'a site the plans have not reached is not a site that is '
            'gone: its car waits rather than being garaged for good');
    expect(a.parkedCars!.count, saved.keys.length - late.length);
    expect(a.siteStats.restoreHeld, late.length,
        reason: 'one held car per site the plans had not reached');
    expect(a.siteStats.restoreGaveUp, 0);

    // The backlog drains. The site table syncs on the moved `sitesRev`, and
    // the cars that waited go down on the stalls they were saved on.
    plans.drain();
    back.advance(0.5);
    _expectEveryCarOnItsKey(back, saved.keys);
    expect(a.siteStats.restoreGaveUp, 0, reason: 'nobody gave up');
  });

  test('the hold ends when the plans say they are finished: what never '
      'arrived is garaged at its building, once, and counted', () {
    final saved = _savedTown();
    final back = CitySim.fromJson(saved.json, bodies: fixtureBodies);
    final never = (saved.keys.keys.toList()..sort()).first;
    final plans = _Backlogged(back.agents.plans, <String>[never]);
    back.agents.debugPlans = plans;

    back.advance(0.5);
    final a = back.agents;
    expect(a.siteStats.restoreHeld, 1);
    expect(a.siteStats.restoreGaveUp, 0);

    // The source finishes without ever planning that site. Nothing syncs —
    // no `sitesRev` move, no new row — and the car is resolved anyway: the
    // bound is asked at every prime, so a colony whose plans never move
    // again is never left holding.
    plans.settle();
    back.advance(0.5);
    expect(a.siteStats.restoreGaveUp, 1);
    expect(a.siteStats.restoreDropped, 0, reason: 'its building stands');

    final building = a.buildings!.handleOfSite(never);
    expect(building, isNotNull);
    final slot = SlotPool.slotOf(building!);
    final cars = a.parkedCars!;
    var found = 0;
    for (var i = 0; i < cars.pool.highWater; i++) {
      if (!cars.pool.isSlotLive(i) || cars.building[i] != slot) continue;
      expect(CarWhere.values[cars.where[i]], CarWhere.garaged,
          reason: 'garaged AT its building, so its home pool hands it back');
      found++;
    }
    expect(found, 1);
    expect(cars.count, saved.keys.length, reason: 'no car was lost');

    // Once, and only once: the block is done with, and the counters stand.
    run(back, 5);
    expect(a.siteStats.restoreGaveUp, 1);
    expect(a.siteStats.restoreHeld, 1);
    expect(cars.count, saved.keys.length);
  });

  test('a saved car whose building is gone is dropped, once, and counted',
      () {
    // A site the loaded colony has no building for at all — the plat rule
    // changed under the save, or the lot was cleared. That is not a site
    // that may still be planned, so it is never held: it is dropped at the
    // first prime, as it always was.
    final saved = _savedTown();
    final ids = saved.keys.keys.toList()..sort();
    final block = saved.json['agents']! as Map<String, dynamic>;
    final sites = (block['sites']! as List).cast<String>();
    final at = sites.indexOf(ids.first);
    expect(at, greaterThanOrEqualTo(0));
    sites[at] = 'lot-the-plat-no-longer-has';

    final back = CitySim.fromJson(saved.json, bodies: fixtureBodies);
    back.advance(0.5);
    final a = back.agents;
    expect(a.siteStats.restoreDropped, 1);
    expect(a.siteStats.restoreHeld, 0);
    expect(a.parkedCars!.count, saved.keys.length - 1);
    run(back, 5);
    expect(a.siteStats.restoreDropped, 1, reason: 'dropped once, not again');
  });

  test('a save taken while cars are still waiting carries them, and the load '
      'after it parks every one of them', () {
    final saved = _savedTown();
    final back = CitySim.fromJson(saved.json, bodies: fixtureBodies);
    final ids = saved.keys.keys.toList()..sort();
    final late = <String>[for (var i = 0; i < ids.length; i += 2) ids[i]];
    back.agents.debugPlans =
        _Backlogged(BookPlanSource(back.siteAccess), late);

    back.advance(0.5);
    expect(back.agents.parkedCars!.garagedCars, 0);
    expect(back.agents.parkedCars!.count, lessThan(saved.keys.length));
    expect(back.agents.siteStats.restoreHeld, late.length);

    // The save taken in that state writes the cars that are down AND the
    // rows still waiting: the same cars the first save held.
    final again = back.toJson();
    final block = again['agents']! as Map<String, dynamic>;
    expect(block['v'], 2);
    expect((block['cars']! as List), hasLength(saved.keys.length));
    // The CAR half, byte for byte. The population's own half — the budgets
    // and the realisation's stream (§14.1, slice 3) — is the colony's live
    // state and moves with every tick it runs, which is what it is for.
    final was = _agentsBlockOf(saved.json);
    expect(block['sites'], was['sites']);
    expect(block['cars'], was['cars'],
        reason: 'byte for byte the rows it was loaded from: the ones still '
            'waiting go out exactly as they came in');

    // And the load after it — whose book drains inside `fromJson` — parks
    // every one of them on its own key.
    final third = CitySim.fromJson(again, bodies: fixtureBodies);
    third.advance(0.5);
    expect(third.agents.siteStats.restoreHeld, 0,
        reason: 'a drained book has every row ready at the first prime');
    _expectEveryCarOnItsKey(third, saved.keys);
  });

  test('a source that never says it is finished is bounded by agent time',
      () {
    // The backstop. `BookPlanSource` answers from the book's last sync, so a
    // real colony settles in a tick or two; a source that can never say so
    // must still not hold a car for ever.
    AgentTuning.readoutWorkPerStep = 1; // the window below is 1,500 sub-steps
    final saved = _savedTown();
    final back = CitySim.fromJson(saved.json, bodies: fixtureBodies);
    final never = (saved.keys.keys.toList()..sort()).first;
    back.agents.debugPlans =
        _Backlogged(back.agents.plans, <String>[never]);

    back.advance(0.5);
    final a = back.agents;
    expect(a.siteStats.restoreHeld, 1);
    expect(a.siteStats.restoreGaveUp, 0);

    // Just short of the hold: still waiting, whatever the plans do.
    back.agents.advance(kRestoreHoldS - 10);
    back.advance(0.5);
    expect(a.siteStats.restoreGaveUp, 0);

    back.agents.advance(20);
    back.advance(0.5);
    expect(a.siteStats.restoreGaveUp, 1,
        reason: 'past ${kRestoreHoldS}s of agent time it is resolved');
    expect(a.parkedCars!.count, saved.keys.length);
  }, timeout: const Timeout(Duration(minutes: 3)));
}

// ---- The save every test here loads ------------------------------------------

/// A grown town with a car on the first free stall of every lot that has one,
/// saved: the JSON, and what each site's car must come back on.
typedef _Saved = ({Map<String, dynamic> json, Map<String, int> keys});

_Saved _savedTown() {
  final city = town(grown: true, agentTraffic: true);
  run(city, 30);
  final a = city.agents;
  a.forceTrip('nowhere', 'nowhere'); // primes the tables
  final sites = a.sites!;
  final cars = a.parkedCars!;
  final keys = <String, int>{};
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
        // A home pool's car with no owner: a commuter's would be woken at
        // work by the load and drive off in the tick being asserted (§14.3,
        // `restoreAtWork`).
        ownerKind: CarOwnerKind.homePool,
        owner: -1,
        kind: 0,
        variant: 7);
    if (car == SlotPool.none) continue;
    sites.occupy(r, stall, car);
    keys[a.buildings!.siteId[sites.building[r]]] = key;
  }
  expect(keys.length, greaterThan(3), reason: 'lots with stalls to park on');
  expect(cars.count, keys.length, reason: 'one car per site here');
  return (json: city.toJson(), keys: keys);
}

/// Every car of [city] stands in a lot, on the stall its `(siteId, stallKey)`
/// names, and the site row agrees that the car is on it.
void _expectEveryCarOnItsKey(CitySim city, Map<String, int> want) {
  final a = city.agents;
  final cars = a.parkedCars!;
  final sites = a.sites!;
  expect(cars.lotCars, want.length, reason: 'every car came back to a lot');
  expect(cars.garagedCars, 0);
  expect(cars.kerbCars, 0);
  for (var i = 0; i < cars.pool.highWater; i++) {
    if (!cars.pool.isSlotLive(i)) continue;
    final id = a.buildings!.siteId[cars.building[i]];
    expect(want, contains(id));
    expect(cars.stallKey[i], want[id], reason: 'the same stall, by key');
    final row = cars.row[i];
    expect(sites.plan[row]!.stallKey(cars.stall[i]), want[id]);
    expect(sites.stallCar[sites.stallBase[row] + cars.stall[i]],
        cars.pool.handleOf(i),
        reason: 'and the stall knows which car is on it');
    expect(cars.variant[i], 7);
  }
}

Map<String, dynamic> _agentsBlockOf(Map<String, dynamic> json) =>
    json['agents']! as Map<String, dynamic>;

// ---- A plan source with a backlog in flight ---------------------------------

/// [inner]'s plans, with some sites' WITHHELD: what the book looks like part
/// way through a budgeted re-plan (site-access §4.1), which nothing else in
/// the traffic fixtures can say.
///
/// A withheld site has no plan, no slot and is not current — the three
/// answers a site the book has not reached gives — while its building stands
/// in the colony's layout exactly as it always did. [plansComplete] is false
/// until [drain] or [settle], as a book with work left reports.
class _Backlogged implements SitePlanSource {
  _Backlogged(this.inner, Iterable<String> hold) {
    _hold.addAll(hold);
  }

  final SitePlanSource inner;
  final Set<String> _hold = <String>{};
  int _rev = 0;
  bool _complete = false;

  @override
  int get sitesRev => inner.sitesRev + _rev;

  @override
  List<SiteAccessChunk> get chunks => inner.chunks;

  @override
  SiteAccessPlan? planOf(String siteId) =>
      _hold.contains(siteId) ? null : inner.planOf(siteId);

  @override
  int slotOf(String siteId) =>
      _hold.contains(siteId) ? -1 : inner.slotOf(siteId);

  @override
  bool isCurrentFor(String siteId, RoadGraph g) =>
      !_hold.contains(siteId) && inner.isCurrentFor(siteId, g);

  @override
  bool get plansComplete => _complete;

  /// The backlog drains: every plan appears and `sitesRev` moves with it, so
  /// the site table syncs.
  void drain() {
    _hold.clear();
    _rev++;
    _complete = true;
  }

  /// The source finishes with the withheld sites still unplanned, and
  /// WITHOUT moving `sitesRev`: nothing syncs, and the hold must end anyway.
  void settle() => _complete = true;
}
