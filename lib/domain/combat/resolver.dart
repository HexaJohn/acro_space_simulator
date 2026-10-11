// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The auto-resolver's arithmetic for one objective, one step
/// (docs/plans/combat.md §7.5).
///
/// Pure: strengths in, losses out. The operation applies them. Kept apart so
/// a test can check the pairwise sums against their closed form — with the
/// counter table at 1 everywhere, each defender's loss is just its share of
/// the attacker's capped strength, and the pairwise loop must agree with that
/// to rounding.
library;

import 'dart:math' as math;

import 'formation.dart';
import 'resolver_tuning.dart';

/// A formation's strength: `count × P × quality × M(morale) × Sup`.
double formationStrength(Formation f, ResolverTuning t, {required bool armed}) =>
    f.count *
    t.powerOf(f.kind) *
    f.quality *
    (0.25 + 0.75 * f.morale) *
    (armed ? 1.0 : t.noAmmoFactor);

/// What one step of contact at one objective does.
class ContactLosses {
  ContactLosses(this.attackerLoss, this.defenderLoss, this.a, this.d);

  /// Members each attacking formation loses this step (fractional).
  final List<double> attackerLoss;

  /// Members each defending formation loses this step (fractional).
  final List<double> defenderLoss;

  /// Effective pressure each side applies, after the width cap and the other
  /// side's fortification: what the control swing compares.
  final double a, d;
}

/// One step of contact. [attS]/[defS] are strengths, [attC]/[defC] their
/// counter classes, in the same order.
///
/// The width cap first: a side brings at most [width] to bear, spread over its
/// formations by strength. Then each dealer's effective strength is shared
/// over the targets by THEIR strength, times the counter factor — the pairwise
/// form, so a counter table can make an anti-armour team hurt tanks without
/// changing how much damage there is in total when every factor is 1.
ContactLosses contactLosses({
  required List<double> attS,
  required List<CounterClass> attC,
  required List<double> defS,
  required List<CounterClass> defC,
  required double width,
  required double fDef,
  required double fAtt,
  required double fuzz,
  required double dt,
  required ResolverTuning tuning,
  CounterTuning counters = const CounterTuning.uniform(),
}) {
  var sumA = 0.0, sumD = 0.0;
  for (final s in attS) {
    sumA += s;
  }
  for (final s in defS) {
    sumD += s;
  }
  final attLoss = List<double>.filled(attS.length, 0);
  final defLoss = List<double>.filled(defS.length, 0);
  if (!(sumA > 0) || !(sumD > 0)) {
    return ContactLosses(attLoss, defLoss, sumA > 0 ? math.min(sumA, width) / fDef : 0,
        sumD > 0 ? math.min(sumD, width) / fAtt : 0);
  }
  final eA = math.min(sumA, width);
  final eD = math.min(sumD, width);
  final kA = tuning.alpha * fuzz / fDef * dt;
  final kD = tuning.alpha * (2 - fuzz) / fAtt * dt;
  for (var i = 0; i < attS.length; i++) {
    final ei = attS[i] * eA / sumA;
    for (var j = 0; j < defS.length; j++) {
      defLoss[j] += kA * ei * (defS[j] / sumD) * counters.factor(attC[i], defC[j]);
    }
  }
  for (var j = 0; j < defS.length; j++) {
    final ej = defS[j] * eD / sumD;
    for (var k = 0; k < attS.length; k++) {
      attLoss[k] += kD * ej * (attS[k] / sumA) * counters.factor(defC[j], attC[k]);
    }
  }
  return ContactLosses(attLoss, defLoss, eA / fDef, eD / fAtt);
}

/// The control swing for one step: `κ·(a − d)/max(a, d, ε)·dt`.
double controlSwing(double a, double d, double dt, ResolverTuning t) {
  final m = math.max(a, math.max(d, 1e-9));
  return t.kappa * (a - d) / m * dt;
}
