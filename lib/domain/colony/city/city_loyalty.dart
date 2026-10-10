// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A colony's loyalty to the player, and what it does when that runs out
/// (docs/plans/colony-secession.md, phase 1).
///
/// The model is split in two. [CityLoyalty] is the state and the rules, and
/// reads nothing of the colony but the handful of numbers a tick hands it
/// ([LoyaltyInputs]) — so a test can drive it for forty colony days in a
/// millisecond, and the rules can be read without the five thousand lines
/// of economy around them. [CityLoyaltySim] is the glue on [CitySim]: it
/// measures those numbers, applies the stage effects the colony can feel
/// (self-government, the tax revolt) and names the causes a warning shows.
///
/// Phase 1 only WARNS and STRIKES: the control gate that would refuse the
/// player's commands on an independent colony is phase 2, so here a
/// secession is recorded and announced, the colony's port closes to the
/// player, and nothing else is refused.
library;

import 'dart:math' as math;

import 'city_sim.dart';
import 'commodity.dart';

/// Whose orders a colony takes (§3.1, §6.3).
enum Allegiance {
  /// The player's: the normal state.
  colonial,

  /// Seceded (§4): a faction the simulation runs.
  independent,

  /// Retaken by force (§6.3, phase 4). Never entered in phase 1; the value
  /// exists so a save written by a later build loads.
  occupied,
}

/// How far a colony has turned (§3.5).
enum LoyaltyStage {
  loyal('Loyal'),
  restless('Restless'),
  defiant('Defiant'),

  /// The secession condition fired but the colony cannot feed itself, so
  /// it cannot leave: it strikes, its settlers leave, and its rebels take
  /// the port.
  standoff('Standoff'),

  /// [Allegiance.independent].
  seceded('Independent');

  const LoyaltyStage(this.label);
  final String label;
}

/// Every number the loyalty model runs on, in one place (§3.2, §3.4, §3.5).
///
/// Times are in EARTH days of [daySec] colony seconds — the 120 s reference
/// day [CitySim.dayLengthSec] scales every body's day from — and not in the
/// host body's own day. A day there is a lighting cycle: the Moon's is 1200
/// s by the clamp, and a political calendar on it would let a lunar colony
/// sulk ten times longer than an Earth one for the same neglect.
class CityLoyaltyTuning {
  const CityLoyaltyTuning({
    this.daySec = 120,
    this.graceDays = 10,
    this.neglectScaleDays = 20,
    this.absenceDays = 40,
    this.contentShield = 0.75,
    this.misruleDays = 10,
    this.misruleReference = 0.8,
    this.misruleFloor = 0.3,
    this.revoltHit = 0.15,
    this.revoltWindowDays = 15,
    this.revoltsToSecede = 3,
    this.recoverDays = 5,
    this.recoverAmount = 0.2,
    this.recentDays = 10,
    this.restlessBelow = 0.6,
    this.restlessAbove = 0.65,
    this.defiantBelow = 0.3,
    this.defiantAbove = 0.35,
    this.independenceBar = 0.9,
    this.sufficiencyEaseDays = 5,
    this.desperationDays = 15,
    this.revoltDesperation = 0.15,
    this.desperationDecayDays = 10,
    this.seizeDesperation = 0.4,
    this.defiantThrottle = 0.7,
    this.defiantTax = 0.5,
    this.standoffThrottle = 0.4,
    this.standoffTax = 0.0,
    this.bearableMood = 0.5,
    this.taxPullDays = 2,
  });

  /// Colony seconds in one day of this calendar.
  final double daySec;

  /// Days without an act of governance before neglect starts to tell.
  final double graceDays;

  /// Days over which neglect ramps from nothing to full erosion.
  final double neglectScaleDays;

  /// Days after [graceDays] for neglect alone to take a wholly discontented
  /// colony from loyalty 1 to 0 — the ramp included.
  final double absenceDays;

  /// How much of the neglect a content colony shrugs off: erosion runs at
  /// `1 − contentShield × content`. 0.75 makes a fully content colony erode
  /// four times slower, the "~4× longer" the plan's table promises (its
  /// formula's 0.7 gives 3.3×).
  final double contentShield;

