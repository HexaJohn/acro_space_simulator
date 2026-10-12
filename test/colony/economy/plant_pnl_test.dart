// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/economy/economy_contracts.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/plant_pnl.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_handling.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_ledger.dart';
import 'package:flutter_test/flutter_test.dart';

const _book = PriceBook(
  prices: {'ore': 6, 'steel': 30, 'tubes': 25},
  wagePerWorkerS: 0.5,
  powerPerKJ: 1e-4,
);

/// A steel mill's hour on the floor, by hand: 100 ore in, 70 steel and 20
/// tubes out, 3,000 worker-seconds, 2e6 kJ, a forklift for 500 s.
FactoryLedger _ledger() => FactoryLedger()
  ..seconds = 100
  ..energyKJ = 2e6
  ..addReceived('ore', 100)
  ..addShipped('steel', 70)
  ..addShipped('tubes', 20)
  ..addWork(WorkRole.station, 2000)
  ..addWork(WorkRole.handler, 1000)
  ..addEquipment(HandlerKind.forklift, 500)
  ..addEquipment(HandlerKind.onFoot, 1000);

/// A plant's P&L is its ledger's counters priced at local prices (§3
/// "Ownership and money"); only corporate tax on a PRIVATE plant's profit is
/// real money. These pin the arithmetic and who pays tax.
void main() {
  /// Every line from a hand-built ledger, checked against hand arithmetic.
  test('P&L lines are the ledger priced at the book', () {
    final p = pnlFor(_ledger(), _book,
        owner: const Ownership.private('acme'),
        economy: EconomyKind.capitalism);
    expect(p.seconds, 100);
    expect(p.revenue, 70 * 30 + 20 * 25); // 2600
    expect(p.inputs, 100 * 6); // 600
    expect(p.wages, 3000 * 0.5); // 1500
    expect(p.power, closeTo(2e6 * 1e-4, 1e-9)); // 200
    expect(p.logistics, (100 + 70 + 20) * kLogisticsFeePerUnit);
    expect(
        p.equipment,
        closeTo(
            500 * equipmentWearPerS(HandlerKind.forklift) +
                1000 * equipmentWearPerS(HandlerKind.onFoot),
            1e-9));
    final preTax = 2600 - 600 - 1500 - 200 - p.logistics - p.equipment;
    expect(p.preTax, closeTo(preTax, 1e-9));
    expect(p.tax, closeTo(preTax * corporateTaxRate(EconomyKind.capitalism),
        1e-9));
    expect(p.profit, closeTo(preTax - p.tax, 1e-9));
  });

  /// A custom logistics fee replaces the flat default.
  test('logistics fee is a per-unit parameter', () {
    final p = pnlFor(_ledger(), _book,
        owner: const Ownership.state(), economy: EconomyKind.socialism,
        logisticsPerUnit: 2);
    expect(p.logistics, 190 * 2);
  });

  /// State plants pay no corporate tax; nor does a private plant at a loss
  /// (tax is on positive pre-tax profit only).
  test('no tax for state plants or for losses', () {
    final state = pnlFor(_ledger(), _book,
        owner: const Ownership.state(), economy: EconomyKind.capitalism);
    expect(state.preTax, greaterThan(0));
    expect(state.tax, 0);

    const dear = PriceBook(
        prices: {'ore': 6, 'steel': 30, 'tubes': 25},
        wagePerWorkerS: 5, powerPerKJ: 1e-4);
    final losing = pnlFor(_ledger(), dear,
        owner: const Ownership.private('acme'),
        economy: EconomyKind.socialism);
    expect(losing.preTax, lessThan(0));
    expect(losing.tax, 0);
    expect(losing.profit, losing.preTax);
  });

  /// Tax rates rise from free market to communism, so the economy choice
  /// is a real lever on the treasury.
  test('corporate tax rate orders by economy', () {
    expect(corporateTaxRate(EconomyKind.freeMarket),
        lessThan(corporateTaxRate(EconomyKind.capitalism)));
    expect(corporateTaxRate(EconomyKind.capitalism),
        lessThan(corporateTaxRate(EconomyKind.socialism)));
    expect(corporateTaxRate(EconomyKind.socialism),
        lessThan(corporateTaxRate(EconomyKind.communism)));
  });

  /// An empty ledger is an empty P&L, not NaN.
  test('an empty ledger prices to zero', () {
    final p = pnlFor(FactoryLedger(), _book,
        owner: const Ownership.private('x'), economy: EconomyKind.freeMarket);
    expect(p.revenue, 0);
    expect(p.costs, 0);
    expect(p.tax, 0);
  });
}
