// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Winning an independent colony back (docs/plans/colony-secession.md §6.1,
/// §6.2): the terms it states, the binding terms it rejoins under, the
/// reputation the player's other colonies earn, and the petitions that
/// reputation — or hunger — brings.
///
/// Like `city_loyalty.dart`, the model is split in two. [CityReclaim] is the
/// state and the rules, held on the colony's [CityLoyalty] and ticked from
/// its loyalty step, reading only what that step hands it — so a test can
/// run a petition's whole holdout in a millisecond. [CityReclaimSim] is the
/// glue on [CitySim]: accepting (which reaches the tax and the laws),
/// declining, and the world-level reputation, which no single colony can
/// see — it is the mean over its NEIGHBOURS, measured where every colony is
/// in reach (`AdvanceSimulationTick`) and handed to each.
///
/// No money changes hands (Q1): treasuries are per colony and there is no
/// player purse to buy a colony back with, so a way back costs the player
/// rule, not coin — for a while, the colony's terms bind the player's hand
/// at the control gate (`city_control.dart`).
library;

import 'dart:math' as math;

import 'city_loyalty.dart';
import 'city_sim.dart';

/// Every number the ways back run on (§6.1, §6.2), in loyalty-calendar days
/// ([CityLoyaltyTuning.daySec]).
class ReclaimTuning {
  const ReclaimTuning({
    this.neglectFullDays = 40,
    this.misruleFrom = 0.3,
    this.misruleFull = 0.9,
    this.neglectWeight = 0.3,
    this.misruleWeight = 0.3,
    this.revoltWeight = 0.25,
    this.desperationWeight = 0.15,
    this.mildTaxCap = 0.25,
    this.harshTaxCap = 0.05,
    this.lawsFrom = 0.3,
    this.maxKeptLaws = 3,
    this.noDemolitionFrom = 0.55,
    this.baseDays = 10,
    this.severityDays = 30,
    this.independenceDays = 10,
    this.independenceFullDays = 30,
    this.lightShare = 0.4,
    this.rejoinLoyalty = 0.5,
    this.goodwillPerTerm = 0.05,
    this.heartsDays = 15,
    this.heartsGap = 0.2,
    this.heartsDecayDays = 10,
    this.holdoutDays = 2,
    this.holdoutDesperationDays = 12,
  });

  /// Days without orders at the declaration that count as the whole of the
  /// neglect grievance.
  final double neglectFullDays;

  /// Rebellion at the declaration over which misrule is a grievance, and at
  /// which it is the whole of it.
  final double misruleFrom;
  final double misruleFull;

  /// How much each grievance weighs in the [Grievance.severity]: neglect,
  /// misrule, revolts (out of the three that break a colony away) and the
  /// desperation it left in. Misrule and revolts outweigh absence: a colony
  /// that was mistreated asks more than one that was forgotten.
  final double neglectWeight;
  final double misruleWeight;
  final double revoltWeight;
  final double desperationWeight;

  /// The tax cap at severity 0 and at severity 1.
  final double mildTaxCap;
  final double harshTaxCap;

  /// The severity from which the colony names laws to be kept, and how many
  /// it names at severity 1.
  final double lawsFrom;
  final int maxKeptLaws;

  /// The severity from which it forbids demolitions.
  final double noDemolitionFrom;

  /// How long terms run: [baseDays], plus [severityDays] at severity 1, plus
  /// [independenceDays] once it has been independent [independenceFullDays]
  /// — a colony long used to its own rule gives it up slowly.
  final double baseDays;
  final double severityDays;
  final double independenceDays;
  final double independenceFullDays;

  /// The share of its grievance a colony that ASKS to come back (a hearts
  /// petition) still holds against the player: its terms are light.
  final double lightShare;

  /// The loyalty a colony rejoins at (§6.1).
  final double rejoinLoyalty;

  /// Loyalty each term the player grants a dependency petition adds on top:
  /// a colony that asked for help and got it on generous terms remembers.
  final double goodwillPerTerm;

  /// A colony doing [heartsGap] worse than the player's reputation fills its
  /// petition pressure in [heartsDays]; doing no worse, the pressure drains
  /// over [heartsDecayDays].
  final double heartsDays;
  final double heartsGap;
  final double heartsDecayDays;