  /// Days a colony held at rebellion [misruleReference] takes to lose its
  /// loyalty from misrule alone. Rebellion below [misruleFloor] costs none:
  /// every colony grumbles.
  final double misruleDays;
  final double misruleReference;
  final double misruleFloor;

  /// Loyalty a revolt knocks off at once; three close together are
  /// near-fatal.
  final double revoltHit;

  /// [revoltsToSecede] revolts inside [revoltWindowDays] fire the secession
  /// condition whatever the loyalty.
  final double revoltWindowDays;
  final int revoltsToSecede;

  /// [recoverAmount] of loyalty restored by [recoverDays] of attended,
  /// fully content rule.
  final double recoverDays;
  final double recoverAmount;

  /// How recently an act of governance must be for the colony to count as
  /// attended — the window in which good rule wins loyalty back.
  final double recentDays;

  /// Stage lines, each with its way back above it (hysteresis): Restless
  /// below [restlessBelow] until back above [restlessAbove], Defiant below
  /// [defiantBelow] until back above [defiantAbove].
  final double restlessBelow;
  final double restlessAbove;
  final double defiantBelow;
  final double defiantAbove;

  /// The self-sufficiency a colony of no desperation needs to secede; the
  /// bar is `independenceBar × (1 − desperation)`.
  final double independenceBar;

  /// Days the measured self-sufficiency is eased over: one good harvest
  /// does not make a colony independent, one bad day does not undo it.
  final double sufficiencyEaseDays;

  /// Days of standoff at mood 0 to reach desperation 1.
  final double desperationDays;

  /// Desperation one revolt adds.
  final double revoltDesperation;

  /// Days of attended, content rule to clear desperation 1.
  final double desperationDecayDays;

  /// Desperation past which a colony in standoff seizes its spaceport.
  final double seizeDesperation;

  /// The strike: what a Defiant colony's non-life-support production runs
  /// at, and the share of tax it still pays; and the same in standoff.
  final double defiantThrottle;
  final double defiantTax;
  final double standoffThrottle;
  final double standoffTax;

  /// The mood a self-governing colony's tax revolt tries to hold, and the
  /// days its pull takes to close the gap to the tax that mood bears.
  final double bearableMood;
  final double taxPullDays;

  double get graceS => graceDays * daySec;
  double get neglectScaleS => neglectScaleDays * daySec;
  double get recentS => recentDays * daySec;
  double get revoltWindowS => revoltWindowDays * daySec;

  /// Loyalty per second neglect takes at full ramp and content 0. With a
  /// linear ramp over [neglectScaleDays] the ramp itself costs half its
  /// length at full rate, so the full-rate span is what is left of
  /// [absenceDays] after that.
  double get absenceRate =>
      1 / (math.max(1e-6, absenceDays - neglectScaleDays / 2) * daySec);

  /// Loyalty per second per unit of rebellion over [misruleFloor].
  double get misruleRate => 1 /
      (misruleDays * daySec * math.max(1e-6, misruleReference - misruleFloor));

  /// Loyalty per second attended, fully content rule restores.
  double get recoverRate => recoverAmount / (recoverDays * daySec);
}

/// What one tick of the colony hands the loyalty model.
class LoyaltyInputs {
  const LoyaltyInputs({
    required this.dt,
    required this.happiness,
    required this.coverage,
    required this.rebellion,
    required this.sufficiency,
    this.hasSpaceport = true,
    this.starving = false,
    this.causes,
  });

  /// Colony seconds this tick.
  final double dt;

  /// Mood 0..1, and the share of required services covered 0..1: together
  /// `content`, the term that shields from neglect and earns recovery.
  final double happiness;
  final double coverage;

  /// The smoothed rebellion meter 0..1: misrule.
  final double rebellion;

  /// This tick's measured self-sufficiency 0..1 (§3.4), before easing.
  final double sufficiency;

  /// Whether there is a working port to seize.
  final bool hasSpaceport;

  /// Whether the colony is starving: a seized port being starved out adds
  /// to desperation.
  final bool starving;

  /// The warning's cause text, built only when a notice needs it.
  final String Function()? causes;
}

