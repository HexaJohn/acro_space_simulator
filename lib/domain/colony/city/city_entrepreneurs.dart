// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Entrepreneurs, the `CitySim` side (docs/plans/dynamic-markets.md
/// phase 4): when a good's local margin stays high, an AI firm founds a
/// plant for it. The pure state and arithmetic are
/// `economy/entrepreneurs.dart`; the rules that read the colony live here,
/// the same split as `city_economy.dart` / `colony_economy.dart`.
///
/// Once per colony day, after prices close ([CityEconomy.closeEconomyDay]
/// calls [entrepreneursCloseDay]):
///
/// 1. **May anyone found?** ([foundingRefusal]) Not under communism, not
///    while the colony's [Law.industrialLicensing] is in force (the player's
///    switch: off by default, so foundings happen under capitalism and a
///    free market unless the player says no), and not in a colony that
///    isn't the player's to build in: one that is independent or occupied,
///    Defiant or in Standoff (nobody invests in a colony on strike), or
///    under a rejoining term that forbids demolition (a plot staked by a
///    stranger re-cuts the street lots around it, the same edit the term
///    exists to stop). A refused colony's pressure is dropped, so lifting a
///    ban starts the count afresh rather than founding the next morning.
/// 2. **Which goods are dear?** Every good a floor plant the colony may build
///    ([CitySim.unlocked]: population and invention; [placementRefusal])
///    makes is scored by the best such plant's margin
///    ([foundingProspect]); the pressure counts the days it stays high
///    (`FoundingState.recordDay`).
/// 3. **Found.** Once the cooldown is out, the ripest good whose plant
///    passes the hiring, power and input gates ([foundingGateRefusal]) and
///    finds a site ([foundingSite]) is founded ([foundPlant]). At most one
///    a cooldown.
///
/// **Exit.** A founded plant is an ordinary private floor plant with books
/// like any other, so phase 1-3's firm policy runs it: a losing one lays
/// off, idles, closes and is offered to the player to nationalise or sell
/// (`city_economy.dart`).
///
/// **The build ghost.** The sim does not know where the player's ghost is
/// hovering (that is UI state, `screens/`), so a founding cannot avoid it
/// directly. Instead it never builds over anything the player has zoned or
/// built, and takes at most one site a month.
/// TODO(ui): pass the ghost's pending site to the sim and skip foundings
/// while a placement is pending.
library;

import 'dart:math' as math;

import 'city_building_spec.dart';
import 'city_control.dart';
import 'city_economy.dart';
import 'city_factories.dart';
import 'city_loyalty.dart';
import 'city_sim.dart';
import 'city_site_rules.dart';
import 'city_war.dart';
import 'commodity.dart';
import 'economy/economy_clock.dart';
import 'economy/economy_contracts.dart';
import 'economy/entrepreneurs.dart';
import 'economy/firm_policy.dart';
import 'economy/local_prices.dart' show kCapitalRecoveryYears;
import 'economy/markets.dart' show kEarthMarketId;
import 'economy/plant_pnl.dart';
import 'economy/skill_tiers.dart';
import 'factory/factory_handling.dart';
import 'factory/factory_templates.dart';
import 'parcel.dart';

/// Each floor plant template's handlers' wear per working second (its
/// roster at [equipmentWearPerS]), built once: what a founded plant's books
/// will charge.
final Map<String, double> _templateWear = {
  for (final t in kFactoryPlantTypes)
    t: () {
      final bp = factoryTemplateFor(t);
      if (bp == null) return 0.0;
      var w = 0.0;
      for (final k in HandlerKind.values) {
        w += (bp.roster[k] ?? 0) * equipmentWearPerS(k);
      }
      return w;
    }(),
};

