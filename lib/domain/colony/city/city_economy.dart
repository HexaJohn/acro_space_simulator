// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A colony's plant economy: the `CitySim` side of docs/plans/factory-floors.md
/// §3 "Ownership and money" and §7 Q8-Q11 (phase 5, wave 3).
///
/// `CitySim` holds the state ([CitySim.colonyEconomy], a [ColonyEconomy])
/// and calls in from its tick, placement, rename/drop and save paths; the
/// rules live here, the same split as `city_factories.dart`.
///
/// What the user decided, and where it lands:
/// - **Shadow prices (Q8).** Once per colony day ([kColonyDaySec]) the
///   colony's [MarketFacts] are read off the sim ([marketFacts]) and the
///   local market is solved ([localMarket]). Each floor plant's ledger for
///   the day is priced into a [PlantPnL] and folded into its operator's
///   [FirmBook]. None of those credits are paid by anyone. The only money
///   that reaches `funds` is corporate tax in and the state's industry
///   deficit and subsidies out, through [kCreditsToFunds].
/// - **Ownership by economy.** A new plant is a private firm under capitalism
///   or a free market and state-owned under socialism or communism
///   ([defaultOwnerFor]); communism tolerates no private plant at all, so one
///   left over from an earlier economy is nationalised at the next day close.
///   [nationalise] / [privatise] are the site actions.
/// - **A failing firm (Q11)** lays off its cheapest handler, then idles half
///   its stations ([kIdleStationsThrottle]), then closes, and the closed
///   plant waits in [pendingFirmOffers] for [resolveFirmOffer]: nationalise
///   or sell to a new firm.
/// - **State plants (Q10)** never act; their daily loss is the industry
///   deficit Budget line.
/// - **Investment (Q9).** An edit to a built floor owes ore
///   (`CitySim.pendingFloorInvestment`, from `closeFloor`). When the edited
///   layout's measurement lands, [settleFloorInvestment] decides who pays:
///   see there.
library;

import 'dart:math' as math;

import '../../planetary/atmospheric_composition.dart';
import 'city_building_spec.dart';
import 'city_sim.dart';
import 'commodity.dart';
import 'economy/colony_economy.dart';
import 'economy/economy_clock.dart';
import 'economy/economy_contracts.dart';
import 'economy/firm_policy.dart';
import 'economy/local_prices.dart';
import 'economy/plant_pnl.dart';
import 'factory/factory_handling.dart';
import 'factory/factory_sim_api.dart';
import 'factory/floor_blueprint.dart';

/// Chemical formula keys [MarketFacts.atmosphere] uses for each gas
/// (`local_prices.dart` reads `'O2'`).
const Map<AtmosphereGas, String> kGasFormula = {
  AtmosphereGas.nitrogen: 'N2',
  AtmosphereGas.oxygen: 'O2',
  AtmosphereGas.carbonDioxide: 'CO2',
  AtmosphereGas.hydrogen: 'H2',
  AtmosphereGas.helium: 'He',
  AtmosphereGas.methane: 'CH4',
  AtmosphereGas.argon: 'Ar',
  AtmosphereGas.water: 'H2O',
};

/// Handler kinds a layoff lets go, cheapest first: a worker on foot before a
/// jack operator before a forklift driver before a crane operator. An AGV has
/// no operator, so laying one off would save no wages; it isn't on the list.
const List<HandlerKind> kLayoffOrder = [
  HandlerKind.onFoot,
  HandlerKind.palletJack,
  HandlerKind.forklift,
  HandlerKind.crane,
];

/// The most corporate tax one private plant pays the treasury, as a multiple
/// of the worker tax its nameplate jobs pay (§/s in a typical colony of this
/// economy: [kCapHappiness], the default tax rate).
///
/// [kCreditsToFunds] puts a Steel Mill's tax at about its workers' own, but
/// the high-value templates (Rocket Parts, Missile Plant) add Earth-priced
/// value per second that converts to a hundred or more §/s: hundreds of a
/// colony's whole worker tax from one building, after which taxes, laws and
/// road upkeep stop mattering. Four times its workers' tax keeps a plant
/// worth having for the budget (the mill sits near one) without letting any
/// one plant swamp it. The firm's books still carry its full tax: only the
/// treasury's take is bounded.
const double kCorporateTaxWorkerMultiple = 4;

