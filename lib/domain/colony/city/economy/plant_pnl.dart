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
import 'industrial_overhead.dart';

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
///
/// **Revenue counts only what sold** (docs/plans/dynamic-markets.md §3
/// "Consequences"): each good shipped is valued at its price times its
/// [sellThrough], the share of the colony's supply of it that found a buyer
/// (`markets.dart` `sellThroughOf`; a good not listed sold whole). The plant
/// takes its pro-rata share of what sold: shipped × price × share. What
/// didn't sell piles up in stock, where the market's cover term pushes the
/// price down. Every unit shipped still pays its freight, and inputs are
/// always paid for whole.
///
/// **Wages by skill tier** (docs/plans/dynamic-markets.md phase 3): every
/// worker-second the ledger counts is split by [labourShares], the plant's
/// labour profile (`skill_tiers.dart` `labourProfileOf`: stations at their
/// recipe's tier, handlers skilled, technicians technical), and each part
/// is paid its tier's market wage ([PriceBook.wageOf]). By profile rather
/// than by the ledger's roles because an aggregate floor books every hour
/// as station work (it knows the layout's job demand, not its role split),
/// and a plant is staffed in its profile's proportions either way. With no
/// shares (a hand-built book or ledger) every hour is paid the book's one
/// wage.
///
/// **Advanced overheads** (`industrial_overhead.dart`): every unit shipped
/// of a good an advanced plant makes books its tooling recovery
/// ([PlantPnL.tooling], straight-line over the plant's nameplate life, the
/// way program accounting spreads tooling over planned units) and its
/// design, test and certification hours at the book's engineering wage
/// ([PlantPnL.engineering]). Per unit SHIPPED, so a plant whose market
/// takes only part of its output carries more tooling per unit sold.
PlantPnL pnlFor(
  FactoryLedger ledger,
  PriceBook book, {
  required Ownership owner,
  required EconomyKind economy,
  double logisticsPerUnit = kLogisticsFeePerUnit,
  Map<String, double> sellThrough = const {},
  Map<SkillTier, double> labourShares = const {},
}) {
  double valued(Map<String, double> units, {bool sold = false}) {
    var sum = 0.0;
    for (final c in units.keys.toList()..sort()) {
      final share = sold ? (sellThrough[c] ?? 1.0) : 1.0;
      sum += units[c]! * book.price(c) * share;
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
  final revenue = valued(ledger.shipped, sold: true);
  final inputs = valued(ledger.received);
  final ws = ledger.totalWorkerSeconds;
  final byTier = <SkillTier, double>{};
  var wages = 0.0;
  if (labourShares.isEmpty) {
    wages = ws * book.wagePerWorkerS;
  } else {
    for (final t in SkillTier.values) {
      final s = labourShares[t];
      if (s == null || !(s > 0)) continue;
      final w = ws * s * book.wageOf(t);
      byTier[t] = w;
      wages += w;
    }
  }
  final power = ledger.energyKJ * book.powerPerKJ;
  final logistics =
      (unitsOf(ledger.received) + unitsOf(ledger.shipped)) * logisticsPerUnit;
  final overhead = overheadBooked(ledger.shipped, book);
  final preTax = revenue -
      (inputs +
          wages +
          power +
          logistics +
          equipment +
          overhead.tooling +
          overhead.engineering);
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
    wagesByTier: Map.unmodifiable(byTier),
    tooling: overhead.tooling,
    engineering: overhead.engineering,
  );
}

/// The books of a STAFF-STARVED day: [seconds] in which the plant sold
/// nothing, used nothing and paid no wages because the labour market gave
/// it no one (`CityEconomy.closeEconomyDay`, "the starved-of-staff rule"),
/// charged only what owning the plant costs whether or not anyone works it:
/// - its ore build cost recovered at [capitalPerS] ([PlantPnL.capital]);
/// - its specialised tooling recovered at [toolingPerS] ([PlantPnL.tooling],
///   `industrial_overhead.dart` `toolingRecoveryPerS`; a working day books
///   the same recovery per unit shipped instead).
///
/// No revenue, so no tax: a private firm's loss is its own, a state plant's
/// is the industry deficit like any other loss.
///
/// Why not book nothing, as a day the colony refused the plant does: a firm
/// the market starves of staff is starved because it can't outbid anyone
/// (`labour_market.dart` `labourBid`: private firms bid by margin), so its
/// idle days ARE evidence about it. Skipping them froze a losing firm at
/// "distressed" for ever: no `FirmBook.record`, so no `decide`, so the
/// ladder (lay off → idle → close → offer) never reached its end.
PlantPnL standingPnlFor({
  required double seconds,
  required double capitalPerS,
  double toolingPerS = 0,
}) {
  final s = seconds > 0 ? seconds : 0.0;
  final cap = capitalPerS > 0 ? capitalPerS * s : 0.0;
  final tool = toolingPerS > 0 ? toolingPerS * s : 0.0;
  return PlantPnL(
    seconds: s,
    revenue: 0,
    inputs: 0,
    wages: 0,
    power: 0,
    logistics: 0,
    equipment: 0,
    tax: 0,
    tooling: tool,
    capital: cap,
  );
}
