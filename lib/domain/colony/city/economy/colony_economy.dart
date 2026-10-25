// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// One colony's economy state: the books of every plant operator, the
/// colony's local prices, and the only two money flows the shadow-price
/// model lets reach the treasury (docs/plans/factory-floors.md §3
/// "Ownership and money", §7 Q8-Q11).
///
/// `CitySim` holds one ([CitySim.colonyEconomy]); the rules that read the
/// colony and write this live in `city_economy.dart`, the same split as
/// `city_factories.dart` / `FactoryFloors`. This file stays pure: no
/// `CitySim`, no Flutter, no clock but the colony seconds it is handed.
///
/// **Shadow prices (user decision Q8).** Every plant keeps a P&L at the
/// colony's local prices, but those credits are book-keeping: no wage is
/// paid out of `funds`, no good is bought. Real money moves on exactly two
/// lines, both converted from credits by [kCreditsToFunds]:
/// - **corporate tax** on a private plant's profit flows IN;
/// - **industry deficit** (a state plant's loss, Q10) and one-off
///   **industrial subsidies** (a private firm's investment that would not
///   pay back in [kFirmPaybackYears], Q9) flow OUT.
///
/// **Daily.** Prices are solved and books closed once per colony day
/// ([kColonyDaySec]); the tax and deficit found for a day are paid evenly
/// over the next one ([corporateTaxFundsPerS], [industryDeficitFundsPerS]).
/// A daily cadence because a firm's behaviour is a monthly average anyway
/// (`kFirmWindowSec`) and a price solve is a few hundred iterations; a
/// colony-second cadence would buy nothing and cost every frame.
///
/// Deterministic: every map is a [SplayTreeMap] (saved and walked in key
/// order), the day clock is the sim's own integrated time, and firm ids are
/// numbered from a saved serial ([firmSerial]).
library;

import 'dart:collection';

import '../factory/factory_handling.dart';
import '../factory/factory_sim_api.dart';
import '../factory/floor_blueprint.dart';
import 'economy_contracts.dart';
import 'firm_policy.dart';
import 'learning.dart';
import 'local_prices.dart';
import 'markets.dart';

/// Funds (`CitySim.funds`, the treasury's §) per economy credit.
///
/// Credits are the economy's unit (≈ 2020s US dollars: Earth prices,
/// wages); funds are the city builder's treasury, which has always been
/// paid by WORKER TAX: `workforce × happiness × tax × taxPerWorkerPerSec ×
/// fundsMult`. The two only meet on the corporate-tax and deficit lines, so
/// this one constant sets how much a plant matters to the treasury, and it
/// is calibrated so a healthy plant's corporate tax is the SAME ORDER as the
/// worker tax its own staff pay — a factory then matters to the budget
/// about as much as the people it employs, never dwarfs it.
///
/// The arithmetic (Earth starter colony, capitalism, the Steel Mill's
/// template at its full flat rate, on Earth prices — an Earth colony trades
/// at them, `earth_market.dart` — and the derived Earth wage of 0.395
/// credits per worker-second, `local_prices.dart`):
/// - revenue 1.5 steel × 80 + 0.4 tubes × 120 = 168 credits/s;
/// - costs 2 ore × 40 = 80, wages 35 × 0.395 = 13.8, freight
///   3.9 units × 0.5 = 1.95, power ≈ 0 (Earth power is nearly free at the
///   derived price);
/// - pre-tax profit ≈ 72.2 credits/s; corporate tax at the capitalist 21%
///   ≈ 15.2 credits/s.
/// - The same 35 workers' worker tax: 35 × 0.6 (typical happiness) × 0.15
///   (the default tax) × 0.05 §/worker-s (`taxPerWorkerPerSec`) × 1.4
///   (capitalism's fundsMult) ≈ 0.22 §/s.
/// - 0.22 / 15.2 ≈ 0.0145, rounded to 0.015: the mill's corporate tax lands
///   at ≈ 0.23 §/s, about what its workers pay again.
/// `economy_funds_test.dart` re-derives both sides from a live colony and
/// pins them within a factor of two of each other.
///
/// The other templates on the same scale (Earth, capitalism, full rate):
/// Refinery ≈ 0.3 §/s, Rations Plant ≈ 0.02, Arms ≈ 1.4, Electronics ≈ 5.4,
/// Rocket Parts ≈ 120, Missile Plant ≈ 610. The last two are the spec
/// recipes' value added at Earth prices (43 kg of tube and boards into
/// 40 kg of $1,000/kg engine parts every colony second), not this constant.
/// Since dynamic markets those rents fall as the plant floods its market
/// (revenue counts only what sells, and Earth's price drops under its
/// exports); what reaches the treasury from any one plant also saturates
/// smoothly under a generous SAFETY ceiling, a multiple of its own workers'
/// tax (`kCorporateTaxSafetyMultiple`, `city_economy.dart`), against a
/// runaway bug.
const double kCreditsToFunds = 0.015;

