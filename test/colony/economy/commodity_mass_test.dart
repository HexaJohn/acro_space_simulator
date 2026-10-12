// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/commodity.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/commodity_mass.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/earth_market.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_item.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mass and Earth price tables (§3 "Prices are local and derived"): the
/// import ceiling is price + transport/kg × kg/unit, so a missing entry
/// would silently misprice a good.
void main() {
  /// Every colony commodity has an explicit mass and Earth price entry, and
  /// only compute is massless.
  test('every commodity has a mass and an Earth price', () {
    for (final c in Commodity.ordered) {
      expect(kCommodityKgPerUnit.containsKey(c), isTrue, reason: c);
      expect(kEarthPricePerKg.containsKey(c), isTrue, reason: c);
      if (c == Commodity.compute) {
        expect(kgPerUnit(c), 0);
      } else {
        expect(kgPerUnit(c), greaterThan(0), reason: c);
      }
    }
    expect(isShippable(Commodity.compute), isFalse);
    expect(isShippable(Commodity.garbage), isFalse);
    expect(isShippable(Commodity.oxygen), isTrue);
  });

  /// A dock converts factory items to commodities one for one, so their
  /// masses must agree; intermediates take the factory item's mass, and a
  /// crate prices as the units it holds.
  test('commodity masses agree with factory items', () {
    for (final item in FactoryItems.table.values) {
      expect(kgPerUnit(item.commodity) * item.commodityUnits,
          closeTo(item.kgPerUnit, 1e-9), reason: item.id);
    }
    expect(kgPerUnit('pigIron'), FactoryItems.pigIron.kgPerUnit);
    expect(earthPrice('crate:steel'), earthPrice(Commodity.steel) * 10);
  });

  /// Value per kg is what separates "make it here" from "ship it in":
  /// electronics carry orders of magnitude more per kg than oxygen.
  test('value per kg: electronics >> oxygen, water', () {
    double perKg(String c) => earthPrice(c) / kgPerUnit(c);
    expect(perKg(Commodity.electronics), greaterThan(perKg(Commodity.oxygen) * 100));
    expect(perKg(Commodity.oxygen), greaterThan(perKg(Commodity.water)));
  });

  /// Unknown ids fall back to a documented crate rather than crash.
  test('unknown commodities fall back to defaults', () {
    expect(kgPerUnit('unobtainium'), kUnknownKgPerUnit);
    expect(earthPrice('unobtainium'),
        kEarthUnknownPricePerKg * kUnknownKgPerUnit);
  });
}
