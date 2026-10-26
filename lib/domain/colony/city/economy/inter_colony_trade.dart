// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Inter-colony trade: every player colony is a source and a destination for
/// the others, linked by transport cost (docs/plans/dynamic-markets.md
/// phase 5).
///
/// Before this, a colony's trade band had exactly one other end: Earth. A
/// Martian colony short of food paid Earth's price plus the whole climb out
/// of Earth's well, even with a granary colony next door. Now each colony's
/// import ceiling and export floor ([tradeBandFor]) also consider every
/// other player colony that can trade:
///
/// - **a source** for a good, at its price plus freight to here, when it
///   holds more than its own reserve ([exportableUnits]);
/// - **a destination**, at its price less freight from here, when it is
///   short ([wantedUnits]).
///
/// Freight is the same Δv model Earth trade uses (`transport_cost.dart`);
/// two colonies on the SAME body pay [kSameBodyFreightPerKg] instead (the
/// Δv model reads a same-body route as free, and a surface convoy is not).
///
/// **Physical flows: bookkeeping, option (a) of the phase-5 spec.** Goods
/// really move, but as a daily clearing, not as flights. At its daily close
/// a colony buys ([runImports]) what it is short of from the cheapest
/// partner whose landed price beats both its own price and Earth's landed
/// price: the partner's stock falls and its day's demand rises (an export
/// is a sale), this colony's stock rises and its day's supply rises (an
/// import landed). Volume is capped by each end's spaceport launch capacity
/// ([kPortLaunchKgPerDayPerFuelUnit]). The follow-up is (b): real cargo
/// flights (the existing shuttle runs and `DeliverySchedule`), each leg a
/// ship that takes the route's mission time, so a siege or an orbital
/// blockade can intercept it.
///
/// **Why importer-driven.** Each trade is decided at the IMPORTER's close
/// from its own fresh view of the shortage; an exporter has nothing to
/// decide (it sells whatever stands above its reserve at its price). One
/// side choosing keeps every leg decided exactly once, whatever order the
/// host advances colonies in.
///
/// **Ports.** Both ends need a working spaceport (`MarketFacts.canExport`:
/// a spaceport, not seized by rebels, not an independent colony's). Two
/// colonies on one body still need theirs: the port is the colony's freight
/// terminal, where the launch capacity is counted. (Road links between
/// colonies sharing a body are a follow-up.)
///
/// **Money.** None. Trade is shadow-priced like everything else in the
/// colony economy (factory-floors decision Q8): the importer's price falls
/// because its shelf fills, the exporter's rises because its shelf empties
/// and its sales grow. No credits pass between treasuries; corporate tax
/// and the subsidy lines are untouched. (A treasury-to-treasury hook does
/// not exist cleanly today: `funds` is each colony's own, fed by its own
/// worker and corporate tax. A follow-up could book each leg's value as an
/// off-by-default transfer.)
///
/// **What the band does NOT know (simplification).** A partner quotes its
/// price for a good as soon as it holds any surplus, however small; and the
/// band holds even on a day the route's launch capacity is used up. Prices
/// then converge within freight while the cargo that would justify it is
/// still queued. The physical flow catches up over a few days; a
/// capacity-aware band is a follow-up.
///
/// Pure and deterministic: no RNG; partners in colony-id order, goods in
/// key order, the cheapest landed source first (ties by colony id).
library;

import 'dart:collection';
import 'dart:math' as math;

import 'colony_economy.dart';
import 'commodity_mass.dart';
import 'economy_clock.dart';
import 'economy_contracts.dart';
import 'local_prices.dart';
import 'markets.dart';

// ---- tuning --------------------------------------------------------------------

/// Freight between two colonies on the SAME body, credits per kg: a
/// pressurised crawler convoy or a short ballistic hop across an airless or
/// thin-aired world. Earth road freight runs ~$0.05 per tonne-km, so a
/// 1,000-5,000 km haul is $0.05-0.25/kg; off-world, with no roads, crawlers
/// built to Mars rover standards and crews in suits, about ten times that:
/// ~$2/kg. Far under any interplanetary route (Moon to Mars is hundreds of
/// credits a kg), so two colonies on one world trade almost as one market.
const double kSameBodyFreightPerKg = 2;

