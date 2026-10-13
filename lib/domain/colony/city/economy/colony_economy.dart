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

import '../factory/factory_sim_api.dart';
import '../factory/floor_blueprint.dart';
import 'economy_contracts.dart';
import 'firm_policy.dart';
import 'local_prices.dart';

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
/// 40 kg of $1,000/kg engine parts every colony second), not this constant:
/// left for the balance pass, flagged in the wave-3 report.
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

  /// Colony seconds into the current economy day.
  double dayClockS = 0;

  /// Next firm number (firm ids are `firm-<site>-<n>`).
  int firmSerial = 1;

  /// Units of each commodity the colony drew and made this day so far (the
  /// scarcity signal's demand and supply).
  final SplayTreeMap<String, double> demandUnits = SplayTreeMap();
  final SplayTreeMap<String, double> supplyUnits = SplayTreeMap();

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

  /// Moves [oldId]'s state onto [newId] (a lot rename).
  void renameSite(String oldId, String newId) {
    if (oldId == newId) return;
    final b = books.remove(oldId);
    if (b != null) books[newId] = b;
    final t = throttle.remove(oldId);
    if (t != null) throttle[newId] = t;
    final s = stashed.remove(oldId);
    if (s != null) stashed[newId] = s;
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
    lastPnl.remove(site);
    offers.removeWhere((o) => o.site == site);
  }

  /// Whether anything here outlives the day: a colony that never had a plant
  /// has only a day clock and the day's flows, which a save can drop (its
  /// next day starts fresh and nothing reads them but the price solve).
  bool get hasState =>
      books.isNotEmpty ||
      throttle.isNotEmpty ||
      offers.isNotEmpty ||
      stashed.isNotEmpty ||
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
        'day': dayClockS,
        'serial': firmSerial,
        if (demandUnits.isNotEmpty) 'dem': {...demandUnits},
        if (supplyUnits.isNotEmpty) 'sup': {...supplyUnits},
        'taxPs': corporateTaxFundsPerS,
        'defPs': industryDeficitFundsPerS,
        if (lastIndustrialSubsidy != 0) 'subLast': lastIndustrialSubsidy,
        if (industrialSubsidyTotal != 0) 'subTotal': industrialSubsidyTotal,
      };

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
    dayClockS = d(j['day']);
    firmSerial = (j['serial'] as num?)?.toInt() ?? 1;
    m(j['dem']).forEach((k, v) => demandUnits[k] = d(v));
    m(j['sup']).forEach((k, v) => supplyUnits[k] = d(v));
    corporateTaxFundsPerS = d(j['taxPs']);
    industryDeficitFundsPerS = d(j['defPs']);
    lastIndustrialSubsidy = d(j['subLast']);
    industrialSubsidyTotal = d(j['subTotal']);
  }
}
