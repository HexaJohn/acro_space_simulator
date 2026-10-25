// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Entrepreneurs: AI firms that found plants of their own when a good's
/// local margin stays high (docs/plans/dynamic-markets.md phase 4; user
/// decision §7.3, 2026-10-14: "AI firms found plants when margins stay
/// high").
///
/// **Why.** Phases 1-3 made a colony's prices move by supply and demand, so
/// a colony short of steel pays well above what steel costs to make. Until
/// now only the player could answer that by building a mill. A market
/// economy answers it by itself: somebody sees the rent, raises the money
/// and builds. That is the half of "being first pays; being tenth pays
/// normally" the plan was missing: the rent attracts entry, entry adds
/// supply, the price falls back toward cost.
///
/// **The signal.** Once per colony day, after prices close, every good some
/// floor plant could make is scored by the margin a HYPOTHETICAL new plant
/// would earn ([prospectOf]): its template's flat rates at today's prices,
/// revenue only on what it could expect to sell ([expectedSellThrough]),
/// against today's tier wages, inputs, energy, freight, equipment wear and
/// capital recovery. A day's margin is noisy (a brownout, a cargo landing),
/// so it is smoothed ([kFoundingMarginWindowDays]) and a good builds up
/// PRESSURE only while the smoothed margin holds above
/// [kFoundingMarginThreshold]; one day under it and the count starts over.
/// A good whose pressure reaches [kFoundingPressureDays] is ripe.
///
/// **By economy** ([foundingRate]): capitalism and a free market found at
/// the full rate; socialism tolerates the odd private venture, at a third
/// of the rate (pressure builds three times slower and the cooldown is three
/// times longer); communism never.
///
/// The colony side (who may found, the gates, the site, the money) is
/// `city_entrepreneurs.dart`; this file is the pure state and arithmetic.
/// Deterministic: no RNG, every map a [SplayTreeMap], firms numbered from a
/// saved counter.
library;

import 'dart:collection';
import 'dart:math' as math;

import 'economy_clock.dart';
import 'economy_contracts.dart';

/// Smoothed margin (profit ÷ revenue) a hypothetical new plant must hold
/// for its good to build pressure: 40%. A mature, competitive market pays
/// the normal margin, a third over direct cost (`mature_cost.dart`
/// `kNormalMargin`), which is 25% of revenue; an Earth colony's Steel Mill
/// sits there (~27%). 40% is fifteen points of RENT over that, a price
/// about 1.25× the normal one: a margin worth raising money for, and well
/// clear of the normal plant so a colony trading at Earth's mature prices
/// never sees a stampede of mills.
const double kFoundingMarginThreshold = 0.40;

/// Time constant of the smoothed margin, colony days: a week. Long enough
/// that one brownout or one landed cargo doesn't reset a month of evidence;
/// short against [kFoundingPressureDays], so the count measures the price,
/// not the smoothing's memory.
const double kFoundingMarginWindowDays = 7;

/// Days the smoothed margin must hold above [kFoundingMarginThreshold]
/// before a firm founds: three weeks. Prices close half their gap to
/// equilibrium in about a month (plan §7.5), so a rent that survives three
/// weeks is a shortage, not a spike, and the player who wanted to build the
/// plant themselves has had most of a month to do it first.
const double kFoundingPressureDays = 21;

/// Colony seconds between foundings in one colony: a month. One plant a
/// month is what lets each founding's extra supply show in the price before
/// the next firm decides, the same reason the firm policy spaces its cuts a
/// week apart (`firm_policy.dart` `kFirmActionCooldownSec`): without it two
/// firms would read the same shortage and both build into one glut.
const double kFoundingCooldownSec = 30 * kColonyDaySec;

/// Socialism's founding rate against capitalism's: a third. Pressure builds
/// at this many days per day, and the cooldown is divided by it. Socialism
/// plans its industry; a private venture is tolerated, rarely.
const double kSocialistFoundingRate = 1 / 3;

/// Share of a plant's jobs the colony must have idle (people without a
/// job) before a firm founds it: half. A firm founds where it can hire;
/// the labour market (`labour_market.dart`) then bids for the rest. Without
/// a labour gate an Earth-price colony with a rent on rocket parts would
/// found a plant every month for ever and staff none of them.
const double kFoundingStaffShare = 0.5;

