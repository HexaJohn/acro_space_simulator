// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A colony's labour market: workers of each skill tier against the jobs
/// posted for them, priced like any good (docs/plans/dynamic-markets.md
/// phase 3; user decision §7.4: "a full labour market now, not a fixed
/// premium").
///
/// **Supply.** The colony's labour force (its residents not away at war,
/// times the commute's efficiency) splits into tiers by its SKILL MIX
/// ([LabourMarket.mix]). The mix is state: it drifts toward a target set by
/// education ([educationMix]: the share of people the colony's schools
/// cover, `services['education']`, moves it from [kUnschooledMix] to
/// [kSchooledMix]) and by pay ([retrainTarget]: a tier whose wage stays
/// above its anchor draws people into it), with a time constant of
/// [kSkillMixDays]. So building schools, or paying engineers well for
/// long enough, really does make engineers, slowly.
///
/// **Demand.** Every job the colony posts, in its tier: each flat
/// building's jobs in its type's tier, each factory floor's jobs by its
/// labour profile (stations at their recipe's tier, handlers skilled,
/// technicians technical; `skill_tiers.dart`).
///
/// **Allocation ([allocateLabour]).** Each tick, top tier first, because a
/// worker can take any job BELOW his tier and none above it:
/// 1. flat buildings take their staff first (they are the colony's civic
///    and utility payroll, already rationed by `CitySim`'s life-support-
///    first throttles, which this leaves exactly as they were);
/// 2. factory floors bid for what is left, the HIGHEST BIDDER FIRST: a
///    private firm bids by its margin (a thriving firm outbids a struggling
///    one for the scarce engineer), a state plant at the fixed government
///    pay scale ([kStatePayScale]). Each takes a balanced crew, the share of
///    its posts it can fill in EVERY tier it needs (a plant missing half its
///    engineers runs at half, so it takes only half its handlers too, and
///    leaves the rest for the next bidder). A plant that can't fill its
///    posts runs understaffed: in a shortage the low payers starve first.
///
/// **Wages.** Each tier's wage is its ANCHOR (the cost of living × the
/// tier's skill multiple, `skill_tiers.dart`) times a ratio the market
/// moves once a colony day by the same tâtonnement as goods
/// (`markets.dart` [closeGoodDay]): demand is the posts, supply the workers
/// who filled them plus anyone idle who could have. A shortage raises the
/// tier's wage; half the gap closes in [kLabourHalfLifeDays], the month
/// the user set for goods (§7.5). The ratio is what is stored, not the
/// wage, so a dearer cost of living passes straight into every wage (wages
/// are indexed) while the SCARCITY premium moves at market speed. No wage
/// falls below the cost of living ([wageFloorRatio]): below subsistence
/// nobody works, whatever his tier.
///
/// Pure and deterministic: no RNG, tiers walked in enum order, employers in
/// bid then site-id order.
library;

import 'dart:collection';
import 'dart:math' as math;

import 'economy_contracts.dart';
import 'markets.dart';
import 'skill_tiers.dart';

// ---- tuning --------------------------------------------------------------------

/// Colony days for a tier's wage to close half the gap to a new equilibrium:
/// 30, the month the user set for most goods (§7.5), and the industrial
/// class's figure. Wages are renegotiated over weeks, not overnight.
const double kLabourHalfLifeDays = 30;

/// The labour market's tâtonnement parameters: [kLabourHalfLifeDays], and
/// unit elasticity split evenly (εd 0.5: a plant posts somewhat fewer jobs
/// when labour is dear, mostly by automating; εs 0.5: more people work, and
/// work longer, for more), the textbook labour-market magnitudes. So a tier
/// with posts for twice the people who can fill them settles at twice its
/// anchor wage (q^ε = 2, ε = 1). No world flow: labour is local.
const GoodClassParams kLabourParams = GoodClassParams(
  halfLifeDays: kLabourHalfLifeDays,
  demandElasticity: 0.5,
  supplyElasticity: 0.5,
  worldFlowKgPerS: 0,
);

/// The skill mix of a colony with no schooling at all: what its settlers
/// brought from Earth. Roughly Earth's own workforce by ILO skill level
/// (elementary and plant work ~40%, trades ~33%, technicians and associate
/// professionals ~15%, STEM professionals ~12%). Generous at the top on
/// purpose: a colony is settled by people a launch chose.
const Map<SkillTier, double> kUnschooledMix = {
  SkillTier.unskilled: 0.40,
  SkillTier.skilled: 0.33,
  SkillTier.technical: 0.15,
  SkillTier.engineering: 0.12,
};

