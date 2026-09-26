// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/traffic/agent_kind.dart'
    hide CitizenState;
import 'package:acro_space_simulator/domain/colony/city/traffic/building_table.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/citizen_match.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/citizen_table.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/citizen_trips.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/city_agents.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/parked_cars.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/slot_pool.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_time.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_tuning.dart';
import 'package:flutter_test/flutter_test.dart';

import 'traffic_fixture.dart';

/// Slice 3's demand: §6.4's activity loop on the headless City Builder town,
/// which replaced `CommuteSynth`'s per-building rate (§6.7) and retires
/// `commute_synth_test.dart` with it.
///
/// Every case that file pinned is carried over and asked of PEOPLE instead of
/// buildings: that a day's cycle runs (leave home, reach work, come home),
/// that the demand lands where §6.5's design rate put it, that a cap defers a
/// trip at its origin and never drops one onto the road, and that the
/// inspector can still be told who is driving and why. The rest is new, and
/// is what an activity loop has to answer for: the dwells, the mode, the
/// errands, and that nobody's wake is lost.
///
/// **This file makes its own citizens.** `CityAgents` does not yet realise a
/// population (package E), so each test spawns them into the core's own
/// [CitizenTable] with [settle] and hands the ones who own a car a garaged
/// car at home — which is exactly what §6.6's mint does when the home lot has
/// no room. Everything after that is the shipping code.
void main() {
  tearDown(AgentTuning.reset);

  // ---- The day's cycle -------------------------------------------------------

  test('citizens leave home, reach work, and come home again', () {
    final a = agentsOn(town());
    runAgents(a, 2);
    final people = settle(a);
    expect(people.length, greaterThan(10));
    var sawAtWork = false, sawHomeward = false, sawTravelling = false;
    final errors = <String>[];
    var checks = 0;
    runAgents(a, 900, each: () {
      final t = a.vehicles!;
      for (var sl = 0; sl < t.highWater; sl++) {
        if (t.isSlotLive(sl) && t.purpose[sl] == TripPurpose.homeward.index) {
          sawHomeward = true;
        }
      }
      final c = a.citizens!;
      for (var i = 0; i < c.highWater; i++) {
        if (!c.isSlotLive(i)) continue;
        if (c.state[i] == CitizenState.atWork.index) sawAtWork = true;
        if (c.state[i] == CitizenState.travelling.index) sawTravelling = true;
      }
      if (++checks % 20 == 0) errors.addAll(lost(a));
    });
    final s = a.stats;
    expect(errors, isEmpty);
    expect(sawAtWork, isTrue, reason: 'people reached work and stayed');
    expect(sawTravelling, isTrue, reason: 'and were on the road getting there');
    expect(sawHomeward, isTrue, reason: "and set off home at the day's end");
    expect(a.commutes!.sent, greaterThan(20));
    expect(a.commutes!.commutesSent, greaterThan(10));
    expect(s.spawned, greaterThan(20));
    expect(s.arrived, greaterThan(10));
    expect(s.tripsDone, greaterThan(10));
    expect(s.tripRatio, inInclusiveRange(0.8, 3.0));
    expect(s.commuteEff, inInclusiveRange(0.6, 1.0));
    expect(s.despawnStuck + s.despawnWedge, lessThanOrEqualTo(s.spawned ~/ 10),
        reason: 'a quiet town does not jam');
    expect(s.replans, 0, reason: 'nothing was edited');
  });

  test('describe still tells the inspector who, why, from where to where, '
      'and the way', () {
    final a = agentsOn(town());
    runAgents(a, 2);
    settle(a, perHome: 2);
    runAgents(a, 200);
    final t = a.vehicles!;
    var sl = 0;
    while (sl < t.highWater && !t.isSlotLive(sl)) {
      sl++;
    }
    expect(sl, lessThan(t.highWater), reason: 'something is on the road');
    final h = t.handleOf(sl);
    final d = a.describe(h)!;
    expect(d['handle'], h);
    expect(d['kind'], 'car');
    expect(d['purpose'], anyOf('commute', 'homeward', 'errand'));
    expect(a.buildings!.handleOfSite(d['from']! as String), isNotNull);
    expect(a.buildings!.handleOfSite(d['to']! as String), isNotNull);
    expect(d['freeFlowS']! as double, greaterThan(0));
    expect((d['route']! as List<Map<String, Object?>>), isNotEmpty);
    expect(a.describe(SlotPool.none), isNull);
  });

  // ---- §6.4's rows and their dwells -------------------------------------------

  test("each row's dwell falls inside its own interval", () {
    // §6.3's matching is the facade's from package E, and it would hire the
    // 40% [settle] leaves unemployed at the first building sync: then no
    // citizen ever takes §6.4's second row and "atHome idle" is never drawn.
    // The fixture chooses who works here, so the matching stands aside.
    AgentTuning.jobMatchPerSync = 0;
    final a = agentsOn(town());
    // Away from both peaks, so `rush` is exactly 1 and every interval is the
    // knob's own. Package E publishes the day phase from `CitySim.dayPhase`
    // at every sub-step (§6.1), and the fixture town is founded at 0.25.
    a.city.dayPhase = 0;
    runAgents(a, 2);
    settle(a, perHome: 2);
    final seen = _Dwells(a);
    runAgents(a, 1200, each: seen.sample);
    expect(a.stats.deferred, 0, reason: 'no cap muddied the dwells');
    seen.expectWithin('atHome employed', AgentTuning.homeDwellMinS,
        AgentTuning.homeDwellMaxS);
    seen.expectWithin('atHome idle', AgentTuning.idleDwellMinS,
        AgentTuning.idleDwellMaxS);
    seen.expectWithin(
        'atWork', AgentTuning.commuteReturnMinS, AgentTuning.commuteReturnMaxS);
    seen.expectWithin('atErrand', AgentTuning.errandDwellMinS,
        AgentTuning.errandDwellMaxS);
  });

  test('the dwells scale with their knobs', () {
    AgentTuning.activityDwellScale = 3;
    AgentTuning.errandDwellMinS = 10;
    AgentTuning.errandDwellMaxS = 20;
    final a = agentsOn(town());
    a.city.dayPhase = 0; // rush exactly 1: the knobs and nothing else.
    runAgents(a, 2);
    settle(a, perHome: 2);
    final seen = _Dwells(a);
    runAgents(a, 1200, each: seen.sample);
    // `activityDwellScale` multiplies every interval; the errand knobs move
    // their own row and nobody else's.
    seen.expectWithin('atHome employed', 450, 1260);
    seen.expectWithin('atWork', 720, 1620);
    seen.expectWithin('atErrand', 30, 60);
  });

  test('rush hour shortens the two dwells §6.4 divides, and only those', () {
    // As above: the unrushed rows need citizens the matching has not hired.
    AgentTuning.jobMatchPerSync = 0;
    final a = agentsOn(town());
    runAgents(a, 2);
    settle(a, perHome: 2);
    // Package E publishes the day phase from `CitySim.dayPhase` at the top of
    // every sub-step (§6.1), so the peak is held on the COLONY and the
    // colony is never advanced: the whole run sits at the morning peak.
    a.city.dayPhase = 0.30;
    final seen = _Dwells(a);
    runAgents(a, 1200, each: seen.sample);
    final peak = CitizenTrips.rush(0.30);
    expect(peak, closeTo(1.6, 1e-9));
    seen.expectWithin('atHome employed', AgentTuning.homeDwellMinS / peak,
        AgentTuning.homeDwellMaxS / peak);
    seen.expectWithin('atWork', AgentTuning.commuteReturnMinS / peak,
        AgentTuning.commuteReturnMaxS / peak);
    // The unrushed rows are untouched: §6.4 divides only rows 1 and 3.
    seen.expectWithin('atErrand', AgentTuning.errandDwellMinS,
        AgentTuning.errandDwellMaxS);
    seen.expectWithin('atHome idle', AgentTuning.idleDwellMinS,
        AgentTuning.idleDwellMaxS);
  });

  // ---- The demand scale (§0, Q1) ----------------------------------------------

  test('commuteRatePerResident = 0 emits nothing at all', () {
    AgentTuning.commuteRatePerResident = 0;
    final a = agentsOn(town());
    runAgents(a, 2);
    final people = settle(a, perHome: 2);
    expect(people.length, greaterThan(10));
    runAgents(a, 600);
    final c = a.commutes!;
    expect(c.sent, 0);
    expect(c.commutesSent, 0);
    expect(c.instantTrips, 0);
    expect(c.liveCount, 0, reason: 'not one trip row was ever opened');
    expect(a.stats.spawned, 0);
    expect(a.liveVehicles, 0);
    // And nobody was dropped for it: every wake was answered, so the wheel
    // never backs up and turning the knob on again would start them.
    expect(lost(a), isEmpty);
    final cz = a.citizens!;
    for (var i = 0; i < cz.highWater; i++) {
      if (!cz.isSlotLive(i)) continue;
      expect(cz.state[i], CitizenState.atHome.index);
    }
  });

  test('at the default the demand lands where CommuteSynth left it', () {
    final a = agentsOn(town());
    runAgents(a, 2);
    const seconds = 1200.0;
    // The town FULL: one resident per unit of housing, 60% of them employed
    // and 75% owning a car — §6.5's steady state, and the same population
    // the old per-building rate was written against.
    final people = settle(a, perHome: 0);
    runAgents(a, seconds);
    final b = a.buildings!;
    var housing = 0;
    for (var sl = 0; sl < b.highWater; sl++) {
      if (b.isSlotLive(sl) && b.reachable(sl)) housing += b.housing[sl];
    }
    // What the old synthetic demand would have sent over the same town and
    // the same seconds: `kDesignCommuteRate · housing · seconds`, which is
    // the rate §6.5 derives from this very mix of employment, car ownership
    // and a 915 s cycle.
    final synth = kDesignCommuteRate * housing * seconds;
    final mine = a.commutes!.commutesSent.toDouble();
    expect(people.length, greaterThan(10));
    expect(synth, greaterThan(5));
    // Measured on this town at the time of writing: 800 residents in 800
    // units of housing, 392 job buildings, 1,200 agent seconds — 575
    // outbound commutes against the old rate's 403, a ratio of 1.43. The
    // loop cannot be asked to hit the closed form, and reads a little above
    // it on purpose: §6.5 prices a commute cycle at 915 s including two
    // 120 s drives, and a citizen without a car walks, which until the
    // pedestrians land is instant — so their day is the shorter one. Half
    // to double is the band "the default is today's behaviour" buys.
    expect(mine / synth, inInclusiveRange(0.5, 2.0),
        reason: 'the citizens made $mine outbound commutes where the old '
            'per-building rate would have sent $synth');
  });

  test('the scale is a scale: more of it is more commuting, and the knob '
      'never runs backwards', () {
    double commutes(double rate) {
      AgentTuning.commuteRatePerResident = rate;
      final a = agentsOn(town());
      runAgents(a, 2);
      settle(a, perHome: 2);
      runAgents(a, 900);
      return a.commutes!.commutesSent.toDouble();
    }

    final quarter = commutes(kDesignCommuteRate / 4);
    final one = commutes(kDesignCommuteRate);
    final four = commutes(kDesignCommuteRate * 4);
    expect(quarter, lessThan(one));
    expect(one, lessThan(four));
    expect(quarter, greaterThan(0));
  });

  // ---- §6.5's spawn cap ---------------------------------------------------------

  test('wake-ups over maxSpawnsPerStep roll to the next sub-step in wheel '
      'order, counted once, none lost and none doubled', () {
    AgentTuning.maxSpawnsPerStep = 3;
    final a = agentsOn(town());
    runAgents(a, 2);
    // Carless, so the only cap in play is the wake cap itself: an instant
    // placement asks nothing of the planner or the vehicle table.
    final people = settle(a, perHome: 2, carShare: 0, spreadS: 0);
    final c = a.commutes!, cz = a.citizens!;
    final n = people.length;
    expect(n, greaterThan(9));
    final before = a.stats.deferred;
    // Drive the wheel itself, one agent second at a time, so the test is
    // about the roll-over and not about how often the facade calls it.
    var served = <int>[];
    // On from where the facade's own clock stands, one agent second a step,
    // so the test is about the roll-over and not about how often the facade
    // calls the loop.
    var us = a.timeUs + usOf(1);
    c.wake(us);
    served = _woken(cz, people);
    expect(served.length, 3, reason: 'the cap held');
    expect(served, people.sublist(0, 3),
        reason: 'wheel order is bucket then slot, so spawn order');
    expect(a.stats.deferred - before, n - 3,
        reason: 'everyone behind the cap was deferred, once each');
    for (var k = 1; k * 3 < n; k++) {
      us += usOf(1);
      c.wake(us);
      final now = _woken(cz, people);
      final want = (k + 1) * 3 < n ? (k + 1) * 3 : n;
      expect(now.length, want, reason: 'three more served on sub-step $k');
      expect(now, people.sublist(0, want), reason: 'still in wheel order');
      expect(a.stats.deferred - before, n - 3,
          reason: 'a wake already rolled is not deferred a second time');
      served = now;
    }
    expect(served.length, n, reason: 'none lost');
    // None doubled: everyone has exactly one wake ahead of them, and the
    // ones served first are due again before the ones served last.
    for (final p in people) {
      expect(cz.isScheduled(p), isTrue);
    }
  });

  // ---- §6.4's mode: the car has to be where the person is ----------------------

  test('a citizen whose car is elsewhere does not start a car trip', () {
    final a = agentsOn(town());
    runAgents(a, 2);
    final b = a.buildings!, cz = a.citizens!, p = a.parkedCars!;
    cz.ensureBuildings(b.highWater);
    final homes = <int>[], jobs = <int>[];
    _placesOf(b, homes, jobs);
    expect(homes.length, greaterThan(2));
    expect(jobs, isNotEmpty);
    // Two neighbours with the same job. One's car is at home; the other's
    // stands at a house down the street, which is a car they cannot use.
    final near = cz.spawn(
        home: homes[0],
        work: jobs[0],
        car: CitizenTable.carNone,
        state: CitizenState.atHome,
        wakeUs: 0);
    final far = cz.spawn(
        home: homes[1],
        work: jobs[0],
        car: CitizenTable.carNone,
        state: CitizenState.atHome,
        wakeUs: 0);
    cz.car[CitizenTable.slotOf(near)] = _garage(p, homes[0], near);
    cz.car[CitizenTable.slotOf(far)] = _garage(p, homes[2], far);
    var farDrove = false, nearDrove = false;
    runAgents(a, 600, each: () {
      final t = a.vehicles!, c = a.commutes!;
      for (var sl = 0; sl < t.highWater; sl++) {
        if (!t.isSlotLive(sl)) continue;
        final who = c.citizenOf(t.owner[sl]);
        if (who == far) farDrove = true;
        if (who == near) nearDrove = true;
      }
    });
    expect(nearDrove, isTrue, reason: 'their car was at their door');
    expect(farDrove, isFalse,
        reason: '§6.4: a car trip needs the car where the person is');
    expect(a.commutes!.instantTrips, greaterThan(0),
        reason: 'they walked instead, which is an instant placement until '
            'the pedestrians land (§4.9)');
    // And the car they could not use never moved.
    expect(p.isLive(cz.car[CitizenTable.slotOf(far)]), isTrue);
    expect(p.building[SlotPool.slotOf(cz.car[CitizenTable.slotOf(far)])],
        homes[2]);
  });

  // ---- §6.4's errands (slice3 §0 Q7) -------------------------------------------

  test('an errand goes to neither home nor work, and the near door wins '
      'more often than the far one', () {
    // Never commute, so every departure from home is an errand; and dwells
    // of a second, so a run of a few thousand draws fits in a test.
    AgentTuning.errandFromHome = 1;
    AgentTuning.homeDwellMinS = 1;
    AgentTuning.homeDwellMaxS = 1;
    AgentTuning.errandDwellMinS = 1;
    AgentTuning.errandDwellMaxS = 1;
    final a = agentsOn(town());
    runAgents(a, 2);
    final b = a.buildings!, cz = a.citizens!, c = a.commutes!;
    cz.ensureBuildings(b.highWater);
    final homes = <int>[], jobs = <int>[];
    _placesOf(b, homes, jobs);
    final home = homes[0], work = jobs[0];
    final me = cz.spawn(
        home: home,
        work: work,
        car: CitizenTable.carNone,
        state: CitizenState.atHome,
        wakeUs: 0);
    final tally = <int, int>{};
    var us = a.timeUs;
    var last = -1;
    for (var i = 0; i < 4000; i++) {
      us += usOf(2);
      c.wake(us);
      final at = c.errandOf(me);
      // One count per errand, not one per sub-step spent on it.
      if (at >= 0 && at != last) tally[at] = (tally[at] ?? 0) + 1;
      last = at;
    }
    expect(tally, isNotEmpty);
    expect(tally.containsKey(home), isFalse, reason: 'never their own house');
    expect(tally.containsKey(work), isFalse, reason: 'never their own job');
    expect(tally.length, greaterThan(2), reason: 'the whole town is offered');
    // The weight is 1/(1 + skim/180) on their own mode's skim, so of two
    // candidates the nearer one is drawn more often. Take the nearest and
    // the furthest the town actually offered.
    final skims = StraightLineSkims(b);
    var nearest = -1, furthest = -1;
    var nearS = double.infinity, farS = -1.0;
    for (final at in tally.keys.toList()..sort()) {
      final s = skims.footSkim(home, at);
      if (s < nearS) {
        nearS = s;
        nearest = at;
      }
      if (s > farS) {
        farS = s;
        furthest = at;
      }
    }
    expect(farS, greaterThan(nearS * 1.5), reason: 'the two are far apart');
    expect(tally[nearest]!, greaterThan(tally[furthest]!),
        reason: 'weighted 1/(1 + skim/180) towards the near door');
  });

  // ---- Forced trips are unmoved ------------------------------------------------

  test('a forced trip is still one-way, still nobody\'s, and still answers '
      'for its vehicle', () {
    AgentTuning.commuteRatePerResident = 0;
    final a = agentsOn(town());
    runAgents(a, 4);
    final b = a.buildings!;
    final homes = <int>[], jobs = <int>[];
    _placesOf(b, homes, jobs);
    final trip = a.commutes!.force(b.handleOf(homes[0]), b.handleOf(jobs[0]));
    expect(trip, isNot(SlotPool.none));
    expect(a.commutes!.citizenOf(trip), -1, reason: 'it belongs to nobody');
    expect(a.commutes!.sent, 0, reason: 'a forced trip is not demand');
    var sawVehicle = false;
    runAgents(a, 300, each: () {
      final v = a.commutes!.vehicleOf(trip);
      if (v >= 0) {
        sawVehicle = true;
        expect(a.vehicles!.isLive(v), isTrue);
      }
    });
    expect(sawVehicle, isTrue);
    expect(a.stats.arrived, greaterThan(0));
    expect(a.commutes!.isLive(trip), isFalse,
        reason: 'one way: it ends where it arrived');
    expect(a.commutes!.instantTrips, 0, reason: 'nobody walked');
  });

  // ---- Determinism ---------------------------------------------------------------

  test('one seed, one tick sequence, one history', () {
    int run() {
      final a = agentsOn(town());
      runAgents(a, 2);
      settle(a, perHome: 2);
      runAgents(a, 600);
      return a.digest();
    }

    final first = run();
    expect(run(), first);
  });

  test('the trips come out in the same order both times', () {
    List<String> run() {
      final a = agentsOn(town());
      runAgents(a, 2);
      settle(a, perHome: 2);
      final seen = <String>[];
      final live = <int>{};
      runAgents(a, 400, each: () {
        final c = a.commutes!;
        for (var sl = 0; sl < c.pool.highWater; sl++) {
          if (!c.pool.isSlotLive(sl)) continue;
          final h = c.pool.handleOf(sl);
          if (!live.add(h)) continue;
          seen.add('${c.citizenOf(h)}:${c.originOf(h)}>${c.destOf(h)}');
        }
      });
      return seen;
    }

    final first = run();
    expect(first.length, greaterThan(20));
    expect(run(), first);
  });
}