/// Share of a plant's input draw the colony must have spare (supply over
/// demand, plus stock spread over [kFoundingInputCoverDays]): half. A firm
/// builds a mill where there is ore to buy; at half it can start, and its
/// own demand raises the input's price, which is the market's answer to
/// the rest.
const double kFoundingInputShare = 0.5;

/// Days over which a colony's stock of an input counts as spare supply for
/// [kFoundingInputShare]: a month, the market's own target cover
/// (`markets.dart` cover*).
const double kFoundingInputCoverDays = 30;

/// Seed capital raised per credit of build cost: 1.25, the build cost plus a
/// quarter as WORKING CAPITAL, which the new firm's books start with as cash
/// (what its first investment or a lean month is paid from). The money is
/// raised off-world from investors, in shadow credits like every plant's
/// books (docs/plans/factory-floors.md Q8): it never touches the colony's
/// `funds`.
const double kFoundingSeedCapitalMultiple = 1.25;

/// The colony must hold at least this many times a plant's build cost in
/// ore before a firm buys its ore locally: twice. The firm then takes at
/// most half the store and the player keeps the rest; below that the firm
/// imports all of it (if trade is open), so a founding never leaves the
/// player unable to build.
const double kFoundingLocalOreMultiple = 2;

/// Road cursors a founding tries per attempt, each through the build ghost's
/// own snap (`CitySim.snapSiteCentre`, up to 24 site checks each): sixteen,
/// enough to walk a starter town's streets, bounded so a crowded city
/// doesn't spend a frame on it once a day.
const int kFoundingMaxCursors = 16;

/// Spacing of the road cursors, metres: 150, about one plant frontage, so
/// consecutive cursors don't snap to the same site.
const double kFoundingCursorStepM = 150;

/// How fast foundings happen under [e], against capitalism's: 1 for a
/// market economy, [kSocialistFoundingRate] for socialism, 0 (never) for
/// communism.
double foundingRate(EconomyKind e) => switch (e) {
      EconomyKind.capitalism || EconomyKind.freeMarket => 1,
      EconomyKind.socialism => kSocialistFoundingRate,
      EconomyKind.communism => 0,
    };

/// The share of a new plant's output of a good it could expect to sell:
/// one when the good can be exported (the world buys what lands), else the
/// colony's smoothed demand over its supply WITH the new plant's [added]
/// output on top, the pro-rata share every seller then gets
/// (`markets.dart` `sellThroughOf`). Counting the entrant's own output is
/// what stops a firm founding into demand the existing plants already
/// meet.
double expectedSellThrough({
  required double demandPerS,
  required double supplyPerS,
  required double added,
  required bool exportable,
}) {
  if (exportable) return 1;
  final s = supplyPerS + added;
  if (!(s > 0)) return 1;
  return (demandPerS / s).clamp(0.0, 1.0).toDouble();
}

/// A hypothetical new plant's books per colony second ([prospectOf]).
class PlantProspect {
  const PlantProspect({required this.revenuePerS, required this.costPerS});

  /// What it would sell, at today's prices, per second.
  final double revenuePerS;

  /// Everything it would pay, capital recovery included, per second.
  final double costPerS;

  double get profitPerS => revenuePerS - costPerS;

  /// Profit ÷ revenue; −1 when it would sell nothing.
  double get margin => revenuePerS > 0 ? profitPerS / revenuePerS : -1;

  /// Price over cost, the notice's "N× its cost": revenue ÷ cost (the
  /// plant's joint products share its cost by value, so every good it makes
  /// reads the same ratio).
  double get priceOverCost =>
      costPerS > 0 ? revenuePerS / costPerS : double.infinity;
}