/// What a notice is about.
enum LoyaltyNoticeKind {
  restless,
  defiant,
  standoff,
  portSeized,
  portReleased,
  revolt,
  independence,
  recovered,
}

/// One announcement for the HUD to raise — a queue a host drains, as it
/// drains [CitySim.milestoneToasts]; a headless run lets it grow (bounded).
class LoyaltyNotice {
  const LoyaltyNotice(this.kind, this.message, this.atS);
  final LoyaltyNoticeKind kind;
  final String message;

  /// [CityLoyalty.colonyTimeS] it was raised at.
  final double atS;
}

/// How loud a loyalty warning is; the screen picks the colour.
enum LoyaltySeverity { warn, danger }

/// One line of the status stack (`CityLoyaltySim.loyaltyWarnings`).
class LoyaltyWarning {
  const LoyaltyWarning(this.key, this.severity, this.text);

  /// Stable id: 'independent', 'portSeized', 'standoff', 'defiant',
  /// 'restless' or 'revolt'.
  final String key;
  final LoyaltySeverity severity;
  final String text;
}

/// A cargo the rebels kept (§4.1): what was taken, so the player sees it.
class ImpoundedCargo {
  const ImpoundedCargo(this.resource, this.amount, this.atS);
  final String resource;
  final double amount;
  final double atS;
}

/// A colony's loyalty state and its rules (§3).
class CityLoyalty {
  CityLoyalty({this.tuning = const CityLoyaltyTuning()});

  /// The numbers the rules run on. Configuration, not state: it is not in
  /// the save, so a load runs on whatever the build (or the host) sets.
  CityLoyaltyTuning tuning;

  /// Colony seconds integrated by [tick] — the neglect clock. World epochs
  /// do not reach a headless colony, and colony time is what its economy
  /// already runs on.
  double colonyTimeS = 0;

  /// [colonyTimeS] of the player's last act of governance ([attend]).
  double attendedAtS = 0;

  /// Loyalty 0..1.
  double level = 1;

  Allegiance allegiance = Allegiance.colonial;

  /// The stage, kept rather than derived: the hysteresis needs to know
  /// which side of a band the colony came from.
  LoyaltyStage stage = LoyaltyStage.loyal;

  /// [colonyTimeS] of each revolt inside the window, oldest first.
  final List<double> revolts = [];

  /// 0..1 (§3.4): lowers the independence bar.
  double desperation = 0;

  /// The eased share of its life-support need the colony's own buildings
  /// (and its own sky, for oxygen) cover (§3.4).
  double selfSufficiency = 1;

  /// Whether [selfSufficiency] has been measured: the first measurement is
  /// taken as is rather than eased up from a made-up starting value.
  bool sufficiencyMeasured = false;

  /// The rebels hold the spaceport (§4.1).
  bool portSeized = false;

  /// Seized, and the next craft is still to be let in — and kept.
  bool impoundPending = false;

  /// What the rebels have kept, newest last (bounded).
  final List<ImpoundedCargo> impounded = [];

  /// [colonyTimeS] the colony seceded at, if it has.
  double? independentAtS;

  /// Announcements for a host to drain (bounded).
  final List<LoyaltyNotice> notices = [];

  /// Last tick's drift terms, loyalty per day, for the readout.
  double lastErosion = 0, lastMisrule = 0, lastRecovery = 0;

  static const int _maxNotices = 32;
  static const int _maxImpounded = 20;

  /// Stamp an act of governance (§3.3). Viewing is not one.
  void attend() => attendedAtS = colonyTimeS;

  /// Colony seconds since the last act of governance.
  double get sinceAttendedS => math.max(0.0, colonyTimeS - attendedAtS);

  bool get attendedRecently => sinceAttendedS <= tuning.recentS;

  /// The self-sufficiency a secession needs now (§3.4).
  double get independenceBar =>
      tuning.independenceBar * (1 - desperation.clamp(0.0, 1.0));

  /// Whether the colony could keep itself alive alone.
  bool get selfSufficient => selfSufficiency >= independenceBar;

  /// Revolts inside the window.
  int get recentRevolts => revolts.length;

  /// The colony governs itself (§3.5): auto-voted laws, the tax revolt.
  bool get selfGoverning => stage != LoyaltyStage.loyal;