/// The happiness the tax cap's reference colony has: the "typical" 60% the
/// [kCreditsToFunds] calibration uses.
const double kCapHappiness = 0.6;

/// Most messages [ColonyEconomy.notices] holds: the newest few are what a
/// HUD shows, and the list must not grow for a colony's whole life when no
/// host drains it.
const int kEconomyNoticeCap = 8;

extension CityEconomy on CitySim {
  /// The colony's [Economy] as the economy layer names it (the enums mirror
  /// each other by name).
  EconomyKind get economyKind => EconomyKind.values.byName(economy.name);

  // ---- prices -------------------------------------------------------------

  /// Everything a local price depends on, read off this colony
  /// (docs/plans/factory-floors.md §3): its body and economy, sunlight, the
  /// biome's yields, every power plant's real factor here, the derived sky,
  /// its people and stock, and what it drew and made over the last day.
  ///
  /// [demandPerS] / [supplyPerS] default to the day so far
  /// ([ColonyEconomy.demandUnits] over the day's seconds).
  MarketFacts marketFacts({
    Map<String, double>? demandPerS,
    Map<String, double>? supplyPerS,
  }) {
    final s = sky;
    final days = colonyEconomy.dayClockS;
    Map<String, double> perS(Map<String, double> units) => days > 0
        ? {for (final e in units.entries) e.key: e.value / days}
        : const {};
    return MarketFacts(
      bodyId: body.id.value,
      economy: economyKind,
      solarFactor: solarFactor,
      waterMult: biomeMult(Commodity.water),
      oreMult: biomeMult(Commodity.ore),
      foodMult: biomeMult(Commodity.food),
      atmosphere: {
        for (final e in (body.composition?.fractions.entries ??
            const <MapEntry<AtmosphereGas, double>>[]))
          kGasFormula[e.key]!: e.value,
      },
      surfacePressureKPa: s.pressureAtm * 101.325,
      airDensity: s.airDensity,
      o2Harvestable: o2Harvestable,
      powerFactors: {
        for (final spec in kUtilCatalog)
          if (spec.powerOutput > 0) spec.type: powerFactor(spec.type),
      },
      population: population.round(),
      stock: Map.of(stock),
      demandPerS: demandPerS ?? perS(colonyEconomy.demandUnits),
      supplyPerS: supplyPerS ?? perS(colonyEconomy.supplyUnits),
      canExport: hasSpaceport && !loyalty.portClosedToPlayer,
    );
  }

  /// The last day's solved market (the "why this price" detail), solving now
  /// when none has been yet (a fresh colony, a just-loaded save).
  LocalMarket get localMarket =>
      colonyEconomy.market ??= solveLocalMarket(marketFacts());

  /// The colony's local prices as of the last day close; null before the
  /// first one (a just-loaded save re-solves at its next day).
  PriceBook? get localPrices => colonyEconomy.market?.book;

  // ---- ownership ----------------------------------------------------------

  /// Closed plants waiting on the player (nationalise or sell).
  List<FirmOffer> get pendingFirmOffers => colonyEconomy.offers;

  /// [site]'s operator books (null before its first day close).
  FirmBook? firmBookOf(String site) => colonyEconomy.books[site];

  /// Who runs [site]'s plant (the economy's default if never set).
  Ownership ownerOf(String site) =>
      factoryFloors[site]?.owner ?? colonyEconomy.books[site]?.owner ??
      const Ownership.state();

  /// A fresh, never-reused private firm id for [site].
  String newFirmId(String site) => 'firm-$site-${colonyEconomy.firmSerial++}';