/// Production multiplier a firm sets when it idles stations (firm policy's
/// second cut): half the floor stands, half its staff stay home.
const double kIdleStationsThrottle = 0.5;

/// A closed plant's offer to the player: nationalise it or sell it.
class FirmOffer {
  const FirmOffer({required this.site, required this.options});

  final String site;
  final List<ClosureOption> options;

  Map<String, Object?> toJson() => {
        'site': site,
        'opts': [for (final o in options) o.name],
      };

  static FirmOffer fromJson(Map<String, Object?> j) => FirmOffer(
        site: j['site'] as String,
        options: [
          for (final o in (j['opts'] as List? ?? const []))
            ClosureOption.values.byName(o as String),
        ],
      );
}

/// A built floor's layout before an edit whose cost is not yet settled:
/// what the plant reverts to when nobody will pay for the edit.
class FloorEditStash {
  FloorEditStash({
    required this.blueprint,
    required this.rates,
    required this.designed,
  });

  final FloorBlueprint blueprint;
  final MeasuredRates rates;
  final bool designed;

  Map<String, Object?> toJson() => {
        'bp': blueprint.toJson(),
        'rates': rates.toJson(),
        if (designed) 'designed': true,
      };

  static FloorEditStash fromJson(Map<String, Object?> j) => FloorEditStash(
        blueprint:
            FloorBlueprint.fromJson((j['bp'] as Map).cast<String, Object?>()),
        rates:
            MeasuredRates.fromJson((j['rates'] as Map).cast<String, Object?>()),
        designed: j['designed'] == true,
      );
}

/// How an edited floor's cost was settled ([CityEconomy] in
/// `city_economy.dart`).
enum InvestmentSettlement {
  /// Nothing to settle (no capex owed, or the floor was never edited).
  none,

  /// A private firm paid from its own cash: it pays back in time.
  firmPaid,

  /// A private firm wouldn't (or couldn't) — the treasury subsidised it.
  subsidised,

  /// A state plant: the treasury paid.
  statePaid,

  /// Nobody could pay: the floor went back to its pre-edit layout.
  reverted,
}

class ColonyEconomy {
  /// Each floor plant's operator books, by site id.
  final SplayTreeMap<String, FirmBook> books = SplayTreeMap();

  /// Production multiplier a firm has set on its plant (idle stations,
  /// closed), by site; absent = 1.
  final SplayTreeMap<String, double> throttle = SplayTreeMap();

  /// Closed plants waiting on the player's choice, in the order they closed.
  final List<FirmOffer> offers = [];

  /// Pre-edit layouts of edited floors whose capex isn't settled yet.
  final SplayTreeMap<String, FloorEditStash> stashed = SplayTreeMap();

  /// Handlers each plant's firm has laid off, by site and kind. Saved: a
  /// new owner, or the firm once it is healthy again, hires them back, so a
  /// plant that reopens doesn't run for ever on the roster its failing
  /// operator stripped.
  final SplayTreeMap<String, Map<HandlerKind, int>> laidOff = SplayTreeMap();

  /// Why each site's last floor edit was undone (nobody could pay for it):
  /// the site panel's line once the toast is gone. Runtime only.
  final SplayTreeMap<String, String> lastRevert = SplayTreeMap();

  /// Colony seconds into the current economy day.
  double dayClockS = 0;

  /// Next firm number (firm ids are `firm-<site>-<n>`).
  int firmSerial = 1;

  /// Units of each commodity the colony drew and made this day so far (the
  /// scarcity signal's demand and supply).
  final SplayTreeMap<String, double> demandUnits = SplayTreeMap();
  final SplayTreeMap<String, double> supplyUnits = SplayTreeMap();

  /// Units of each commodity landed by booked freight this day so far: part
  /// of [supplyUnits], and what the colony bought from Earth (Earth's
  /// demand; never the colony's to re-export).
  final SplayTreeMap<String, double> importUnits = SplayTreeMap();

  /// Units of each commodity the colony's own plants MADE this day so far
  /// (flat recipes and factory floors; never freight, a spaceport's landings
  /// or a terraformer's sky): the day's addition to its learning-curve
  /// experience ([TechState.localQ]).
  final SplayTreeMap<String, double> madeUnits = SplayTreeMap();

  /// What the colony knows how to make, and the world's learning and
  /// invention timeline as this colony carries it (docs/plans/
  /// dynamic-markets.md phase 2, `learning.dart`). Saved by `CitySim` under
  /// its own key ('tech'), not here: a colony with no plant saves no plant
  /// economy, but its world clock must survive a load. Reassignable so a
  /// test can give a colony a synthetic catalog.
  TechState tech = TechState();