  /// What non-life-support production runs at: the strike.
  double get strikeThrottle => switch (stage) {
        LoyaltyStage.defiant => tuning.defiantThrottle,
        LoyaltyStage.standoff => tuning.standoffThrottle,
        _ => 1.0,
      };

  /// The share of its tax a colony pays: non-payment.
  double get taxFactor => switch (stage) {
        LoyaltyStage.defiant => tuning.defiantTax,
        LoyaltyStage.standoff => tuning.standoffTax,
        _ => 1.0,
      };

  /// Whether settlers can come and go: a seized port is shut both ways, so
  /// a starving standoff withers from hunger, not departure (§4.1).
  bool get migrationOpen => !portSeized;

  /// Standoff with the port still open: the settlers who live on imports
  /// leave (§3.5).
  bool get standoffEmigration =>
      stage == LoyaltyStage.standoff && !portSeized;

  /// The player's craft are not welcome: the rebels hold the port, or it
  /// is an independent colony's now.
  bool get portClosedToPlayer =>
      portSeized || allegiance == Allegiance.independent;

  /// Why the port refuses the player, for the logistics views.
  String? get portHoldReason => portSeized
      ? 'port held by rebels'
      : (allegiance == Allegiance.independent
          ? 'port closed: the colony is independent'
          : null);

  /// Whether a player craft may be sent to the port now. A seized port lets
  /// ONE more in — the next delivery, which it impounds — and refuses the
  /// rest (§4.1). Consumes that one.
  bool admitCraft() {
    if (!portClosedToPlayer) return true;
    if (portSeized && impoundPending) {
      impoundPending = false;
      return true;
    }
    return false;
  }

  /// Record a cargo the rebels kept.
  void impound(String resource, double amount) {
    if (amount <= 0) return;
    impounded.add(ImpoundedCargo(resource, amount, colonyTimeS));
    if (impounded.length > _maxImpounded) impounded.removeAt(0);
  }

  /// A revolt (`CitySim.socialTick`): loyalty knocked down, desperation up,
  /// and one more toward the three-revolt rule.
  void onRevolt(String message) {
    revolts.add(colonyTimeS);
    level = (level - tuning.revoltHit).clamp(0.0, 1.0);
    desperation = (desperation + tuning.revoltDesperation).clamp(0.0, 1.0);
    _notice(LoyaltyNoticeKind.revolt, message);
  }

  void _notice(LoyaltyNoticeKind kind, String message) {
    notices.add(LoyaltyNotice(kind, message, colonyTimeS));
    if (notices.length > _maxNotices) notices.removeAt(0);
  }

  /// One tick (§3.2–§3.5, §4.1).
  void tick(LoyaltyInputs i) {
    final dt = i.dt;
    if (dt <= 0) return;
    final t = tuning;
    colonyTimeS += dt;
    final windowStart = colonyTimeS - t.revoltWindowS;
    revolts.removeWhere((at) => at < windowStart);

    // Self-sufficiency, eased (§3.4).
    final target = i.sufficiency.clamp(0.0, 1.0);
    if (!sufficiencyMeasured) {
      selfSufficiency = target;
      sufficiencyMeasured = true;
    } else {
      final k = (dt / (t.sufficiencyEaseDays * t.daySec)).clamp(0.0, 1.0);
      selfSufficiency += (target - selfSufficiency) * k;
    }

    final content = (i.happiness * i.coverage).clamp(0.0, 1.0);
    final recent = attendedRecently;

    // Drift (§3.2). An independent colony's loyalty is no longer the
    // player's to lose or win by ruling it; phases 3–4 reopen it.
    if (allegiance != Allegiance.independent) {
      final neglect = math.max(0.0, sinceAttendedS - t.graceS) / t.neglectScaleS;
      final erosion = t.absenceRate *
          math.min(1.0, neglect) *
          (1 - t.contentShield * content);
      final misrule =
          t.misruleRate * math.max(0.0, i.rebellion - t.misruleFloor);
      final recovery = recent ? t.recoverRate * content : 0.0;
      level = (level + (recovery - erosion - misrule) * dt).clamp(0.0, 1.0);
      lastErosion = erosion * t.daySec;
      lastMisrule = misrule * t.daySec;
      lastRecovery = recovery * t.daySec;
    }

    // Desperation (§3.4): the worst of what drives it, so a standoff at
    // mood 0 takes [desperationDays] to reach 1, whatever else is wrong.
    final pressure = [
      stage == LoyaltyStage.standoff ? 1 - i.happiness : 0.0,
      ((i.rebellion - 0.9) / 0.1).clamp(0.0, 1.0),
      ((0.1 - i.happiness) / 0.1).clamp(0.0, 1.0),
      portSeized && i.starving ? 1.0 : 0.0,
    ].reduce(math.max);
    final decay = recent ? content : 0.0;
    desperation = (desperation +
            (pressure / t.desperationDays - decay / t.desperationDecayDays) *
                dt /
                t.daySec)
        .clamp(0.0, 1.0);

    _stageStep(i);
  }