  /// The owner a new plant at [site] gets under this colony's economy:
  /// socialism and communism build state plants, capitalism and a free market
  /// private ones (docs/plans/factory-floors.md §3 "Owner per plant").
  Ownership defaultOwnerFor(String site) => switch (economyKind) {
        EconomyKind.communism || EconomyKind.socialism =>
          const Ownership.state(),
        EconomyKind.capitalism || EconomyKind.freeMarket =>
          Ownership.private(newFirmId(site)),
      };

  /// Gives [site]'s floor its economy-default owner when it has none
  /// (placement, an old save's back-filled plant).
  void ensureFloorOwner(String site) {
    final rec = factoryFloors[site];
    if (rec == null || rec.owner != null) return;
    factoryFloors.setOwner(site, defaultOwnerFor(site));
  }

  /// A new operator takes [site] over with fresh books, full throttle and
  /// the staff the last one laid off hired back: a closed plant reopened
  /// with a stripped roster would ship nothing and (as a state plant) charge
  /// its station wages as a standing deficit.
  void _setOwner(String site, Ownership owner) {
    factoryFloors.setOwner(site, owner);
    colonyEconomy.books[site] = FirmBook(owner: owner);
    colonyEconomy.throttle.remove(site);
    _rehire(site);
  }

  /// Puts [site]'s laid-off handlers back on its roster and has the runner
  /// re-measure the fuller floor. No-op when nobody was laid off.
  void _rehire(String site) {
    final gone = colonyEconomy.laidOff.remove(site);
    final rec = factoryFloors[site];
    if (gone == null || gone.isEmpty || rec == null) return;
    var operators = 0;
    for (final k in (gone.keys.toList()..sort((a, b) => a.index - b.index))) {
      final n = gone[k]!;
      rec.blueprint.roster[k] = (rec.blueprint.roster[k] ?? 0) + n;
      operators += n * kHandlerSpecs[k]!.operators;
    }
    // Their jobs are back today; the runner re-measures the output.
    final r = rec.rates;
    rec.rates = MeasuredRates(
      inPerS: r.inPerS,
      outPerS: r.outPerS,
      powerKw: r.powerKw,
      jobs: r.jobs + operators,
      seconds: r.seconds,
    );
    rec.dirty = true;
    rec.rev++;
  }

  /// Adds [why] to the HUD's notices, keeping only the newest
  /// [kEconomyNoticeCap].
  void pushEconomyNotice(String why) {
    final n = colonyEconomy.notices..add(why);
    if (n.length > kEconomyNoticeCap) {
      n.removeRange(0, n.length - kEconomyNoticeCap);
    }
  }

  /// Takes every notice queued for the HUD (each host shows them as toasts).
  List<String> drainEconomyNotices() {
    final n = colonyEconomy.notices;
    final out = List<String>.of(n);
    n.clear();
    return out;
  }

  /// Site action: the state takes [site]'s plant over, with fresh books. A
  /// closed plant's pending offer is resolved the same way. False when the
  /// site has no floor or is already a state plant.
  bool nationalise(String site) {
    if (colonyEconomy.offers.any((o) => o.site == site)) {
      return resolveFirmOffer(site, ClosureOption.nationalise);
    }
    if (factoryFloors[site] == null || ownerOf(site).isState) return false;
    _setOwner(site, const Ownership.state());
    return true;
  }

  /// Site action: a new private firm takes [site]'s state plant over. Not
  /// under communism, which has no buyers ([closureOptions]).
  bool privatise(String site) {
    if (economyKind == EconomyKind.communism) return false;
    if (factoryFloors[site] == null || !ownerOf(site).isState) return false;
    _setOwner(site, Ownership.private(newFirmId(site)));
    return true;
  }

