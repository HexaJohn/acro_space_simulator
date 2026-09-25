// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/colony/city/traffic/building_table.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/slot_pool.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_rng.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_tuning.dart';
import 'package:flutter_test/flutter_test.dart';

import 'citizen_fixture.dart';
import 'traffic_fixture.dart';

/// Housing, jobs and occupancy (docs/plans/agent-traffic.md §6.2's
/// invariants and §6.3; docs/plans/slice3-implementation.md §1.3, package
/// B): who the colony houses, who it employs, who it turns out when a
/// building shrinks or goes, and the fact that the answer is the same
/// whether the work was done in one sync or in ten.
void main() {
  tearDown(AgentTuning.reset);

  /// The order `CityAgents` runs after a building sync (§4's E wiring): the
  /// buildings, the evictions, the lay-offs, the re-housing, the job
  /// matching. Answers what each step did.
  ({int evicted, int laidOff, int housed, int hired}) syncMatch(CitizenTown t) {
    t.sync();
    return (
      evicted: t.match.evictOverHoused(),
      laidOff: t.match.layOffOverStaffed(),
      housed: t.match.rehouse(AgentTuning.rehousePerSync),
      hired: t.match.matchJobs(AgentTuning.jobMatchPerSync),
    );
  }

  /// The slots of the citizens whose row answers [test], in slot order.
  List<int> citizensWhere(CitizenTown t, bool Function(int slot) test) => [
        for (var sl = 0; sl < t.citizens.highWater; sl++)
          if (t.citizens.pool.isSlotLive(sl) && test(sl)) sl,
      ];

  int sumOver(BuildingTable b, int Function(int slot) of) {
    var total = 0;
    for (var sl = 0; sl < b.highWater; sl++) {
      if (b.isSlotLive(sl)) total += of(sl);
    }
    return total;
  }

  /// §6.2's two hard invariants, and the bookkeeping they rest on: the
  /// counts the building table carries are the people the citizen table's
  /// own per-building lists hold, and nobody is left living in a building
  /// that has gone.
  void expectHoused(CitizenTown t, String when) {
    final b = t.buildings;
    for (var sl = 0; sl < b.highWater; sl++) {
      if (!b.isSlotLive(sl)) continue;
      expect(b.residents[sl], lessThanOrEqualTo(b.housing[sl]),
          reason: '$when: ${b.siteId[sl]} is over-housed');
      expect(b.workers[sl], lessThanOrEqualTo(b.jobs[sl]),
          reason: '$when: ${b.siteId[sl]} is over-staffed');
      expect(b.residents[sl], t.citizens.residentsOf(sl),
          reason: '$when: the count and the list disagree at ${b.siteId[sl]}');
      expect(b.workers[sl], t.citizens.workersOf(sl), reason: when);
    }
    expect(sumOver(b, (sl) => b.residents[sl]),
        lessThanOrEqualTo(sumOver(b, (sl) => b.housing[sl])),
        reason: '$when: Σ residents ≤ Σ housing');
    expect(sumOver(b, (sl) => b.workers[sl]),
        lessThanOrEqualTo(sumOver(b, (sl) => b.jobs[sl])),
        reason: '$when: Σ workers ≤ Σ jobs');
    for (final sl in citizensWhere(t, (_) => true)) {
      final home = t.citizens.home[sl], work = t.citizens.work[sl];
      expect(home < 0 || b.isSlotLive(home), isTrue,
          reason: '$when: citizen $sl lives in a building that has gone');
      expect(work < 0 || b.isSlotLive(work), isTrue,
          reason: '$when: citizen $sl works at a building that has gone');
    }
  }

  test('after every sync Σ residents ≤ Σ housing and Σ workers ≤ Σ jobs, in '
      'a town that grows and in one that loses its buildings', () {
    final city = town(grown: true);
    final t = CitizenTown(on: city);
    t.sync();
    // Growing: utilisation climbs step by step, which is how a grown lot's
    // homes and jobs arrive (city_sim's `(x·uf).round()`), and people keep
    // arriving faster than one sync's budget can house them.
    for (final progress in const [0.2, 0.45, 0.65, 0.9, 1.0]) {
      growAll(city, progress: progress);
      for (var i = 0; i < 40; i++) {
        t.add();
      }
      syncMatch(t);
      expectHoused(t, 'growth to $progress');
    }
    expect(t.citizens.liveCount, 200);
    expect(citizensWhere(t, (sl) => t.citizens.home[sl] >= 0), isNotEmpty);
    expect(citizensWhere(t, (sl) => t.citizens.work[sl] >= 0), isNotEmpty);

    // Losing them: half the town's utilisation goes, and then six of its
    // lots are cleared outright.
    growAll(city, progress: 0.45);
    syncMatch(t);
    expectHoused(t, 'the town shrank');

    final b = t.buildings;
    final lots = [
      for (var sl = 0; sl < b.highWater; sl++)
        if (b.isSlotLive(sl) && b.siteId[sl].startsWith('lot-')) b.siteId[sl],
    ];
    expect(lots.length, greaterThan(8));
    for (final id in lots.take(6)) {
      city.clearParcel(id);
      syncMatch(t);
      expectHoused(t, 'after $id was cleared');
      expect(b.handleOfSite(id), isNull);
    }
    expect(b.removals, greaterThanOrEqualTo(6));
  });

  test('an eviction takes the newest residents, a lay-off the last hired',
      () {
    final t = CitizenTown();
    t.sync();
    final b = t.buildings;
    final home = t.homes.first, job = t.jobs.first;
    final beds = b.housing[home], desks = b.jobs[job];
    expect(beds, greaterThan(1));
    expect(desks, greaterThan(1));

    final moved = [for (var i = 0; i < beds + 3; i++) t.add(home: home)];
    final hired = [for (var i = 0; i < desks + 2; i++) t.add(work: job)];
    expect(t.match.evictOverHoused(), 3);
    expect(t.match.layOffOverStaffed(), 2);

    for (var i = 0; i < moved.length; i++) {
      final sl = SlotPool.slotOf(moved[i]);
      expect(t.citizens.home[sl] == home, i < beds,
          reason: 'resident $i of $beds: the last in are the first out');
      if (i >= beds) {
        expect(t.citizens.sleepsNear[sl], home,
            reason: 'an evicted citizen sleeps nearest the home they lost');
      }
    }
    for (var i = 0; i < hired.length; i++) {
      final sl = SlotPool.slotOf(hired[i]);
      expect(t.citizens.work[sl] == job, i < desks,
          reason: 'worker $i of $desks: last hired, first out');
    }
    expect(b.residents[home], beds);
    expect(b.workers[job], desks);
  });

  test('the stand-in skim is d/12 by car and 1.35·d/1.3 on foot', () {
    final t = CitizenTown();
    t.sync();
    final b = t.buildings;
    final from = t.homes.first, to = t.jobs.last;
    final de = b.centroidE[to] - b.centroidE[from];
    final dn = b.centroidN[to] - b.centroidN[from];
    final d = math.sqrt(de * de + dn * dn);
    expect(d, greaterThan(20), reason: 'two buildings, not one');
    expect(t.match.skims.carSkim(from, to), closeTo(d / 12, 1e-9));
    expect(t.match.skims.footSkim(from, to), closeTo(1.35 * d / 1.3, 1e-9));
    expect(t.match.skims.carSkim(from, from), 0);
    expect(t.match.skims.footSkim(to, from),
        closeTo(t.match.skims.footSkim(from, to), 1e-9),
        reason: 'a straight line is the same both ways');
  });

  test('a citizen with no car is never given the job only a car could '
      'reach', () {
    final w = _twoJobs(seed: 4242);
    final t = w.town;
    // Every carless citizen walks to the near job: on foot the far one is
    // six minutes further, ten times over §6.3's 30 s tie band.
    for (var i = 0; i < 20; i++) {
      t.add(home: w.home);
    }
    expect(t.match.matchJobs(20), 20);
    for (final sl in citizensWhere(t, (_) => true)) {
      expect(t.citizens.work[sl], w.near,
          reason: 'a 470 m walk is not the commute a 120 m one is');
    }

    // The same two jobs are a tie for a driver — 29 s apart — so the draw
    // sends them to both.
    final drivers = [
      for (var i = 0; i < 40; i++) t.add(home: w.home, car: 100 + i),
    ];
    expect(t.match.matchJobs(40), 40);
    final atFar = [
      for (final c in drivers)
        if (t.citizens.work[SlotPool.slotOf(c)] == w.far) c,
    ];
    expect(atFar, isNotEmpty, reason: 'a car makes the far job a candidate');
    expect(atFar.length, lessThan(40), reason: 'and the near one as well');
  });

  test('a tie inside 30 s is broken by the rng, and by nothing else', () {
    /// One citizen with a car, two equal jobs [farM] apart: which they take.
    int pick(int seed, {double farM = 470}) {
      final w = _twoJobs(seed: seed, farM: farM);
      final c = w.town.add(home: w.home, car: 7);
      expect(w.town.match.matchJobs(1), 1);
      final at = w.town.citizens.work[SlotPool.slotOf(c)];
      return at == w.near ? 0 : (at == w.far ? 1 : -1);
    }

    expect(pick(11), pick(11), reason: 'one seed, one history');
    final seen = <int>{};
    for (var seed = 1; seed <= 24; seed++) {
      seen.add(pick(seed));
    }
    expect(seen, {0, 1},
        reason: 'another seed sends them to the other job: the tie is the '
            "rng's, and not the slot order's");

    // Outside the band there is no tie to break: 900 m is 65 s further by
    // car, so every seed takes the near job.
    for (var seed = 1; seed <= 12; seed++) {
      expect(pick(seed, farM: 900), 0, reason: 'the best is the best');
    }
  });

  test('a home is drawn in proportion to its vacancy, and one seed draws '
      'one history', () {
    final t = CitizenTown();
    t.sync();
    final b = t.buildings;
    // Two homes in the whole colony: nine places at one, one at the other.
    // Nothing here runs the match, so the sculpted counts stand.
    final homes = t.homes;
    expect(homes.length, greaterThan(2));
    final big = homes[0], small = homes[1];
    for (var sl = 0; sl < b.highWater; sl++) {
      if (b.isSlotLive(sl)) b.housing[sl] = 0;
    }
    b.housing[big] = 9;
    b.housing[small] = 1;

    const draws = 20000;
    var toBig = 0;
    final rng = TrafficRng(31);
    for (var i = 0; i < draws; i++) {
      final sl = b.drawVacantHome(rng);
      expect(sl == big || sl == small, isTrue);
      if (sl == big) toBig++;
    }
    expect(toBig / draws, closeTo(0.9, 0.01));

    final one = [for (var i = 0; i < 40; i++) b.drawVacantHome(TrafficRng(5))];
    final two = [for (var i = 0; i < 40; i++) b.drawVacantHome(TrafficRng(5))];
    expect(two, one, reason: 'the same seed draws the same home');

    // A full building offers nothing, and an over-full one nothing either.
    b.residents[big] = 9;
    b.residents[small] = 0;
    expect(b.housingVacancy(big), 0);
    for (var i = 0; i < 50; i++) {
      expect(b.drawVacantHome(rng), small);
    }
    b.residents[small] = 4;
    expect(b.housingVacancy(small), 0, reason: 'a vacancy is never negative');
    expect(b.drawVacantHome(rng), -1, reason: 'the colony is full');
  });

  test('the budgets hold: 64 a sync, the rest next sync, the same order '
      'either way', () {
    CitizenTown crowded() {
      final t = CitizenTown(seed: 909);
      t.sync();
      // Room for everyone, so that only the budget bounds the work.
      final b = t.buildings;
      for (var sl = 0; sl < b.highWater; sl++) {
        if (b.isSlotLive(sl) && b.housing[sl] > 0) b.housing[sl] = 40;
      }
      for (var i = 0; i < 300; i++) {
        t.add();
      }
      return t;
    }

    final once = crowded(), tenfold = crowded();
    expect(once.match.rehouse(640), 300, reason: 'one sync, every move');
    var housed = 0;
    for (var i = 0; i < 10; i++) {
      final moved = tenfold.match.rehouse(AgentTuning.rehousePerSync);
      expect(moved, i < 4 ? 64 : (i == 4 ? 44 : 0),
          reason: 'sync $i houses its 64, and the rest wait for the next');
      housed += moved;
    }
    expect(housed, 300);
    for (var sl = 0; sl < once.citizens.highWater; sl++) {
      expect(tenfold.citizens.home[sl], once.citizens.home[sl],
          reason: 'citizen $sl went to the same home either way');
    }

    // The same again for the jobs, from the same two towns now housed
    // alike: a budget spread over ten syncs hires the same people into the
    // same jobs as one sync that did it all.
    final hiredAtOnce = once.match.matchJobs(640);
    expect(hiredAtOnce, greaterThan(0));
    var hired = 0;
    for (var i = 0; i < 10; i++) {
      final took = tenfold.match.matchJobs(AgentTuning.jobMatchPerSync);
      expect(took, lessThanOrEqualTo(AgentTuning.jobMatchPerSync));
      hired += took;
    }
    expect(hired, hiredAtOnce);
    for (var sl = 0; sl < once.citizens.highWater; sl++) {
      expect(tenfold.citizens.work[sl], once.citizens.work[sl],
          reason: 'citizen $sl took the same job either way');
    }
    expect(tenfold.match.digest(0), once.match.digest(0),
        reason: 'and the two towns are the same town');
  });

  test('the homeless are the population less the housing, as socialTick '
      'counts them', () {
    final t = CitizenTown();
    t.sync();
    final b = t.buildings;
    var housing = 0;
    for (var sl = 0; sl < b.highWater; sl++) {
      if (!b.isSlotLive(sl)) continue;
      expect(b.served[sl], 1, reason: '${b.siteId[sl]} is on the network');
      housing += b.housing[sl];
    }
    expect(housing, greaterThan(10));
    for (var i = 0; i < housing + 25; i++) {
      t.add();
    }
    // Enough syncs for a 64-a-sync budget to catch up with the queue.
    for (var i = 0; i * AgentTuning.rehousePerSync < housing + 64; i++) {
      syncMatch(t);
    }
    final homeless = citizensWhere(t, (sl) => t.citizens.home[sl] < 0).length;
    expect(homeless, 25);
    expect(homeless, math.max(0, t.citizens.liveCount - housing),
        reason: 'city_sim.dart:1860 counts the same people');
  });

  test('nothing is reallocated once the town is warm', () {
    final t = CitizenTown();
    t.sync();
    for (var i = 0; i < 80; i++) {
      t.add();
    }
    for (var i = 0; i < 3; i++) {
      syncMatch(t);
    }
    final warm = <String, Object>{};
    t.match.collectBuffers(warm, 'match');
    warm['buildings.residents'] = t.buildings.residents;
    warm['buildings.workers'] = t.buildings.workers;
    warm['buildings.corpses'] = t.buildings.corpses;
    final keys = warm.keys.toList();
    expect(keys.length, 5);

    for (var i = 0; i < 200; i++) {
      syncMatch(t);
      t.match.drawVacantHome();
      t.match.pickEmigrant();
      t.match.pickForDeath();
    }
    final now = <String, Object>{};
    t.match.collectBuffers(now, 'match');
    now['buildings.residents'] = t.buildings.residents;
    now['buildings.workers'] = t.buildings.workers;
    now['buildings.corpses'] = t.buildings.corpses;
    for (final key in keys) {
      expect(identical(now[key], warm[key]), isTrue,
          reason: '$key was replaced after warm-up');
    }
  });

  test('the emigrant is the homeless first, then the unemployed, then a '
      'draw; the dying are drawn by residents', () {
    final t = CitizenTown();
    t.sync();
    final home = t.homes.first, job = t.jobs.first;
    expect(t.match.pickEmigrant(), -1, reason: 'nobody to lose');
    expect(t.match.pickForDeath(), -1);

    final settled = t.add(home: home, work: job);
    final jobless = t.add(home: home);
    final street = t.add();
    expect(t.match.pickEmigrant(), street, reason: 'the homeless go first');
    t.citizens.remove(street);
    expect(t.match.pickEmigrant(), jobless, reason: 'then the unemployed');
    t.citizens.remove(jobless);
    expect(t.match.pickEmigrant(), settled, reason: 'then whoever is drawn');

    // A death lands on a resident, in a building drawn by its residents.
    final other = t.homes[1];
    for (var i = 0; i < 20; i++) {
      t.add(home: other);
    }
    final lost = <int>{};
    for (var i = 0; i < 200; i++) {
      final c = t.match.pickForDeath();
      expect(c, isNot(-1));
      final at = t.citizens.home[SlotPool.slotOf(c)];
      expect(at == home || at == other, isTrue);
      lost.add(at);
    }
    expect(lost, {home, other}, reason: 'both homes lose someone in the end');

    // A colony of nothing but the homeless still loses someone.
    final only = CitizenTown();
    only.sync();
    final drifter = only.add();
    expect(only.match.pickForDeath(), drifter);
  });

  test('a building that goes leaves nobody living or working in it', () {
    final city = town();
    final t = CitizenTown(on: city);
    t.sync();
    final b = t.buildings;
    final home = t.homes.first, job = t.jobs.first;
    final site = b.siteId[home], jobSite = b.siteId[job];
    final people = [
      for (var i = 0; i < 3; i++) t.add(home: home, work: job),
    ];
    syncMatch(t);
    expect(b.residents[home], 3);
    expect(b.workers[job], 3);

    city.clearParcel(site);
    city.clearParcel(jobSite);
    syncMatch(t);
    for (final c in people) {
      final sl = SlotPool.slotOf(c);
      expect(t.citizens.home[sl], isNot(home),
          reason: 'the residents of a building that went are homeless — or '
              're-housed, which the same sync may have done for them');
      expect(t.citizens.work[sl] == job, isFalse);
    }
    expect(t.citizens.residentsOf(home), 0);
    expect(t.citizens.workersOf(job), 0);
  });
}