/// Inter-colony cargo one spaceport moves per colony day, kg, per unit of
/// the port's propellant draw (`CityBuildingSpec.inputs[fuel]`: 1 for the
/// basic Spaceport, 2.6 for the Complex, 6 for the Starport — the
/// catalogue already sizes a port's traffic by what it burns).
///
/// 100 t: one heavy reusable flight a day from one pad (a mature methalox
/// launcher lifts 100-150 t, `transport_cost.dart`; with its two-day
/// turnaround a pad works two vehicles). The capacity is shared by cargo
/// in and out: a port that lands 60 t of food today can send 40 t of steel.
/// Booked Earth freight and life-support trickles keep their own flights,
/// so they do not draw on it.
const double kPortLaunchKgPerDayPerFuelUnit = 100000;

/// Days over which an importer refills its shelf to target cover: each day
/// it orders a fifth of the gap. A port lands cargo every few days and a
/// buyer orders what it can land in that window, not a month's stock in
/// one night (which would also swing both prices far past each other).
/// With a steady drain d a day the shelf settles at
/// cover* − [kTradeRefillDays]·d, 25 of the 30 target days.
const double kTradeRefillDays = 5;

/// Days of its own consumption an exporter keeps for itself before it sells
/// a unit to another colony: the same target cover its market prices
/// against ([kTargetCoverDays]). A colony never ships out the food its own
/// people need this month...
const double kTradeReserveCoverDays = kTargetCoverDays;

/// ... or, when its store cannot hold a month (most colonies' cannot: the
/// starter store holds ~600 units of each good against a few hundred eaten
/// a day), half its store ([TradePartner.stockCap]). Half: the shelf a
/// granary colony keeps full is what lets it ride out its own bad week, and
/// the other half is what it can sell.
const double kTradeReserveCapShare = 0.5;

/// Units below which a leg is not worth a flight (and not recorded).
const double kTradeMinUnits = 1e-6;

// ---- the other end -------------------------------------------------------------

/// One player colony as the trade sees it. `city_trade.dart` adapts a
/// `CitySim`; a test can supply its own.
abstract interface class TradePartner {
  /// The colony's id (`CitySim.id`): the deterministic order of partners.
  String get colonyId;

  /// `CelestialBody.id` it stands on.
  String get bodyId;

  /// Whether its spaceport can trade (`MarketFacts.canExport`).
  bool get portOpen;

  /// Inter-colony cargo its ports move per colony day, kg.
  double get launchCapacityKgPerDay;

  /// Its economy: its market (prices, smoothed flows) and trade state.
  ColonyEconomy get economy;

  /// Units of [commodity] held now.
  double stockOf(String commodity);

  /// Units of any one good its store holds (`CitySim.stockCap`): cargo
  /// beyond it would be clipped on landing, so no colony orders more.
  double get stockCap;

  /// Adds [units] (negative: removes) of [commodity] to its stock.
  void addStock(String commodity, double units);
}

/// Freight per kg from [fromBody] to [toBody] between two colonies: the Δv
/// model's route, or [kSameBodyFreightPerKg] on one body.
double interColonyFreightPerKg(
  TransportCostModel transport,
  String fromBody,
  String toBody,
) => fromBody == toBody
    ? kSameBodyFreightPerKg
    : transport.perKg(fromBody, toBody);

/// [p]'s own smoothed demand for [c], units/s: its market's demand less
/// what it ships to other colonies ([ColonyTrade.exportPerS]). An export
/// is a sale (it counts in the market's demand) but not a mouth to feed,
/// so it must not swell the reserve the colony keeps for itself.
double ownDemandPerS(TradePartner p, String c) {
  final m = p.economy.colonyMarket.goods[c];
  if (m == null) return 0;
  final out = p.economy.trade.exportPerS[c] ?? 0.0;
  return math.max(0.0, m.demandPerS - out);
}