  /// The player's answer to a closed plant's offer: [choice] must be one the
  /// offer made. The plant reopens at full throttle under its new owner with
  /// fresh books (nationalised: the state; sold: a new firm). False when no
  /// offer is pending for [site] or [choice] isn't on it.
  bool resolveFirmOffer(String site, ClosureOption choice) {
    final offers = colonyEconomy.offers;
    final i = offers.indexWhere((o) => o.site == site);
    if (i < 0 || !offers[i].options.contains(choice)) return false;
    offers.removeAt(i);
    _setOwner(
        site,
        choice == ClosureOption.nationalise
            ? const Ownership.state()
            : Ownership.private(newFirmId(site)));
    return true;
  }

  /// [site]'s production multiplier its operator set (1 = running).
  double floorThrottleOf(String site) => colonyEconomy.throttleOf(site);

  // ---- the daily close ------------------------------------------------------

  /// Advances the economy day by [dt] colony seconds; closes it when full.
  /// Called once per tick from `advance`, after production and before the
  /// treasury is paid, so a closing day's tax is paid from this tick on.
  void economyTick(double dt) {
    final e = colonyEconomy;
    e.dayClockS += dt;
    if (e.dayClockS >= kColonyDaySec) closeEconomyDay();
  }

  /// Closes the economy day now: solves prices from the day's flows, prices
  /// every floor plant's ledger into its books, lets each private firm act,
  /// and sets the next day's corporate-tax and industry-deficit rates.
  void closeEconomyDay() {
    final e = colonyEconomy;
    final market = solveLocalMarket(marketFacts());
    e.market = market;
    final book = market.book;
    final econ = economyKind;

    final day = e.dayClockS > 0 ? e.dayClockS : kColonyDaySec;
    // One nameplate job's worker tax, §/s, in a typical colony: the
    // per-plant tax cap's unit. A reference colony, not this one's mood of
    // the day: a cap that followed happiness would let one bad week (or a
    // tax holiday) zero every plant's tax.
    final workerTaxPerJob = kCapHappiness *
        CitySim.defaultTaxRate *
        CitySim.taxPerWorkerPerSec *
        economy.fundsMult;
    var taxFunds = 0.0;
    var deficit = 0.0;
    for (final site in factoryFloors.siteIds) {
      final rec = factoryFloors[site]!;
      var owner = rec.owner;
      if (owner == null) {
        ensureFloorOwner(site);
        owner = rec.owner!;
      }
      // Communism tolerates no private plant: one left from an earlier
      // economy is taken over, books and all, at the first day close.
      if (econ == EconomyKind.communism && !owner.isState) {
        _setOwner(site, const Ownership.state());
        e.offers.removeWhere((o) => o.site == site);
        owner = const Ownership.state();
      }
      final firm = e.books[site] ??= FirmBook(owner: owner);
      firm.owner = owner;
      final ledger = factoryFloors.takeLedger(site);
      // A closed plant trades nothing; whatever it ran up is not booked.
      if (firm.isClosed) continue;
      final pnl = pnlFor(ledger, book, owner: owner, economy: econ);
      e.lastPnl[site] = pnl;
      // A day the colony never let the plant work (no inputs, or every
      // crate refused at a full warehouse) books nothing (the floor stands
      // its staff down then) and is no evidence about the firm: folding it
      // in would only decay the rolling books toward zero.
      if (ledger.totalWorkerSeconds <= 0 &&
          ledger.shipped.isEmpty &&
          ledger.energyKJ <= 0) {
        continue;
      }
      firm.record(pnl);
      if (owner.isState) {
        deficit += math.max(0.0, -pnl.preTax);
      } else {
        // Paid over the next day at the rate the day ran up, bounded per
        // plant ([kCorporateTaxWorkerMultiple]).
        final jobs = siteSpec(site)?.jobs ?? rec.rates.jobs;
        final cap = jobs * workerTaxPerJob * kCorporateTaxWorkerMultiple;
        taxFunds += math.min(pnl.tax * kCreditsToFunds / day, cap);
      }
      // A firm back in health hires back whoever it let go.
      if (firm.health == FirmHealth.healthy && rec.live == null) {
        _rehire(site);
      }
      final action = firm.decide(
        canLayOff: rec.live == null && _layoffKind(rec.blueprint) != null,
        canIdle: e.throttleOf(site) > kIdleStationsThrottle,
      );
      _apply(site, action);
    }

    // Over the day's own length (not the plants' booked seconds, which a
    // plant placed mid-day has fewer of) so a day's tax is paid exactly
    // once.
    e.corporateTaxFundsPerS = taxFunds;
    e.industryDeficitFundsPerS = deficit * kCreditsToFunds / day;
    e.dayClockS = 0;
    e.demandUnits.clear();
    e.supplyUnits.clear();
  }