extension CityEntrepreneurs on CitySim {
  /// Why no firm may found a plant here now, or null when one may (see the
  /// library doc, step 1).
  String? get foundingRefusal {
    if (foundingRate(economyKind) <= 0) {
      return 'Communism allows no private enterprise.';
    }
    if (laws.contains(Law.industrialLicensing)) {
      return 'Industrial Licensing is in force.';
    }
    if (loyalty.allegiance != Allegiance.colonial) {
      return 'The colony is not the player\'s to build in.';
    }
    if (!playerControl.allowed) return playerControl.reason;
    final stage = loyalty.stage;
    if (stage == LoyaltyStage.defiant || stage == LoyaltyStage.standoff) {
      return 'Nobody invests in a colony that is ${stage.label}.';
    }
    final term = demolitionRefusal;
    if (term != null) return term;
    return null;
  }

  /// Whether the colony can trade with the world for a founding's ore and a
  /// good's exports: the same rule the market uses (`markets.dart`
  /// `tradeOpen`: a working port, or Earth itself).
  bool get _tradeOpen =>
      body.id.value == kEarthMarketId ||
      (hasSpaceport && !loyalty.portClosedToPlayer);

  /// The books a new [spec] plant (its template, at its spec's flat rates)
  /// would keep at today's prices; null before the first close or for a
  /// plant without a template. Revenue counts what it could expect to sell
  /// ([expectedSellThrough], its own output added to the colony's supply);
  /// costs are today's inputs, tier wages, power, freight, its template's
  /// equipment wear and its build cost's recovery over
  /// [kCapitalRecoveryYears] at the local ore price.
  PlantProspect? foundingProspect(CityBuildingSpec spec) {
    final book = colonyEconomy.market?.book;
    if (book == null || factoryTemplateFor(spec.type) == null) return null;
    final rates = flatRatesOf(spec);
    final exportOpen = _tradeOpen;
    final goods = colonyEconomy.colonyMarket.goods;
    final sell = <String, double>{
      for (final c in rates.outPerS.keys)
        c: expectedSellThrough(
          demandPerS: goods[c]?.demandPerS ?? 0,
          supplyPerS: goods[c]?.supplyPerS ?? 0,
          added: rates.outPerS[c]!,
          exportable: exportOpen && (book.exportFloor[c] ?? 0) > 0,
        ),
    };
    return prospectOf(
      outPerS: rates.outPerS,
      inPerS: rates.inPerS,
      jobs: rates.jobs,
      powerKw: rates.powerKw,
      price: book.price,
      wage: book.wageOf,
      powerPerKJ: book.powerPerKJ,
      labourShares: labourSharesOf(spec.type),
      fallbackWage: book.wagePerWorkerS,
      sellThrough: sell,
      freightPerUnit: kLogisticsFeePerUnit,
      wearPerS: _templateWear[spec.type] ?? 0,
      capitalPerS: spec.buildCost *
          book.price(Commodity.ore) /
          (kCapitalRecoveryYears * kGameYearSec),
    );
  }

  /// The floor plants a firm may found here: placeable plants with a
  /// template, unlocked by population and invention, in catalogue order.
  List<CityBuildingSpec> get _foundable => [
        for (final s in kUtilCatalog)
          if (kFactoryPlantTypeSet.contains(s.type) &&
              factoryTemplateFor(s.type) != null &&
              unlocked(s) &&
              placementRefusal(s) == null)
            s,
      ];

  /// Why a firm can't start [spec] here today, or null: it can't hire
  /// [kFoundingStaffShare] of its jobs from the idle, the grid has no room
  /// for its draw, or an input isn't to be had ([kFoundingInputShare]).
  String? foundingGateRefusal(CityBuildingSpec spec) {
    if (!infiniteRobotics) {
      final idle =
          math.max(0, population.floor() - troopersAway) - jobs;
      if (idle < spec.jobs * kFoundingStaffShare) {
        return 'Not enough idle workers for a ${spec.label}.';
      }
    }
    if (!infinitePower && powerOut - powerDraw < spec.powerDraw) {
      return 'No spare power for a ${spec.label}.';
    }
    final goods = colonyEconomy.colonyMarket.goods;
    for (final c in (spec.inputs.keys.toList()..sort())) {
      final m = goods[c];
      final spare = math.max(0.0, (m?.supplyPerS ?? 0) - (m?.demandPerS ?? 0)) +
          stockOf(c) / (kFoundingInputCoverDays * kColonyDaySec);
      if (spare < spec.inputs[c]! * kFoundingInputShare) {
        return 'Not enough ${Commodity.name(c)} for a ${spec.label}.';
      }
    }
    return null;
  }