/// The skill mix of a colony whose schools cover everyone: a fully educated
/// industrial society, a quarter engineers (the upper end of OECD tertiary
/// STEM attainment, for a society that exists to build rockets).
const Map<SkillTier, double> kSchooledMix = {
  SkillTier.unskilled: 0.20,
  SkillTier.skilled: 0.30,
  SkillTier.technical: 0.25,
  SkillTier.engineering: 0.25,
};

/// Time constant, colony days, of the skill mix's drift toward its target:
/// half a game-year. An evening course turns a handler into a technician in
/// months; a degree takes years; this is the blend a colony's lifetime can
/// show.
const double kSkillMixDays = 182.625;

/// How hard pay pulls people into a tier: the target share scales with the
/// wage ratio (above its anchor) to this power. 1: a tier paid double its
/// anchor for long enough draws double its educational share. Only a
/// PREMIUM pulls: a tier in surplus (its ratio below one) keeps its
/// educational share, since nobody unlearns a trade because it pays badly
/// for a season; he takes a lower job instead.
const double kRetrainElasticity = 1;

/// A state plant's bid for scarce labour: the government pay scale, the
/// market wage exactly (1). A private firm bids 1 + its margin, so a
/// thriving firm outbids the state for the last engineer and a losing one
/// is outbid by it.
const double kStatePayScale = 1;

/// Largest margin a private firm's bid counts: a firm earning more than
/// 100% on revenue bids no higher than one earning exactly that.
const double kMaxBidMargin = 1;

// ---- mixes --------------------------------------------------------------------

/// The skill mix education [coverage] (0..1: the share of the colony its
/// schools serve) aims for: [kUnschooledMix] to [kSchooledMix], linearly.
Map<SkillTier, double> educationMix(double coverage) {
  final c = coverage.isFinite ? coverage.clamp(0.0, 1.0).toDouble() : 0.0;
  return {
    for (final t in SkillTier.values)
      t: kUnschooledMix[t]! + (kSchooledMix[t]! - kUnschooledMix[t]!) * c,
  };
}

/// [base] tilted toward the tiers paid above their anchor
/// (ratio^[kRetrainElasticity] for ratio > 1), renormalised to sum to one.
Map<SkillTier, double> retrainTarget(
  Map<SkillTier, double> base,
  Map<SkillTier, double> ratio,
) {
  final raw = <SkillTier, double>{};
  var sum = 0.0;
  for (final t in SkillTier.values) {
    final q = math.max(1.0, ratio[t] ?? 1.0);
    final v = (base[t] ?? 0) * math.pow(q, kRetrainElasticity).toDouble();
    raw[t] = v;
    sum += v;
  }
  if (!(sum > 0)) return Map.of(base);
  return {for (final t in SkillTier.values) t: raw[t]! / sum};
}

/// The lowest ratio [tier]'s wage may fall to: the cost of living, which is
/// the unskilled anchor (1 / the tier's skill multiple).
double wageFloorRatio(SkillTier tier) => 1 / skillMultipleOf(tier);

/// A private firm's or state plant's bid for scarce labour (see
/// [kStatePayScale]).
double labourBid({required bool isState, required double margin}) {
  if (isState) return kStatePayScale;
  final m = margin.isFinite ? margin : 0.0;
  return 1 + m.clamp(-1.0, kMaxBidMargin).toDouble();
}

// ---- allocation ---------------------------------------------------------------

/// One factory floor competing for labour this tick.
class LabourEmployer {
  const LabourEmployer({
    required this.site,
    required this.jobs,
    required this.bid,
  });

  final String site;

  /// Posts by tier, workers (its profile × the jobs it runs today).
  final Map<SkillTier, double> jobs;

  /// [labourBid]: who is served first in a shortage.
  final double bid;
}

/// What one tick's allocation found.
class LabourAllocation {
  const LabourAllocation({
    required this.share,
    required this.posted,
    required this.available,
  });

  /// Each employer's staffing share: the share of its posts it filled in
  /// every tier it needs (1 when it filled them all).
  final Map<String, double> share;

  /// Jobs posted by tier (flat and floor), workers: the market's demand.
  final Map<SkillTier, double> posted;

  /// Workers by tier who worked a job of that tier, plus everyone left idle
  /// who could have (his tier or above): the market's supply.
  final Map<SkillTier, double> available;
}