  /// The handler a layoff lets go: the cheapest kind with more than one on
  /// the roster. Never the LAST of a kind: every template's routes need each
  /// kind it hires (a template with its handlers emptied ships nothing but
  /// keeps its station jobs), so cutting the last one costs revenue faster
  /// than it saves wages, and each layoff would force the next.
  HandlerKind? _layoffKind(FloorBlueprint bp) {
    for (final k in kLayoffOrder) {
      if ((bp.roster[k] ?? 0) > 1 && kHandlerSpecs[k]!.operators > 0) return k;
    }
    return null;
  }

  void _apply(String site, FirmAction action) {
    final e = colonyEconomy;
    switch (action) {
      case FirmAction.layoff:
        final rec = factoryFloors[site]!;
        final k = _layoffKind(rec.blueprint);
        if (k == null) return;
        final left = rec.blueprint.roster[k]! - 1;
        if (left > 0) {
          rec.blueprint.roster[k] = left;
        } else {
          rec.blueprint.roster.remove(k);
        }
        // Remembered (and saved), so a new owner or the firm's recovery
        // hires them back ([_rehire]).
        final gone = e.laidOff.putIfAbsent(site, () => {});
        gone[k] = (gone[k] ?? 0) + 1;
        // The staff are gone today; the runner re-measures what the
        // thinner floor really makes (a stale result is dropped by rev).
        final r = rec.rates;
        rec.rates = MeasuredRates(
          inPerS: r.inPerS,
          outPerS: r.outPerS,
          powerKw: r.powerKw,
          jobs: math.max(0.0, r.jobs - kHandlerSpecs[k]!.operators),
          seconds: r.seconds,
        );
        rec.dirty = true;
        rec.rev++;
      case FirmAction.idleStations:
        e.throttle[site] = kIdleStationsThrottle;
      case FirmAction.close:
        e.throttle[site] = 0;
        e.offers.add(
            FirmOffer(site: site, options: closureOptions(economyKind)));
      case FirmAction.invest:
      case FirmAction.none:
        break;
    }
  }

  // ---- investment -------------------------------------------------------------

  /// Keeps [site]'s pre-edit layout until the edit's cost is settled; the
  /// FIRST stash stands across several edits (the ore owed accumulates from
  /// that layout too).
  void stashFloorEdit(String site, FloorEditStash stash) {
    colonyEconomy.stashed.putIfAbsent(site, () => stash);
  }

  /// Shadow profit per colony second, before tax, that a floor running at
  /// [rates] with [roster] would earn at [book]'s prices: the same lines as
  /// [pnlFor], with equipment wear charged for every handler on the roster.
  double ratesProfitPerS(
    MeasuredRates rates,
    PriceBook book, {
    Map<HandlerKind, int> roster = const {},
  }) {
    var revenue = 0.0, inputs = 0.0, units = 0.0;
    for (final c in (rates.outPerS.keys.toList()..sort())) {
      revenue += rates.outPerS[c]! * book.price(c);
      units += rates.outPerS[c]!;
    }
    for (final c in (rates.inPerS.keys.toList()..sort())) {
      inputs += rates.inPerS[c]! * book.price(c);
      units += rates.inPerS[c]!;
    }
    var wear = 0.0;
    for (final k in HandlerKind.values) {
      wear += (roster[k] ?? 0) * equipmentWearPerS(k);
    }
    return revenue -
        inputs -
        rates.jobs * book.wagePerWorkerS -
        rates.powerKw * book.powerPerKJ -
        units * kLogisticsFeePerUnit -
        wear;
  }

