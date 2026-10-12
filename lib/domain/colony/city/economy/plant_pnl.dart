// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A plant's profit and loss over a period: its floor's cost counters
/// priced at the colony's local prices (docs/plans/factory-floors.md §3
/// "Ownership and money", §7 Q8).
///
/// The floor ledger (`factory_ledger.dart`) counts what a period USED —
/// worker-seconds, kilojoules, units in and out, equipment hours — and holds
/// no prices. Multiplying by a [PriceBook] turns that into money, which is
/// why a better floor layout is literally cheaper per unit: the design
/// reward and the money side are the same lever.
///
/// SHADOW prices (user decision Q8): revenue and costs are what the plant's
/// work is worth at local prices, not cash changing hands. The only real
/// money is [PlantPnL.tax], corporate tax on a PRIVATE plant's positive
/// pre-tax profit, which flows into `funds`. A state plant pays none; its
/// loss is charged to `funds` as the industry deficit (`firm_policy.dart`).
library;

import '../factory/factory_handling.dart';
import '../factory/factory_ledger.dart';
import 'economy_contracts.dart';

/// Freight fee per commodity unit through a dock, credits: hauling a
/// pallet a few kilometres across the colony (~$0.10/t-km over ~5 km).
/// Flat until agent-traffic freight trucks exist, then per truck trip.
const double kLogisticsFeePerUnit = 0.5;

/// Wear and depreciation per working colony-second, by handler kind,
/// credits. Set against a wage of ~0.4-1.3/worker-s: a forklift costs about
/// a fifth of its driver (real: ~$5/h against ~$30/h), a crane about half a
/// worker, an AGV a third (it replaces one but needs upkeep).
double equipmentWearPerS(HandlerKind k) => switch (k) {
      // Gloves and a trolley.
      HandlerKind.onFoot => 0.002,
      // A manual or powered pallet jack.
      HandlerKind.palletJack => 0.02,
      // An electric forklift with its charger and battery wear.
      HandlerKind.forklift => 0.12,
      // A bridge crane and its rail bay.
      HandlerKind.crane => 0.4,
      // An automated guided vehicle: no operator, real maintenance.
      HandlerKind.agv => 0.3,
    };

/// Corporate tax on a private plant's positive pre-tax profit, by economy.
/// A free market barely taxes; socialism taxes hard; under communism a
/// private plant is barely tolerated.
double corporateTaxRate(EconomyKind e) => switch (e) {
      EconomyKind.freeMarket => 0.10,
      EconomyKind.capitalism => 0.21,
      EconomyKind.socialism => 0.35,
      EconomyKind.communism => 0.50,
    };

/// Prices [ledger] at [book]. Units the ledger lists are colony commodity
/// units (crates already converted at the dock). Commodities are summed in
/// sorted order so the result does not depend on map insertion order.
PlantPnL pnlFor(
  FactoryLedger ledger,
  PriceBook book, {
  required Ownership owner,
  required EconomyKind economy,
  double logisticsPerUnit = kLogisticsFeePerUnit,
}) {
  double valued(Map<String, double> units) {
    var sum = 0.0;
    for (final c in units.keys.toList()..sort()) {
      sum += units[c]! * book.price(c);
    }
    return sum;
  }

  double unitsOf(Map<String, double> units) {
    var sum = 0.0;
    for (final c in units.keys.toList()..sort()) {
      sum += units[c]!;
    }
    return sum;
  }

  var equipment = 0.0;
  for (final k in HandlerKind.values) {
    equipment += (ledger.equipmentSeconds[k] ?? 0) * equipmentWearPerS(k);
  }
  final revenue = valued(ledger.shipped);
  final inputs = valued(ledger.received);
  final wages = ledger.totalWorkerSeconds * book.wagePerWorkerS;
  final power = ledger.energyKJ * book.powerPerKJ;
  final logistics =
      (unitsOf(ledger.received) + unitsOf(ledger.shipped)) * logisticsPerUnit;
  final preTax = revenue - (inputs + wages + power + logistics + equipment);
  final tax = owner.isState || preTax <= 0
      ? 0.0
      : preTax * corporateTaxRate(economy);
  return PlantPnL(
    seconds: ledger.seconds,
    revenue: revenue,
    inputs: inputs,
    wages: wages,
    power: power,
    logistics: logistics,
    equipment: equipment,
    tax: tax,
  );
}
