// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The `CitySim` side of inter-colony trade and the shared world market
/// (docs/plans/dynamic-markets.md phase 5): a colony as a [TradePartner],
/// and the colony-reading steps the daily close calls
/// (`city_economy.dart`). The rules live in `economy/inter_colony_trade.dart`
/// and `economy/world_economy.dart`, the same split as `city_economy.dart` /
/// `economy/colony_economy.dart`.
library;

import 'city_building_spec.dart';
import 'city_sim.dart';
import 'commodity.dart';
import 'economy/colony_economy.dart';
import 'economy/commodity_mass.dart';
import 'economy/economy_contracts.dart';
import 'economy/inter_colony_trade.dart';
import 'economy/markets.dart';
import 'economy/world_economy.dart';

/// A [CitySim] as the trade and the world market see it.
class CityTradePartner implements TradePartner {
  CityTradePartner(this.sim);

  final CitySim sim;

  @override
  String get colonyId => sim.id;

  @override
  String get bodyId => sim.body.id.value;

  /// A working spaceport the player may use: exactly `MarketFacts.canExport`.
  @override
  bool get portOpen => sim.hasSpaceport && !sim.loyalty.portClosedToPlayer;

  /// Every working spaceport's share ([kPortLaunchKgPerDayPerFuelUnit] per
  /// unit of its propellant draw; a port spec without one counts as 1).
  /// Zero when the port is shut.
  @override
  double get launchCapacityKgPerDay {
    if (!portOpen) return 0;
    var units = 0.0;
    double draw(CityBuildingSpec s) {
      final f = s.inputs[Commodity.fuel] ?? 0.0;
      return f > 0 ? f : 1.0;
    }

    for (final e in sim.utils.entries) {
      if (e.value.type == 'spaceport' && sim.isConnected(e.key)) {
        units += draw(e.value);
      }
    }
    if (sim.layout.parcels.isNotEmpty) {
      final net = sim.parcelNetwork();
      for (final (parcel, spec) in sim.parcelBuiltLots()) {
        if (spec.type == 'spaceport' && net.lotServed(parcel.id)) {
          units += draw(spec);
        }
      }
    }
    return units * kPortLaunchKgPerDayPerFuelUnit;
  }

  @override
  ColonyEconomy get economy => sim.colonyEconomy;

  @override
  double stockOf(String commodity) => sim.stockOf(commodity);

  @override
  double get stockCap => sim.stockCap;

  @override
  void addStock(String commodity, double units) {
    final next = sim.stockOf(commodity) + units;
    sim.stock[commodity] = next > 0 ? next : 0.0;
  }
}

extension CityTrade on CitySim {
  /// This colony as a trade partner.
  TradePartner get tradePartner => CityTradePartner(this);

  /// The world market this colony trades in.
  WorldEconomy get worldEconomy => colonyEconomy.world;

  /// Joins [world] (the host that holds every colony calls this as it takes
  /// the colony in).
  void joinWorld(WorldEconomy world) => world.join(CityTradePartner(this));

  /// The other player colonies of this colony's world, in id order.
  List<TradePartner> get tradePartners => worldEconomy.partnersOf(id);

  /// What the other colonies add to this colony's trade band today
  /// ([tradeBandFor]), freight by [transport].
  ({Map<String, double> ceiling, Map<String, double> floor}) colonyTradeBand(
    TransportCostModel transport,
  ) => tradeBandFor(tradePartner, tradePartners, transport);

  /// The day's imports from the other colonies ([runImports]), against
  /// Earth's landed price here: Earth's live price plus freight, for every
  /// good Earth makes. Called first thing by the daily close, so the cargo
  /// is part of the day it closes. The legs are kept in
  /// [ColonyTrade.lastImports].
  List<TradeLeg> runColonyImports(TransportCostModel transport) {
    final e = colonyEconomy;
    final partners = tradePartners;
    e.trade.lastImports.clear();
    if (partners.isEmpty) return const [];
    final here = body.id.value;
    final noEarth = e.tech.missingOnEarth;
    final earthLanded = <String, double>{};
    final earthT = transport.perKg(kEarthMarketId, here);
    for (final g in e.earthMarket.goods.entries) {
      if (noEarth.contains(g.key) || !earthT.isFinite) continue;
      earthLanded[g.key] = g.value.price + earthT * kgPerUnit(g.key);
    }
    final legs = runImports(
      tradePartner,
      partners,
      transport,
      earthLanded: earthLanded,
    );
    e.trade.lastImports.addAll(legs);
    return legs;
  }
}