  /// The colony's own market: every traded good's price, stock and smoothed
  /// flows (docs/plans/dynamic-markets.md phase 1). Empty until the first
  /// day close seeds it from today's solve; saved with the rest.
  Market colonyMarket = Market();

  /// Earth's world market as this colony sees it: seeded once from
  /// `kEarthPricePerKg`, then moved by world supply and demand plus this
  /// colony's own trade with it. Each colony carries its own copy until
  /// phase 5's inter-colony trade gives the world market a single owner.
  Market earthMarket = Market();

  /// Per good, the share of supply that sold at the last close
  /// (`markets.dart` `sellThroughOf`): what revenue counts. Saved, so an
  /// investment settled between a load and the next close values output
  /// exactly as the unsaved colony would.
  final SplayTreeMap<String, double> sellThrough = SplayTreeMap();

  /// Funds per second paid in / out over the current day: the last day's
  /// corporate tax and state-plant deficit, converted by [kCreditsToFunds].
  double corporateTaxFundsPerS = 0;
  double industryDeficitFundsPerS = 0;

  /// One-off industrial spending, funds: the last subsidy or state
  /// investment, and the running total (the Budget drawer's line).
  double lastIndustrialSubsidy = 0;
  double industrialSubsidyTotal = 0;

  /// Messages for the HUD to drain (an edit reverted for want of money).
  /// Runtime only, like `CitySim.milestoneToasts`.
  final List<String> notices = [];

  /// The last day's solve (runtime; re-solved on demand after a load).
  LocalMarket? market;

  /// The last day's P&L by site (runtime: what the site panel shows).
  final SplayTreeMap<String, PlantPnL> lastPnl = SplayTreeMap();

  /// Throttle of [site]'s plant, 0..1.
  double throttleOf(String site) => throttle[site] ?? 1;

  /// Adds a production flow (units/s, + made, − drawn) over [dt] seconds.
  void addFlow(String commodity, double perSec, double dt) {
    if (perSec > 0) {
      supplyUnits[commodity] = (supplyUnits[commodity] ?? 0) + perSec * dt;
    } else if (perSec < 0) {
      demandUnits[commodity] = (demandUnits[commodity] ?? 0) - perSec * dt;
    }
  }

  /// Adds an import flow (units/s landed by freight) over [dt] seconds. The
  /// caller records it as supply through [addFlow] too.
  void addImport(String commodity, double perSec, double dt) {
    if (perSec > 0) {
      importUnits[commodity] = (importUnits[commodity] ?? 0) + perSec * dt;
    }
  }

  /// Adds [perSec] units/s the colony's own plants made over [dt] seconds.
  void addMade(String commodity, double perSec, double dt) {
    if (perSec > 0) {
      madeUnits[commodity] = (madeUnits[commodity] ?? 0) + perSec * dt;
    }
  }

  /// Moves [oldId]'s state onto [newId] (a lot rename).
  void renameSite(String oldId, String newId) {
    if (oldId == newId) return;
    final b = books.remove(oldId);
    if (b != null) books[newId] = b;
    final t = throttle.remove(oldId);
    if (t != null) throttle[newId] = t;
    final s = stashed.remove(oldId);
    if (s != null) stashed[newId] = s;
    final l = laidOff.remove(oldId);
    if (l != null) laidOff[newId] = l;
    final why = lastRevert.remove(oldId);
    if (why != null) lastRevert[newId] = why;
    final p = lastPnl.remove(oldId);
    if (p != null) lastPnl[newId] = p;
    for (var i = 0; i < offers.length; i++) {
      if (offers[i].site == oldId) {
        offers[i] = FirmOffer(site: newId, options: offers[i].options);
      }
    }
  }

  /// Drops [site]'s state (the plant is gone).
  void dropSite(String site) {
    books.remove(site);
    throttle.remove(site);
    stashed.remove(site);
    laidOff.remove(site);
    lastRevert.remove(site);
    lastPnl.remove(site);
    offers.removeWhere((o) => o.site == site);
  }

  /// Whether anything here outlives the day: a colony that never had a plant
  /// has only a day clock and the day's flows, which a save can drop (its
  /// next day starts fresh and nothing reads them but the price solve).
  ///
  /// The markets alone don't count: a plantless colony saves as it did before
  /// the economy, and its markets re-seed from today's model on load (the
  /// old-save path). No plant's books depend on them, and a plant placed
  /// later starts the colony saving them with everything else.
  bool get hasState =>
      books.isNotEmpty ||
      throttle.isNotEmpty ||
      offers.isNotEmpty ||
      stashed.isNotEmpty ||
      laidOff.isNotEmpty ||
      firmSerial != 1 ||
      corporateTaxFundsPerS != 0 ||
      industryDeficitFundsPerS != 0 ||
      industrialSubsidyTotal != 0;