// ---- The fixture's people ------------------------------------------------------

/// Puts people in the town's houses: [perHome] in each — or one per unit of
/// HOUSING when it is 0, which is the town full — [employedShare] of them
/// given a job in turn, and [carShare] of them a car garaged at home, which
/// is where §6.6's mint puts a car when the home lot has no room. Their first
/// wake is spread over [spreadS], so a street of identical houses does not
/// leave all in one second. Returns the handles in spawn order, which is slot
/// order and so wheel order.
List<int> settle(CityAgents a,
    {int perHome = 1,
    double employedShare = 0.6,
    double carShare = 0.75,
    double spreadS = 200}) {
  final b = a.buildings!, c = a.citizens!, p = a.parkedCars!;
  c.ensureBuildings(b.highWater);
  final homes = <int>[], jobs = <int>[];
  _placesOf(b, homes, jobs);
  final made = <int>[];
  var k = 0, nextJob = 0;
  for (final home in homes) {
    final n = perHome > 0 ? perHome : b.housing[home];
    for (var i = 0; i < n; i++) {
      final hasJob = jobs.isNotEmpty && _share(k, employedShare);
      final ci = c.spawn(
          home: home,
          work: hasJob ? jobs[nextJob++ % jobs.length] : -1,
          car: CitizenTable.carNone,
          state: CitizenState.atHome,
          wakeUs: spreadS <= 0 ? 0 : (k % 10) * spreadS / 10 * kUsPerSecond);
      if (ci == SlotPool.none) return made;
      if (_share(k * 7 + 3, carShare)) {
        c.car[CitizenTable.slotOf(ci)] = _garage(p, home, ci);
      }
      made.add(ci);
      k++;
    }
  }
  return made;
}