  /// The day's founding pass (library doc). [daySec] is the closed day's
  /// length in colony seconds (the cooldown runs on it).
  void entrepreneursCloseDay(double daySec) {
    final f = colonyEconomy.founding;
    f.cooldownS = math.max(0.0, f.cooldownS - daySec);
    if (foundingRefusal != null) {
      f.pressure.clear();
      f.daySerial++;
      return;
    }
    final rate = foundingRate(economyKind);
    final specs = _foundable;
    // Each good's best new plant: the highest margin among the plants that
    // make it (catalogue order breaking a tie).
    final best = <String, (CityBuildingSpec, PlantProspect)>{};
    for (final s in specs) {
      final p = foundingProspect(s);
      if (p == null) continue;
      for (final g in s.outputs.keys) {
        final had = best[g];
        if (had == null || p.margin > had.$2.margin) best[g] = (s, p);
      }
    }
    f.recordDay({for (final e in best.entries) e.key: e.value.$2.margin}, rate);
    if (f.cooldownS > 0) return;
    for (final g in f.ripe) {
      final (spec, prospect) = best[g]!;
      if (foundingGateRefusal(spec) != null) continue;
      if (foundPlant(spec, g, prospect) != null) return;
    }
  }

  /// Runs [body] as if no designed blueprint were picked for [type]: a
  /// founding builds the TEMPLATE floor, whatever the player chose for
  /// their own plants, and the site predicate, the cost and the record must
  /// all see the same floor.
  T _withTemplate<T>(String type, T Function() body) {
    final pick = selectedFloorBlueprint.remove(type);
    try {
      return body();
    } finally {
      if (pick != null) selectedFloorBlueprint[type] = pick;
    }
  }

  /// Where a new [spec] plant can stand: the build ghost's own snap
  /// ([CitySim.snapSiteCentre]) from cursors along the colony's roads (by
  /// road id, then along each road every [kFoundingCursorStepM]; at most
  /// [kFoundingMaxCursors]), the first that passes
  /// [CitySim.siteBlockedReason] and covers no street lot anyone has zoned
  /// or built on (staking a plot re-cuts the lots under it: a firm that put
  /// its mill over a street of houses would have demolished them, the same
  /// rule the independent governor keeps). Null when none.
  Vec2? foundingSite(CityBuildingSpec spec) => _withTemplate(spec.type, () {
        final size = spec.siteMetres(cellM: CitySim.cellM);
        final hw = size.width / 2, hd = size.depth / 2;
        final taken = [
          for (final p in layout.autoParcels)
            if (p.use != ParcelUse.unzoned ||
                parcelBuildings.containsKey(p.id) ||
                grownParcels.containsKey(p.id))
              _boundsOf(p),
        ];
        final roads = [...layout.roads]..sort((a, b) => a.id.compareTo(b.id));
        var tried = 0;
        for (final r in roads) {
          for (final cursor in r.sample(stepM: kFoundingCursorStepM)) {
            if (tried++ >= kFoundingMaxCursors) return null;
            final c = snapSiteCentre(spec, cursor);
            if (c == null) continue;
            final covers = taken.any((b) =>
                b.$1 <= c.e + hw + 1 &&
                b.$2 >= c.e - hw - 1 &&
                b.$3 <= c.n + hd + 1 &&
                b.$4 >= c.n - hd - 1);
            if (covers) continue;
            if (siteBlockedReason(spec, c) == null) return c;
          }
        }
        return null;
      });