/// The books of a new plant making [outPerS] from [inPerS] with [jobs]
/// workers (split by tier as [labourShares]) and [powerKw], at [prices]:
/// output valued at [sellThrough] (per good; absent = 1), inputs paid whole,
/// every unit through the docks paying [freightPerUnit], its handlers'
/// [wearPerS], and its build cost recovered as [capitalPerS]. The same
/// lines a plant's own books charge (`plant_pnl.dart` `pnlFor`), so a firm
/// founds on the margin its books will then show. Goods are summed in
/// sorted order (deterministic float sums).
PlantProspect prospectOf({
  required Map<String, double> outPerS,
  required Map<String, double> inPerS,
  required double jobs,
  required double powerKw,
  required double Function(String good) price,
  required double Function(SkillTier tier) wage,
  required double powerPerKJ,
  Map<SkillTier, double> labourShares = const {},
  double fallbackWage = 0,
  Map<String, double> sellThrough = const {},
  double freightPerUnit = 0,
  double wearPerS = 0,
  double capitalPerS = 0,
}) {
  var revenue = 0.0, inputs = 0.0, units = 0.0;
  for (final c in (outPerS.keys.toList()..sort())) {
    revenue += outPerS[c]! * price(c) * (sellThrough[c] ?? 1.0);
    units += outPerS[c]!;
  }
  for (final c in (inPerS.keys.toList()..sort())) {
    inputs += inPerS[c]! * price(c);
    units += inPerS[c]!;
  }
  var w = 0.0;
  if (labourShares.isEmpty) {
    w = fallbackWage;
  } else {
    for (final t in SkillTier.values) {
      w += (labourShares[t] ?? 0) * wage(t);
    }
  }
  final cost = inputs +
      jobs * w +
      powerKw * powerPerKJ +
      units * freightPerUnit +
      wearPerS +
      capitalPerS;
  return PlantProspect(revenuePerS: revenue, costPerS: cost);
}

/// One good's founding pressure.
class GoodPressure {
  GoodPressure({required this.margin, this.days = 0});

  /// The smoothed margin of the best new plant making it.
  double margin;

  /// Days that margin has held above [kFoundingMarginThreshold], weighted
  /// by [foundingRate].
  double days;

  Map<String, Object?> toJson() => {'m': margin, if (days != 0) 'd': days};

  static GoodPressure fromJson(Map<String, Object?> j) => GoodPressure(
        margin: (j['m'] as num?)?.toDouble() ?? 0,
        days: (j['d'] as num?)?.toDouble() ?? 0,
      );
}

/// What a founding did, for the colony's record and the UI.
class Founding {
  const Founding({
    required this.firm,
    required this.plantType,
    required this.good,
    required this.priceOverCost,
    required this.daySerial,
  });

  /// The new firm's id, which is also its name ("Aldine Corp").
  final String firm;
  final String plantType;

  /// The good whose margin drew it.
  final String good;

  /// Its price over cost on the day it founded.
  final double priceOverCost;

  /// The colony economy day it founded on (counted by [FoundingState]).
  final int daySerial;

  Map<String, Object?> toJson() => {
        'firm': firm,
        'type': plantType,
        'good': good,
        'x': priceOverCost,
        'day': daySerial,
      };

  static Founding fromJson(Map<String, Object?> j) => Founding(
        firm: j['firm'] as String,
        plantType: j['type'] as String,
        good: j['good'] as String,
        priceOverCost: (j['x'] as num?)?.toDouble() ?? 0,
        daySerial: (j['day'] as num?)?.toInt() ?? 0,
      );
}

/// Founders' names, in the order firms take them: invented surnames and
/// places, none a real company. A colony's thirteenth firm reuses the first
/// with a numeral ([founderName]).
const List<String> kFounderNames = [
  'Aldine',
  'Brightwater',
  'Corvane',
  'Dunmore',
  'Ellery',
  'Fenwick',
  'Garrow',
  'Halvane',
  'Ironvale',
  'Juniper',
  'Kestrel',
  'Larkspur',
];

/// The [n]th founded firm's name (1-based): "Aldine Corp", …, then
/// "Aldine Corp 2" on the second pass. Unique within a colony, and never
/// shaped like a default firm id (`firm-<site>-<n>`), so the two can't
/// collide.
String founderName(int n) {
  final i = (n - 1) % kFounderNames.length;
  final pass = (n - 1) ~/ kFounderNames.length + 1;
  return '${kFounderNames[i]} Corp${pass > 1 ? ' $pass' : ''}';
}