  /// Days a dependent colony holds out before it petitions: [holdoutDays],
  /// plus [holdoutDesperationDays] at desperation 1 at the declaration
  /// (§3.4) — liberty or death takes longer to give up.
  final double holdoutDays;
  final double holdoutDesperationDays;
}

/// What drove a colony out, measured at the moment it left: what its terms
/// are derived from (§6.1). Saved, since the live state has moved on by the
/// time anyone negotiates — its neglect clock no longer counts the player,
/// and its rebellion settles under its own rule.
class Grievance {
  const Grievance({
    this.neglectDays = 0,
    this.rebellion = 0,
    this.revolts = 0,
    this.desperation = 0,
  });

  /// Days without orders at the declaration.
  final double neglectDays;

  /// The rebellion meter at the declaration.
  final double rebellion;

  /// Revolts inside the window at the declaration.
  final int revolts;

  /// Desperation at the declaration (§3.4).
  final double desperation;

  /// How badly the colony was run, 0..1.
  double severity(ReclaimTuning t, {int revoltsToSecede = 3}) {
    double share(double v) => v.isFinite ? v.clamp(0.0, 1.0) : 0.0;
    return (t.neglectWeight * share(neglectDays / t.neglectFullDays) +
            t.misruleWeight *
                share((rebellion - t.misruleFrom) /
                    math.max(1e-6, t.misruleFull - t.misruleFrom)) +
            t.revoltWeight *
                share(revolts / math.max(1, revoltsToSecede)) +
            t.desperationWeight * share(desperation))
        .clamp(0.0, 1.0);
  }

  Map<String, dynamic> toJson() => {
        if (neglectDays != 0) 'neglect': neglectDays,
        if (rebellion != 0) 'rebellion': rebellion,
        if (revolts != 0) 'revolts': revolts,
        if (desperation != 0) 'desperation': desperation,
      };

  static Grievance fromJson(Map json) {
    double n(Object? v) => v is num ? v.toDouble() : 0;
    return Grievance(
      neglectDays: n(json['neglect']),
      rebellion: n(json['rebellion']),
      revolts: n(json['revolts']).round(),
      desperation: n(json['desperation']).clamp(0.0, 1.0),
    );
  }
}

/// Terms a colony rejoins under (§6.1): what the player may not do to it
/// while they run. Immutable; [CityReclaim.terms] holds the ones in force.
class BindingTerms {
  const BindingTerms({
    this.taxCap,
    this.keptLaws = const {},
    this.noDemolition = false,
    this.days = 0,
  });

  /// No terms at all: what a player who sets none grants.
  static const BindingTerms none = BindingTerms();

  /// The highest tax the player may set, or null for no cap.
  final double? taxCap;

  /// Laws the player may not repeal.
  final Set<Law> keptLaws;

  /// Whether demolition is refused.
  final bool noDemolition;

  /// How long they run, in loyalty-calendar days.
  final double days;

  /// How many terms there are (a cap, each kept law, the demolition ban).
  int get count =>
      (taxCap != null ? 1 : 0) + keptLaws.length + (noDemolition ? 1 : 0);

  /// No terms, or none that last.
  bool get isEmpty => count == 0 || days <= 0;

  /// Each term in the player's words, for a list.
  List<String> describe() => [
        if (taxCap case final cap?) 'tax at most ${pct(cap)}',
        for (final l in Law.values)
          if (keptLaws.contains(l)) 'keep ${l.label}',
        if (noDemolition) 'no demolitions',
      ];

  static String pct(double v) => '${(v * 100).round()}%';

  Map<String, dynamic> toJson() => {
        if (taxCap != null) 'tax': taxCap,
        if (keptLaws.isNotEmpty)
          'laws': [
            for (final l in Law.values)
              if (keptLaws.contains(l)) l.name,
          ],
        if (noDemolition) 'noDemolish': true,
        'days': days,
      };

  static BindingTerms fromJson(Map json) {
    final tax = json['tax'];
    final laws = json['laws'];
    final days = json['days'];
    return BindingTerms(
      taxCap: tax is num ? tax.toDouble().clamp(0.0, 1.0) : null,
      keptLaws: {
        for (final n in laws is List ? laws : const [])
          ...Law.values.where((l) => l.name == n),
      },
      noDemolition: json['noDemolish'] == true,
      days: days is num ? math.max(0.0, days.toDouble()) : 0,
    );
  }
}