  void _stageStep(LoyaltyInputs i) {
    final t = tuning;
    String causes() => i.causes?.call() ?? '';
    if (allegiance == Allegiance.independent) {
      stage = LoyaltyStage.seceded;
      return;
    }
    final condition = level <= 0 || revolts.length >= t.revoltsToSecede;
    if (condition || stage == LoyaltyStage.standoff) {
      if (selfSufficient) {
        _secede(causes());
        return;
      }
      if (!condition &&
          stage == LoyaltyStage.standoff &&
          level > t.defiantAbove) {
        stage = level > t.restlessAbove
            ? LoyaltyStage.loyal
            : LoyaltyStage.restless;
        _release();
        _notice(LoyaltyNoticeKind.recovered,
            'The standoff is over: the colony takes orders again.');
      } else if (stage != LoyaltyStage.standoff) {
        stage = LoyaltyStage.standoff;
        _notice(LoyaltyNoticeKind.standoff,
            'Would secede, but cannot feed itself — ${causes()}');
      }
    } else {
      final was = stage;
      var s = was;
      // Down through the lines, then back up through their return lines.
      if (s == LoyaltyStage.loyal && level < t.restlessBelow) {
        s = LoyaltyStage.restless;
      }
      if (s == LoyaltyStage.restless && level < t.defiantBelow) {
        s = LoyaltyStage.defiant;
      }
      if (s == LoyaltyStage.defiant && level > t.defiantAbove) {
        s = LoyaltyStage.restless;
      }
      if (s == LoyaltyStage.restless && level > t.restlessAbove) {
        s = LoyaltyStage.loyal;
      }
      stage = s;
      if (s != was) {
        if (s == LoyaltyStage.restless && was == LoyaltyStage.loyal) {
          _notice(LoyaltyNoticeKind.restless,
              'The colony is restless and governing itself — ${causes()}');
        } else if (s == LoyaltyStage.defiant) {
          _notice(LoyaltyNoticeKind.defiant,
              'The colony is defiant: strikes and unpaid taxes — ${causes()}');
        } else if (s == LoyaltyStage.loyal) {
          _notice(LoyaltyNoticeKind.recovered, 'The colony is loyal again.');
        }
      }
    }

    // The port (§4.1): taken once desperation passes the line in standoff,
    // given back when loyalty climbs past the Defiant line.
    if (stage == LoyaltyStage.standoff &&
        !portSeized &&
        i.hasSpaceport &&
        desperation > t.seizeDesperation) {
      portSeized = true;
      impoundPending = true;
      _notice(LoyaltyNoticeKind.portSeized,
          'Rebels have seized the spaceport: the next delivery will be '
          'impounded, then docking is refused.');
    } else if (portSeized && level > t.defiantAbove) {
      _release();
    }
  }

  void _release() {
    if (!portSeized) return;
    portSeized = false;
    impoundPending = false;
    _notice(LoyaltyNoticeKind.portReleased,
        'The rebels have given the spaceport back.');
  }

  void _secede(String causes) {
    allegiance = Allegiance.independent;
    stage = LoyaltyStage.seceded;
    independentAtS = colonyTimeS;
    // The port becomes the independent colony's own, and stays shut to the
    // player ([portClosedToPlayer]); it is no longer a rebel holding.
    portSeized = false;
    impoundPending = false;
    _notice(LoyaltyNoticeKind.independence,
        'The colony has declared independence — $causes');
  }

