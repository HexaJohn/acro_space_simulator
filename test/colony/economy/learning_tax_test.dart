// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The corporate-tax safety ceiling under learning curves
/// (docs/plans/dynamic-markets.md phase 2): phase 1 left the Rocket Parts
/// and Missile plants saturating `kCorporateTaxSafetyMultiple` because
/// Earth's price for their goods never fell. Now it does, as the world
/// makes more; this measures how far over game years.
///
/// Since phase 3 the mature cost under every curve is DERIVED from the
/// recipes (`mature_cost.dart`), not the old seed over the premium, so the
/// rent left once the premium is gone is the normal margin, not the old
/// table's eight-times value added. Measured (an Earth colony's private
/// plant, its output sold to Earth): Rocket Parts' raw tax is 17×, 12×,
/// 10×, 8×, 7× its workers' over years 0/1/2/5/10 (it was 391× → 188×),
/// the Missile Plant's 10×, 3×, 3×, 2×, 2× (it was 1,707× → 705×). Neither
/// is pinned at the 30× safety ceiling any more: the treasury gets 43% →
/// 21% and 28% → 7% of it.
///
/// Years of a live colony would take minutes, so the WORLD is fast-forwarded
/// headless between checkpoints (Earth's market and the colony's copy of the
/// world's learning stepped day by day, with the plant's output sold to
/// Earth all along, as an Earth colony's exportable surplus is), and the
/// colony itself runs a week at each checkpoint to let its prices settle
/// into Earth's new band (arbitrage closes half the gap a day) and book a
/// day of the plant at them.
library;

import 'package:acro_space_simulator/domain/colony/city/city_economy.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/commodity.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/colony_economy.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/economy_clock.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/learning.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/markets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../factory_integration/economy_fixture.dart';
import '../factory_integration/factory_colony_fixture.dart';

/// Steps [sim]'s world (its tech and its Earth market) on to world day
/// [day], headless, with [exportsPerS] sold to Earth and made locally.
void fastForwardWorld(CitySim sim, int day, Map<String, double> exportsPerS) {
  final e = sim.colonyEconomy;
  while (e.tech.worldDay < day) {
    final units = {
      for (final x in exportsPerS.entries) x.key: x.value * kColonyDaySec,
    };
    e.tech.recordLocal(units);
    e.tech.advanceWorldDay(exportsUnits: units);
    applyWorldTech(e.earthMarket, e.tech);
    closeEarthDay(e.earthMarket, exportsPerS: exportsPerS);
  }
}

/// One checkpoint of a plant's tax.
class TaxPoint {
  TaxPoint(this.years, this.earthPrice, this.rawMultiple, this.saturation);
  final double years;

  /// Earth's price of the plant's good, credits per unit.
  final double earthPrice;

  /// The plant's raw corporate tax as a multiple of its workers' tax.
  final double rawMultiple;

  /// What reached the treasury as a share of the safety ceiling.
  final double saturation;
}

List<TaxPoint> measure(String type, String good) {
  final sim = economyColony();
  final spec = specOf(type);
  final lot = placePlant(sim, type);
  final out = <TaxPoint>[];
  for (final years in const [0.0, 1.0, 2.0, 5.0, 10.0]) {
    if (years > 0) {
      final rate = sim.factoryFloors[lot]!.rates.outPerS[good] ?? 0.0;
      fastForwardWorld(sim, (years * 365.25).round(), {good: rate});
    }
    runDays(sim, 7.01, specs: [spec], inputs: 1e5);
    final pnl = sim.colonyEconomy.lastPnl[lot]!;
    final ceiling = sim.corporateTaxCeilingFor(lot);
    final workerTax = ceiling / kCorporateTaxSafetyMultiple;
    final raw = pnl.tax * kCreditsToFunds / kColonyDaySec;
    final paid = softTaxCeiling(raw, ceiling);
    expect(sim.colonyEconomy.corporateTaxFundsPerS,
        lessThanOrEqualTo(ceiling + 1e-9), reason: '$type at $years years');
    out.add(TaxPoint(years, sim.colonyEconomy.earthMarket.priceOf(good)!,
        raw / workerTax, paid / ceiling));
  }
  // ignore: avoid_print
  print('$type on Earth (ceiling ${kCorporateTaxSafetyMultiple.toStringAsFixed(0)}× '
      'workers\' tax):\n${out.map((p) => '  year ${p.years.toStringAsFixed(0)}: '
          'Earth ${Commodity.name(good)} ${p.earthPrice.toStringAsFixed(0)}/unit, '
          'raw tax ${p.rawMultiple.toStringAsFixed(0)}× workers\', '
          'paid ${(p.saturation * 100).toStringAsFixed(1)}% of ceiling').join('\n')}');
  return out;
}

void main() {
  for (final (type, good) in const [
    ('rocketfactory', Commodity.rocketParts),
    ('missilefactory', Commodity.missiles),
  ]) {
    test('$type: its rent erodes with world learning, well under the ceiling',
        () {
      final pts = measure(type, good);
      for (var i = 1; i < pts.length; i++) {
        expect(pts[i].earthPrice, lessThan(pts[i - 1].earthPrice),
            reason: 'Earth\'s price falls year on year');
        expect(pts[i].rawMultiple, lessThan(pts[i - 1].rawMultiple),
            reason: 'and so does the plant\'s rent');
      }
      // Phase 2 measured both plants pinned at the ceiling for a decade
      // (saturation > 0.99) because their mature cost came from the seed
      // table. Derived bottom-up (phase 3) the rent is the scarcity premium
      // plus the normal margin, so the ceiling no longer binds anywhere:
      // under it from year 0, and falling every year.
      for (final p in pts) {
        expect(p.rawMultiple, lessThan(kCorporateTaxSafetyMultiple),
            reason: 'year ${p.years}: ${p.rawMultiple}x workers tax');
        expect(p.saturation, lessThan(0.5), reason: 'year ${p.years}');
      }
    });
  }
}