/// Allocates [labourForce] workers split by [mix] (shares by tier): the
/// [flatJobs] (workers flat buildings take today, by tier, after the
/// colony's own throttles; [flatPosted] what they post) first, then each of
/// [employers] in bid order, a balanced crew each. See the library doc.
LabourAllocation allocateLabour({
  required double labourForce,
  required Map<SkillTier, double> mix,
  Map<SkillTier, double> flatJobs = const {},
  Map<SkillTier, double>? flatPosted,
  List<LabourEmployer> employers = const [],
}) {
  const tiers = SkillTier.values;
  final n = tiers.length;
  final force = labourForce.isFinite && labourForce > 0 ? labourForce : 0.0;
  final rem = [for (final t in tiers) force * (mix[t] ?? 0)];
  final filled = List<double>.filled(n, 0);
  final posted = List<double>.filled(n, 0);

  // Takes up to [need] workers for a tier-[i] job: its own tier first, then
  // the nearest tier above with anyone left. Returns how many it got.
  double take(int i, double need) {
    var got = 0.0;
    for (var u = i; u < n && need - got > 1e-12; u++) {
      final g = math.min(rem[u], need - got);
      if (g <= 0) continue;
      rem[u] -= g;
      got += g;
    }
    filled[i] += got;
    return got;
  }

  // 1. Flat buildings, top tier down (so a higher tier's own jobs are
  // served before its people fill lower ones).
  for (var i = n - 1; i >= 0; i--) {
    final t = tiers[i];
    final need = flatJobs[t] ?? 0;
    posted[i] += (flatPosted ?? flatJobs)[t] ?? 0;
    if (need > 0) take(i, need);
  }

  // 2. Floors in bid order: each the largest balanced share every tier can
  // still give it. With higher tiers able to fill lower jobs, a crew of
  // share s fits exactly when, for every tier t, s × (posts at t and above)
  // ≤ (workers left at t and above) — Hall's condition for nested skills.
  final ranked = [...employers]
    ..sort((a, b) {
      final c = b.bid.compareTo(a.bid);
      return c != 0 ? c : a.site.compareTo(b.site);
    });
  final share = SplayTreeMap<String, double>();
  for (final e in ranked) {
    var s = 1.0;
    var needAbove = 0.0, haveAbove = 0.0;
    var any = false;
    for (var i = n - 1; i >= 0; i--) {
      final need = e.jobs[tiers[i]] ?? 0;
      if (need > 0) {
        posted[i] += need;
        any = true;
      }
      needAbove += need > 0 ? need : 0;
      haveAbove += rem[i];
      if (needAbove > 0) s = math.min(s, haveAbove / needAbove);
    }
    if (!any) {
      share[e.site] = 1;
      continue;
    }
    s = s.clamp(0.0, 1.0).toDouble();
    for (var i = n - 1; i >= 0; i--) {
      final need = (e.jobs[tiers[i]] ?? 0) * s;
      if (need > 0) take(i, need);
    }
    share[e.site] = s;
  }

  // Supply as the market sees it: who worked each tier's jobs, plus anyone
  // idle at that tier or above.
  final available = <SkillTier, double>{};
  var idleAbove = 0.0;
  for (var i = n - 1; i >= 0; i--) {
    idleAbove += rem[i];
    available[tiers[i]] = filled[i] + idleAbove;
  }
  return LabourAllocation(
    share: share,
    posted: {for (var i = 0; i < n; i++) tiers[i]: posted[i]},
    available: {for (final t in tiers) t: available[t]!},
  );
}

// ---- state --------------------------------------------------------------------

/// One colony's labour market: each tier's wage ratio (with its smoothed
/// flows), the skill mix, and the day's running tallies. Held by
/// `ColonyEconomy.labour`; saved by `CitySim` under its own key, so a colony
/// with no plant keeps its wages too.
class LabourMarket {
  /// Each tier's wage as a [GoodMarket]: its price is the RATIO to the
  /// tier's anchor (anchor 1), its flows are posts and workers. Absent =
  /// never closed a day (ratio 1, the anchor).
  final SplayTreeMap<SkillTier, GoodMarket> wages = SplayTreeMap(
    (a, b) => a.index - b.index,
  );

  /// The labour force's share in each tier; empty until first used, then
  /// seeded at the education target.
  final SplayTreeMap<SkillTier, double> mix = SplayTreeMap(
    (a, b) => a.index - b.index,
  );

  /// Worker-seconds posted and available by tier over the day so far.
  final SplayTreeMap<SkillTier, double> postedWS = SplayTreeMap(
    (a, b) => a.index - b.index,
  );
  final SplayTreeMap<SkillTier, double> availableWS = SplayTreeMap(
    (a, b) => a.index - b.index,
  );

  /// Colony seconds the day's tallies cover.
  double daySeconds = 0;

  /// Nothing priced, nothing tallied: an old save's (or a new colony's)
  /// market, seeded on first use.
  bool get isFresh =>
      wages.isEmpty && mix.isEmpty && postedWS.isEmpty && daySeconds == 0;

  /// [tier]'s wage over its anchor (1 before the first close).
  double ratioOf(SkillTier tier) => wages[tier]?.price ?? 1;