  // ---- Persistence ----------------------------------------------------------

  /// The saved state, each field omitted at its default so a colony that
  /// never strayed saves almost nothing. Notices and drift terms are
  /// display state and are not saved.
  Map<String, dynamic> toJson() => {
        if (colonyTimeS != 0) 't': colonyTimeS,
        if (attendedAtS != 0) 'attended': attendedAtS,
        if (level != 1) 'level': level,
        if (allegiance != Allegiance.colonial) 'allegiance': allegiance.name,
        if (stage != LoyaltyStage.loyal) 'stage': stage.name,
        if (revolts.isNotEmpty) 'revolts': List<double>.of(revolts),
        if (desperation != 0) 'desperation': desperation,
        if (sufficiencyMeasured) 'sufficiency': selfSufficiency,
        if (portSeized) 'portSeized': true,
        if (impoundPending) 'impoundPending': true,
        if (impounded.isNotEmpty)
          'impounded': [
            for (final c in impounded)
              {'res': c.resource, 'amt': c.amount, 't': c.atS},
          ],
        if (independentAtS != null) 'independentAt': independentAtS,
      };

  /// Restore from [toJson]'s map. Tolerant: an absent or unreadable field
  /// keeps its default, so an old save (no map at all) loads as a loyal,
  /// just-attended colony at time zero.
  void restore(Object? json) {
    if (json is! Map) return;
    double num0(Object? v, double d) => v is num ? v.toDouble() : d;
    colonyTimeS = num0(json['t'], 0);
    attendedAtS = num0(json['attended'], 0);
    level = num0(json['level'], 1).clamp(0.0, 1.0);
    allegiance = Allegiance.values
            .where((a) => a.name == json['allegiance'])
            .firstOrNull ??
        Allegiance.colonial;
    stage = LoyaltyStage.values
            .where((s) => s.name == json['stage'])
            .firstOrNull ??
        LoyaltyStage.loyal;
    revolts
      ..clear()
      ..addAll([
        for (final v in (json['revolts'] is List ? json['revolts'] as List : const []))
          if (v is num) v.toDouble(),
      ]);
    desperation = num0(json['desperation'], 0).clamp(0.0, 1.0);
    final suff = json['sufficiency'];
    if (suff is num) {
      selfSufficiency = suff.toDouble().clamp(0.0, 1.0);
      sufficiencyMeasured = true;
    }
    portSeized = json['portSeized'] == true;
    impoundPending = json['impoundPending'] == true;
    impounded.clear();
    final imp = json['impounded'];
    for (final e in imp is List ? imp : const []) {
      if (e is! Map) continue;
      final res = e['res'];
      if (res is! String) continue;
      impounded.add(ImpoundedCargo(res, num0(e['amt'], 0), num0(e['t'], 0)));
    }
    final ind = json['independentAt'];
    independentAtS = ind is num ? ind.toDouble() : null;
  }
}

/// The loyalty model's glue on the colony: measuring, applying, naming.
extension CityLoyaltySim on CitySim {
  /// The share of the colony's life-support need its OWN buildings and its
  /// own sky cover this tick (§3.4): for each of food, water and oxygen,
  /// [localNet] — the net output of the life-support buildings, less what
  /// any building draws — against the population's need, and the worst of
  /// the three. Oxygen always counts, whatever the complexity, and the air
  /// itself is a local source ([CitySim.airO2]). Deliveries, shuttle cargo,
  /// relief and the spaceport's own "imports" are not in [localNet]; the
  /// stockpile is not either — a full larder is not a farm.
  double localSufficiency(Map<String, double> localNet) {
    final pop = population;
    if (pop <= 1e-9) return 1.0;
    double share(String c, double perPerson, {double sky = 0}) {
      final need = pop * perPerson;
      return (((localNet[c] ?? 0) + sky * need) / need).clamp(0.0, 1.0);
    }

    return [
      share(Commodity.food, CitySim.foodPerPersonPerSec),
      share(Commodity.water, CitySim.waterPerPersonPerSec),
      // Oxygen per head is the sim's water rate (see the life-support step).
      share(Commodity.oxygen, CitySim.waterPerPersonPerSec, sky: airO2),
    ].reduce(math.min);
  }