/// One colony's entrepreneur state: the cooldown, each good's pressure,
/// the firm counter and what has been founded. Saved by `CitySim` under its
/// own key ('founding'), like 'tech'; an old save has none and starts
/// fresh: no pressure, so nothing can found for [kFoundingPressureDays].
class FoundingState {
  /// Colony seconds until the next founding may happen.
  double cooldownS = 0;

  /// Economy days closed since the state began (the record's clock).
  int daySerial = 0;

  /// Firms founded so far: the next one is [founderName] of this + 1.
  int firms = 0;

  /// Each candidate good's pressure, by good.
  final SplayTreeMap<String, GoodPressure> pressure = SplayTreeMap();

  /// Every founding, oldest first.
  final List<Founding> history = [];

  bool get isFresh =>
      cooldownS == 0 &&
      daySerial == 0 &&
      firms == 0 &&
      pressure.isEmpty &&
      history.isEmpty;

  /// The weight of one smoothing step a day.
  static double get _alpha => 1 - math.exp(-1 / kFoundingMarginWindowDays);

  /// Folds one day's margins ([today], good → the best new plant's margin)
  /// into the pressure, at [rate] days per day ([foundingRate]). A good not
  /// in [today] (no plant may make it now) loses its pressure; a good whose
  /// smoothed margin falls under [kFoundingMarginThreshold] starts its
  /// count over.
  void recordDay(Map<String, double> today, double rate) {
    daySerial++;
    for (final g in pressure.keys.toList()) {
      if (!today.containsKey(g)) pressure.remove(g);
    }
    for (final g in (today.keys.toList()..sort())) {
      // Floored at −1 (a plant that sells nothing): a glutted good's margin
      // can read −40,000 when its revenue rounds to nothing, and smoothing
      // that would keep the good "unprofitable" for months after the glut
      // cleared. Capped at 1, which no plant with any cost exceeds.
      final m = today[g]!.clamp(-1.0, 1.0).toDouble();
      final p = pressure[g];
      if (p == null) {
        // First sight: seeded at the day's margin, no history.
        final fresh = GoodPressure(margin: m);
        pressure[g] = fresh;
        if (m >= kFoundingMarginThreshold) fresh.days = rate;
        continue;
      }
      p.margin += (m - p.margin) * _alpha;
      p.days = p.margin >= kFoundingMarginThreshold ? p.days + rate : 0;
    }
  }

  /// Goods whose pressure has reached [kFoundingPressureDays], best smoothed
  /// margin first (the name breaking a tie).
  List<String> get ripe {
    final out = [
      for (final e in pressure.entries)
        if (e.value.days >= kFoundingPressureDays) e.key,
    ];
    out.sort((a, b) {
      final c = pressure[b]!.margin.compareTo(pressure[a]!.margin);
      return c != 0 ? c : a.compareTo(b);
    });
    return out;
  }

  /// Takes the next firm's name.
  String nextFirm() => founderName(++firms);

  Map<String, Object?>? toJsonOrNull() => isFresh
      ? null
      : {
          if (cooldownS != 0) 'cool': cooldownS,
          'day': daySerial,
          'firms': firms,
          if (pressure.isNotEmpty)
            'p': {for (final e in pressure.entries) e.key: e.value.toJson()},
          if (history.isNotEmpty) 'h': [for (final f in history) f.toJson()],
        };

  /// Restores [toJsonOrNull]'s state; null (an old save) leaves it fresh.
  void restore(Map<String, Object?>? j) {
    if (j == null) return;
    cooldownS = (j['cool'] as num?)?.toDouble() ?? 0;
    daySerial = (j['day'] as num?)?.toInt() ?? 0;
    firms = (j['firms'] as num?)?.toInt() ?? 0;
    final p = j['p'];
    if (p is Map) {
      for (final k in (p.keys.cast<String>().toList()..sort())) {
        final v = p[k];
        if (v is Map) {
          pressure[k] = GoodPressure.fromJson(v.cast<String, Object?>());
        }
      }
    }
    for (final f in (j['h'] as List? ?? const [])) {
      if (f is Map) history.add(Founding.fromJson(f.cast<String, Object?>()));
    }
  }
}
