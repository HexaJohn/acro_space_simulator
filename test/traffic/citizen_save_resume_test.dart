// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A town with people in it, saved and resumed (docs/plans/agent-traffic.md
/// §14.1, §14.3, §14.4; slice3-implementation.md §0 Q4).
///
/// The same PEOPLE come back — the same homes, the same jobs, the same
/// licences — and every car that was somebody's is theirs again. That second
/// half is what §0 Q4's one direction buys: the `cit` block carries no car
/// column at all, because a car has no stable save id; the CAR row carries
/// the dense index of its owner in that block, and the load rebuilds
/// `CitizenTable.car` from it as each car goes down. So the assertion that
/// matters is not "the columns round-tripped" but "the same person owns the
/// same car, on the same stall".
///
/// Agents in flight are never saved (§14.3), so a citizen the save caught
/// TRAVELLING cannot come back on the road: they resume where their leg
/// began, with a five-second wake, and their car is wherever it was parked.
/// That is the one thing a load deliberately does not restore, and it is
/// asserted here as a rule rather than as a loss.
///
/// The digest (§17.4) is the last word: two colonies that agree on it agree
/// on every column the citizens, the budgets, the matching and the parked
/// cars live in.
library;

import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/citizen_table.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/city_agents.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/parked_cars.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_tuning.dart';
import 'package:flutter_test/flutter_test.dart';

import 'traffic_fixture.dart';

void main() {
  tearDown(AgentTuning.reset);

  test('a town of citizens is saved and resumed: the same people, the same '
      'homes and jobs, the same cars, and the same digest', () {
    // A settled City Builder town on its own site book, run long enough that
    // its people are housed and hired, its cars are standing on stalls and at
    // kerbs, and somebody is out on the road.
    //
    // A hundred and twenty people, not a share of the housing: a fully built
    // starter town feeds about two hundred, and one settled to its roofline
    // starves and empties itself while the window runs (the colony economy's
    // own behaviour, and no business of this test).
    AgentTuning.commuteRatePerResident = 0.004;
    final city = town(agentTraffic: true);
    city.agents.debugSettle(people: 120);
    run(city, 150);
    final a = city.agents;
    final was = _census(a);
    final flying = _inFlight(a);
    expect(was.length, greaterThan(20), reason: 'a town with people in it');
    expect(was.where((p) => p.work.isNotEmpty).length, greaterThan(10),
        reason: 'people at work');
    expect(flying, isNotEmpty,
        reason: 'and somebody on the road, whom §14.3 does not save');
    final cars = a.parkedCars!;
    expect(cars.lotCars, greaterThan(0), reason: 'cars on stalls');
    expect(cars.kerbCars, greaterThan(0), reason: 'and cars at kerbs');
    final owned = _owners(a);
    expect(owned.length, greaterThan(10), reason: 'cars with owners');

    // The save, and the load that puts it down.
    final json = city.toJson();
    final block = json['agents']! as Map<String, dynamic>;
    expect(block['v'], 2);
    expect((block['cit']! as Map)['home'], hasLength(was.length),
        reason: 'the citizens are written dense, in slot order');
    expect(block.containsKey('ledger'), isTrue);
    expect(block.containsKey('pop'), isTrue);

    final back = CitySim.fromJson(json, bodies: fixtureBodies);
    back.advance(0.5);
    final b = back.agents;

    // The same people: same count, same homes, same jobs, same licences —
    // each read by the SITE they stand on, which is the only name for a
    // building a save has (§14.1).
    final now = _census(b);
    expect(now, orderedEquals(was),
        reason: 'the same citizens, in the same slot order');

    // The same cars, owned by the same people and standing where they stood.
    expect(_owners(b), _mapWithoutFlight(owned, flying),
        reason: 'every car that was somebody\'s is theirs again, on the same '
            'site and the same stall key');

    // §14.3: nobody comes back on the road, and the travellers resume where
    // their leg began, due five seconds on.
    for (var i = 0; i < b.citizens!.highWater; i++) {
      if (!b.citizens!.isSlotLive(i)) continue;
      expect(b.citizens!.agent[i], -1, reason: 'no agent in flight');
      expect(b.citizens!.state[i], isNot(CitizenState.travelling.index));
      expect(b.citizens!.state[i], isNot(CitizenState.riding.index));
    }
    expect(b.vehicles!.liveCount, 0, reason: 'a load starts its ramp afresh');

    // The budgets came with them, so the first `syncExternal` measures only
    // what somebody else changed (§14.1's `last`) and the load does not
    // reconcile a second town on top of the one it just restored — which is
    // what a colony resumed without them would do, and it would show as
    // twice the people.
    expect(b.citizens!.liveCount, a.citizens!.liveCount);
    expect(back.population, closeTo(city.population, 3),
        reason: 'the tick the load ran moved it by a tick\'s worth, no more');

    // And the whole history agrees: a colony saved and resumed digests as one
    // that was resumed from the same bytes (§17.4).
    final twin = CitySim.fromJson(json, bodies: fixtureBodies)..advance(0.5);
    expect(twin.agents.digest(), b.digest());
  });
}