  /// Settles what editing [site]'s built floor costs, once the edited
  /// layout's rates are measured (`applyFloorMeasure` calls it; [oldRates]
  /// are the rates the record ran on before).
  ///
  /// Two things are paid, by different hands:
  /// - **The materials are ore, always, from colony stock** — the kit is
  ///   physically built out of it, whoever pays. Freed kit (a negative
  ///   amount owed) goes back into stock. Too little ore and nothing can be
  ///   built: the edit is reverted.
  /// - **The VALUE of that ore (capex in credits at the local ore price)** is
  ///   borne by the owner:
  ///   - a private firm pays it from its own (shadow) cash when the change
  ///     pays back within [kFirmPaybackYears] ([firmWillBuild]) — savings
  ///     = shadow profit per second at the new rates minus at the old, both
  ///     at today's prices — and it has the cash;
  ///   - otherwise the treasury pays it as an industrial SUBSIDY, real money
  ///     out of `funds` (× [kCreditsToFunds]);
  ///   - a state plant's capex is paid by the treasury the same way;
  ///   - when `funds` can't cover it, the floor goes back to its pre-edit
  ///     layout and rates and a notice says why.
  InvestmentSettlement settleFloorInvestment(
    String site,
    MeasuredRates oldRates,
  ) {
    final e = colonyEconomy;
    final stash = e.stashed.remove(site);
    final oreDue = pendingFloorInvestment.remove(site) ?? 0;
    final rec = factoryFloors[site];
    if (rec == null || oreDue.abs() < 1e-9) return InvestmentSettlement.none;
    if (oreDue < 0) {
      // Freed kit is salvage, at the bulldozer's rate: credited in full, a
      // strip-then-demolish cycle would print ore.
      stock[Commodity.ore] =
          stockOf(Commodity.ore) - oreDue * CitySim.refundFraction;
      return InvestmentSettlement.none;
    }
    final book = localMarket.book;
    final capex = oreDue * book.price(Commodity.ore);
    final owner = ownerOf(site);

    InvestmentSettlement revert(String why) {
      if (stash != null) {
        rec
          ..blueprint = stash.blueprint.copy()
          ..rates = stash.rates
          ..designed = stash.designed
          ..dirty = false;
        rec.rev++;
      }
      pushEconomyNotice(why);
      // Kept for the site panel after the toast is gone.
      e.lastRevert[site] = why;
      return InvestmentSettlement.reverted;
    }

    if (stockOf(Commodity.ore) < oreDue) {
      return revert('The floor edit needs ${oreDue.toStringAsFixed(0)} ore '
          'the colony does not have: the old layout stays.');
    }
    if (!owner.isState) {
      final firm = e.books[site] ??= FirmBook(owner: owner);
      final savings = ratesProfitPerS(rec.rates, book,
              roster: rec.blueprint.roster) -
          ratesProfitPerS(stash?.rates ?? oldRates, book,
              roster: stash?.blueprint.roster ?? rec.blueprint.roster);
      if (firm.cash >= capex &&
          firmWillBuild(capex: capex, savingsPerS: savings)) {
        firm.cash -= capex;
        stock[Commodity.ore] = stockOf(Commodity.ore) - oreDue;
        return InvestmentSettlement.firmPaid;
      }
    }
    final cost = capex * kCreditsToFunds;
    if (funds < cost) {
      return revert('The treasury cannot cover the '
          '§${cost.toStringAsFixed(0)} the floor edit costs: the old '
          'layout stays.');
    }
    funds -= cost;
    e.lastIndustrialSubsidy = cost;
    e.industrialSubsidyTotal += cost;
    stock[Commodity.ore] = stockOf(Commodity.ore) - oreDue;
    return owner.isState
        ? InvestmentSettlement.statePaid
        : InvestmentSettlement.subsidised;
  }
}