/// Why a colony asks to come back (§6.2).
enum PetitionKind {
  /// The player's other colonies are run better than it runs itself: it
  /// asks on light terms of its own.
  hearts,

  /// It cannot keep itself alive: it asks on whatever terms the player sets.
  dependency,
}

/// A request to rejoin, waiting on the player's answer.
class Petition {
  const Petition(this.kind, this.atS, {this.terms});
  final PetitionKind kind;

  /// [CityLoyalty.colonyTimeS] it was raised at.
  final double atS;

  /// The colony's own (light) terms for a [PetitionKind.hearts] petition;
  /// null for a dependency one, whose terms are the player's.
  final BindingTerms? terms;

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        't': atS,
        if (terms != null) 'terms': terms!.toJson(),
      };

  static Petition? fromJson(Object? json) {
    if (json is! Map) return null;
    final kind =
        PetitionKind.values.where((k) => k.name == json['kind']).firstOrNull;
    if (kind == null) return null;
    final t = json['t'];
    final terms = json['terms'];
    return Petition(kind, t is num ? t.toDouble() : 0,
        terms: terms is Map ? BindingTerms.fromJson(terms) : null);
  }
}

/// The ways back: state and rules (§6.1, §6.2).
class CityReclaim {
  CityReclaim({this.tuning = const ReclaimTuning()});

  /// Configuration, not state: not saved (like [CityLoyalty.tuning]).
  ReclaimTuning tuning;

  /// What drove it out, recorded at the declaration ([onSecede]).
  Grievance? grievance;

  /// The terms in force since the colony rejoined, or null.
  BindingTerms? terms;

  /// [CityLoyalty.colonyTimeS] [terms] run out at.
  double termsUntilS = 0;

  /// Hearts petition pressure 0..1 (§6.2): fills while the colony does
  /// worse than the player's [reputation], drains otherwise.
  double pressure = 0;

  /// Colony seconds the colony has been unable to keep itself alive, net
  /// of the time it could (it drains as it fills): the dependency
  /// petition's holdout clock.
  double dependentS = 0;

  /// The request to rejoin waiting on the player, if any.
  Petition? petition;

  /// The population-weighted mean loyalty × mood of the player's colonial
  /// colonies in this world, handed in by the world each tick
  /// ([CityReclaimSim.handOutReputation]); null with none to measure —
  /// the flat sandbox, or a world whose only colony is this one. Working
  /// input, not saved: the next tick hands it in again.
  double? reputation;

  /// Days left on the terms at [nowS] on a calendar of [daySec], rounded
  /// up: "1 day left" until the last second of it.
  int daysLeft(double nowS, double daySec) =>
      math.max(0, ((termsUntilS - nowS) / daySec - 1e-9).ceil());

  /// The terms the colony states for rejoining now (§6.1): from its
  /// [grievance] and how long it has been on its own. [laws] are the laws
  /// it holds, the ones it can name to be kept.
  BindingTerms statedTerms(
      {required double independentDays,
      required Set<Law> laws,
      int revoltsToSecede = 3}) {
    final s = (grievance ?? const Grievance())
        .severity(tuning, revoltsToSecede: revoltsToSecede);
    return termsFor(s, independentDays: independentDays, laws: laws);
  }

  /// The light terms of a hearts petition: the same rule on a share of the
  /// grievance.
  BindingTerms lightTerms(
      {required double independentDays,
      required Set<Law> laws,
      int revoltsToSecede = 3}) {
    final s = (grievance ?? const Grievance())
        .severity(tuning, revoltsToSecede: revoltsToSecede);
    return termsFor(s * tuning.lightShare,
        independentDays: independentDays * tuning.lightShare, laws: laws);
  }

  /// Terms at [severity] 0..1: always a tax cap, tighter the worse the rule;
  /// past [ReclaimTuning.lawsFrom] the laws it holds, more of them the
  /// worse; past [ReclaimTuning.noDemolitionFrom] no demolitions; and longer
  /// the worse and the longer it was gone.
  BindingTerms termsFor(double severity,
      {required double independentDays, required Set<Law> laws}) {
    final t = tuning;
    final s = severity.clamp(0.0, 1.0);
    final cap = ((t.mildTaxCap + (t.harshTaxCap - t.mildTaxCap) * s) * 100)
            .round() /
        100;
    final kept = <Law>{};
    if (s >= t.lawsFrom && t.maxKeptLaws > 0) {
      final n = 1 +
          ((s - t.lawsFrom) / math.max(1e-6, 1 - t.lawsFrom) *
                  (t.maxKeptLaws - 1))
              .round();
      kept.addAll(Law.values.where(laws.contains).take(n));
    }
    final gone = (independentDays / math.max(1e-6, t.independenceFullDays))
        .clamp(0.0, 1.0);
    final days = (t.baseDays + t.severityDays * s + t.independenceDays * gone)
        .roundToDouble();
    return BindingTerms(
      taxCap: cap,
      keptLaws: kept,
      noDemolition: s >= t.noDemolitionFrom,
      days: days,
    );
  }