/// A car of [owner]'s, out of the world at building slot [home]: §7.5 D17
/// step 5's last resort, and the one place a test can put a car without a
/// lot plan under it.
int _garage(ParkedCarTable p, int home, int owner) => p.garage(
    building: home,
    ownerKind: CarOwnerKind.citizen,
    owner: owner,
    kind: AgentKind.car.index,
    variant: 0);

/// The town's served homes and its reachable job buildings, in slot order.
void _placesOf(BuildingTable b, List<int> homes, List<int> jobs) {
  for (var sl = 0; sl < b.highWater; sl++) {
    if (!b.isSlotLive(sl) || b.served[sl] == 0) continue;
    if (b.housing[sl] > 0) homes.add(sl);
    if (b.jobs[sl] > 0 && b.reachable(sl)) jobs.add(sl);
  }
}

/// A fixed share of the [k]th person, spread evenly and without a draw.
bool _share(int k, double s) => (k % 20) < (s * 20).round();

/// Every citizen the simulation can no longer wake: neither a wake on the
/// wheel nor a live trip to arrive from. Nothing may ever be on this list.
List<String> lost(CityAgents a) {
  final c = a.citizens!, t = a.commutes!;
  final out = <String>[];
  for (var i = 0; i < c.highWater; i++) {
    if (!c.isSlotLive(i)) continue;
    final h = c.handleOf(i);
    if (c.isScheduled(h) || t.tripOf(h) >= 0) continue;
    out.add('citizen $h in state ${c.state[i]} has no wake and no trip');
  }
  return out;
}