  /// Every tier's ratio, in tier order (`MarketFacts.wageRatio`).
  Map<SkillTier, double> get ratios => {
    for (final t in SkillTier.values) t: ratioOf(t),
  };

  /// The skill mix to staff with today: the saved one, or (fresh) the
  /// target education [coverage] gives, which this then keeps.
  Map<SkillTier, double> mixFor(double coverage) {
    if (mix.isEmpty) mix.addAll(educationMix(coverage));
    return mix;
  }

  /// Adds one tick's allocation ([dt] colony seconds) to the day's tallies.
  void record(LabourAllocation a, double dt) {
    if (!(dt > 0)) return;
    for (final t in SkillTier.values) {
      postedWS[t] = (postedWS[t] ?? 0) + (a.posted[t] ?? 0) * dt;
      availableWS[t] = (availableWS[t] ?? 0) + (a.available[t] ?? 0) * dt;
    }
    daySeconds += dt;
  }

  /// Closes one labour day: each tier's wage ratio steps by the day's
  /// average posts against workers ([closeGoodDay] with [kLabourParams];
  /// no stock, anchor 1, so the cost ceiling caps a ratio at
  /// `kCostCeilingMultiple`), floored at the cost of living
  /// ([wageFloorRatio]); then the skill mix drifts one day toward
  /// [retrainTarget] of education [coverage]'s mix. A day with no tally
  /// (nothing ticked) steps nothing but the mix.
  void closeDay({required double coverage}) {
    final secs = daySeconds;
    if (secs > 0) {
      for (final t in SkillTier.values) {
        final d = (postedWS[t] ?? 0) / secs;
        final s = (availableWS[t] ?? 0) / secs;
        final day = GoodDay(demandPerS: d, supplyPerS: s, anchor: 1);
        final had = wages[t];
        final m = had ?? seedGood(1, day);
        if (had == null) {
          wages[t] = m;
        } else {
          closeGoodDay(m, day, kLabourParams);
        }
        final lo = wageFloorRatio(t);
        if (!(m.price >= lo)) m.price = lo;
      }
    }
    final current = mixFor(coverage);
    final target = retrainTarget(educationMix(coverage), ratios);
    final w = 1 - math.exp(-1 / kSkillMixDays);
    var sum = 0.0;
    for (final t in SkillTier.values) {
      final v = (current[t] ?? 0) + ((target[t] ?? 0) - (current[t] ?? 0)) * w;
      current[t] = v;
      sum += v;
    }
    if (sum > 0) {
      for (final t in SkillTier.values) {
        current[t] = current[t]! / sum;
      }
    }
    postedWS.clear();
    availableWS.clear();
    daySeconds = 0;
  }

  // ---- saving ----

  /// The market as saved; null while fresh (an old save's shape).
  Map<String, Object?>? toJsonOrNull() {
    if (isFresh) return null;
    Map<String, Object?> byTier(Map<SkillTier, double> m) => {
      for (final e in m.entries) e.key.name: e.value,
    };
    return {
      if (wages.isNotEmpty)
        'w': {for (final e in wages.entries) e.key.name: e.value.toJson()},
      if (mix.isNotEmpty) 'mix': byTier(mix),
      if (postedWS.isNotEmpty) 'pd': byTier(postedWS),
      if (availableWS.isNotEmpty) 'av': byTier(availableWS),
      if (daySeconds != 0) 'sec': daySeconds,
    };
  }

  /// Restores [j] into this fresh market; null (an old save) leaves it
  /// fresh, to be seeded at the anchor wages and the education mix.
  void restore(Map<String, Object?>? j) {
    if (j == null) return;
    Map<String, Object?> m(Object? o) =>
        ((o as Map?) ?? const {}).cast<String, Object?>();
    SkillTier? tier(String k) {
      for (final t in SkillTier.values) {
        if (t.name == k) return t;
      }
      return null; // a tier a later version dropped
    }

    void into(Map<SkillTier, double> to, Object? from) {
      m(from).forEach((k, v) {
        final t = tier(k);
        final d = (v as num?)?.toDouble();
        if (t != null && d != null && d.isFinite) to[t] = d;
      });
    }

    m(j['w']).forEach((k, v) {
      final t = tier(k);
      if (t == null || v is! Map) return;
      final g = GoodMarket.fromJson(v.cast<String, Object?>());
      if (g.price > 0 && g.price.isFinite) wages[t] = g;
    });
    into(mix, j['mix']);
    into(postedWS, j['pd']);
    into(availableWS, j['av']);
    daySeconds = (j['sec'] as num?)?.toDouble() ?? 0;
  }
}
