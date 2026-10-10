// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';

import 'package:acro_space_simulator/adapters/events/in_memory_event_bus.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/ports/compute_port.dart';
import 'package:acro_space_simulator/application/usecases/advance_simulation_tick.dart';
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_control.dart';
import 'package:acro_space_simulator/domain/colony/city/city_loyalty.dart';
import 'package:acro_space_simulator/domain/colony/city/city_reclaim.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/independent_governor.dart';
import 'package:acro_space_simulator/domain/orbits/soi_transition_service.dart';
import 'package:acro_space_simulator/domain/simulation/simulation_clock.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:flutter_test/flutter_test.dart';

import '../traffic/traffic_fixture.dart';

/// The ways back (docs/plans/colony-secession.md §6.1, §6.2, phase 3): the
/// terms a colony states and how they scale with how it was run, rejoining
/// under them and the gate that holds the player to them, reputation over
/// the player's colonial colonies, and the petitions it and hunger bring.
void main() {
  const day = 120.0; // the loyalty calendar's day, colony seconds
  const t = ReclaimTuning();

  /// Declare [city] independent now, as `CityLoyalty._secede` would, with
  /// [why] as what drove it out.
  void secede(CitySim city, [Grievance why = const Grievance()]) {
    city.loyalty
      ..allegiance = Allegiance.independent
      ..stage = LoyaltyStage.seceded
      ..independentAtS = city.colonyTimeS
      ..independenceCauses = 'no orders for 50 days';
    city.loyalty.reclaim.onSecede(why);
  }

  CitySim clone(CitySim city) => CitySim.fromJson(
      jsonDecode(jsonEncode(city.toJson())) as Map<String, dynamic>,
      bodies: fixtureBodies);

  /// One model tick of an independent colony's loyalty and ways back, as
  /// `CityLoyaltySim.loyaltyTick` runs them.
  void tickModel(CityLoyalty l, double dt,
      {double happiness = 0.5,
      double sufficiency = 1,
      bool starving = false,
      Set<Law> laws = const {}}) {
    l.tick(LoyaltyInputs(
        dt: dt,
        happiness: happiness,
        coverage: 1,
        rebellion: 0,
        sufficiency: sufficiency,
        starving: starving));
    l.reclaim.tick(l,
        dt: dt,
        happiness: happiness,
        starving: starving,
        populated: true,
        laws: laws);
  }

  CityLoyalty independentModel({Grievance why = const Grievance()}) {
    // Its last orders long behind it, as any seceded colony's are: an
    // attended colony's good rule would ease its desperation.
    final l = CityLoyalty()
      ..allegiance = Allegiance.independent
      ..stage = LoyaltyStage.seceded
      ..attendedAtS = -100 * day
      ..independentAtS = 0;
    l.reclaim.onSecede(why);
    return l;
  }

  const allLaws = {Law.curfew, Law.freeHealthcare, Law.wealthTax, Law.robotTax};

  group('terms (§6.1)', () {
    test('worse rule states more terms, for longer, under a tighter cap', () {
      final r = CityReclaim();
      BindingTerms termsOf(Grievance g, {double gone = 0}) {
        r.grievance = g;
        return r.statedTerms(independentDays: gone, laws: allLaws);
      }

      final forgotten = termsOf(const Grievance(neglectDays: 20));
      final misruled = termsOf(
          const Grievance(neglectDays: 20, rebellion: 0.7, revolts: 1));
      final brutal = termsOf(const Grievance(
          neglectDays: 40, rebellion: 0.95, revolts: 3, desperation: 1));
      expect(forgotten.count, 1, reason: 'a tax cap alone: ${forgotten.describe()}');
      expect(forgotten.noDemolition, isFalse);
      expect(misruled.count, greaterThan(forgotten.count));
      expect(misruled.days, greaterThan(forgotten.days));
      expect(misruled.taxCap!, lessThan(forgotten.taxCap!));
      expect(brutal.count, greaterThan(misruled.count));
      expect(brutal.days, greaterThan(misruled.days));
      expect(brutal.taxCap!, lessThan(misruled.taxCap!));
      expect(brutal.noDemolition, isTrue);
      expect(brutal.keptLaws, hasLength(t.maxKeptLaws));
      expect(brutal.taxCap, closeTo(t.harshTaxCap, 1e-9));
      // Severity is monotone in each grievance alone.
      var last = -1.0;
      for (final reb in [0.2, 0.4, 0.6, 0.8, 1.0]) {
        final s = Grievance(rebellion: reb).severity(t);
        expect(s, greaterThanOrEqualTo(last));
        last = s;
      }
      // Time away lengthens them; it does not add to them.
      final longGone = termsOf(const Grievance(neglectDays: 20), gone: 60);
      expect(longGone.days, forgotten.days + t.independenceDays);
      expect(longGone.count, forgotten.count);
    });

    test('kept laws are ones it holds; none held, none named', () {
      final r = CityReclaim()
        ..grievance = const Grievance(
            neglectDays: 40, rebellion: 0.95, revolts: 3, desperation: 1);
      final terms =
          r.statedTerms(independentDays: 0, laws: {Law.freeHealthcare});
      expect(terms.keptLaws, {Law.freeHealthcare});
      expect(r.statedTerms(independentDays: 0, laws: {}).keptLaws, isEmpty);
    });

    test('accepting rejoins at 0.5, bound; the gate holds each term', () {
      final city = starterKit();
      run(city, 30);
      city.govt = Govt.democracy;
      secede(
          city,
          const Grievance(
              neglectDays: 40, rebellion: 0.95, revolts: 3, desperation: 1));
      city.loyalty.revolts.addAll([city.colonyTimeS, city.colonyTimeS]);
      run(city, 5 * day);
      // What its own council holds when the player comes to the table.
      city
        ..laws.addAll({Law.curfew, Law.freeHealthcare})
        ..taxRate = 0.3;
      final terms = city.negotiatedTerms();
      expect(terms.noDemolition, isTrue);
      expect(terms.keptLaws, contains(Law.curfew));
      expect(city.playerControl.allowed, isFalse);

      expect(city.acceptNegotiation(), isTrue);
      final l = city.loyalty;
      expect(l.allegiance, Allegiance.colonial);
      expect(l.level, 0.5);
      expect(l.stage, LoyaltyStage.restless);
      expect(l.attendedAtS, l.colonyTimeS, reason: 'accepting is an act');
      expect(l.revolts, isEmpty);
      expect(l.notices.last.kind, LoyaltyNoticeKind.rejoined);
      expect(city.playerControl.allowed, isTrue);
      expect(city.reclaim.terms, isNotNull);
      expect(city.taxRate, lessThanOrEqualTo(terms.taxCap! + 1e-9),
          reason: 'held under the cap it rejoined on');
      expect(city.termsDaysLeft, terms.days.round());

      // The tax cap.
      final cap = terms.taxCap!;
      expect(city.taxCeiling, cap);
      expect(city.taxRefusal(cap), isNull);
      final tax = city.taxRefusal(cap + 0.05)!;
      expect(tax, contains('cap the tax at ${(cap * 100).round()}%'));
      expect(tax, contains('${terms.days.round()} days left'));
      expect(city.economyRefusal(Economy.communism), contains('levies 50%'));
      expect(city.economyRefusal(Economy.socialism), isNull);
      // The kept law.
      expect(city.repealRefusal(Law.curfew), contains('keep Curfew'));
      expect(city.repealRefusal(Law.emissionsCap), isNull);
      // No demolitions.
      String? said;
      expect(city.mayDemolish((why) => said = why), isFalse);
      expect(said, contains('forbid demolitions'));
      expect(city.mayAct(), isTrue, reason: 'everything else takes orders');

      // The colony's own vote keeps the law it demanded, crime or none.
      city.crime = 0;
      run(city, 3 * day);
      expect(city.laws, contains(Law.curfew));

      // The terms run out; normal rule resumes. Attended meanwhile, or the
      // neglect would take it away again before they did.
      for (var d = 0; d < terms.days.round() + 1; d++) {
        city.attend();
        run(city, day);
      }
      expect(l.allegiance, Allegiance.colonial);
      expect(city.reclaim.terms, isNull);
      expect(l.notices.map((n) => n.kind),
          contains(LoyaltyNoticeKind.termsExpired));
      expect(city.taxRefusal(0.4), isNull);
      expect(city.repealRefusal(Law.curfew), isNull);
      expect(city.demolitionRefusal, isNull);
      expect(city.mayDemolish(), isTrue);
    });

    test('declining keeps it independent and changes nothing', () {
      final city = starterKit();
      run(city, 30);
      secede(city, const Grievance(rebellion: 0.8));
      final before = jsonEncode(city.toJson());
      final terms = city.negotiatedTerms();
      expect(terms.isEmpty, isFalse);
      // Hearing the terms, and walking away, is no act.
      expect(jsonEncode(city.toJson()), before);
      expect(city.loyalty.allegiance, Allegiance.independent);
      expect(city.acceptPetition(), isFalse, reason: 'no petition waiting');
      expect(city.loyalty.allegiance, Allegiance.independent);
    });

    test('a re-secession drops the terms the last rejoining left', () {
      final r = CityReclaim()
        ..terms = const BindingTerms(taxCap: 0.1, days: 10)
        ..termsUntilS = 9999;
      r.onSecede(const Grievance(revolts: 3));
      expect(r.terms, isNull);
      expect(r.grievance!.revolts, 3);
    });
  });

  group('win hearts (§6.2)', () {
    test('reputation is pop-weighted over colonial colonies only', () {
      CitySim colony(double pop, double level, double mood,
          {Allegiance a = Allegiance.colonial}) {
        final c = starterKit()
          ..population = pop
          ..happiness = mood;
        c.loyalty
          ..level = level
          ..allegiance = a;
        return c;
      }

      final a = colony(100, 1, 0.8);
      final b = colony(300, 0.5, 0.4);
      final rebel = colony(1000, 1, 0.9, a: Allegiance.independent);
      final held = colony(1000, 1, 0.9, a: Allegiance.occupied);
      final empty = colony(0, 1, 1);
      expect(CityReclaimSim.reputationOf([a, b, rebel, held, empty]),
          closeTo((100 * 0.8 + 300 * 0.5 * 0.4) / 400, 1e-12));
      expect(CityReclaimSim.reputationOf([rebel]), isNull,
          reason: 'no colonial colony: no reputation');
      expect(CityReclaimSim.reputationOf(const []), isNull);
    });

    test('the world tick hands it to every colony; one colony gets none', () {
      final system = RealSolarSystem.build();
      final bodies = system.all.where((b) => !b.isStar).toList();
      CitySim found(String id) => CitySim.found(
          const CityConfig(bodyId: 'earth', gridSize: 20),
          bodies: bodies,
          id: id);
      AdvanceSimulationTick tickOver(List<CitySim> cities) =>
          AdvanceSimulationTick(
            vessels: InMemoryVesselRepository(),
            universe: StaticUniverseRepository(system),
            compute: DartCompute(),
            soi: const SoiTransitionService(),
            events: InMemoryEventBus(),
            colonies: InMemoryColonyRepository(),
            deposits: InMemoryDepositRepository(),
            weather: const NullWeatherRepository(),
            cities: InMemoryCityRepository(cities),
          );

      final home = found('home')
        ..population = 200
        ..happiness = 0.7;
      home.loyalty.level = 0.9;
      final rebel = found('rebel')..population = 50;
      secede(rebel);
      final clock = SimulationClock(warpFactor: 1, fixedStep: 1);
      final want = CityReclaimSim.reputationOf([home, rebel])!;
      tickOver([home, rebel]).execute(clock);
      expect(rebel.reclaim.reputation, closeTo(want, 1e-12));
      expect(home.reclaim.reputation, closeTo(want, 1e-12));

      // Alone in its world, there is nobody for it to envy.
      final lone = found('lone')..population = 50;
      secede(lone);
      tickOver([lone]).execute(SimulationClock(warpFactor: 1, fixedStep: 1));
      expect(lone.reclaim.reputation, isNull);
    });

    test('pressure builds only while it does worse, and petitions past 1', () {
      final l = independentModel(why: const Grievance(rebellion: 0.9));
      l.reclaim.reputation = 0.7;
      // Doing better than the player's colonies: nothing.
      for (var i = 0; i < 40; i++) {
        tickModel(l, day, happiness: 0.8, laws: allLaws);
      }
      expect(l.reclaim.pressure, 0);
      expect(l.reclaim.petition, isNull);
      // Doing worse by 0.4: full in heartsGap × heartsDays / 0.4 days.
      final fill = t.heartsGap * t.heartsDays / 0.4;
      for (var d = 0; d < fill.floor() - 1; d++) {
        tickModel(l, day, happiness: 0.3, laws: allLaws);
      }
      expect(l.reclaim.pressure, inExclusiveRange(0.5, 1));
      expect(l.reclaim.petition, isNull);
      for (var d = 0; d < 3; d++) {
        tickModel(l, day, happiness: 0.3, laws: allLaws);
      }
      final p = l.reclaim.petition!;
      expect(p.kind, PetitionKind.hearts);
      expect(l.notices.last.kind, LoyaltyNoticeKind.petition);
      // Light terms: lighter than the ones it would state at the table.
      final stated = l.reclaim
          .statedTerms(independentDays: l.colonyTimeS / day, laws: allLaws);
      expect(p.terms!.count, lessThanOrEqualTo(stated.count));
      expect(p.terms!.days, lessThan(stated.days));
      expect(p.terms!.taxCap!, greaterThan(stated.taxCap!));
      // It is still independent until the player answers.
      expect(l.allegiance, Allegiance.independent);
    });

    test('no reputation, no pressure', () {
      final l = independentModel();
      for (var d = 0; d < 60; d++) {
        tickModel(l, day, happiness: 0.05);
      }
      expect(l.reclaim.pressure, 0);
      expect(l.reclaim.petition, isNull);
    });

    test('pressure under warp: one big step fills it as many small ones', () {
      final a = independentModel()..reclaim.reputation = 0.6;
      final b = independentModel()..reclaim.reputation = 0.6;
      tickModel(a, 4 * day, happiness: 0.4);
      for (var i = 0; i < 400; i++) {
        tickModel(b, 0.01 * day, happiness: 0.4);
      }
      expect(a.reclaim.pressure, closeTo(b.reclaim.pressure, 1e-9));
      expect(a.reclaim.pressure, greaterThan(0));
    });

    test('declining a hearts petition drains it; it asks again later', () {
      final l = independentModel()..reclaim.reputation = 0.9;
      var days = 0;
      while (l.reclaim.petition == null && days < 100) {
        tickModel(l, day, happiness: 0.1);
        days++;
      }
      expect(l.reclaim.petition?.kind, PetitionKind.hearts);
      l.reclaim.declinePetition();
      expect(l.reclaim.petition, isNull);
      expect(l.reclaim.pressure, 0);
      tickModel(l, day, happiness: 0.1);
      expect(l.reclaim.petition, isNull, reason: 'not on the next tick');
      for (var d = 0; d < days + 1; d++) {
        tickModel(l, day, happiness: 0.1);
      }
      expect(l.reclaim.petition?.kind, PetitionKind.hearts);
    });

    test('accepting a hearts petition rejoins on its light terms', () {
      final city = starterKit();
      run(city, 30);
      secede(city, const Grievance(rebellion: 0.9, revolts: 2));
      city.reclaim
        ..reputation = 1.0
        ..pressure = 1;
      run(city, 1);
      final p = city.reclaim.petition!;
      expect(p.kind, PetitionKind.hearts);
      expect(city.acceptPetition(), isTrue);
      expect(city.loyalty.allegiance, Allegiance.colonial);
      expect(city.loyalty.level, t.rejoinLoyalty);
      expect(city.reclaim.terms!.taxCap, p.terms!.taxCap);
      expect(city.reclaim.petition, isNull);
    });
  });

  group('the dependency petition (§6.2)', () {
    test('below the bar it petitions, later the more desperate it left', () {
      int daysToPetition(double desperationAtSecession) {
        final l = independentModel(
            why: Grievance(desperation: desperationAtSecession));
        for (var d = 1; d <= 60; d++) {
          tickModel(l, day, sufficiency: 0.2);
          if (l.reclaim.petition != null) {
            expect(l.reclaim.petition!.kind, PetitionKind.dependency);
            expect(l.reclaim.petition!.terms, isNull,
                reason: 'the player sets them');
            return d;
          }
        }
        return -1;
      }

      final calm = daysToPetition(0);
      final desperate = daysToPetition(1);
      expect(calm, t.holdoutDays.round());
      expect(desperate, (t.holdoutDays + t.holdoutDesperationDays).round());
    });

    test('a self-sufficient colony never asks', () {
      final l = independentModel();
      for (var d = 0; d < 60; d++) {
        tickModel(l, day, sufficiency: 0.95);
      }
      expect(l.reclaim.petition, isNull);
      expect(l.reclaim.dependentS, 0);
    });

    test('regardless of reputation — and a starving one asks at bar 0', () {
      // Desperation 1: the live bar is 0, so only hunger tells.
      final l = independentModel(why: const Grievance(desperation: 1))
        ..desperation = 1
        ..reclaim.reputation = 0.0;
      for (var d = 0; d < 30; d++) {
        tickModel(l, day, sufficiency: 0.3, happiness: 0.6);
      }
      expect(l.reclaim.petition, isNull, reason: 'fed, it holds out');
      for (var d = 0; d < 30; d++) {
        tickModel(l, day, sufficiency: 0.3, happiness: 0, starving: true);
      }
      expect(l.reclaim.petition?.kind, PetitionKind.dependency);
    });

    test('it outranks a hearts petition already waiting', () {
      final l = independentModel()..reclaim.reputation = 0.9;
      l.reclaim.pressure = 1;
      tickModel(l, 1, happiness: 0.1);
      expect(l.reclaim.petition?.kind, PetitionKind.hearts);
      for (var d = 0; d < 4; d++) {
        tickModel(l, day, happiness: 0.1, sufficiency: 0.1);
      }
      expect(l.reclaim.petition?.kind, PetitionKind.dependency);
    });

    test('accepted on the player\'s terms, each granted adds goodwill', () {
      CitySim petitioning() {
        final city = starterKit();
        run(city, 30);
        secede(city);
        city.reclaim.dependentS = 1e9; // long past its holdout
        city.loyalty.tuning = const CityLoyaltyTuning(independenceBar: 5);
        run(city, 1);
        expect(city.reclaim.petition?.kind, PetitionKind.dependency);
        return city;
      }

      final none = petitioning();
      expect(none.acceptPetition(), isTrue);
      expect(none.loyalty.level, t.rejoinLoyalty);
      expect(none.reclaim.terms, isNull);

      final generous = petitioning()..laws.add(Law.curfew);
      expect(
          generous.acceptPetition(const BindingTerms(
              taxCap: 0.1,
              keptLaws: {Law.curfew},
              noDemolition: true,
              days: 20)),
          isTrue);
      expect(generous.loyalty.level,
          closeTo(t.rejoinLoyalty + 3 * t.goodwillPerTerm, 1e-12));
      expect(generous.repealRefusal(Law.curfew), isNotNull);
      expect(generous.demolitionRefusal, isNotNull);
      expect(generous.termsDaysLeft, 20);
    });

    test('declined, it holds out again before it asks again', () {
      final l = independentModel();
      for (var d = 0; d < 3; d++) {
        tickModel(l, day, sufficiency: 0.2);
      }
      expect(l.reclaim.petition, isNotNull);
      l.reclaim.declinePetition();
      expect(l.reclaim.dependentS, 0);
      tickModel(l, day, sufficiency: 0.2);
      expect(l.reclaim.petition, isNull);
      for (var d = 0; d < 2; d++) {
        tickModel(l, day, sufficiency: 0.2);
      }
      expect(l.reclaim.petition?.kind, PetitionKind.dependency);
    });
  });

  group('the save', () {
    test('terms, their clock, grievance, pressure and petitions survive', () {
      final city = starterKit();
      run(city, 30);
      city.laws.add(Law.curfew);
      secede(
          city,
          const Grievance(
              neglectDays: 33, rebellion: 0.8, revolts: 2, desperation: 0.4));
      city.reclaim
        ..pressure = 0.37
        ..dependentS = 1.5 * day
        ..petition = const Petition(PetitionKind.hearts, 42,
            terms: BindingTerms(taxCap: 0.2, days: 12));
      final copy = clone(city);
      final r = copy.reclaim;
      expect(r.grievance!.neglectDays, 33);
      expect(r.grievance!.rebellion, 0.8);
      expect(r.grievance!.revolts, 2);
      expect(r.grievance!.desperation, 0.4);
      expect(r.pressure, 0.37);
      expect(r.dependentS, 1.5 * day);
      expect(r.petition!.kind, PetitionKind.hearts);
      expect(r.petition!.atS, 42);
      expect(r.petition!.terms!.taxCap, 0.2);
      expect(r.petition!.terms!.days, 12);
      expect(jsonEncode(copy.toJson()['loyalty']),
          jsonEncode(city.toJson()['loyalty']));

      // Rejoined and bound: the terms and how long they have left.
      expect(city.acceptNegotiation(), isTrue);
      final bound = clone(city);
      expect(bound.reclaim.terms!.describe(), city.reclaim.terms!.describe());
      expect(bound.reclaim.termsUntilS, city.reclaim.termsUntilS);
      expect(bound.termsDaysLeft, city.termsDaysLeft);
      expect(bound.repealRefusal(Law.curfew), city.repealRefusal(Law.curfew));
      expect(bound.taxRefusal(0.4), city.taxRefusal(0.4));
    });

    test('a colony that never left saves no reclaim block', () {
      final city = starterKit();
      run(city, 30);
      final loyalty = city.toJson()['loyalty'];
      expect(loyalty is Map ? loyalty['reclaim'] : null, isNull);
    });

    test("the governor's log survives a load", () {
      final city = starterKit();
      run(city, 2 * day);
      secede(city);
      run(city, 7 * day);
      expect(city.governorLog, isNotEmpty);
      final copy = clone(city);
      expect([for (final a in copy.governorLog) '${a.kind}|${a.text}|${a.atS}'],
          [for (final a in city.governorLog) '${a.kind}|${a.text}|${a.atS}']);
    });

    test('warnings: a petition and running terms show in the status list',
        () {
      final city = starterKit();
      run(city, 30);
      secede(city);
      city.reclaim.petition = Petition(PetitionKind.dependency, 0);
      expect(city.loyaltyWarnings().map((w) => w.key), contains('petition'));
      expect(city.acceptPetition(
              const BindingTerms(taxCap: 0.1, days: 3)),
          isTrue);
      final w = city.loyaltyWarnings().firstWhere((w) => w.key == 'terms');
      expect(w.text, contains('tax at most 10%'));
      expect(w.text, contains('3 days left'));
    });
  });
}