  /// The declaration: what drove it out is recorded, and anything the last
  /// rejoining left — terms, a petition, pressure — is gone with it.
  void onSecede(Grievance why) {
    grievance = why;
    terms = null;
    termsUntilS = 0;
    pressure = 0;
    dependentS = 0;
    petition = null;
  }

  /// One tick (§6.2), after [CityLoyalty.tick] moved the clock: terms run
  /// out for a colony that has rejoined; for one still away, the hearts
  /// pressure and the dependency holdout run, and either may raise a
  /// petition. Linear in [dt] under steady inputs, so one warped step fills
  /// the pressure as many small ones would.
  void tick(
    CityLoyalty l, {
    required double dt,
    required double happiness,
    required bool starving,
    required bool populated,
    required Set<Law> laws,
  }) {
    if (dt <= 0) return;
    final t = tuning;
    final day = l.tuning.daySec;
    if (l.allegiance != Allegiance.independent) {
      petition = null;
      pressure = 0;
      dependentS = 0;
      if (terms != null && l.colonyTimeS >= termsUntilS) {
        terms = null;
        termsUntilS = 0;
        l.notice(LoyaltyNoticeKind.termsExpired,
            'The rejoining terms have run out: normal rule resumes.');
      }
      return;
    }
    terms = null;

    // Hearts (§6.2): pressure fills while the colony does worse than the
    // player's other colonies, and drains while it does not — or with no
    // other colony to compare itself with.
    final rep = reputation;
    final gap = rep == null || !populated ? 0.0 : rep - happiness;
    if (gap > 0) {
      pressure += gap / (t.heartsGap * t.heartsDays * day) * dt;
    } else {
      pressure -= dt / (t.heartsDecayDays * day);
    }
    pressure = pressure.clamp(0.0, 1.0);

    // Dependency (§4, §6.2): below the bar its desperation sets — or
    // starving below the bar of a colony with none. The live bar alone is
    // not enough: hunger pins mood at 0, which drives desperation to 1 and
    // the bar to 0, and a colony starving to death would then measure
    // "sufficient" and never ask for the help it is dying without.
    final dependent = populated &&
        (l.selfSufficiency < l.independenceBar ||
            (starving && l.selfSufficiency < l.tuning.independenceBar));
    dependentS = math.max(0.0, dependentS + (dependent ? dt : -dt));

    final desperate = (grievance?.desperation ?? l.desperation).clamp(0.0, 1.0);
    final holdoutS =
        (t.holdoutDays + t.holdoutDesperationDays * desperate) * day;
    final independentDays =
        (l.colonyTimeS - (l.independentAtS ?? l.colonyTimeS)) / day;
    if (petition?.kind != PetitionKind.dependency &&
        dependent &&
        dependentS >= holdoutS) {
      petition = Petition(PetitionKind.dependency, l.colonyTimeS);
      l.notice(
          LoyaltyNoticeKind.petition,
          'The colony cannot keep itself alive and asks to rejoin, on '
          'whatever terms you set.');
    } else if (petition == null && pressure >= 1) {
      final light = lightTerms(
          independentDays: independentDays,
          laws: laws,
          revoltsToSecede: l.tuning.revoltsToSecede);
      petition = Petition(PetitionKind.hearts, l.colonyTimeS, terms: light);
      l.notice(
          LoyaltyNoticeKind.petition,
          'Your other colonies are run better than it runs itself: it asks '
          'to rejoin on light terms (${light.describe().join(', ')}).');
    }
  }

  /// The player turns the petition down: it stays independent, and asks
  /// again only once its reason has built up again.
  void declinePetition() {
    final p = petition;
    if (p == null) return;
    petition = null;
    switch (p.kind) {
      case PetitionKind.hearts:
        pressure = 0;
      case PetitionKind.dependency:
        dependentS = 0;
    }
  }

