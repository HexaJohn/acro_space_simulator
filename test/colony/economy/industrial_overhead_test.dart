// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Advanced plants' tooling capital and engineering hours
/// (`industrial_overhead.dart`): in the mature cost, in the colony cost
/// solve and in the P&L, agreeing with each other, and deterministic.
library;

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/commodity.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/commodity_mass.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/earth_market.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/economy_clock.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/economy_contracts.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/industrial_overhead.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/learning.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/local_prices.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/mature_cost.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/plant_pnl.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_ledger.dart';
import 'package:flutter_test/flutter_test.dart';

CityBuildingSpec _spec(String type) =>
    kUtilCatalog.firstWhere((s) => s.type == type);

/// The advanced goods and the plant that makes each.
const Map<String, String> _advanced = {
  Commodity.electronics: 'electronics',
  Commodity.rocketParts: 'rocketfactory',
  Commodity.missiles: 'missilefactory',
};

void main() {
  final book = earthMatureMarket.book;

  test('every overhead plant is a catalogue recipe making what it lists', () {
    for (final e in kPlantOverheads.entries) {
      final spec = _spec(e.key);
      expect(e.value.toolingCredits, greaterThan(0), reason: e.key);
      expect(e.value.engineeringHoursPerUnit, isNotEmpty, reason: e.key);
      for (final g in e.value.engineeringHoursPerUnit.keys) {
        expect(spec.outputs.containsKey(g), isTrue, reason: '${e.key} $g');
        expect(overheadMakerOf(g), e.key);
      }
    }
    // The commodity process plants carry none.
    for (final t in const ['steelmill', 'refinery', 'rationsfactory']) {
      expect(overheadOf(t), isNull, reason: t);
      expect(toolingRecoveryPerS(t), 0);
    }
  });

  test("an engineering hour is 15 worker-seconds; Earth's contract wage is "
      "the mature solve's", () {
    expect(kWorkerSecondsPerHour, 15);
    expect(
      earthEngineeringWagePerS,
      closeTo(book.wageOf(SkillTier.engineering), 1e-9),
    );
    // The cheaper of the local and Earth wages.
    expect(engineeringWagePerS(earthEngineeringWagePerS * 3),
        earthEngineeringWagePerS);
    expect(engineeringWagePerS(earthEngineeringWagePerS / 2),
        earthEngineeringWagePerS / 2);
  });

  // The mature-cost breakdown has tooling and engineering lines, and they
  // are what dominates an advanced good, as they do a real one.
  for (final e in _advanced.entries) {
    test('${e.key}: the mature cost carries tooling and engineering', () {
      final spec = _spec(e.value);
      final rate = spec.outputs[e.key]!;
      final tooling = toolingPerUnit(e.key);
      final engineering = engineeringWorkerSecondsOf(e.key) *
          book.wageOf(SkillTier.engineering);
      expect(tooling, closeTo(toolingRecoveryPerS(e.value) / rate, 1e-9));
      expect(tooling, greaterThan(0));
      expect(engineering, greaterThan(0));
      final mature = earthMatureCost(e.key)!;
      // With the normal margin on top, the two lines are most of the price.
      final overhead = (tooling + engineering) * (1 + kNormalMargin);
      expect(overhead / mature, greaterThan(0.5), reason: e.key);
      // ignore: avoid_print
      print('${e.key}: mature ${mature.toStringAsFixed(0)}/unit, tooling '
          '${tooling.toStringAsFixed(0)}, engineering '
          '${engineering.toStringAsFixed(0)} '
          '(${engineeringHoursPerUnit(e.value, e.key)} h), '
          '${overheadJobsOf(e.value).toStringAsFixed(0)} overhead engineers');
    });
  }

  // The real-world sanity band: each advanced good's Earth price, from day 0
  // down to its mature cost (where a decade of world learning heads), stays
  // within 3× of the old reference table on day 0 and inside an order of
  // magnitude at maturity.
  test('advanced goods within 3× of the real-world reference', () {
    final t = TechState();
    for (final g in _advanced.keys) {
      final real = earthPrice(g);
      final day0 = t.earthUnitCost(g)!;
      expect(day0 / real, inInclusiveRange(1 / 3, 3), reason: g);
      expect(earthMatureCost(g)! / real, inInclusiveRange(0.1, 3),
          reason: '$g mature');
    }
  });

  // The P&L books exactly what the cost solve charges: a plant shipping its
  // nameplate for a second books its per-second tooling recovery, split
  // over its outputs (the Arms Factory's joint products sum back to it).
  test('the P&L books tooling and engineering on units shipped', () {
    for (final type in kPlantOverheads.keys.toList()..sort()) {
      final spec = _spec(type);
      final ledger = FactoryLedger()..seconds = 1;
      for (final o in spec.outputs.entries) {
        ledger.addShipped(o.key, o.value);
      }
      final pnl = pnlFor(ledger, book,
          owner: const Ownership.private('acme'),
          economy: EconomyKind.capitalism);
      expect(pnl.tooling, closeTo(toolingRecoveryPerS(type), 1e-9),
          reason: type);
      var eng = 0.0;
      for (final o in spec.outputs.entries) {
        eng += o.value *
            engineeringWorkerSecondsPerUnit(type, o.key) *
            earthEngineeringWagePerS;
      }
      expect(pnl.engineering, closeTo(eng, 1e-9), reason: type);
      // Engineering is overhead, not the floor's wage line.
      expect(pnl.wages, 0);
      expect(pnl.costs,
          closeTo(pnl.logistics + pnl.tooling + pnl.engineering, 1e-9));
      expect(pnl.toJson()['tool'], pnl.tooling);
      expect(pnl.toJson()['eng'], pnl.engineering);
    }
    // A good no overhead plant makes books none.
    final steel = pnlFor(FactoryLedger()..addShipped(Commodity.steel, 10),
        book, owner: const Ownership.state(), economy: EconomyKind.socialism);
    expect(steel.tooling, 0);
    expect(steel.engineering, 0);
    expect(steel.toJson().containsKey('tool'), isFalse);
  });

  // A dear local engineer is replaced by Earth's contract rate, in the books
  // as in the price.
  test("engineering is paid at the cheaper of local and Earth's wage", () {
    final dear = PriceBook(
      prices: book.prices,
      wagePerWorkerS: book.wagePerWorkerS,
      powerPerKJ: book.powerPerKJ,
      tierWages: {SkillTier.engineering: earthEngineeringWagePerS * 25},
    );
    final cheap = PriceBook(
      prices: book.prices,
      wagePerWorkerS: book.wagePerWorkerS,
      powerPerKJ: book.powerPerKJ,
      tierWages: {SkillTier.engineering: earthEngineeringWagePerS / 2},
    );
    final shipped = {Commodity.rocketParts: 1.0};
    final atDear = overheadBooked(shipped, dear);
    final atCheap = overheadBooked(shipped, cheap);
    final ws = engineeringWorkerSecondsOf(Commodity.rocketParts);
    expect(atDear.engineering, closeTo(ws * earthEngineeringWagePerS, 1e-9));
    expect(atCheap.engineering,
        closeTo(ws * earthEngineeringWagePerS / 2, 1e-9));
    expect(atDear.tooling, atCheap.tooling);
  });

  // A colony's cost solve carries the same lines: rocket parts on Mars cost
  // at least their tooling and contracted engineering, times the colony's
  // learning multiplier.
  test("a colony's local cost includes the overhead", () {
    final facts = MarketFacts(
      bodyId: 'mars',
      economy: EconomyKind.capitalism,
      population: 1000,
      learningMult: const {Commodity.rocketParts: 2},
    );
    final m = solveLocalMarket(facts);
    final floor = (toolingPerUnit(Commodity.rocketParts) +
            engineeringWorkerSecondsOf(Commodity.rocketParts) *
                engineeringWagePerS(
                    m.book.wageOf(SkillTier.engineering))) *
        2;
    expect(m.localCost[Commodity.rocketParts], greaterThan(floor));
  });

  test('deterministic: the same solve and books every time', () {
    final a = solveLocalMarket(earthMatureFacts(),
        pinned: {
          for (final e in kExtractionCostPerKg.entries)
            e.key: e.value * kgPerUnit(e.key),
        },
        costMarkup: 1 + kNormalMargin);
    for (final g in marketGoods()) {
      expect(a.book.prices[g], earthMatureMarket.book.prices[g], reason: g);
    }
    // Booking does not depend on the order goods were shipped in.
    final x = overheadBooked(
        {Commodity.guns: 3, Commodity.ammo: 10, Commodity.missiles: 1}, book);
    final y = overheadBooked(
        {Commodity.missiles: 1, Commodity.ammo: 10, Commodity.guns: 3}, book);
    expect(x.tooling, y.tooling);
    expect(x.engineering, y.engineering);
    // Tooling is a credit investment over ten game-years, not ore.
    expect(kCapitalRecoveryYears * kGameYearSec, 10 * 365.25 * kColonyDaySec);
  });
}