/// Units of [c] [p] can sell another colony now: its stock above its
/// reserve, [kTradeReserveCoverDays] of its own demand or
/// [kTradeReserveCapShare] of its store, whichever is less. Zero when its
/// port is shut.
double exportableUnits(TradePartner p, String c) {
  if (!p.portOpen || !isShippable(c)) return 0;
  final reserve = math.min(
    kTradeReserveCoverDays * ownDemandPerS(p, c) * kColonyDaySec,
    kTradeReserveCapShare * p.stockCap,
  );
  return math.max(0.0, p.stockOf(c) - reserve);
}

/// Units of [c] [p] wants to buy today: [1/kTradeRefillDays] of the gap
/// between its target cover ([kTargetCoverDays] of its own demand) and its
/// stock, but never more than its store has room for. Zero when its port
/// is shut.
double wantedUnits(TradePartner p, String c) {
  if (!p.portOpen || !isShippable(c)) return 0;
  final stock = p.stockOf(c);
  final target = kTargetCoverDays * ownDemandPerS(p, c) * kColonyDaySec;
  final gap = math.max(0.0, target - stock) / kTradeRefillDays;
  return math.min(gap, math.max(0.0, p.stockCap - stock));
}

// ---- the band ------------------------------------------------------------------

/// What the other colonies add to [self]'s trade band, per good: the
/// cheapest landed price of a partner that can sell ([ceiling]), and the
/// best netback from a partner that wants to buy ([floor]). Empty when
/// [self]'s port is shut. The cost solve takes both
/// (`local_prices.dart` `solveLocalMarket`'s `tradeCeiling` / `tradeFloor`).
({Map<String, double> ceiling, Map<String, double> floor}) tradeBandFor(
  TradePartner self,
  Iterable<TradePartner> partners,
  TransportCostModel transport,
) {
  final hi = SplayTreeMap<String, double>();
  final lo = SplayTreeMap<String, double>();
  if (!self.portOpen) return (ceiling: hi, floor: lo);
  for (final b in partners) {
    if (b.colonyId == self.colonyId || !b.portOpen) continue;
    final inT = interColonyFreightPerKg(transport, b.bodyId, self.bodyId);
    final outT = interColonyFreightPerKg(transport, self.bodyId, b.bodyId);
    for (final e in b.economy.colonyMarket.goods.entries) {
      final c = e.key;
      if (!isShippable(c)) continue;
      final kg = kgPerUnit(c);
      final p = e.value.price;
      if (!(p > 0) || !p.isFinite) continue;
      if (inT.isFinite && exportableUnits(b, c) > kTradeMinUnits) {
        final landed = p + inT * kg;
        final had = hi[c];
        if (had == null || landed < had) hi[c] = landed;
      }
      if (outT.isFinite && wantedUnits(b, c) > kTradeMinUnits) {
        final netback = p - outT * kg;
        final had = lo[c];
        if (netback > 0 && (had == null || netback > had)) lo[c] = netback;
      }
    }
  }
  return (ceiling: hi, floor: lo);
}

// ---- the daily clearing --------------------------------------------------------

/// One cargo leg cleared at an importer's close.
class TradeLeg {
  const TradeLeg({
    required this.good,
    required this.fromColony,
    required this.toColony,
    required this.units,
    required this.sourcePrice,
    required this.landedPrice,
    required this.destinationPrice,
  });

  final String good;
  final String fromColony;
  final String toColony;
  final double units;

  /// Credits per unit: at the source, landed here (source + freight), and
  /// the importer's own price it beat.
  final double sourcePrice;
  final double landedPrice;
  final double destinationPrice;

  @override
  String toString() =>
      'TradeLeg($good $fromColony→$toColony '
      '${units.toStringAsFixed(2)} @ ${sourcePrice.toStringAsFixed(2)} '
      '→ ${landedPrice.toStringAsFixed(2)} vs '
      '${destinationPrice.toStringAsFixed(2)})';
}