  /// The loyalty step of a tick: the model, then the tax revolt.
  void loyaltyTick(double dt,
      {required Map<String, double> localNet, required double coverage}) {
    loyalty.tick(LoyaltyInputs(
      dt: dt,
      happiness: happiness,
      coverage: coverage,
      rebellion: rebellion,
      sufficiency: localSufficiency(localNet),
      hasSpaceport: hasSpaceport,
      starving: starved,
      causes: () => loyaltyCauses().join('; '),
    ));
    if (loyalty.selfGoverning) _taxRevolt(dt);
  }

  /// A self-governing colony pulls an over-high tax down toward what its
  /// mood bears (§3.5): the rate at which the tax's own happiness cost
  /// would leave it at [CityLoyaltyTuning.bearableMood]. It only ever pulls
  /// DOWN — a tax revolt, not a budget office — and leaves an economy whose
  /// tax is not the colony's to set alone.
  void _taxRevolt(double dt) {
    if (!economy.taxControllable) return;
    final penalty = economy.taxHappinessPenalty;
    if (penalty <= 1e-6) return;
    final t = loyalty.tuning;
    final gap = math.max(0.0, t.bearableMood - happiness);
    final bearable = math.max(0.0, taxRate - gap / penalty);
    if (taxRate <= bearable) return;
    final k = (dt / (t.taxPullDays * t.daySec)).clamp(0.0, 1.0);
    taxRate += (bearable - taxRate) * k;
  }

  /// The population the colony is heading for, under the loyalty stage:
  /// in a standoff with the port still open, the settlers the colony
  /// cannot keep alive on its own leave by the ordinary emigration path
  /// (§3.5), down to what its own life support covers or its crew floor.
  double loyaltyPopCap(double target) {
    if (!loyalty.standoffEmigration) return target;
    final floor = (CitySim.landerCrew + reliefCrew).toDouble();
    return math.min(
        target, math.max(floor, population * loyalty.selfSufficiency));
  }

  /// The actual terms of the drift equation, worded for a warning (§3.5):
  /// "no orders for 34 days", "rebellion 0.82: crime, inequality".
  List<String> loyaltyCauses() {
    final t = loyalty.tuning;
    final out = <String>[];
    final days = loyalty.sinceAttendedS / t.daySec;
    if (loyalty.sinceAttendedS > t.graceS) {
      out.add('no orders for ${days.floor()} days');
    }
    if (rebellion > t.misruleFloor) {
      final drivers = <(String, double)>[
        ('unhappiness', 0.5 * (1 - happiness)),
        ('crime', 0.2 * crime),
        ('inequality', 0.2 * inequality),
        ('corruption', 0.1 * corruption),
      ]..sort((a, b) => b.$2.compareTo(a.$2));
      final total = drivers.fold(0.0, (s, d) => s + d.$2);
      final named = [
        for (final d in drivers)
          if (total > 0 && d.$2 >= 0.2 * total) d.$1,
      ].take(3);
      out.add('rebellion ${rebellion.toStringAsFixed(2)}'
          '${named.isEmpty ? '' : ': ${named.join(', ')}'}');
    }
    final n = loyalty.recentRevolts;
    if (n > 0) {
      out.add('$n revolt${n == 1 ? '' : 's'} in '
          '${t.revoltWindowDays.round()} days');
    }
    if (loyalty.stage == LoyaltyStage.standoff ||
        (!loyalty.selfSufficient &&
            loyalty.allegiance == Allegiance.colonial &&
            loyalty.stage != LoyaltyStage.loyal)) {
      out.add('self-sufficiency ${(loyalty.selfSufficiency * 100).round()}% '
          'of ${(loyalty.independenceBar * 100).round()}% needed');
    }
    if (out.isEmpty) out.add('loyalty ${(loyalty.level * 100).round()}%');
    return out;
  }

