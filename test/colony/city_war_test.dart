// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_loyalty.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/city_war.dart';
import 'package:acro_space_simulator/domain/colony/city/commodity.dart';
import 'package:acro_space_simulator/domain/combat/formation.dart';
import 'package:acro_space_simulator/domain/combat/launch/plan_operation.dart';
import 'package:acro_space_simulator/domain/combat/operation.dart';
import 'package:flutter_test/flutter_test.dart';

import '../traffic/traffic_fixture.dart';

/// A colony's side of the war: combat.md §7.3 and §7.6.
void main() {
  final barracks = kUtilCatalog.firstWhere((s) => s.type == 'barracks');

  /// A source colony: the starter kit plus a barracks on a street lot, fed.
  ({CitySim city, String site}) source({double people = 60}) {
    final city = starterKit()..id;
    String? site;
    for (final lot in freeLots(city)) {
      if (place(city, lot.id, barracks)) {
        site = lot.id;
        break;
      }
    }
    expect(site, isNotNull, reason: 'a street lot the barracks fits');
    city.stock[Commodity.rations] = 200;
    city.stock[Commodity.guns] = 40;
    city.stock[Commodity.ammo] = 200;
    city.population = people;
    run(city, 2);
    return (city: city, site: site!);
  }

  /// A target in standoff whose rebels hold the port: a Moon colony, which
  /// lives on its oxygen deliveries and so cannot leave (secession §3.4) —
  /// an Earth colony driven this far simply secedes.
  CitySim seizedTarget() {
    final city = starterKit(body: 'moon');
    run(city, 2);
    city.loyalty
      ..level = 0
      ..stage = LoyaltyStage.standoff
      ..selfSufficiency = 0
      ..sufficiencyMeasured = true
      ..portSeized = true
      ..impoundPending = true
      ..desperation = 0.6;
    return city;
  }

  group('a barracks as a source of troopers', () {
    test('fields half its staff at the strike throttle, with kit from its own '
        'inputs', () {
      final s = source();
      final src = s.city.trooperSources().single;
      expect(src.siteId, s.site);
      expect(src.ready, isTrue);
      expect(src.available, (30 * s.city.restThrottle * 0.5).floor());
      expect(src.kitPerTrooperDay[Commodity.rations], closeTo(2.0, 1e-12));
      expect(src.kitPerTrooperDay[Commodity.guns], closeTo(0.2, 1e-12));
      expect(src.kitPerTrooperDay[Commodity.ammo], closeTo(1.2, 1e-12));
    });

    test('is not ready without its inputs, and says why', () {
      final s = source();
      s.city.stock[Commodity.ammo] = 0;
      final src = s.city.trooperSources().single;
      expect(src.ready, isFalse);
      expect(src.notReadyWhy, 'short of ammo');
    });
  });

  group('troopers away', () {
    test('deploying half a barracks halves its jobs and its safety, and the kit '
        'leaves the stock', () {
      final s = source(people: 200);
      final c = s.city;
      run(c, 1);
      final jobsBefore = c.jobs, safetyBefore = c.services['safety'] ?? 0;
      final ammoBefore = c.stockOf(Commodity.ammo);
      c.applyCombatWrite(DeployWrite(1, s.site, 15, 30, const {Commodity.ammo: 54}));
      run(c, 1);
      expect(c.siteFactorOf(s.site), 0.5);
      expect(c.jobs, jobsBefore - 15);
      expect(c.services['safety'], closeTo(safetyBefore - 75, 1e-9));
      expect(c.stockOf(Commodity.ammo), lessThan(ammoBefore - 50));
      expect(c.troopersAway, 15);
    });

    test('coming home ends the deployment; the wounded wait two days, the dead '
        'are charged to the colony', () {
      final s = source(people: 200);
      final c = s.city;
      c.applyCombatWrite(DeployWrite(1, s.site, 15, 30, const {}));
      final popBefore = c.population;
      c.applyCombatWrite(TroopersHomeWrite(1, s.site, alive: 9, wounded: 3, dead: 3));
      expect(c.troopersAway, 0);
      expect(c.siteFactorOf(s.site), 1.0);
      expect(c.population, closeTo(popBefore - 3, 1e-9));
      expect(c.troopersRecovering, 3);
      run(c, 2 * 120 + 1);
      expect(c.troopersRecovering, 0);
      expect(c.war.wounded, isEmpty);
    });
  });

  group('the retaken port', () {
    test('without a garrison the rebels take it straight back (the trap)', () {
      final t = seizedTarget();
      t.loyalty.releaseByForce();
      expect(t.loyalty.portSeized, isFalse);
      run(t, 1);
      expect(t.loyalty.portSeized, isTrue, reason: 'nothing about the standoff changed');
    });

    test('a garrison holds it, the player hears the true story, and it costs '
        'loyalty, not desperation', () {
      // Under the 0.35 a standoff must climb past to end, but above 0, so the
      // cost shows.
      final t = seizedTarget()..loyalty.level = 0.3;
      final level = t.loyalty.level, desp = t.loyalty.desperation;
      final attended = t.loyalty.attendedAtS;
      t.applyCombatWrite(PortRetakenWrite(PortGarrison(
          opId: 1,
          homeColonyId: 'src',
          count: 4,
          perTrooperDay: const {Commodity.rations: 2, Commodity.ammo: 1.2},
          stock: {Commodity.rations: 100, Commodity.ammo: 100})));
      expect(t.loyalty.notices.last.kind, LoyaltyNoticeKind.portRetaken);
      expect(t.loyalty.notices.last.message, 'Your troopers have retaken the spaceport.');
      expect(t.loyalty.level, closeTo(level - 0.05, 1e-12));
      expect(t.loyalty.desperation, desp);
      expect(t.loyalty.attendedAtS, attended, reason: 'force is not governance');
      run(t, 30);
      expect(t.loyalty.portSeized, isFalse);
      expect(t.loyalty.forceUsed, isTrue);
    });

    test('a win does not make a standoff colony secede on the next step', () {
      final t = seizedTarget();
      t.loyalty.desperation = 0.95;
      t.applyCombatWrite(PortRetakenWrite(PortGarrison(
          opId: 1, homeColonyId: 'src', count: 4,
          perTrooperDay: const {}, stock: {})));
      run(t, 1);
      expect(t.loyalty.allegiance, Allegiance.colonial);
    });

    test('the garrison eats its stock; unpaid for a day, a tenth go home', () {
      final t = seizedTarget();
      t.applyCombatWrite(PortRetakenWrite(PortGarrison(
          opId: 1, homeColonyId: 'src', count: 20,
          perTrooperDay: const {Commodity.rations: 2},
          stock: {Commodity.rations: 20})));
      run(t, 60);
      expect(t.war.garrison!.stock[Commodity.rations], closeTo(0, 1e-9),
          reason: '20 troopers eat 40 rations a day; 20 last half a day');
      run(t, 121);
      expect(t.war.garrison!.count, 18);
      expect(t.war.outbox.whereType<GarrisonHomeEvent>().single.count, 2);
    });

    test('a failed attempt costs loyalty and adds desperation', () {
      final t = seizedTarget()..loyalty.level = 0.3;
      final level = t.loyalty.level, desp = t.loyalty.desperation;
      t.applyCombatWrite(const PortRepulsedWrite());
      expect(t.loyalty.level, closeTo(level - 0.1, 1e-12));
      expect(t.loyalty.desperation, closeTo(desp + 0.05, 1e-12));
      expect(t.loyalty.portSeized, isTrue);
    });
  });

  group('telling the war', () {
    test('a stage change is posted; the first tick posts nothing', () {
      final t = seizedTarget();
      run(t, 1);
      t.war.outbox.clear();
      run(t, 1);
      expect(t.war.outbox, isEmpty);
      t.loyalty.allegiance = Allegiance.independent;
      run(t, 1);
      expect(t.war.outbox.whereType<StageChangedEvent>(), isNotEmpty);
    });

    test('a lost home site is posted and the deployment let go', () {
      final s = source();
      s.city.applyCombatWrite(DeployWrite(1, s.site, 4, 30, const {}));
      s.city.clearParcel(s.site);
      run(s.city, 1);
      expect(s.city.war.outbox.whereType<SiteLostEvent>().single.siteId, s.site);
      expect(s.city.troopersAway, 0);
    });
  });

  test('the war state and the force record survive a save', () {
    final s = source(people: 200);
    final c = s.city;
    c.applyCombatWrite(DeployWrite(7, s.site, 10, 30, const {}));
    c.applyCombatWrite(TroopersHomeWrite(7, s.site, alive: 8, wounded: 2, dead: 0));
    c.applyCombatWrite(DeployWrite(8, s.site, 6, 30, const {}));
    c.loyalty.forceUsed = true;
    final back = CitySim.fromJson(c.toJson(), bodies: fixtureBodies);
    expect(back.troopersAway, 6);
    expect(back.siteFactorOf(s.site), closeTo(0.8, 1e-12));
    expect(back.troopersRecovering, 2);
    expect(back.loyalty.forceUsed, isTrue);
    final quiet = starterKit();
    expect(quiet.toJson().containsKey('war'), isFalse, reason: 'nothing at war, nothing saved');
  });

  test('from snapshots to a resolved operation and back home', () {
    final s = source(people: 400);
    final t = seizedTarget();
    final target = t.launchSnapshot();
    expect(target.portSeized, isTrue);
    expect(target.spaceportJobs, greaterThan(0));
    final src = s.city.sourceSnapshot();
    final avail = src.sources.single.available;
    final planned = planPortRetake(
      operationId: 1,
      target: target,
      sources: [src],
      draws: [TrooperDraw(src.colonyId, s.site, avail)],
      garrison: 2,
    );
    expect(planned.refusal, isNull);
    final op = planned.operation!;
    for (final d in planned.debits) {
      s.city.applyCombatWrite(DeployWrite(op.id, d.siteId, d.troopers, d.jobs, d.kit));
    }
    expect(s.city.troopersAway, avail);
    var guard = 0;
    while (!op.resolved && guard++ < 6000) {
      op.advance(0.5);
    }
    expect(op.resolved, isTrue);
    // ignore: avoid_print
    print('${src.name}: $avail troopers vs ${op.defenderRaised} → ${op.outcome} '
        '(${op.band}), ${op.attackerDead} dead, ${op.attackerWounded} wounded');
    final popBefore = s.city.population;
    for (final h in op.attackerByHome()) {
      s.city.applyCombatWrite(TroopersHomeWrite(op.id, null,
          alive: h.alive, wounded: h.wounded, dead: h.dead));
    }
    expect(s.city.troopersAway, 0);
    expect(s.city.population, closeTo(popBefore - op.attackerDead, 1e-9));
    if (op.outcome == OperationOutcome.won) {
      t.applyCombatWrite(const PortRetakenWrite(null));
      expect(t.loyalty.portSeized, isFalse);
    }
  });

  test('troopers go in even squads of at most eight, never a lone straggler', () {
    final s = source(people: 400);
    final src = s.city.sourceSnapshot();
    final avail = src.sources.single.available;
    expect(avail, greaterThanOrEqualTo(9));
    for (final n in {9, avail}) {
      final op = planPortRetake(
        operationId: 1,
        target: seizedTarget().launchSnapshot(),
        sources: [src],
        draws: [TrooperDraw(src.colonyId, s.site, n)],
      ).operation!;
      final sizes = [
        for (final f in op.formations)
          if (f.side == CombatSide.attacker) f.count,
      ];
      expect(sizes.fold<int>(0, (a, b) => a + b), n);
      expect(sizes.length, (n + 7) ~/ 8);
      expect(sizes.reduce(math.max) - sizes.reduce(math.min), lessThanOrEqualTo(1),
          reason: '$n troopers split as $sizes');
    }
  });

  test('a planner refusal names the reason', () {
    final s = source();
    final t = seizedTarget();
    final src = s.city.sourceSnapshot();
    final tooMany = planPortRetake(
        operationId: 1,
        target: t.launchSnapshot(),
        sources: [src],
        draws: [TrooperDraw(src.colonyId, s.site, 999)]);
    expect(tooMany.refusal, contains('can field only'));
    t.loyalty.portSeized = false;
    final notSeized = planPortRetake(
        operationId: 1, target: t.launchSnapshot(), sources: [src], draws: const []);
    expect(notSeized.refusal, 'The spaceport is not held by rebels.');
  });
}
