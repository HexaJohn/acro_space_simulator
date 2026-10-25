// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Earth's mature costs derived bottom-up from the recipes
/// (docs/plans/dynamic-markets.md phase 3, `mature_cost.dart`): no good's
/// mature cost comes from the old hand-set price table any more.
library;

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/commodity.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/commodity_mass.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/earth_market.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/economy_clock.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/learning.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/local_prices.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/markets.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/mature_cost.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/plant_pnl.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/skill_tiers.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_handling.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_templates.dart';
import 'package:flutter_test/flutter_test.dart';

/// The goods whose derived Earth price lands more than an order of
/// magnitude under the real-world reference, and why: their flat recipes
/// are far more productive per worker than the real trades (50 people make
/// 40 kg of rocket parts every colony second — 4.8 t a day — out of 43 kg
/// of tube and boards, so the part costs little more than its materials),
/// and the real price is mostly engineering hours, R&D and capital the
/// recipe doesn't carry. Closing it is a recipe retune, not a price.
const Set<String> kRecipeBoundGoods = {
  Commodity.electronics,
  Commodity.rocketParts,
  Commodity.missiles,
};

void main() {
  final m = earthMatureMarket;
  final book = m.book;

  test('the mature solve converges, with no import source anywhere', () {
    expect(m.converged, isTrue);
    expect(book.importCeiling, isEmpty, reason: 'nothing is bought in');
    for (final c in marketGoods()) {
      expect(m.sourceOf[c], isNot(kSourceImport), reason: c);
    }
  });

  test('raw goods sit at their documented extraction cost', () {
    for (final e in kExtractionCostPerKg.entries) {
      expect(m.sourceOf[e.key], kSourcePinned, reason: e.key);
      expect(earthMatureCost(e.key), e.value * kgPerUnit(e.key), reason: e.key);
    }
  });

  // Every manufactured good is priced by the recipe that makes it cheapest
  // on Earth, never by a table.
  test('every manufactured good is priced by a recipe', () {
    for (final c in const [
      Commodity.steel,
      Commodity.tubes,
      Commodity.electronics,
      Commodity.rocketParts,
      Commodity.missiles,
      Commodity.guns,
      Commodity.ammo,
      Commodity.medicine,
      Commodity.rations,
    ]) {
      final src = m.sourceOf[c]!;
      expect(
        kUtilCatalog.any((s) => s.type == src) || src.startsWith('i-'),
        isTrue,
        reason: '$c from $src',
      );
      expect(earthMatureCost(c), greaterThan(0), reason: c);
    }
  });

  // The carry-over fix: rocket parts' mature price is its recipe's inputs
  // at Earth's mature prices, its jobs at Earth's tier wages, its energy,
  // the capital recovery of its build cost, its floor's freight fee and
  // equipment wear, plus the normal margin — recomputed here by hand.
  test('rocket parts: mature price = inputs + labour + energy + capital + '
      'margin', () {
    final spec = kUtilCatalog.firstWhere((s) => s.type == 'rocketfactory');
    expect(m.sourceOf[Commodity.rocketParts], spec.type);
    var inputs = 0.0, units = 0.0;
    for (final e in spec.inputs.entries) {
      inputs += e.value * book.price(e.key);
      units += e.value;
    }
    for (final v in spec.outputs.values) {
      units += v;
    }
    final labour =
        spec.jobs *
        book.wagePerWorkerS *
        wageMultipleOf(labourSharesOf(spec.type));
    final energy =
        spec.powerDraw * book.powerPerKJ * kKjPerPowerUnitS +
        spec.computeDraw * book.price(Commodity.compute);
    final capital =
        spec.buildCost *
        book.price(Commodity.ore) /
        (kCapitalRecoveryYears * kGameYearSec);
    var wear = 0.0;
    final roster = factoryTemplateFor(spec.type)!.roster;
    for (final k in HandlerKind.values) {
      wear += (roster[k] ?? 0) * equipmentWearPerS(k);
    }
    final freight = units * kLogisticsFeePerUnit;
    final direct = inputs + labour + energy + capital + wear + freight;
    final rate = spec.outputs[Commodity.rocketParts]!;
    final expected = direct * (1 + kNormalMargin) / rate;
    final got = earthMatureCost(Commodity.rocketParts)!;
    expect(got, closeTo(expected, expected * 1e-6));
    // The labour is engineers and skilled handlers, dearer than the cost
    // of living (2.3× on average for the template's crew).
    expect(wageMultipleOf(labourSharesOf(spec.type)), greaterThan(2));
    // No longer eight times its inputs (phase 2's seed calibration): the
    // inputs are most of the direct cost, and the price is about twice them.
    final perUnitInputs = inputs / rate;
    expect(got / perUnitInputs, inInclusiveRange(1.5, 2.5));
    // ignore: avoid_print
    print(
      'rocket parts mature ${got.toStringAsFixed(1)}/unit: inputs '
      '${(inputs / rate).toStringAsFixed(1)}, labour '
      '${(labour / rate).toStringAsFixed(1)}, energy '
      '${(energy / rate).toStringAsFixed(2)}, capital '
      '${(capital / rate).toStringAsFixed(4)}, wear+freight '
      '${((wear + freight) / rate).toStringAsFixed(2)}, margin '
      '${(direct * kNormalMargin / rate).toStringAsFixed(1)} '
      '(${(got / perUnitInputs).toStringAsFixed(2)}× inputs)',
    );
  });

  // Earth's day-0 price is the mature cost times one plus the premium left
  // today; the curve takes it down from there.
  test("Earth's day-0 price is mature × (1 + today's premium)", () {
    final t = TechState();
    for (final g in t.catalog.goods) {
      final s = t.catalog[g]!;
      final mature = earthMatureCost(g);
      if (mature == null) continue;
      final want = s.learns ? mature * (1 + s.premiumToday) : mature;
      expect(t.earthUnitCost(g), closeTo(want, want * 1e-12), reason: g);
    }
  });

  // The old table survives only as this: a real-world sanity reference.
  // Every derived Earth price is within an order of magnitude of what the
  // good really sells for, except the recipe-bound advanced goods, which
  // land below it by the documented margin (see [kRecipeBoundGoods]).
  test('derived Earth prices against the real-world reference', () {
    final t = TechState();
    final lines = <String>[];
    for (final c in marketGoods()) {
      final real = earthPrice(c);
      final day0 = t.earthUnitCost(c) ?? earthMatureCost(c);
      if (!(real > 0) || day0 == null) continue;
      final r = day0 / real;
      lines.add(
        '$c ${(day0 / kgPerUnit(c)).toStringAsFixed(3)}/kg vs '
        '${(real / kgPerUnit(c)).toStringAsFixed(3)} (×${r.toStringAsFixed(3)}, '
        '${goodClassOf(c).name})',
      );
      if (kRecipeBoundGoods.contains(c)) {
        expect(r, lessThan(0.1), reason: '$c: recipe-bound, below real');
        expect(r, greaterThan(0.001), reason: '$c: but not absurdly');
      } else {
        expect(r, inInclusiveRange(0.1, 10), reason: '$c ×$r');
      }
    }
    // ignore: avoid_print
    print(lines.join('\n'));
  });
}
