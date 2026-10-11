// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Every number the auto-resolver uses, in one const place
/// (docs/plans/combat.md §7.5).
///
/// Calibrated by stepping the rules, not by guessing: two 16-trooper squads at
/// a port each break when their 7th member falls, at about 174 s — a
/// fair fight is three minutes at 1× (test/combat/resolver_test.dart pins it).
library;

import 'formation.dart';

class ResolverTuning {
  const ResolverTuning({
    this.alpha = 1 / 185,
    this.kappa = 1 / 120,
    this.fuzzAmplitude = 0.15,
    this.fuzzRoundS = 30,
    this.moraleLossPerShare = 1.5,
    this.pinnedBelow = 0.35,
    this.brokenBelow = 0.2,
    this.rallyAt = 0.45,
    this.surrenderBelow = 0.15,
    this.recoverOutOfContact = 0.002,
    this.recoverHolding = 0.0005,
    this.hungerDrain = 0.0005,
    this.holdingControl = 0.5,
    this.winControl = 0.9,
    this.winHoldS = 60,
    this.noAmmoFactor = 0.35,
    this.emplacementPower = 3.0,
    this.daySec = 120,
    this.ceasefireDays = 10,
    this.assaultCeasefireDays = 20,
    this.kitOutLossDays = 2,
    this.aiEveryS = 30,
    this.waveSize = 8,
    this.advanceRatio = 0.8,
    this.withdrawLoss = 0.10,
    this.musteringDays = 0.25,
    this.transitDaysSameBody = 0.5,
    this.transitDaysOtherBody = 1.5,
    this.pyrrhicLossShare = 0.5,
    this.decisiveLossShare = 0.2,
    this.valiantDefenderShare = 0.5,
    this.decisiveDefeatDefenderShare = 0.2,
    this.standardFire = 1.2,
    this.collateralShare = 0.25,
  });

  /// Members removed per second per unit of effective enemy strength.
  final double alpha;

  /// Control swing per second at total dominance (a full swing in 240 s).
  final double kappa;

  /// Fuzz amplitude: losses scale by 1 ± this, rerolled each [fuzzRoundS].
  final double fuzzAmplitude;
  final int fuzzRoundS;

  /// Morale lost per member removed, as a share of members at engagement.
  final double moraleLossPerShare;

  final double pinnedBelow;
  final double brokenBelow;
  final double rallyAt;

  /// The defender surrenders when its strength-weighted morale is below this.
  final double surrenderBelow;

  /// Morale per second out of contact, while holding, and without rations.
  final double recoverOutOfContact;
  final double recoverHolding;
  final double hungerDrain;

  /// |control| a side needs on its own side to count as holding.
  final double holdingControl;

  /// The attacker wins by holding the goal at this control for [winHoldS].
  final double winControl;
  final int winHoldS;

  /// Strength factor with no ammo left.
  final double noAmmoFactor;

  /// Strength per member of a gun emplacement.
  final double emplacementPower;

  /// An operation day, s (the loyalty calendar's day).
  final double daySec;

  /// No decision after this many days of fighting: ceasefire.
  final double ceasefireDays;

  /// The same for a colony assault, which marches across a whole colony: two
  /// marches of 300–600 m are most of a port retake's ten days on their own.
  final double assaultCeasefireDays;

  /// Every attacker out of kit for this long: lost.
  final double kitOutLossDays;

  /// The abstract AIs think every this many seconds.
  final int aiEveryS;

  /// Most militia one defender wave brings.
  final int waveSize;

  /// Attackers advance only when S_A/F_def ≥ this × S_D/F_att, on whole
  /// strengths (not width-capped).
  final double advanceRatio;

  /// Share of survivors lost in a fighting withdrawal.
  final double withdrawLoss;

  final double musteringDays;
  final double transitDaysSameBody;
  final double transitDaysOtherBody;

  /// Outcome bands by the share of the attacking force lost (removed/raised).
  final double pyrrhicLossShare;
  final double decisiveLossShare;

  /// Defeat bands by the share of the defending force lost.
  final double valiantDefenderShare;
  final double decisiveDefeatDefenderShare;

  /// Attacker fire under Standard ROE, against Restrained's 1.
  final double standardFire;

  /// Civilians killed per defender killed under Standard ROE, unsheltered.
  final double collateralShare;

  /// Strength per member before quality, morale and supply.
  double powerOf(FormationKind kind) =>
      kind == FormationKind.emplacement ? emplacementPower : 1.0;
}

/// Halo Wars' counter triangle as M[dealer][target], applied to loss sharing
/// only. Phase 1 is M ≡ 1: pinned by a test, so counters change nothing until
/// the base and vehicles give them something to counter.
class CounterTuning {
  const CounterTuning.uniform()
      : _m = null,
        name = 'uniform';
  const CounterTuning(List<List<double>> m, {this.name = 'custom'}) : _m = m;

  final List<List<double>>? _m;

  /// Saved with an operation, so a load fights on the table it launched on.
  final String name;

  double factor(CounterClass dealer, CounterClass target) =>
      _m == null ? 1.0 : _m[dealer.index][target.index];

  static CounterTuning byName(String? n) => n == kCounters.name ? kCounters : const CounterTuning.uniform();
}

/// The 1b-ii table (combat.md §7D), rows the dealer, columns the target, in
/// [CounterClass] order (inf, empHmg, empAt, empAa, arm, air, structure): a
/// heavy machine gun cuts infantry down, and infantry behind a gun's arc
/// suffer it; everything else is even until armour and air arrive.
const CounterTuning kCounters = CounterTuning([
  [1, 0.8, 0.8, 0.8, 1, 1, 1],
  [1.25, 1, 1, 1, 1, 1, 1],
  [1, 1, 1, 1, 1, 1, 1],
  [1, 1, 1, 1, 1, 1, 1],
  [1, 1, 1, 1, 1, 1, 1],
  [1, 1, 1, 1, 1, 1, 1],
  [1, 1, 1, 1, 1, 1, 1],
], name: 'halo1');