/// Clears one day of [importer]'s imports from [partners]: for every good
/// it trades (key order) and wants ([wantedUnits]), buys from the partner
/// whose landed price is cheapest (ties by colony id) while that beats
/// both its own price and Earth's landed price ([earthLanded], per unit;
/// absent = Earth has no source), until the want, the partner's surplus
/// ([exportableUnits]) or either port's remaining launch capacity runs out.
///
/// Each leg moves the stock and books it on both sides' day: the importer's
/// supply and [ColonyTrade.inUnits], the exporter's demand and
/// [ColonyTrade.outUnits], and the cargo mass on both ports
/// ([ColonyTrade.portKgToday]). Returns the legs, in the order cleared.
List<TradeLeg> runImports(
  TradePartner importer,
  Iterable<TradePartner> partners,
  TransportCostModel transport, {
  Map<String, double> earthLanded = const {},
}) {
  final legs = <TradeLeg>[];
  if (!importer.portOpen) return legs;
  final mine = importer.economy;
  final sources = [
    for (final b in partners)
      if (b.colonyId != importer.colonyId && b.portOpen) b,
  ]..sort((a, b) => a.colonyId.compareTo(b.colonyId));
  if (sources.isEmpty) return legs;
  double room(TradePartner p) =>
      math.max(0.0, p.launchCapacityKgPerDay - p.economy.trade.portKgToday);

  for (final e in mine.colonyMarket.goods.entries.toList()) {
    final c = e.key;
    if (!isShippable(c)) continue;
    final kg = kgPerUnit(c);
    var want = wantedUnits(importer, c);
    if (!(want > kTradeMinUnits)) continue;
    final own = e.value.price;
    final earth = earthLanded[c] ?? double.infinity;
    final offers = <(double, TradePartner)>[];
    for (final b in sources) {
      final m = b.economy.colonyMarket.goods[c];
      if (m == null || !(m.price > 0) || !m.price.isFinite) continue;
      final t = interColonyFreightPerKg(transport, b.bodyId, importer.bodyId);
      if (!t.isFinite) continue;
      final landed = m.price + t * kg;
      if (landed < own && landed <= earth) offers.add((landed, b));
    }
    offers.sort((x, y) {
      final byPrice = x.$1.compareTo(y.$1);
      return byPrice != 0 ? byPrice : x.$2.colonyId.compareTo(y.$2.colonyId);
    });
    for (final (landed, b) in offers) {
      if (!(want > kTradeMinUnits)) break;
      final cap = math.min(room(importer), room(b)) / kg;
      final u = math.min(want, math.min(exportableUnits(b, c), cap));
      if (!(u > kTradeMinUnits)) continue;
      final source = b.economy.colonyMarket.goods[c]!.price;
      b.addStock(c, -u);
      importer.addStock(c, u);
      // An export is a sale: the exporter's demand. An import landed is
      // the importer's supply. One unit-second each: the units are the
      // day's, whatever its length (`ColonyEconomy.addFlow`).
      b.economy
        ..addFlow(c, -u, 1)
        ..trade.addOut(c, u, u * kg);
      mine
        ..addFlow(c, u, 1)
        ..trade.addIn(c, u, u * kg);
      want -= u;
      legs.add(
        TradeLeg(
          good: c,
          fromColony: b.colonyId,
          toColony: importer.colonyId,
          units: u,
          sourcePrice: source,
          landedPrice: landed,
          destinationPrice: own,
        ),
      );
    }
  }
  return legs;
}

// ---- per-colony state ----------------------------------------------------------

/// One colony's trade with the others: the day's cargo, the smoothed export
/// flow its reserve is measured without, the running totals, and the last
/// close's legs. Held by [ColonyEconomy.trade]; saved by `CitySim` under its
/// own key ('trade'), omitted while the colony has never traded.
class ColonyTrade {
  /// Cargo through this colony's ports today, kg, in and out: what is left
  /// of [TradePartner.launchCapacityKgPerDay].
  double portKgToday = 0;

