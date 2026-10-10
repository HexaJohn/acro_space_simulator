// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';

import 'package:acro_space_simulator/domain/colony/city/city_loyalty.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/commodity.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/city_edit_overlay.dart';
import 'package:flutter_test/flutter_test.dart';

import '../traffic/traffic_fixture.dart';

/// Loyalty inside a real colony (docs/plans/colony-secession.md phase 1):
/// the stage effects a tick feels, the port the rebels take, what counts
/// as attention, and the save that stops misrule being save-scummed away.
void main() {
  /// An identical copy of [city], through its own save — and its loyalty
  /// tuning, which is the build's configuration and not saved.
  CitySim clone(CitySim city) => CitySim.fromJson(
      jsonDecode(jsonEncode(city.toJson())) as Map<String, dynamic>,
      bodies: fixtureBodies)
    ..loyalty.tuning = city.loyalty.tuning;

  /// The town's spaceport site.
  String portOf(CitySim city) => city.landingPads().first.$1.id;

  group('stage effects', () {
    test('Defiant strikes: rest of production x0.7, half the tax', () {
      final base = town();
      run(base, 60);
      final a = clone(base)..happiness = 0.8;
      final b = clone(base)..happiness = 0.8;
      b.loyalty
        ..level = 0.2
        ..stage = LoyaltyStage.defiant;
      a.advance(0.5);
      b.advance(0.5);
      expect(b.loyalty.stage, LoyaltyStage.defiant);
      expect(a.taxIncomeRate, greaterThan(0));
      expect(b.restThrottle / a.restThrottle, closeTo(0.7, 1e-9));
      expect(b.lifeThrottle, a.lifeThrottle,
          reason: 'the strikers still work the farms');
      expect(b.taxIncomeRate / a.taxIncomeRate, closeTo(0.5, 1e-9));
    });

    test('Standoff: x0.4 and no tax at all', () {
      final base = town();
      run(base, 60);
      final a = clone(base)..happiness = 0.8;
      final b = clone(base)..happiness = 0.8;
      b.loyalty
        ..tuning = const CityLoyaltyTuning(independenceBar: 5)
        ..level = 0.1
        ..stage = LoyaltyStage.standoff;
      a.advance(0.5);
      b.advance(0.5);
      expect(b.loyalty.stage, LoyaltyStage.standoff);
      expect(b.restThrottle / a.restThrottle, closeTo(0.4, 1e-9));
      expect(b.taxIncomeRate, 0);
    });

    test('Restless self-governs: laws vote themselves under an autocrat', () {
      final base = town();
      run(base, 60);
      final a = clone(base);
      final b = clone(base);
      for (final c in [a, b]) {
        c
          ..govt = Govt.autocracy
          ..crime = 0.95
          ..laws.clear();
      }
      b.loyalty
        ..level = 0.5
        ..stage = LoyaltyStage.restless;
      a.advance(0.5);
      b.advance(0.5);
      expect(a.laws, isNot(contains(Law.curfew)),
          reason: "a loyal colony waits for the autocrat's orders");
      expect(b.laws, contains(Law.curfew),
          reason: 'a restless one has stopped waiting');
    });

    test('Restless pulls an over-high tax toward what the mood bears', () {
      final base = town();
      run(base, 60);
      final a = clone(base)..taxRate = 0.4;
      final b = clone(base)..taxRate = 0.4;
      b.loyalty
        ..level = 0.5
        ..stage = LoyaltyStage.restless;
      run(a, 120);
      run(b, 120);
      expect(a.taxRate, 0.4, reason: 'a loyal colony pays what it is told');
      expect(b.loyalty.stage, LoyaltyStage.restless);
      expect(b.happiness, lessThan(0.5), reason: 'a mood that bears less');
      expect(b.taxRate, lessThan(0.3), reason: 'a tax revolt');
    });
  });

  group('secession in a colony', () {
    test('a dependent colony stands off; a self-sufficient one leaves', () {
      final base = town();
      run(base, 60);
      // Three revolts close together: the condition, whatever the loyalty.
      final t = base.colonyTimeS;
      final dependent = clone(base)
        ..loyalty.tuning = const CityLoyaltyTuning(independenceBar: 5)
        ..loyalty.revolts.addAll([t, t, t]);
      final free = clone(base)
        ..loyalty.tuning = const CityLoyaltyTuning(independenceBar: 0.1)
        ..loyalty.revolts.addAll([t, t, t]);
      run(dependent, 2);
      run(free, 2);
      expect(dependent.loyalty.stage, LoyaltyStage.standoff);
      expect(dependent.loyalty.allegiance, Allegiance.colonial);
      expect(
          dependent.loyaltyWarnings().map((w) => w.text),
          contains(startsWith('Would secede, but cannot feed itself')));
      expect(free.loyalty.allegiance, Allegiance.independent);
      expect(free.loyalty.notices.last.kind, LoyaltyNoticeKind.independence);
      expect(free.loyaltyWarnings().first.key, 'independent');
    });

    test('an Earth town can feed itself and leaves; a raw Mars one cannot',
        () {
      // The default bar, measured, not forced: an Earth town once it has
      // eaten through its founding larder (the first days, when the larder
      // feeds people its farms do not) lives on its own farms and pumps
      // and the sky.
      final earth = town();
      run(earth, 3000);
      expect(earth.loyalty.selfSufficiency,
          greaterThanOrEqualTo(const CityLoyaltyTuning().independenceBar));
      // The same town on Mars, its air shipped in: alive, and dependent.
      final mars = starterKit(body: 'mars');
      zoneAll(mars);
      buildAll(mars);
      for (var i = 0; i < 1200; i++) {
        mars.stock[Commodity.oxygen] = mars.stockCap;
        mars.advance(0.5);
      }
      expect(mars.population, greaterThan(CitySim.landerCrew));
      expect(mars.loyalty.selfSufficiency, lessThan(0.5));

      for (final c in [earth, mars]) {
        final t = c.colonyTimeS;
        c.loyalty.revolts.addAll([t, t, t]);
        for (var i = 0; i < 4; i++) {
          c.stock[Commodity.oxygen] = c.stockCap;
          c.advance(0.5);
        }
      }
      expect(earth.loyalty.allegiance, Allegiance.independent);
      expect(mars.loyalty.stage, LoyaltyStage.standoff);
    });

    test('a standoff sheds those living on imports, and keeps the rest', () {
      final base = town();
      run(base, 120);
      final loyal = clone(base);
      final standoff = clone(base);
      standoff.loyalty
        ..tuning = const CityLoyaltyTuning(independenceBar: 5)
        ..level = 0
        ..stage = LoyaltyStage.standoff;
      // Imports keep coming — a larder kept full — so both towns could
      // live past what their farms feed.
      for (var i = 0; i < 600; i++) {
        for (final c in [loyal, standoff]) {
          c.stock[Commodity.food] = c.stockCap;
          c.stock[Commodity.water] = c.stockCap;
          c.advance(0.5);
        }
      }
      expect(standoff.loyalty.stage, LoyaltyStage.standoff);
      expect(standoff.loyalty.portSeized, isFalse,
          reason: 'its port open, so its settlers can leave');
      final local = standoff.loyalty.localCapacity;
      expect(local, greaterThan(4.0 * (CitySim.landerCrew + standoff.reliefCrew)),
          reason: 'its own farms and pumps feed a real town');
      expect(standoff.population, closeTo(local, 0.1 * local),
          reason: 'it settles at what it can feed itself, not the crew '
              'floor');
      expect(loyal.population, greaterThan(1.2 * standoff.population),
          reason: 'those who lived on imports are the ones who left');
    });

    test('a revolt hits loyalty, and is announced and on the status list',
        () {
      final city = town();
      run(city, 30);
      city.govt = Govt.anarchy;
      for (var i = 0; i < 400 && city.revoltMsg == null; i++) {
        city
          ..rebellion = 0.999
          ..happiness = 0
          ..crime = 1
          ..inequality = 1
          ..corruption = 1;
        city.advance(0.5);
      }
      expect(city.revoltMsg, isNotNull, reason: 'the colony revolted');
      expect(city.loyalty.level, lessThanOrEqualTo(1 - 0.15 + 1e-9));
      expect(city.loyalty.recentRevolts, 1);
      expect(city.loyalty.notices.map((n) => n.kind),
          contains(LoyaltyNoticeKind.revolt));
      expect(city.loyaltyWarnings().map((w) => w.key), contains('revolt'));
    });

    test('the warning names the actual causes', () {
      final city = town();
      run(city, 30);
      city.loyalty.attendedAtS = city.colonyTimeS - 34.5 * 120;
      city
        ..rebellion = 0.82
        ..crime = 0.9
        ..inequality = 0.8
        ..happiness = 0.9
        ..corruption = 0;
      final causes = city.loyaltyCauses();
      expect(causes, contains('no orders for 34 days'));
      expect(causes, contains(startsWith('rebellion 0.82: crime, inequality')));
    });
  });

  group('the seized port', () {
    /// A town in a standoff whose rebels have just taken the port: dependent
    /// by fiat (a bar it cannot clear), loyalty low enough to stay put.
    (CitySim, String) seized({double settle = 30}) {
      final city = town();
      run(city, settle);
      city.loyalty
        ..tuning = const CityLoyaltyTuning(independenceBar: 5)
        ..level = 0.05
        ..desperation = 0.5
        ..stage = LoyaltyStage.standoff
        ..portSeized = true
        ..impoundPending = true;
      return (city, portOf(city));
    }

    test('impounds the next delivery, holds the craft, refuses the rest', () {
      final (city, port) = seized();
      final food = DeliverySchedule(
          resource: Commodity.food, intervalSec: 30, amount: 200, timer: 1)
        ..recurring = true;
      final water = DeliverySchedule(
          resource: Commodity.water, intervalSec: 30, amount: 200, timer: 2)
        ..recurring = true;
      city.deliveries[port] = [food, water];
      run(city, 120);

      expect(city.craft, hasLength(1), reason: 'one craft let in, no more');
      final c = city.craft.single;
      expect(c.resource, Commodity.food);
      expect(c.held, isTrue, reason: 'grounded on its pad');
      expect(c.phase, 0.5);
      final taken = city.loyalty.impounded.single;
      expect(taken.resource, Commodity.food);
      expect(taken.amount, c.payload);
      expect(water.timer, greaterThan(0), reason: 'the schedule is suspended');
      expect(city.loyalty.portHoldReason, 'port held by rebels');
      expect(city.loyaltyWarnings().map((w) => w.key), contains('portSeized'));

      // Relief cannot land either.
      city.reliefCooldown = 0;
      expect(city.requestRelief(port), isFalse);
      expect(city.craft, hasLength(1));
      expect(city.blocked, contains('port held by rebels'));
    });

    test('a delivery grounded for fuel does not spend the one admission',
        () {
      final (city, port) = seized();
      final food = DeliverySchedule(
          resource: Commodity.food, intervalSec: 30, amount: 200, timer: 1)
        ..recurring = true
        ..spareFuel = false;
      city.deliveries[port] = [food];
      for (var i = 0; i < 10; i++) {
        city
          ..stock[Commodity.fuel] = 0
          ..stock[Commodity.oxidizer] = 0
          ..advance(0.5);
      }
      expect(city.craft, isEmpty, reason: 'grounded: nothing flew');
      expect(city.blocked, contains('grounded'));
      expect(city.loyalty.impoundPending, isTrue,
          reason: 'the next delivery that flies is still the one impounded');

      for (var i = 0; i < 120; i++) {
        city
          ..stock[Commodity.fuel] = 500
          ..stock[Commodity.oxidizer] = 500
          ..advance(0.5);
      }
      expect(city.craft.single.held, isTrue);
      expect(city.loyalty.impounded.single.resource, Commodity.food);
      expect(city.loyalty.impoundPending, isFalse);
    });

    test('closes migration both ways', () {
      // Long enough for the town to have room for more than its crew.
      final (city, _) = seized(settle: 600);
      // The same colony, loyal, its port its own.
      final open = clone(city);
      open.loyalty
        ..level = 1
        ..desperation = 0
        ..stage = LoyaltyStage.loyal
        ..portSeized = false
        ..impoundPending = false;
      city.population = 40;
      open.population = 40;
      run(city, 20);
      run(open, 20);
      expect(open.popTarget, greaterThan(41));
      expect(open.population, greaterThan(41), reason: 'an open port fills');
      expect(city.population, lessThanOrEqualTo(40),
          reason: 'nobody lands at a held port');

      // Far past what it can feed: at an open port the hungry leave as
      // well as die; at a held one they can only die.
      double lostToMigration(CitySim c) {
        c.population = 2000;
        var died = 0.0;
        for (var i = 0; i < 40; i++) {
          c.advance(0.5);
          died += c.deathRate * 0.5;
        }
        return 2000 - c.population - died;
      }

      expect(lostToMigration(clone(open)), greaterThan(10),
          reason: 'an open port lets the hungry go');
      expect(lostToMigration(clone(city)), closeTo(0, 1e-6),
          reason: 'nobody leaves a held one: withering is hunger, not '
              'departure');
    });

    test('is given back when loyalty climbs, and the held craft leaves', () {
      final (city, port) = seized();
      final food = DeliverySchedule(
          resource: Commodity.food, intervalSec: 30, amount: 200, timer: 1)
        ..recurring = true;
      city.deliveries[port] = [food];
      run(city, 60);
      expect(city.craft.single.held, isTrue);
      city.loyalty.level = 0.5;
      run(city, 1);
      expect(city.loyalty.portSeized, isFalse);
      expect(city.loyalty.stage, isNot(LoyaltyStage.standoff));
      expect(city.craft.every((c) => !c.held), isTrue);
      run(city, 30);
      expect(city.craft.where((c) => c.granted && c.phase < 0.5), isEmpty,
          reason: 'the held craft lifted off');
    });
  });

  group('self-sufficiency', () {
    test('oxygen always counts, and the sky is a local source', () {
      final earth = starterKit()..population = 10;
      final mars = starterKit(body: 'mars')..population = 10;
      const farmsAndPumps = {Commodity.food: 1.0, Commodity.water: 1.0};
      expect(earth.airO2, 1.0);
      expect(mars.airO2, 0.0);
      expect(earth.localSufficiency(farmsAndPumps), 1.0);
      expect(mars.localSufficiency(farmsAndPumps), 0.0,
          reason: 'fed and watered, but every breath is shipped in');
      expect(
          mars.localSufficiency({...farmsAndPumps, Commodity.oxygen: 0.15}),
          closeTo(0.5, 1e-9));
    });

    test('a full larder is not a farm', () {
      final earth = starterKit()..population = 10;
      earth.stock[Commodity.food] = 1e6;
      expect(earth.localSufficiency(const {Commodity.water: 1.0}), 0.0);
    });
  });

  group('attention', () {
    test('a player act stamps it; looking does not', () {
      final city = starterKit();
      run(city, 30);
      final lots = freeLots(city);
      final edit = CityEditController()..set(CityEditTool.inspect);
      edit.applyToLot(city, lots.first.id);
      expect(city.loyalty.attendedAtS, 0, reason: 'viewing is not governing');
      edit
        ..set(CityEditTool.zone)
        ..zoneKind = 'commercial';
      // An access easement refuses zoning, and a refusal is no act: the
      // stamp moves on the first lot that takes it.
      String? zoned;
      for (final lot in lots) {
        edit.applyToLot(city, lot.id);
        if (city.layout.parcelById(lot.id)?.use == ParcelUse.commercial) {
          zoned = lot.id;
          break;
        }
        expect(city.loyalty.attendedAtS, 0, reason: 'refused: ${edit.blocked}');
      }
      expect(zoned, isNotNull);
      expect(city.loyalty.attendedAtS, city.colonyTimeS);
    });
  });

  group('the save', () {
    test('keeps the political and loyalty state', () {
      final (city, port) = (town(), '');
      run(city, 30);
      final site = portOf(city);
      city
        ..taxRate = 0.31
        ..laws.addAll({Law.curfew, Law.wealthTax})
        ..rebellion = 0.7
        ..crime = 0.4
        ..corruption = 0.2
        ..inequality = 0.5;
      city.loyalty
        ..attendedAtS = 12
        ..level = 0.42
        ..stage = LoyaltyStage.standoff
        ..desperation = 0.45
        ..selfSufficiency = 0.3
        ..portSeized = true
        ..impoundPending = false
        ..revolts.addAll([20, 25])
        ..impound(Commodity.water, 180);
      city.craft.add(LandedCraft(
          site: site,
          padIndex: 0,
          isRelief: false,
          resource: Commodity.water,
          payload: 180)
        ..granted = true
        ..phase = 0.5
        ..held = true);
      expect(port, isEmpty);

      final back = clone(city);
      expect(back.taxRate, 0.31);
      expect(back.laws, containsAll({Law.curfew, Law.wealthTax}));
      expect(back.laws, city.laws);
      expect((back.rebellion, back.crime, back.corruption, back.inequality),
          (0.7, 0.4, 0.2, 0.5));
      final l = back.loyalty;
      expect(l.colonyTimeS, city.colonyTimeS);
      expect(l.attendedAtS, 12);
      expect(l.level, 0.42);
      expect(l.stage, LoyaltyStage.standoff);
      expect(l.desperation, 0.45);
      expect(l.selfSufficiency, 0.3);
      expect(l.portSeized, isTrue);
      expect(l.revolts, [20, 25]);
      expect(l.impounded.single.resource, Commodity.water);
      expect(back.craft.single.held, isTrue, reason: 'still grounded');
      expect(back.craft.single.site, site);
      expect(back.toJson()['loyalty'], city.toJson()['loyalty']);
    });

    test('an independent colony stays independent through a load', () {
      final city = town()
        ..loyalty.allegiance = Allegiance.independent
        ..loyalty.stage = LoyaltyStage.seceded
        ..loyalty.independentAtS = 3;
      final back = clone(city);
      expect(back.loyalty.allegiance, Allegiance.independent);
      expect(back.loyalty.independentAtS, 3);
    });

    test('an old save — none of it — loads as a loyal, well-ruled colony',
        () {
      final city = town();
      run(city, 30);
      city
        ..taxRate = 0.3
        ..laws.add(Law.curfew)
        ..rebellion = 0.6;
      city.loyalty.level = 0.2;
      final json = jsonDecode(jsonEncode(city.toJson())) as Map<String, dynamic>
        ..remove('taxRate')
        ..remove('laws')
        ..remove('rebellion')
        ..remove('crime')
        ..remove('corruption')
        ..remove('inequality')
        ..remove('loyalty');
      final old = CitySim.fromJson(json, bodies: fixtureBodies);
      expect(old.taxRate, CitySim.defaultTaxRate);
      expect(old.laws, isEmpty);
      expect(old.rebellion, 0);
      expect(old.loyalty.level, 1);
      expect(old.loyalty.stage, LoyaltyStage.loyal);
      expect(old.colonyTimeS, 0);
      old.advance(0.5);
      expect(old.loyalty.stage, LoyaltyStage.loyal, reason: 'and it runs');
    });

    test('a colony never misruled saves none of it', () {
      final json = town().toJson();
      for (final k in [
        'taxRate',
        'laws',
        'rebellion',
        'crime',
        'corruption',
        'inequality',
        'loyalty',
      ]) {
        expect(json.containsKey(k), isFalse, reason: k);
      }
    });
  });
}