  Map<String, Object?> toJson() => {
        if (books.isNotEmpty)
          'books': {for (final e in books.entries) e.key: e.value.toJson()},
        if (throttle.isNotEmpty) 'thr': {...throttle},
        if (offers.isNotEmpty) 'offers': [for (final o in offers) o.toJson()],
        if (stashed.isNotEmpty)
          'stash': {for (final e in stashed.entries) e.key: e.value.toJson()},
        if (laidOff.isNotEmpty)
          'laid': {
            for (final e in laidOff.entries)
              e.key: {
                for (final k in HandlerKind.values)
                  if ((e.value[k] ?? 0) > 0) k.name: e.value[k],
              },
          },
        'day': dayClockS,
        'serial': firmSerial,
        if (demandUnits.isNotEmpty) 'dem': {...demandUnits},
        if (supplyUnits.isNotEmpty) 'sup': {...supplyUnits},
        if (importUnits.isNotEmpty) 'imp': {...importUnits},
        if (madeUnits.isNotEmpty) 'made': {...madeUnits},
        if (!colonyMarket.isEmpty) 'mkt': colonyMarket.toJson(),
        if (!earthMarket.isEmpty) 'earthMkt': earthMarket.toJson(),
        if (sellThrough.isNotEmpty) 'sell': {...sellThrough},
        'taxPs': corporateTaxFundsPerS,
        'defPs': industryDeficitFundsPerS,
        if (lastIndustrialSubsidy != 0) 'subLast': lastIndustrialSubsidy,
        if (industrialSubsidyTotal != 0) 'subTotal': industrialSubsidyTotal,
      };

  /// The learning state as `CitySim` saves it (its own 'tech' key), or null
  /// while it is fresh (an old save's shape). With [withEarth] — a colony
  /// whose plant economy isn't saved ([hasState] false and no floor) — it
  /// carries Earth's market too: its prices lag their falling anchors by a
  /// few percent (the advanced class's 40-day half-life against a curve
  /// sliding ~15% a year), and re-seeding them at the anchor on every load
  /// would make them jump.
  Map<String, Object?>? techJson({required bool withEarth}) {
    if (tech.isFresh) return null;
    return {
      ...tech.toJson(),
      if (withEarth && !earthMarket.isEmpty) 'earthMkt': earthMarket.toJson(),
    };
  }

  /// Restores [techJson]'s state; null (an old save) leaves it fresh. Earth's
  /// market comes from it only when the plant economy brought none.
  void restoreTech(Map<String, Object?>? j) {
    if (j == null) return;
    tech.restore(j);
    final earth = j['earthMkt'];
    if (earthMarket.isEmpty && earth is Map) {
      earthMarket = Market.fromJson(earth.cast<String, Object?>());
    }
  }

  /// Restores a saved state into this (empty) one; null leaves it fresh.
  void restore(Map<String, Object?>? j) {
    if (j == null) return;
    Map<String, Object?> m(Object? o) =>
        ((o as Map?) ?? const {}).cast<String, Object?>();
    double d(Object? o) => (o as num?)?.toDouble() ?? 0;
    m(j['books']).forEach((k, v) {
      books[k] = FirmBook.fromJson(m(v));
    });
    m(j['thr']).forEach((k, v) => throttle[k] = d(v));
    for (final o in (j['offers'] as List? ?? const [])) {
      offers.add(FirmOffer.fromJson(m(o)));
    }
    m(j['stash']).forEach((k, v) {
      stashed[k] = FloorEditStash.fromJson(m(v));
    });
    m(j['laid']).forEach((site, v) {
      laidOff[site] = {
        for (final e in m(v).entries)
          HandlerKind.values.byName(e.key): (e.value as num).toInt(),
      };
    });
    dayClockS = d(j['day']);
    firmSerial = (j['serial'] as num?)?.toInt() ?? 1;
    m(j['dem']).forEach((k, v) => demandUnits[k] = d(v));
    m(j['sup']).forEach((k, v) => supplyUnits[k] = d(v));
    m(j['imp']).forEach((k, v) => importUnits[k] = d(v));
    m(j['made']).forEach((k, v) => madeUnits[k] = d(v));
    // An old save has neither market: both stay empty and the next day
    // close seeds them from today's model.
    colonyMarket = Market.fromJson(m(j['mkt']));
    earthMarket = Market.fromJson(m(j['earthMkt']));
    m(j['sell']).forEach((k, v) => sellThrough[k] = d(v));
    corporateTaxFundsPerS = d(j['taxPs']);
    industryDeficitFundsPerS = d(j['defPs']);
    lastIndustrialSubsidy = d(j['subLast']);
    industrialSubsidyTotal = d(j['subTotal']);
  }
}