  /// Units landed from, and shipped to, other colonies this day so far.
  /// [inUnits] is part of the day's supply but not Earth's demand (it was
  /// not bought from Earth) and never the colony's to re-export.
  final SplayTreeMap<String, double> inUnits = SplayTreeMap();
  final SplayTreeMap<String, double> outUnits = SplayTreeMap();

  /// Shipments to other colonies, smoothed like the market's flows
  /// ([kFlowSmoothingDays]), units/s ([ownDemandPerS]).
  final SplayTreeMap<String, double> exportPerS = SplayTreeMap();

  /// Every unit ever landed from / shipped to other colonies, by good.
  final SplayTreeMap<String, double> totalIn = SplayTreeMap();
  final SplayTreeMap<String, double> totalOut = SplayTreeMap();

  /// The legs this colony bought at its last close (runtime: the UI's
  /// "where this came from", and tests).
  final List<TradeLeg> lastImports = [];

  /// The world day this colony last announced inventions up to (runtime;
  /// null after a load, when the next close takes the world's day as seen).
  int? worldDaySeen;

  bool get isEmpty =>
      portKgToday == 0 &&
      inUnits.isEmpty &&
      outUnits.isEmpty &&
      exportPerS.isEmpty &&
      totalIn.isEmpty &&
      totalOut.isEmpty;

  void addIn(String c, double units, double kg) {
    inUnits[c] = (inUnits[c] ?? 0) + units;
    totalIn[c] = (totalIn[c] ?? 0) + units;
    portKgToday += kg;
  }

  void addOut(String c, double units, double kg) {
    outUnits[c] = (outUnits[c] ?? 0) + units;
    totalOut[c] = (totalOut[c] ?? 0) + units;
    portKgToday += kg;
  }

  /// Ends this colony's trade day of [daySec] colony seconds: the day's
  /// shipments fold into [exportPerS], and the port's capacity and the
  /// day's tallies start over.
  void closeDay(double daySec) {
    final w = flowSmoothingWeight;
    final goods = SplayTreeSet<String>()
      ..addAll(exportPerS.keys)
      ..addAll(outUnits.keys);
    for (final c in goods) {
      final today = daySec > 0 ? (outUnits[c] ?? 0) / daySec : 0.0;
      final next = (exportPerS[c] ?? 0) + (today - (exportPerS[c] ?? 0)) * w;
      // A flow that has decayed to nothing leaves the save.
      if (next > kFlowEps) {
        exportPerS[c] = next;
      } else {
        exportPerS.remove(c);
      }
    }
    portKgToday = 0;
    inUnits.clear();
    outUnits.clear();
  }

  Map<String, Object?>? toJsonOrNull() => isEmpty
      ? null
      : {
          if (portKgToday != 0) 'kg': portKgToday,
          if (inUnits.isNotEmpty) 'in': {...inUnits},
          if (outUnits.isNotEmpty) 'out': {...outUnits},
          if (exportPerS.isNotEmpty) 'xps': {...exportPerS},
          if (totalIn.isNotEmpty) 'tin': {...totalIn},
          if (totalOut.isNotEmpty) 'tout': {...totalOut},
        };

  /// Restores [j]; null (an old save, or a colony that never traded) leaves
  /// it empty.
  void restore(Map<String, Object?>? j) {
    if (j == null) return;
    void into(SplayTreeMap<String, double> m, Object? o) {
      ((o as Map?) ?? const {}).forEach((k, v) {
        final x = (v as num?)?.toDouble() ?? 0;
        if (x.isFinite && x != 0) m[k as String] = x;
      });
    }

    portKgToday = (j['kg'] as num?)?.toDouble() ?? 0;
    into(inUnits, j['in']);
    into(outUnits, j['out']);
    into(exportPerS, j['xps']);
    into(totalIn, j['tin']);
    into(totalOut, j['tout']);
  }
}