/// A town sculpted down to two jobs, [nearM] and [farM] from the one home
/// that has any room, with every other job closed.
///
/// The defaults put the two 29 s apart by car — inside §6.3's 30 s tie band,
/// so a driver may be sent to either — and 363 s apart on foot, far outside
/// it, so a citizen walking always takes the near one.
({CitizenTown town, int home, int near, int far}) _twoJobs(
    {required int seed, double nearM = 120, double farM = 470}) {
  final t = CitizenTown(seed: seed);
  t.sync();
  final b = t.buildings;
  final home = t.homes.first;
  final jobs = t.jobs;
  final near = jobs.firstWhere((sl) => sl != home);
  final far = jobs.lastWhere((sl) => sl != home && sl != near);
  for (var sl = 0; sl < b.highWater; sl++) {
    if (b.isSlotLive(sl)) b.jobs[sl] = 0;
  }
  b.housing[home] = 200;
  b.jobs[near] = 100;
  b.jobs[far] = 100;
  b.centroidE[home] = 0;
  b.centroidN[home] = 0;
  b.centroidE[near] = nearM;
  b.centroidN[near] = 0;
  b.centroidE[far] = farM;
  b.centroidN[far] = 0;
  if (!b.reachable(near) || !b.reachable(far)) {
    throw StateError('the sculpted jobs must be jobs a car can reach');
  }
  return (town: t, home: home, near: near, far: far);
}