/// The citizens of [people] whose first wake has moved off zero, in the
/// order they were spawned: who the loop has served.
List<int> _woken(CitizenTable c, List<int> people) => [
      for (final p in people)
        if (c.isLive(p) && c.wakeUs[CitizenTable.slotOf(p)] > 0) p,
    ];

/// Dwells caught at the moment they are set, by §6.4's row.
///
/// A row is recognised by the state the citizen is in when their wake moves
/// forward, which is the one moment the interval is observable: the loop
/// writes the state and the wake together.
class _Dwells {
  _Dwells(this.agents);

  final CityAgents agents;
  final Map<String, double> _lo = <String, double>{};
  final Map<String, double> _hi = <String, double>{};
  final Map<String, int> _n = <String, int>{};
  List<double> _was = const [];
  List<bool> _known = const [];

  void sample() {
    final c = agents.citizens!;
    final now = agents.timeUs.toDouble();
    if (_was.length < c.capacity) {
      _was = List<double>.filled(c.capacity, -1);
      _known = List<bool>.filled(c.capacity, false);
    }
    for (var i = 0; i < c.highWater; i++) {
      if (!c.isSlotLive(i)) continue;
      final w = c.wakeUs[i];
      if (w == _was[i]) continue;
      final first = !_known[i];
      _was[i] = w;
      _known[i] = true;
      // The wake a citizen was SPAWNED with is the fixture's, not a dwell
      // §6.4 drew: the first sighting of a slot only seeds the watch.
      if (first || w <= now) continue;
      final row = _rowOf(c, i);
      if (row == null) continue;
      final s = (w - now) / kUsPerSecond;
      final lo = _lo[row], hi = _hi[row];
      _lo[row] = lo == null || s < lo ? s : lo;
      _hi[row] = hi == null || s > hi ? s : hi;
      _n[row] = (_n[row] ?? 0) + 1;
    }
  }

  String? _rowOf(CitizenTable c, int i) {
    switch (CitizenState.values[c.state[i]]) {
      case CitizenState.atHome:
        return c.work[i] >= 0 ? 'atHome employed' : 'atHome idle';
      case CitizenState.atWork:
        return 'atWork';
      case CitizenState.atErrand:
        return 'atErrand';
      case CitizenState.outOfTown:
        return 'outOfTown';
      default:
        return null;
    }
  }

  void expectWithin(String row, double minS, double maxS) {
    expect(_n[row] ?? 0, greaterThan(4),
        reason: 'row "$row" was never taken often enough to judge');
    // The watch reads after a whole 0.5 s tick, which is up to three
    // sub-steps after the dwell was set, so a draw may be read that much
    // short of itself.
    expect(_lo[row]!, greaterThanOrEqualTo(minS - 3 * kStepS - 1e-6),
        reason: '$row dwelt ${_lo[row]} s, under U($minS, $maxS)');
    expect(_hi[row]!, lessThanOrEqualTo(maxS + 1e-6),
        reason: '$row dwelt ${_hi[row]} s, over U($minS, $maxS)');
  }
}