  bool get _isEmpty =>
      grievance == null &&
      terms == null &&
      pressure == 0 &&
      dependentS == 0 &&
      petition == null;

  /// The saved state, or null with nothing to keep: a colony that never
  /// left saves as it always has.
  Map<String, dynamic>? toJson() => _isEmpty
      ? null
      : {
          if (grievance != null) 'why': grievance!.toJson(),
          if (terms != null) ...{
            'terms': terms!.toJson(),
            'until': termsUntilS,
          },
          if (pressure != 0) 'pressure': pressure,
          if (dependentS != 0) 'dependent': dependentS,
          if (petition != null) 'petition': petition!.toJson(),
        };

  /// Restore [toJson]'s map; absent or unreadable fields keep defaults.
  void restore(Object? json) {
    grievance = null;
    terms = null;
    termsUntilS = 0;
    pressure = 0;
    dependentS = 0;
    petition = null;
    if (json is! Map) return;
    final why = json['why'];
    if (why is Map) grievance = Grievance.fromJson(why);
    final tm = json['terms'];
    final until = json['until'];
    if (tm is Map && until is num) {
      final b = BindingTerms.fromJson(tm);
      if (!b.isEmpty) {
        terms = b;
        termsUntilS = until.toDouble();
      }
    }
    final p = json['pressure'];
    if (p is num) pressure = p.toDouble().clamp(0.0, 1.0);
    final d = json['dependent'];
    if (d is num) dependentS = math.max(0.0, d.toDouble());
    petition = Petition.fromJson(json['petition']);
  }
}

/// The ways back on the colony: what reaches past the loyalty model into
/// the colony's tax and laws, and the world's reputation.
extension CityReclaimSim on CitySim {
  CityReclaim get reclaim => loyalty.reclaim;

  /// Loyalty-calendar days since the declaration (0 for a colony that has
  /// not left).
  double get independentDays {
    final at = loyalty.independentAtS;
    if (at == null) return 0;
    return math.max(0.0, loyalty.colonyTimeS - at) / loyalty.tuning.daySec;
  }

  /// Whole days left on the binding terms, rounded up; 0 with none.
  int get termsDaysLeft => reclaim.terms == null
      ? 0
      : reclaim.daysLeft(loyalty.colonyTimeS, loyalty.tuning.daySec);

  /// A binding term's refusal, worded for the player: "The rejoining terms
  /// cap the tax at 10% (12 days left)." [what] is the term's verb phrase.
  String termRefusal(String what) {
    final n = termsDaysLeft;
    return 'The rejoining terms $what ($n day${n == 1 ? '' : 's'} left).';
  }

  /// What the colony asks to rejoin now (§6.1). Meaningful only while it is
  /// independent.
  BindingTerms negotiatedTerms() => reclaim.statedTerms(
      independentDays: independentDays,
      laws: laws,
      revoltsToSecede: loyalty.tuning.revoltsToSecede);

  /// Accept the colony's stated terms (§6.1): it rejoins at
  /// [ReclaimTuning.rejoinLoyalty], bound by them. False, and nothing
  /// changes, for a colony that is not independent.
  bool acceptNegotiation() {
    if (loyalty.allegiance != Allegiance.independent) return false;
    _rejoin(negotiatedTerms(), reclaim.tuning.rejoinLoyalty,
        'The colony has rejoined on its terms');
    return true;
  }

  /// Accept the waiting petition (§6.2): a hearts petition on the colony's
  /// own light terms, a dependency petition on [playerTerms] (none if
  /// null), each term granted adding goodwill. False with no petition.
  bool acceptPetition([BindingTerms? playerTerms]) {
    final p = reclaim.petition;
    if (p == null || loyalty.allegiance != Allegiance.independent) {
      return false;
    }
    switch (p.kind) {
      case PetitionKind.hearts:
        _rejoin(p.terms ?? BindingTerms.none, reclaim.tuning.rejoinLoyalty,
            'The colony has rejoined, won back by how you rule the others');
      case PetitionKind.dependency:
        final granted = playerTerms ?? BindingTerms.none;
        final level = reclaim.tuning.rejoinLoyalty +
            reclaim.tuning.goodwillPerTerm *
                (granted.isEmpty ? 0 : granted.count);
        _rejoin(granted, level, 'The colony has rejoined on your terms');
    }
    return true;
  }

