// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/colony/city/city_control.dart';
import 'package:acro_space_simulator/domain/colony/city/city_loyalty.dart';
import 'package:acro_space_simulator/domain/colony/city/city_occupation.dart';
import 'package:acro_space_simulator/domain/colony/city/city_reclaim.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/city_war.dart';
import 'package:acro_space_simulator/domain/colony/city/commodity.dart';
import 'package:flutter_test/flutter_test.dart';

import '../traffic/traffic_fixture.dart';

/// A colony held by force: combat.md §7A.
void main() {
  /// A starter colony that has just broken away by three revolts.
  CitySim independent() {
    final city = starterKit();
    run(city, 20);
    final t = city.colonyTimeS;
    city.loyalty
      ..allegiance = Allegiance.independent
      ..stage = LoyaltyStage.seceded
      ..level = 0
      ..independentAtS = t
      ..independenceCauses = '3 revolts in 15 days'
      ..revolts.addAll([t - 30, t - 20, t - 10])
      ..reclaim.grievance = const Grievance(rebellion: 1, revolts: 3);
    return city;
  }

  PortGarrison garrison({int n = 6, double stock = 200}) => PortGarrison(
        opId: 7,
        homeColonyId: 'home',
        count: n,
        perTrooperDay: const {Commodity.rations: 2, Commodity.ammo: 1.2},
        stock: {Commodity.rations: stock, Commodity.ammo: stock},
        occupation: true,
      );

  CitySim taken({int n = 6, double stock = 200}) {
    final city = independent();
    city.applyCombatWrite(const WarDeadWrite(4));
    city.applyCombatWrite(OccupyWrite(garrison(n: n, stock: stock)));
    return city;
  }

  test('a colony that left by three revolts, taken, stays taken past the next '
      'step', () {
    final city = taken();
    final l = city.loyalty;
    expect(l.allegiance, Allegiance.occupied);
    expect(l.level, closeTo(0.2, 1e-12));
    expect(l.stage, LoyaltyStage.defiant);
    expect(l.revolts, isEmpty, reason: 'kept, three revolts would expel it at once');
    expect(l.independentAtS, isNull);
    expect(l.reclaim.grievance!.revolts, 3, reason: 'the grievance is kept');
    expect(l.reclaim.grievance!.warDead, 4);
    expect(l.warDead, 4);
    expect(l.notices.last.kind, LoyaltyNoticeKind.occupied);
    run(city, 1);
    expect(l.allegiance, Allegiance.occupied);
    expect(l.selfGoverning, isFalse, reason: 'a garrison governs, not its council');
    expect(city.playerControl.allowed, isTrue);
    expect(city.war.garrison!.occupation, isTrue);
  });

  test('suppression holds rebellion growth down, and costs mood', () {
    final city = taken(n: 6);
    final pop = city.population;
    final s = city.suppression;
    expect(s, closeTo((6 / (0.05 * pop)).clamp(0.0, 0.8), 1e-12));
    expect(city.occupationMoodCost, closeTo(0.1 * s, 1e-12));
    // The same rebellion step, with and without the garrison.
    city
      ..happiness = 0
      ..crime = 0.8
      ..inequality = 0.8;
    final saved = (city.crime, city.inequality, city.corruption);
    final laws = {...city.laws};
    double grow() {
      city.laws
        ..clear()
        ..addAll(laws);
      city
        ..rebellion = 0
        ..crime = saved.$1
        ..inequality = saved.$2
        ..corruption = saved.$3;
      city.socialTick(0, 1);
      return city.rebellion;
    }

    final held = grow();
    city.war.garrison!.count = 0;
    final free = grow();
    expect(free, greaterThan(0));
    expect(held, closeTo(free * (1 - s), 1e-9));
  });

  test('three revolts under guard: it rises, and a lost rising throws the garrison out (§7N)', () {
    final city = taken();
    final t = city.colonyTimeS;
    city.loyalty.revolts.addAll([t, t, t]);
    run(city, 0.5);
    expect(city.loyalty.allegiance, Allegiance.occupied, reason: 'the fight decides it now');
    expect(city.loyalty.risen, isTrue);
    expect(city.loyalty.notices.last.kind, LoyaltyNoticeKind.uprising);
    final up = city.war.outbox.whereType<UprisingEvent>().last;
    expect((up.troopers, up.homeColonyId), (6, 'home'));
    city.war.outbox.clear();

    city.applyCombatWrite(const UprisingFoughtWrite(3));
    run(city, 0.5);
    expect(city.war.outbox.whereType<UprisingEvent>(), isEmpty, reason: 'taken up: said once');

    city.applyCombatWrite(const UprisingEndWrite(held: false, garrisonLost: 2, rebelDead: 5));
    expect(city.loyalty.allegiance, isNot(Allegiance.occupied));
    expect(city.loyalty.warDead, 4 + 5, reason: 'the rebels killed are a grievance');
    run(city, 0.5);
    expect(city.war.garrison, isNull);
    final home = city.war.outbox.whereType<GarrisonHomeEvent>().single;
    expect(home.expelled, isTrue);
    expect(home.count, 4, reason: 'the survivors');
    expect(city.loyalty.notices.map((n) => n.kind), contains(LoyaltyNoticeKind.occupationEnded));
  });

  test('a rising the garrison holds is crushed: revolts cleared, rebellion halved, quiet a while', () {
    final city = taken();
    final t = city.colonyTimeS;
    city.loyalty.revolts.addAll([t, t, t]);
    run(city, 0.5);
    city.applyCombatWrite(const UprisingFoughtWrite(3));
    city.rebellion = 0.8;
    city.applyCombatWrite(const UprisingEndWrite(held: true, garrisonLost: 1, rebelDead: 3));
    final l = city.loyalty;
    expect(l.allegiance, Allegiance.occupied);
    expect(l.risen, isFalse);
    expect(l.revolts, isEmpty);
    expect(city.rebellion, closeTo(0.4, 1e-12));
    expect(city.war.garrison!.count, 5);
    expect(l.notices.last.kind, LoyaltyNoticeKind.uprisingCrushed);
    // Three more revolts would raise it again at once: not while it is quiet.
    final t2 = l.colonyTimeS;
    l.revolts.addAll([t2, t2, t2]);
    run(city, 1);
    expect(l.risen, isFalse);
    l.colonyTimeS = l.uprisingQuietUntilS;
    l.revolts
      ..clear()
      ..addAll([l.colonyTimeS, l.colonyTimeS, l.colonyTimeS]);
    run(city, 1);
    expect(l.risen, isTrue);
    final back = CitySim.fromJson(city.toJson(), bodies: fixtureBodies);
    expect(back.loyalty.risen, isTrue);
    expect(back.loyalty.uprisingQuietUntilS, l.uprisingQuietUntilS);
  });

  test('a rising nobody fights — no combat phase — throws the garrison out after a day', () {
    final city = taken();
    final t = city.colonyTimeS;
    city.loyalty.revolts.addAll([t, t, t]);
    run(city, 0.5);
    expect(city.loyalty.risen, isTrue);
    run(city, CityLoyalty.uprisingFallbackDays * 120 + 1);
    expect(city.loyalty.allegiance, isNot(Allegiance.occupied));
    expect(city.war.garrison, isNull);
    expect(city.war.outbox.whereType<GarrisonHomeEvent>().single.expelled, isTrue);
  });

  test('a raid: beaten off, or a fifth of the ore and rations gone', () {
    final city = starterKit();
    city.stock[Commodity.ore] = 100;
    city.stock[Commodity.rations] = 50;
    final level = city.loyalty.level;
    city.applyCombatWrite(const RaidEndWrite('r', 'Rival', raided: false, dead: 0));
    expect(city.stockOf(Commodity.ore), 100);
    expect(city.loyalty.notices.last.kind, LoyaltyNoticeKind.raidBeaten);
    city.applyCombatWrite(const RaidEndWrite('r', 'Rival', raided: true, dead: 0));
    expect(city.stockOf(Commodity.ore), closeTo(80, 1e-9));
    expect(city.stockOf(Commodity.rations), closeTo(40, 1e-9));
    expect(city.loyalty.level, closeTo(math.max(0.0, level - 0.05), 1e-12));
    final p = city.war.outbox.whereType<PlunderedEvent>().single;
    expect(p.raiderId, 'r');
    expect(p.ore, closeTo(20, 1e-9));
    expect(p.rations, closeTo(10, 1e-9));
    expect(city.loyalty.notices.last.kind, LoyaltyNoticeKind.raided);
  });

  test('the charter: offered after ten days on the line, restored on the order', () {
    final l = CityLoyalty()
      ..reclaim.grievance = const Grievance(revolts: 3)
      ..occupy();
    l.level = 0.7;
    const calm = LoyaltyInputs(dt: 10, happiness: 1, coverage: 1, rebellion: 0, sufficiency: 0);
    for (var i = 0; i < 119; i++) {
      l.tick(calm);
    }
    expect(l.charterReady, isFalse);
    expect(l.restoreCharter(), isFalse, reason: 'not yet earned');
    for (var i = 0; i < 3; i++) {
      l.tick(calm);
    }
    expect(l.charterReady, isTrue);
    expect(l.notices.where((n) => n.kind == LoyaltyNoticeKind.charterReady), hasLength(1));
    // Dropping under the line restarts the clock.
    l.level = 0.5;
    l.tick(calm);
    expect(l.charterReady, isFalse);
    expect(l.charterSinceS, isNull);

    final city = taken();
    city.loyalty
      ..level = 0.7
      ..charterSinceS = city.colonyTimeS - 11 * 120;
    city.applyCombatWrite(const RestoreCharterWrite());
    expect(city.loyalty.allegiance, Allegiance.colonial);
    expect(city.loyalty.reclaim.grievance, isNull);
    expect(city.war.garrison, isNull);
    final home = city.war.outbox.whereType<GarrisonHomeEvent>().single;
    expect(home.expelled, isFalse);
  });

  test('withdrawing early costs loyalty and hands it the colonial rules', () {
    final city = taken();
    city.loyalty.level = 0.5;
    city.applyCombatWrite(const GarrisonWithdrawWrite());
    expect(city.loyalty.allegiance, Allegiance.colonial);
    expect(city.loyalty.level, closeTo(0.3, 1e-12));
    expect(city.war.garrison, isNull);
    expect(city.war.outbox.whereType<GarrisonHomeEvent>().single.count, 6);
  });

  test('upkeep: its own stock first, then the colony\'s, which costs mood', () {
    final city = taken(stock: 0);
    city.stock[Commodity.rations] = 50;
    city.stock[Commodity.ammo] = 50;
    city.warTick(12);
    // 6 troopers × 2 rations a day × a tenth of a day.
    expect(city.stockOf(Commodity.rations), closeTo(50 - 1.2, 1e-9));
    expect(city.war.requisitioning, isTrue);
    expect(city.occupationMoodCost, closeTo(0.1 * city.suppression + 0.05, 1e-12));
    expect(city.war.garrison!.unpaidS, 0);
  });

  test('unpaid, a tenth of it goes home a day', () {
    final city = taken(stock: 0);
    city.stock[Commodity.rations] = 0;
    city.stock[Commodity.ammo] = 0;
    for (var i = 0; i < 121; i++) {
      city.warTick(1);
    }
    expect(city.war.garrison!.count, 5);
    expect(city.war.outbox.whereType<GarrisonHomeEvent>().single.count, 1);
  });

  test('an occupation survives a save', () {
    final city = taken();
    city.loyalty.charterSinceS = city.colonyTimeS - 120;
    final back = CitySim.fromJson(city.toJson(), bodies: fixtureBodies);
    expect(back.loyalty.allegiance, Allegiance.occupied);
    expect(back.loyalty.garrisonHoldsColony, isTrue);
    expect(back.loyalty.garrisonHoldsPort, isFalse);
    expect(back.loyalty.warDead, 4);
    expect(back.loyalty.charterSinceS, city.loyalty.charterSinceS);
    expect(back.war.garrison!.occupation, isTrue);
    expect(back.war.garrison!.count, 6);
    expect(back.loyalty.reclaim.grievance!.warDead, 4);
  });

  test('an independent colony names what an assault would fight over', () {
    final city = independent();
    final snap = city.launchSnapshot();
    expect(snap.independent, isTrue);
    expect(snap.objectives, isNotEmpty);
    expect(snap.objectives.first.kind, 'seat');
    final ids = [for (final o in snap.objectives) o.siteId];
    expect(ids.toSet(), hasLength(ids.length), reason: 'each a different site');
    // ignore: avoid_print
    print('objectives: ${[for (final o in snap.objectives) '${o.kind}@${o.siteId}']}');
    final colonial = starterKit().launchSnapshot();
    expect(colonial.independent, isFalse);
    expect(colonial.objectives, isEmpty);
  });

  test('a beaten-off assault hardens it for ten days', () {
    final city = independent();
    city.applyCombatWrite(const AssaultRepulsedWrite());
    expect(city.launchSnapshot().resolveBoost, 0.2);
    city.loyalty.colonyTimeS += 11 * 120;
    // colonyTimeS on the colony is what the boost is timed on.
    expect(city.colonyTimeS, greaterThan(city.war.resolveBoostUntilS - 1e9));
  });
}