  /// The loyalty warnings that apply now, most severe first, each naming
  /// its causes — the one list the status stack and the HUD both show, so
  /// the two cannot disagree about what is wrong.
  List<LoyaltyWarning> loyaltyWarnings() {
    final l = loyalty;
    final out = <LoyaltyWarning>[];
    String why() => loyaltyCauses().join('; ');
    if (l.allegiance == Allegiance.independent) {
      final since = l.independentAtS;
      final days = since == null
          ? null
          : ((l.colonyTimeS - since) / l.tuning.daySec).floor();
      out.add(LoyaltyWarning(
          'independent',
          LoyaltySeverity.danger,
          days == null
              ? 'Independent — takes no orders'
              : 'Independent for $days days — takes no orders'));
    }
    if (l.portSeized) {
      final n = l.impounded.length;
      out.add(LoyaltyWarning(
          'portSeized',
          LoyaltySeverity.danger,
          'Rebels hold the spaceport'
          '${n == 0 ? ' — next delivery will be impounded' : ' — $n cargo${n == 1 ? '' : 's'} impounded'}'));
    }
    switch (l.stage) {
      case LoyaltyStage.standoff:
        out.add(LoyaltyWarning('standoff', LoyaltySeverity.danger,
            'Would secede, but cannot feed itself — ${why()}'));
      case LoyaltyStage.defiant:
        out.add(LoyaltyWarning('defiant', LoyaltySeverity.danger,
            'Defiant: strikes, unpaid taxes — ${why()}'));
      case LoyaltyStage.restless:
        out.add(LoyaltyWarning('restless', LoyaltySeverity.warn,
            'Restless (loyalty ${(l.level * 100).round()}%) — ${why()}'));
      case LoyaltyStage.loyal:
      case LoyaltyStage.seceded:
        break;
    }
    // A revolt stays on the list for two days; after that it is one of the
    // causes the stage warning names, for as long as it counts.
    final last = l.revolts.isEmpty ? null : l.revolts.last;
    if (last != null && l.colonyTimeS - last <= 2 * l.tuning.daySec) {
      final n = l.recentRevolts;
      out.add(LoyaltyWarning(
          'revolt',
          LoyaltySeverity.danger,
          'REVOLT — $n in ${l.tuning.revoltWindowDays.round()} days'
          '${n >= l.tuning.revoltsToSecede - 1 && l.allegiance == Allegiance.colonial ? ' (one more and it breaks away)' : ''}'));
    }
    return out;
  }

  /// The loyalty block of a save, or null when there is nothing to keep.
  Map<String, dynamic>? loyaltySaveJson() {
    final j = loyalty.toJson();
    final held = heldCraftJson();
    if (held.isNotEmpty) j['held'] = held;
    return j.isEmpty ? null : j;
  }

  /// Restore [loyaltySaveJson]'s block; null (an old save) is a loyal,
  /// just-attended colony.
  void restoreLoyalty(Object? json) {
    loyalty.restore(json);
    if (json is Map) restoreHeldCraft(json['held']);
  }

  /// Held craft (§4.1), for the save: craft are otherwise not saved — a
  /// visit re-derives in forty seconds — but a craft the rebels hold is the
  /// player's, grounded until the port is retaken.
  List<Map<String, dynamic>> heldCraftJson() => [
        for (final c in craft)
          if (c.held)
            {
              'site': c.site,
              'pad': c.padIndex,
              if (c.isRelief) 'relief': true,
              if (c.resource != null) 'res': c.resource,
              'amt': c.payload,
            },
      ];

  /// Restore [heldCraftJson]'s craft, parked mid-dwell with their cargo
  /// already in the stock.
  void restoreHeldCraft(Object? json) {
    if (json is! List) return;
    for (final e in json) {
      if (e is! Map) continue;
      final site = e['site'];
      final pad = e['pad'];
      if (site is! String || pad is! num) continue;
      final amt = e['amt'];
      craft.add(LandedCraft(
        site: site,
        padIndex: pad.toInt(),
        isRelief: e['relief'] == true,
        resource: e['res'] is String ? e['res'] as String : null,
        payload: amt is num ? amt.toDouble() : 0,
      )
        ..granted = true
        ..phase = 0.5
        ..held = true);
    }
  }
}