  /// Turn the petition down: the colony stays independent.
  void declinePetition() => reclaim.declinePetition();

  /// The terms a dependency petition's player may grant: a cap at each of
  /// these, any of the laws it holds, and the demolition ban.
  static const List<double> taxCapChoices = [0.05, 0.1, 0.15, 0.2, 0.25];

  void _rejoin(BindingTerms terms, double level, String headline) {
    final l = loyalty;
    final t = l.tuning;
    l.allegiance = Allegiance.colonial;
    l.level = level.clamp(0.0, 1.0);
    // The band it lands in, as if it had climbed there.
    l.stage = l.level > t.restlessAbove
        ? LoyaltyStage.loyal
        : (l.level > t.defiantAbove
            ? LoyaltyStage.restless
            : LoyaltyStage.defiant);
    l.independentAtS = null;
    l.independenceCauses = null;
    // The revolts it left over are its own business now: kept, three in the
    // window would break it away again on the next tick.
    l.revolts.clear();
    l.portSeized = false;
    l.impoundPending = false;
    // Accepting is an act of governance: the neglect clock starts now.
    l.attend();
    final r = reclaim;
    r.petition = null;
    r.pressure = 0;
    r.dependentS = 0;
    r.grievance = null;
    if (terms.isEmpty) {
      r.terms = null;
      r.termsUntilS = 0;
    } else {
      r.terms = terms;
      r.termsUntilS = l.colonyTimeS + terms.days * t.daySec;
      // The colony's own council set the tax it comes back with; a cap
      // binds the player from here, and starts by holding the rate under it.
      if (terms.taxCap case final cap? when taxRate > cap) taxRate = cap;
      laws.addAll(terms.keptLaws);
    }
    l.notice(
        LoyaltyNoticeKind.rejoined,
        terms.isEmpty
            ? '$headline.'
            : '$headline: ${terms.describe().join(', ')} for '
                '${terms.days.round()} days.');
  }

  /// The status-list line of a waiting petition, or null.
  LoyaltyWarning? reclaimWarning() {
    final p = reclaim.petition;
    if (p == null || loyalty.allegiance != Allegiance.independent) return null;
    return switch (p.kind) {
      PetitionKind.hearts => LoyaltyWarning(
          'petition',
          LoyaltySeverity.warn,
          'Asks to rejoin on light terms — '
          '${(p.terms ?? BindingTerms.none).describe().join(', ')}'),
      PetitionKind.dependency => const LoyaltyWarning(
          'petition',
          LoyaltySeverity.warn,
          'Cannot keep itself alive and asks to rejoin — on your terms'),
    };
  }

  /// The status-list line of the binding terms in force, or null.
  LoyaltyWarning? termsWarning() {
    final b = reclaim.terms;
    if (b == null || loyalty.allegiance == Allegiance.independent) return null;
    final n = termsDaysLeft;
    return LoyaltyWarning(
        'terms',
        LoyaltySeverity.warn,
        'Rejoining terms: ${b.describe().join(', ')} — '
        '$n day${n == 1 ? '' : 's'} left');
  }

  /// The reputation (§6.2) of the player's rule over [cities]: their
  /// population-weighted mean of loyalty × mood, over the COLONIAL ones —
  /// an independent colony's mood is its own council's, and an occupied
  /// one is held by force. Null with no colonial colony that anyone lives
  /// in.
  static double? reputationOf(Iterable<CitySim> cities) {
    var weight = 0.0, sum = 0.0;
    for (final c in cities) {
      if (c.loyalty.allegiance != Allegiance.colonial) continue;
      final pop = c.population;
      if (pop <= 0) continue;
      weight += pop;
      sum += pop * c.loyalty.level.clamp(0.0, 1.0) * c.happiness.clamp(0.0, 1.0);
    }
    return weight > 0 ? sum / weight : null;
  }

  /// Hand every colony in [cities] the reputation of the player's rule over
  /// them ([reputationOf]) — the world-level half of the hearts route, run
  /// where every colony is in reach, before any of them ticks.
  static void handOutReputation(Iterable<CitySim> cities) {
    final r = reputationOf(cities);
    for (final c in cities) {
      c.loyalty.reclaim.reputation = r;
    }
  }
}