  /// [p]'s bounding box: (minE, maxE, minN, maxN).
  static (double, double, double, double) _boundsOf(Parcel p) {
    var minE = double.infinity, maxE = -double.infinity;
    var minN = double.infinity, maxN = -double.infinity;
    for (final v in p.polygon) {
      minE = math.min(minE, v.e);
      maxE = math.max(maxE, v.e);
      minN = math.min(minN, v.n);
      maxN = math.max(maxN, v.n);
    }
    return (minE, maxE, minN, maxN);
  }

  /// Founds a [spec] plant for [good] (its margin [prospect]); returns the
  /// new site id, or null when no site or no ore was to be had (nothing
  /// changes then).
  ///
  /// **The money.** The firm raises [kFoundingSeedCapitalMultiple] × the
  /// plant's build cost as seed capital from off-world investors, shadow
  /// credits like every plant's books: the colony's `funds` never pay. The
  /// build cost is spent on the spot; the rest is the new firm's opening
  /// cash.
  ///
  /// **The ore.** Ore is physical: the plant is built out of it. The firm
  /// buys it from colony stock, at the local ore price, only when the colony
  /// holds [kFoundingLocalOreMultiple] times what it needs (it never takes
  /// more than half the store). Otherwise it imports all of it at the ore's
  /// import ceiling (landed by its own freight, off the colony's market),
  /// which needs trade to be open; with neither, there is no founding.
  ///
  /// The plant is the template floor, owned by a NEW private firm named
  /// [founderName], and a notice says why it came.
  String? foundPlant(CityBuildingSpec spec, String good, PlantProspect prospect) {
    final book = colonyEconomy.market?.book;
    if (book == null) return null;
    final centre = foundingSite(spec);
    if (centre == null) return null;
    final ore = spec.buildCost;
    final local = stockOf(Commodity.ore) >= ore * kFoundingLocalOreMultiple;
    if (!local && !_tradeOpen) return null;
    final orePrice = local
        ? book.price(Commodity.ore)
        : (book.importCeiling[Commodity.ore] ?? book.price(Commodity.ore));
    final capex = ore * orePrice;
    // The player's own build-refusal line is UI state; a founding must not
    // leave its own refusal (or clear the player's) there.
    final blockedBefore = blocked;
    // Imported ore lands in the store and `claimSite` builds the plant out
    // of it: the store ends where it began.
    if (!local) stock[Commodity.ore] = stockOf(Commodity.ore) + ore;
    final parcel = _withTemplate(spec.type, () => claimSite(spec, centre));
    blocked = blockedBefore;
    if (parcel == null) {
      if (!local) stock[Commodity.ore] = stockOf(Commodity.ore) - ore;
      return null;
    }
    final site = parcel.id;
    final f = colonyEconomy.founding;
    final firm = f.nextFirm();
    final owner = Ownership.private(firm);
    factoryFloors.setOwner(site, owner);
    colonyEconomy.books[site] = FirmBook(
      owner: owner,
      cash: capex * kFoundingSeedCapitalMultiple - capex,
    );
    f.cooldownS = kFoundingCooldownSec / foundingRate(economyKind);
    // Every good the plant makes has its answer now.
    for (final g in spec.outputs.keys) {
      f.pressure.remove(g);
    }
    final ratio = prospect.priceOverCost;
    f.history.add(Founding(
      firm: firm,
      plantType: spec.type,
      good: good,
      priceOverCost: ratio,
      daySerial: f.daySerial,
    ));
    pushEconomyNotice('$firm founded a ${spec.label} — '
        '${Commodity.name(good).toLowerCase()} was selling at '
        '${ratio.toStringAsFixed(1)}× its cost.');
    return site;
  }

  /// The site a founded firm's plant stands on, or null when it is gone (a
  /// demolition) or the firm no longer runs it (nationalised, sold on).
  String? siteOfFirm(String firm) {
    for (final id in factoryFloors.siteIds) {
      if (factoryFloors[id]?.owner?.firmId == firm) return id;
    }
    return null;
  }
}