/// One citizen as a save can name them: the site their home and their job
/// stand on, and their flags. The STATE is deliberately not here — §14.3
/// moves a traveller's — and it is asserted on its own.
typedef _Person = ({String home, String work, int flags});

/// Every live citizen of [a], in slot order, named by site.
List<_Person> _census(CityAgents a) {
  final c = a.citizens!, b = a.buildings!;
  String site(int slot) =>
      slot >= 0 && slot < b.highWater && b.isSlotLive(slot)
          ? b.siteId[slot]
          : '';
  return [
    for (var i = 0; i < c.highWater; i++)
      if (c.isSlotLive(i))
        (home: site(c.home[i]), work: site(c.work[i]), flags: c.flags[i]),
  ];
}

/// The places in the census of the citizens the save caught on the road:
/// the ones §14.3 resumes at their origin, whose car was a VEHICLE at the
/// moment of the save and so was never written at all.
Set<int> _inFlight(CityAgents a) {
  final c = a.citizens!;
  final out = <int>{};
  var n = 0;
  for (var i = 0; i < c.highWater; i++) {
    if (!c.isSlotLive(i)) continue;
    if (c.state[i] == CitizenState.travelling.index ||
        c.state[i] == CitizenState.riding.index) {
      out.add(n);
    }
    n++;
  }
  return out;
}

/// Per citizen-owned car of [a]: the person who owns it, by their place in
/// the census, and where it stands. A car whose owner is a legacy building
/// handle is not here — nobody owns it yet (§0 Q3).
Map<int, String> _owners(CityAgents a) {
  final c = a.citizens!, cars = a.parkedCars!, b = a.buildings!;
  final dense = <int, int>{};
  var n = 0;
  for (var i = 0; i < c.highWater; i++) {
    if (c.isSlotLive(i)) dense[i] = n++;
  }
  final out = <int, String>{};
  for (var i = 0; i < cars.pool.highWater; i++) {
    if (!cars.pool.isSlotLive(i)) continue;
    if (cars.ownerKind[i] != CarOwnerKind.citizen.index) continue;
    final owner = cars.owner[i];
    if (!c.isLive(owner)) continue;
    final at = dense[CitizenTable.slotOf(owner)];
    if (at == null) continue;
    final building = cars.building[i];
    final site = building >= 0 &&
            building < b.highWater &&
            b.isSlotLive(building)
        ? b.siteId[building]
        : '';
    // A car on a lot or in a garage is named by the SITE it belongs to and
    // the stall key it stands on, which is exactly what the save writes
    // (§14.1, C-19). A kerb car belongs to no site at all — it is saved by
    // its POSE and re-snapped to the nearest slot on load — so it is named
    // by the road edge it stands beside.
    out[at] = switch (CarWhere.values[cars.where[i]]) {
      CarWhere.lot => 'lot@$site#${cars.stallKey[i]}',
      CarWhere.kerb => 'kerb@edge${cars.edge[i]}',
      CarWhere.garaged => 'garaged@$site',
    };
  }
  return out;
}

/// [owned] without the people in [flying]: their car went with them into the
/// vehicle table and was never saved (§14.3), so a load has no row to give
/// back.
Map<int, String> _mapWithoutFlight(Map<int, String> owned, Set<int> flying) {
  final out = <int, String>{};
  owned.forEach((at, where) {
    if (flying.contains(at)) return;
    out[at] = where;
  });
  return out;
}
