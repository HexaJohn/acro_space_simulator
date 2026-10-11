// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_loyalty.dart';
import 'package:flutter_test/flutter_test.dart';

/// The loyalty model on its own (docs/plans/colony-secession.md §3), driven
/// with the handful of numbers a colony tick hands it — so forty colony days
/// run in a moment, and each rule is tested with nothing else moving.
void main() {
  const tuning = CityLoyaltyTuning();
  const day = 120.0; // the tuning's Earth day, in colony seconds

  /// Tick [l] for [days] in [dt]-second steps, optionally attending every
  /// tick (a player who acts constantly), stopping early on [until].
  double run(
    CityLoyalty l,
    double days, {
    double happiness = 0,
    double coverage = 1,
    double rebellion = 0,
    double sufficiency = 1,
    bool attend = false,
    bool hasSpaceport = true,
    bool populated = true,
    double dt = 5,
    bool Function(CityLoyalty)? until,
  }) {
    final steps = (days * day / dt).round();
    for (var i = 0; i < steps; i++) {
      if (attend) l.attend();
      l.tick(LoyaltyInputs(
        dt: dt,
        happiness: happiness,
        coverage: coverage,
        rebellion: rebellion,
        sufficiency: sufficiency,
        hasSpaceport: hasSpaceport,
        populated: populated,
      ));
      if (until != null && until(l)) return l.colonyTimeS / day;
    }
    return l.colonyTimeS / day;
  }

  group('drift', () {
    test('neglect alone: a grace, then ~40 days to nothing', () {
      final l = CityLoyalty();
      run(l, tuning.graceDays);
      expect(l.level, 1.0, reason: 'an unattended colony is fine for a while');
      final at = run(l, 80, until: (l) => l.level <= 0);
      expect(at, closeTo(tuning.graceDays + tuning.absenceDays, 1.0),
          reason: 'absence alone, discontented: ~10 days grace + ~40 days');
    });

    test('a content colony erodes ~4x slower', () {
      final sullen = CityLoyalty();
      final content = CityLoyalty();
      // Past grace and ramp: full neglect for both.
      run(sullen, 31, happiness: 0);
      run(content, 31, happiness: 1);
      expect(sullen.lastErosion / content.lastErosion, closeTo(4.0, 1e-9));
      // And on the clock: a content colony outlasts a sullen one by far.
      final a = CityLoyalty(), b = CityLoyalty();
      final tSullen = run(a, 400, happiness: 0, until: (l) => l.level <= 0);
      final tContent = run(b, 400, happiness: 1, until: (l) => l.level <= 0);
      expect((tContent - tuning.graceDays) / (tSullen - tuning.graceDays),
          greaterThan(3.0));
      expect(b.level, lessThanOrEqualTo(0),
          reason: 'but neglect still gets there in the end');
    });

    test('misrule alone: rebellion 0.8 takes the loyalty in ~10 days', () {
      final l = CityLoyalty();
      // Attended every tick — no neglect — and miserable, so no recovery.
      final at = run(l, 30,
          rebellion: 0.8, attend: true, until: (l) => l.level <= 0);
      expect(at, closeTo(10, 0.5));
    });

    test('rebellion at the floor costs nothing', () {
      final l = CityLoyalty();
      run(l, 30, rebellion: 0.3, attend: true);
      expect(l.level, 1.0, reason: 'every colony grumbles');
    });

    test('attention plus good rule bring it back: ~0.2 in 5 days', () {
      final l = CityLoyalty()..level = 0.4;
      run(l, 5, happiness: 1, attend: true);
      expect(l.level, closeTo(0.6, 0.01));
    });

    test('attention without good rule earns nothing', () {
      final l = CityLoyalty()..level = 0.4;
      run(l, 5, happiness: 0, attend: true);
      expect(l.level, 0.4, reason: 'recovery is content × attended');
    });

    test('one act counts for the recent window, then it lapses', () {
      final l = CityLoyalty()..level = 0.4;
      l.attend();
      run(l, tuning.recentDays, happiness: 1);
      final after = l.level;
      expect(after, greaterThan(0.75), reason: 'ten good days after one act');
      run(l, 5, happiness: 1);
      expect(l.level, lessThanOrEqualTo(after),
          reason: 'past the window, good rule alone wins nothing back');
    });
  });

  group('stages', () {
    void settle(CityLoyalty l, double level) {
      l.level = level;
      // A tick that moves nothing: attended, content 0, no rebellion.
      l.attend();
      l.tick(const LoyaltyInputs(
          dt: 1e-3, happiness: 0, coverage: 1, rebellion: 0, sufficiency: 0));
    }

    test('hysteresis: a band below each line before turning back', () {
      final l = CityLoyalty();
      settle(l, 0.61);
      expect(l.stage, LoyaltyStage.loyal);
      settle(l, 0.59);
      expect(l.stage, LoyaltyStage.restless);
      settle(l, 0.62);
      expect(l.stage, LoyaltyStage.restless, reason: 'not back above 0.65');
      settle(l, 0.66);
      expect(l.stage, LoyaltyStage.loyal);
      settle(l, 0.29);
      expect(l.stage, LoyaltyStage.defiant);
      settle(l, 0.33);
      expect(l.stage, LoyaltyStage.defiant, reason: 'not back above 0.35');
      settle(l, 0.36);
      expect(l.stage, LoyaltyStage.restless);
    });

    test('stage effects: self-government, the strike, non-payment', () {
      final l = CityLoyalty();
      expect((l.selfGoverning, l.strikeThrottle, l.taxFactor),
          (false, 1.0, 1.0));
      l.stage = LoyaltyStage.restless;
      expect((l.selfGoverning, l.strikeThrottle, l.taxFactor),
          (true, 1.0, 1.0));
      l.stage = LoyaltyStage.defiant;
      expect((l.strikeThrottle, l.taxFactor), (0.7, 0.5));
      l.stage = LoyaltyStage.standoff;
      expect((l.strikeThrottle, l.taxFactor), (0.4, 0.0));
    });

    test('a revolt knocks 0.15 off and adds desperation', () {
      final l = CityLoyalty();
      l.onRevolt('REVOLT!');
      expect(l.level, closeTo(0.85, 1e-12));
      expect(l.desperation, closeTo(0.15, 1e-12));
      expect(l.notices.last.kind, LoyaltyNoticeKind.revolt);
    });

    test('three revolts within 15 days fire the secession condition', () {
      final l = CityLoyalty();
      for (var i = 0; i < 3; i++) {
        l.onRevolt('REVOLT!');
        run(l, 4, attend: true, happiness: 0.5, sufficiency: 1);
      }
      expect(l.level, greaterThan(0.4), reason: 'loyalty is not what did it');
      expect(l.allegiance, Allegiance.independent);
      expect(l.notices.map((n) => n.kind),
          contains(LoyaltyNoticeKind.independence));
    });

    test('three revolts spread past the window do not', () {
      final l = CityLoyalty();
      for (var i = 0; i < 3; i++) {
        l.onRevolt('REVOLT!');
        run(l, 8, attend: true, happiness: 0.5, sufficiency: 1);
      }
      expect(l.allegiance, Allegiance.colonial);
      expect(l.recentRevolts, lessThan(3));
    });
  });

  group('self-sufficiency', () {
    test('a self-sufficient colony that runs out of loyalty secedes', () {
      final l = CityLoyalty();
      run(l, 20, rebellion: 1, attend: true, sufficiency: 1,
          until: (l) => l.allegiance != Allegiance.colonial);
      expect(l.allegiance, Allegiance.independent);
      expect(l.stage, LoyaltyStage.seceded);
      expect(l.independentAtS, isNotNull);
      expect(l.portClosedToPlayer, isTrue,
          reason: "its port is its own now, and shut to the player's craft");
    });

    test("an empty colony's reading does not outlive the emptiness", () {
      // Rebels held the port long enough that nobody could land: empty, the
      // colony measures 1.0 (no need, no shortfall). The first settlers in
      // must be measured as they are — dependent — not inherit that 1.0.
      final l = CityLoyalty();
      run(l, 5, sufficiency: 1, populated: false);
      expect(l.sufficiencyMeasured, isFalse);
      run(l, 0.1, sufficiency: 0, populated: true);
      expect(l.selfSufficiency, lessThan(0.05));
    });

    test('an empty colony does not secede', () {
      // Suffocated to its last settler: no need, so no shortfall, so it
      // measures self-sufficient — and nobody is left to declare anything.
      final l = CityLoyalty();
      run(l, 20, rebellion: 1, sufficiency: 1, populated: false);
      expect(l.level, 0);
      expect(l.allegiance, Allegiance.colonial);
    });

    test('a dependent colony cannot leave: standoff, not secession', () {
      final l = CityLoyalty();
      // Content enough that desperation does not run away: it is the
      // dependence alone that holds it.
      run(l, 30, rebellion: 1, happiness: 0.9, attend: true, sufficiency: 0.3);
      expect(l.level, 0);
      expect(l.stage, LoyaltyStage.standoff);
      expect(l.allegiance, Allegiance.colonial);
      expect(l.strikeThrottle, 0.4);
      expect(l.taxFactor, 0.0);
    });

    test('desperation lowers the bar until a desperate dependent secedes',
        () {
      final l = CityLoyalty();
      final standoffAt = run(l, 30,
          rebellion: 1, attend: true, sufficiency: 0.3,
          until: (l) => l.stage == LoyaltyStage.standoff);
      expect(l.stage, LoyaltyStage.standoff);
      expect(l.allegiance, Allegiance.colonial,
          reason: 'when the condition fired, it could not leave');
      // Mood 0: desperation has been climbing all along, and in standoff
      // it climbs on; the bar 0.9 × (1 − d) falls, and at d ≈ 2/3 it
      // passes under 0.3.
      final secededAt = run(l, 30,
          rebellion: 1, attend: true, sufficiency: 0.3,
          until: (l) => l.allegiance == Allegiance.independent);
      expect(l.allegiance, Allegiance.independent,
          reason: 'liberty or death');
      expect(l.desperation, greaterThan(0.6));
      expect(secededAt - standoffAt, greaterThan(1),
          reason: 'not at once: it held out first');
      expect(secededAt, lessThan(standoffAt + tuning.desperationDays));
    });

    test('becoming self-sufficient in standoff secedes at once', () {
      final l = CityLoyalty();
      run(l, 20, rebellion: 1, happiness: 0.9, attend: true, sufficiency: 0.2,
          until: (l) => l.stage == LoyaltyStage.standoff);
      expect(l.stage, LoyaltyStage.standoff);
      run(l, 20, rebellion: 1, happiness: 0.9, attend: true, sufficiency: 1,
          until: (l) => l.allegiance == Allegiance.independent);
      expect(l.allegiance, Allegiance.independent);
    });

    test('sufficiency eases over days: one good harvest is not a farm', () {
      final l = CityLoyalty();
      run(l, 1, sufficiency: 0.2);
      expect(l.selfSufficiency, closeTo(0.2, 1e-9),
          reason: 'the first measurement is taken as is');
      run(l, 1, sufficiency: 1);
      expect(l.selfSufficiency, lessThan(0.4));
      run(l, 20, sufficiency: 1);
      expect(l.selfSufficiency, greaterThan(0.95));
    });

    test('a standoff ends when attention and good rule win it back', () {
      final l = CityLoyalty();
      run(l, 20, rebellion: 1, happiness: 0.9, attend: true, sufficiency: 0.2,
          until: (l) => l.stage == LoyaltyStage.standoff);
      run(l, 20, happiness: 1, attend: true, sufficiency: 0.2,
          until: (l) => l.stage != LoyaltyStage.standoff);
      expect(l.stage, LoyaltyStage.restless);
      expect(l.level, greaterThan(tuning.defiantAbove));
    });
  });

  group('the port', () {
    CityLoyalty desperateStandoff() {
      final l = CityLoyalty();
      run(l, 40, rebellion: 1, happiness: 0.05, attend: true, sufficiency: 0,
          until: (l) => l.portSeized);
      return l;
    }

    test('rebels seize it once desperation passes 0.4', () {
      final l = desperateStandoff();
      expect(l.stage, LoyaltyStage.standoff);
      expect(l.portSeized, isTrue);
      expect(l.desperation, greaterThan(0.4));
      expect(l.migrationOpen, isFalse, reason: 'closed both ways');
      expect(l.portHoldReason, 'port held by rebels');
    });

    test('one more craft is let in, to be impounded; then none', () {
      final l = desperateStandoff();
      expect(l.admitCraft(), isTrue, reason: 'the next delivery');
      expect(l.admitCraft(), isFalse, reason: 'docking refused after that');
      expect(l.admitCraft(), isFalse);
    });

    test('no port, nothing to seize', () {
      final l = CityLoyalty();
      run(l, 40, rebellion: 1, happiness: 0.05, attend: true, sufficiency: 0,
          hasSpaceport: false, until: (l) => l.desperation > 0.6);
      expect(l.stage, LoyaltyStage.standoff);
      expect(l.portSeized, isFalse);
    });

    test('a standoff held by revolts keeps the port: no seize/release flap',
        () {
      // Three revolts on a dependent colony: loyalty 0.55, over the Defiant
      // line, desperation 0.45, over the seizure line. The revolts, not the
      // level, hold it in standoff.
      final l = CityLoyalty()..attend();
      for (var i = 0; i < 3; i++) {
        l.onRevolt('REVOLT!');
      }
      expect(l.level, greaterThan(tuning.defiantAbove));
      final held = <bool>[];
      run(l, 3, happiness: 0.5, sufficiency: 0.3, until: (l) {
        held.add(l.portSeized);
        return false;
      });
      expect(l.stage, LoyaltyStage.standoff);
      expect(held, everyElement(isTrue),
          reason: 'seized on the first tick and held from then on');
      expect(
          l.notices.where((n) => n.kind == LoyaltyNoticeKind.portSeized),
          hasLength(1));
      expect(l.notices.map((n) => n.kind),
          isNot(contains(LoyaltyNoticeKind.portReleased)));
      expect(l.admitCraft(), isTrue, reason: 'one admission, once');
      run(l, 1, happiness: 0.5, sufficiency: 0.3);
      expect(l.admitCraft(), isFalse,
          reason: 'not a fresh one every other tick');

      // The revolts age out of the window; at loyalty over the line the
      // standoff ends, and that is what gives the port back.
      run(l, tuning.revoltWindowDays, happiness: 0.5, attend: true,
          sufficiency: 0.3, until: (l) => l.stage != LoyaltyStage.standoff);
      expect(l.stage, isNot(LoyaltyStage.standoff));
      expect(l.portSeized, isFalse);
      expect(
          l.notices.where((n) => n.kind == LoyaltyNoticeKind.portReleased),
          hasLength(1));
    });

    test('impounds from one craft merge; separate craft stay separate', () {
      final l = CityLoyalty();
      for (var i = 0; i < 50; i++) {
        l.impound('food', 0.5, source: 'shuttle-a');
      }
      l.impound('fuel', 4, source: 'shuttle-a');
      l.impound('food', 200);
      l.impound('food', 200);
      l.impound('food', 1, source: 'shuttle-a');
      expect(l.impounded.map((c) => (c.resource, c.amount, c.source)), [
        ('food', 26.0, 'shuttle-a'),
        ('fuel', 4.0, 'shuttle-a'),
        ('food', 200.0, null),
        ('food', 200.0, null),
      ]);
    });

    test('given back once loyalty climbs past the Defiant line', () {
      final l = desperateStandoff();
      run(l, 30, happiness: 1, attend: true, sufficiency: 0,
          until: (l) => !l.portSeized);
      expect(l.portSeized, isFalse);
      expect(l.level, greaterThan(tuning.defiantAbove));
      expect(l.admitCraft(), isTrue);
    });
  });

  test('the state round-trips, and an absent block is a loyal colony', () {
    final l = CityLoyalty();
    run(l, 40, rebellion: 1, happiness: 0.05, attend: true, sufficiency: 0,
        until: (l) => l.portSeized);
    l.impound('food', 150);
    l.onRevolt('REVOLT!');
    final back = CityLoyalty()..restore(l.toJson());
    expect(back.toJson(), l.toJson());
    expect(back.colonyTimeS, l.colonyTimeS);
    expect(back.stage, LoyaltyStage.standoff);
    expect(back.portSeized, isTrue);
    expect(back.impounded.single.amount, 150);
    expect(back.revolts, l.revolts);

    final fresh = CityLoyalty()..restore(null);
    expect(fresh.toJson(), isEmpty);
    expect((fresh.level, fresh.stage, fresh.allegiance),
        (1.0, LoyaltyStage.loyal, Allegiance.colonial));
  });
}
