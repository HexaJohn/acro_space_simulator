// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/economy/economy_clock.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/economy_contracts.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/firm_policy.dart';
import 'package:flutter_test/flutter_test.dart';

/// One day's P&L at [margin] (profit ÷ revenue) on 100 credits/s of sales.
PlantPnL _day(double margin, {double revenuePerS = 100}) {
  const s = kColonyDaySec;
  final revenue = revenuePerS * s;
  return PlantPnL(
      seconds: s, revenue: revenue, inputs: revenue * (1 - margin),
      wages: 0, power: 0, logistics: 0, equipment: 0, tax: 0);
}

/// Feeds [days] days at [margin] into [b].
void _run(FirmBook b, double margin, int days) {
  for (var i = 0; i < days; i++) {
    b.record(_day(margin));
  }
}

/// How a firm reacts to its books (§3 "When a firm struggles", §7 Q9-Q11).
void main() {
  /// Hysteresis: a margin that wobbles across the strain ENTRY threshold
  /// strains the firm once and then holds it there — it must climb past
  /// the higher EXIT margin to recover. No flapping at the line.
  test('health has hysteresis: no flapping at a threshold', () {
    final b = FirmBook(owner: const Ownership.private('acme'));
    _run(b, 0.10, 120); // settle healthy
    expect(b.health, FirmHealth.healthy);
    _run(b, -0.05, 90); // settle under the entry line
    expect(b.health, FirmHealth.strained);

    // Wobble around the entry line, never above the exit margin.
    final seen = <FirmHealth>{};
    for (var i = 0; i < 200; i++) {
      b.record(_day(i.isEven ? kStrainEnterMargin + 0.02
          : kStrainEnterMargin - 0.02));
      seen.add(b.health);
    }
    expect(seen, {FirmHealth.strained});

    _run(b, kStrainExitMargin + 0.05, 120);
    expect(b.health, FirmHealth.healthy);
    expect(kStrainExitMargin, greaterThan(kStrainEnterMargin));
    expect(kDistressExitMargin, greaterThan(kDistressEnterMargin));
  });

  /// The payback rule: a private firm buys only what pays back within
  /// kFirmPaybackYears game-years.
  test('firmWillBuild = payback within the horizon', () {
    const horizon = kFirmPaybackYears * kGameYearSec;
    expect(firmWillBuild(capex: 1000, savingsPerS: 1000 / horizon * 1.01),
        isTrue);
    expect(firmWillBuild(capex: 1000, savingsPerS: 1000 / horizon * 0.99),
        isFalse);
    expect(firmWillBuild(capex: 1000, savingsPerS: 0), isFalse);
    expect(firmWillBuild(capex: 0, savingsPerS: 1), isTrue);
  });

  /// Order of reaction: with cash and a quick payback it invests first;
  /// losing, it lays off handlers, then idles stations, then — distressed
  /// for the grace period with nothing left to cut — closes and offers the
  /// plant for nationalisation or sale.
  test('invest, then layoff, idle, close, offer', () {
    final b = FirmBook(owner: const Ownership.private('acme'), cash: 5000);
    const quick = Investment(capex: 1000, savingsPerS: 1);
    expect(b.decide(investment: quick), FirmAction.invest);
    expect(b.cash, 4000);
    // Cooldown: nothing straight after an action.
    expect(b.decide(investment: quick), FirmAction.none);

    _run(b, -0.5, 60);
    expect(b.health, FirmHealth.distressed);
    const slow = Investment(capex: 1e12, savingsPerS: 1);
    expect(b.decide(investment: slow, canLayOff: true, canIdle: true),
        FirmAction.layoff);
    _run(b, -0.5, 8);
    expect(b.decide(canIdle: true), FirmAction.idleStations);
    _run(b, -0.5, 8);
    expect(b.offer(EconomyKind.capitalism), isEmpty);
    expect(b.decide(), FirmAction.close);
    expect(b.isClosed, isTrue);
    expect(b.offer(EconomyKind.capitalism),
        [ClosureOption.nationalise, ClosureOption.sellToNewFirm]);
    expect(b.offer(EconomyKind.communism), [ClosureOption.nationalise]);
    expect(b.decide(canLayOff: true), FirmAction.none,
        reason: 'a closed plant does nothing more');

    final state = b.reopen(ClosureOption.nationalise);
    expect(state.owner.isState, isTrue);
    expect(state.health, FirmHealth.healthy);
    final sold = b.reopen(ClosureOption.sellToNewFirm, newFirmId: 'phoenix');
    expect(sold.owner.firmId, 'phoenix');
  });

  /// A distressed firm that still has cuts to make doesn't close: closing
  /// is the last resort, and it waits out the grace period.
  test('no close while there is something to cut or before the grace', () {
    final b = FirmBook(owner: const Ownership.private('acme'));
    _run(b, -0.5, 10);
    expect(b.health, FirmHealth.distressed);
    expect(b.distressedForS, lessThan(kCloseGraceSec));
    expect(b.decide(), FirmAction.none, reason: 'grace not yet served');
    _run(b, -0.5, 40);
    expect(b.decide(canIdle: true), FirmAction.idleStations);
  });

  /// A state plant never acts or closes; its loss is the industry deficit,
  /// and a private plant never reports one.
  test('state plants never close; their loss is the industry deficit', () {
    final s = FirmBook(owner: const Ownership.state());
    _run(s, -0.5, 200);
    expect(s.decide(canLayOff: true, canIdle: true), FirmAction.none);
    expect(s.isClosed, isFalse);
    expect(s.industryDeficitPerS, closeTo(50, 1),
        reason: '100/s sales at −50% margin');
    expect(s.cash, 0);

    final p = FirmBook(owner: const Ownership.private('acme'));
    _run(p, -0.5, 200);
    expect(p.industryDeficitPerS, 0);
  });

  /// The books survive a save: every field round-trips.
  test('FirmBook toJson/fromJson round-trips', () {
    final b = FirmBook(owner: const Ownership.private('acme'), cash: 123.5);
    _run(b, -0.08, 45);
    b.decide(canLayOff: true);
    final c = FirmBook.fromJson(b.toJson());
    expect(c.toJson(), b.toJson());
    expect(c.owner.firmId, 'acme');
    expect(c.health, b.health);
    final s = FirmBook.fromJson(
        FirmBook(owner: const Ownership.state(), health: FirmHealth.closed)
            .toJson());
    expect(s.owner.isState, isTrue);
    expect(s.isClosed, isTrue);
  });
}
