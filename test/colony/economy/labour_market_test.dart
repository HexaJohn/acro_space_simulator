// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The labour market on its own, headless (docs/plans/dynamic-markets.md
/// phase 3, `labour_market.dart`): wages by tier move by supply against
/// demand at the goods' month-scale half-life, education and pay move the
/// skill mix, and in a shortage the low bidders starve first.
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:acro_space_simulator/domain/colony/city/economy/economy_clock.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/economy_contracts.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/labour_market.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/skill_tiers.dart';
import 'package:flutter_test/flutter_test.dart';

/// One labour day of [m]: [force] workers at the market's mix against
/// [posts] (flat jobs by tier), then the close.
void labourDay(
  LabourMarket m,
  double force,
  Map<SkillTier, double> posts, {
  double coverage = 0,
}) {
  final a = allocateLabour(
    labourForce: force,
    mix: m.mixFor(coverage),
    flatJobs: posts,
  );
  m.record(a, kColonyDaySec);
  m.closeDay(coverage: coverage);
}

void main() {
  // A sudden shortage: posts for twice the engineers there are. The wage
  // ratio heads for 2 (unit elasticity: q^ε = D/S) and closes half the log
  // gap in about the goods' month (§7.5), as measured from the change.
  test('a shortage raises the wage with about a month\'s half-life', () {
    final m = LabourMarket();
    const force = 1000.0;
    final eng = force * kUnschooledMix[SkillTier.engineering]!;
    // A month balanced first, so the shortage is a step from equilibrium.
    for (var d = 0; d < 30; d++) {
      labourDay(m, force, {SkillTier.engineering: eng});
    }
    expect(m.ratioOf(SkillTier.engineering), closeTo(1, 1e-6));
    // Engineers posted for twice the people: nobody idle above them to
    // fill in (engineering is the top tier), so supply is what they are.
    // The posts follow the mix, which the premium slowly retrains people
    // into, so the shortage stays exactly two to one and its equilibrium
    // exactly 2×.
    double? half;
    for (var d = 1; d <= 200; d++) {
      final have = force * m.mix[SkillTier.engineering]!;
      labourDay(m, force, {SkillTier.engineering: 2 * have});
      final q = m.ratioOf(SkillTier.engineering);
      if (half == null && math.log(q) >= 0.5 * math.ln2) half = d.toDouble();
    }
    final settled = m.ratioOf(SkillTier.engineering);
    // ignore: avoid_print
    print(
      'engineering wage: half the gap in $half days, settles at '
      '${settled.toStringAsFixed(3)}× its anchor',
    );
    expect(half, isNotNull);
    expect(
      half!,
      inInclusiveRange(kLabourHalfLifeDays - 3, kLabourHalfLifeDays + 8),
    );
    // Settles near 2× (the bounded gap pushes a little under its tangent
    // far from balance, so it approaches from below).
    expect(settled, inInclusiveRange(1.85, 2.0));
    // A daily step is never more than the class's η.
    expect(kLabourParams.eta, lessThan(0.05));
  });

  // A surplus brings the wage down, but never below the cost of living.
  test('a surplus lowers the wage to the cost of living, no further', () {
    final m = LabourMarket();
    for (var d = 0; d < 400; d++) {
      labourDay(m, 1000, {SkillTier.engineering: 1});
    }
    expect(
      m.ratioOf(SkillTier.engineering),
      closeTo(wageFloorRatio(SkillTier.engineering), 1e-12),
    );
    // An engineer paid the floor earns exactly the unskilled anchor.
    expect(
      wageFloorRatio(SkillTier.engineering) *
          skillMultipleOf(SkillTier.engineering),
      closeTo(1, 1e-12),
    );
    expect(m.ratioOf(SkillTier.unskilled), 1, reason: 'subsistence floor');
  });

  // Schools move the mix: a colony whose schools cover everyone drifts
  // from the settlers' mix toward the schooled one over the mix's time
  // constant (63% of the way in kSkillMixDays).
  test('an education change shifts the supply mix', () {
    final m = LabourMarket();
    m.mixFor(0);
    final e0 = m.mix[SkillTier.engineering]!;
    expect(e0, kUnschooledMix[SkillTier.engineering]);
    final days = kSkillMixDays.round();
    for (var d = 0; d < days; d++) {
      m.closeDay(coverage: 1);
    }
    final e1 = m.mix[SkillTier.engineering]!;
    final target = kSchooledMix[SkillTier.engineering]!;
    final done = (e1 - e0) / (target - e0);
    expect(done, closeTo(1 - math.exp(-days / kSkillMixDays), 0.01));
    expect(
      m.mix[SkillTier.unskilled]!,
      lessThan(kUnschooledMix[SkillTier.unskilled]!),
    );
    var sum = 0.0;
    for (final v in m.mix.values) {
      sum += v;
    }
    expect(sum, closeTo(1, 1e-12));
    // Supply follows: the same people, more of them engineers.
    final before = allocateLabour(labourForce: 1000, mix: kUnschooledMix);
    final after = allocateLabour(labourForce: 1000, mix: m.mix);
    expect(
      after.available[SkillTier.engineering]!,
      greaterThan(before.available[SkillTier.engineering]!),
    );
  });

  // Pay retrains: a tier kept at a premium draws people into it.
  test('a wage that stays high slowly retrains people into the tier', () {
    final base = educationMix(0);
    final t = retrainTarget(base, {SkillTier.technical: 2});
    expect(t[SkillTier.technical]!, greaterThan(base[SkillTier.technical]!));
    // A tier in surplus keeps its share: nobody unlearns a trade.
    final s = retrainTarget(base, {SkillTier.engineering: 0.5});
    for (final k in SkillTier.values) {
      expect(s[k], closeTo(base[k]!, 1e-12));
    }
  });

  // The shortage: 100 engineers, three plants posting 60 each. The best
  // payer fills its posts, the next gets what is left, the worst nothing.
  test('low-paying plants are the first to go understaffed', () {
    const mix = {SkillTier.engineering: 1.0};
    final a = allocateLabour(
      labourForce: 100,
      mix: mix,
      employers: [
        LabourEmployer(
          site: 'a-loser',
          jobs: const {SkillTier.engineering: 60},
          bid: labourBid(isState: false, margin: -0.2),
        ),
        LabourEmployer(
          site: 'b-thriving',
          jobs: const {SkillTier.engineering: 60},
          bid: labourBid(isState: false, margin: 0.4),
        ),
        LabourEmployer(
          site: 'c-state',
          jobs: const {SkillTier.engineering: 60},
          bid: labourBid(isState: true, margin: 0),
        ),
      ],
    );
    expect(a.share['b-thriving'], 1);
    expect(a.share['c-state'], closeTo(40 / 60, 1e-12));
    expect(a.share['a-loser'], 0);
    expect(a.posted[SkillTier.engineering], 180);
  });

  // A plant held back by its scarcest skill takes only the matching share
  // of the others, leaving them for the next bidder.
  test('a crew is balanced: a plant short of engineers frees its handlers', () {
    const mix = {SkillTier.skilled: 0.5, SkillTier.engineering: 0.5};
    final a = allocateLabour(
      labourForce: 40,
      mix: mix,
      employers: const [
        LabourEmployer(
          site: 'rocket',
          jobs: {SkillTier.engineering: 40, SkillTier.skilled: 20},
          bid: 2,
        ),
        LabourEmployer(site: 'mill', jobs: {SkillTier.skilled: 10}, bid: 1),
      ],
    );
    // 20 engineers for 40 posts: half a crew, so 10 of its 20 handlers.
    expect(a.share['rocket'], closeTo(0.5, 1e-12));
    expect(a.share['mill'], 1, reason: 'the other 10 skilled workers');
  });

  // A worker can take any job below his tier: idle engineers pack crates.
  test('higher tiers fill lower jobs, never the reverse', () {
    const mix = {SkillTier.unskilled: 0.5, SkillTier.engineering: 0.5};
    final down = allocateLabour(
      labourForce: 100,
      mix: mix,
      employers: const [
        LabourEmployer(site: 'pack', jobs: {SkillTier.unskilled: 80}, bid: 1),
      ],
    );
    expect(down.share['pack'], 1);
    final up = allocateLabour(
      labourForce: 100,
      mix: mix,
      employers: const [
        LabourEmployer(site: 'fab', jobs: {SkillTier.engineering: 80}, bid: 1),
      ],
    );
    expect(up.share['fab'], closeTo(50 / 80, 1e-12));
  });

  // Flat buildings are staffed first (CitySim's own throttles ration
  // them); the floors share what they leave.
  test('flat buildings take their staff before the floors bid', () {
    const mix = {SkillTier.technical: 1.0};
    final a = allocateLabour(
      labourForce: 50,
      mix: mix,
      flatJobs: const {SkillTier.technical: 40},
      employers: const [
        LabourEmployer(site: 'p', jobs: {SkillTier.technical: 20}, bid: 9),
      ],
    );
    expect(a.share['p'], closeTo(0.5, 1e-12));
  });

  test('the market saves, restores and carries on identically', () {
    final a = LabourMarket();
    for (var d = 0; d < 40; d++) {
      labourDay(a, 500, {
        SkillTier.technical: 120,
        SkillTier.unskilled: 50,
      }, coverage: 0.4);
    }
    // Mid-day tallies too.
    a.record(
      allocateLabour(
        labourForce: 500,
        mix: a.mix,
        flatJobs: const {SkillTier.technical: 120},
      ),
      30,
    );
    final json = jsonDecode(jsonEncode(a.toJsonOrNull())) as Map;
    final b = LabourMarket()..restore(json.cast<String, Object?>());
    expect(jsonEncode(b.toJsonOrNull()), jsonEncode(a.toJsonOrNull()));
    for (var d = 0; d < 20; d++) {
      labourDay(a, 500, {SkillTier.technical: 150}, coverage: 0.4);
      labourDay(b, 500, {SkillTier.technical: 150}, coverage: 0.4);
    }
    expect(jsonEncode(b.toJsonOrNull()), jsonEncode(a.toJsonOrNull()));
    // An old save has no labour market: fresh, every wage at its anchor.
    final fresh = LabourMarket()..restore(null);
    expect(fresh.isFresh, isTrue);
    expect(fresh.toJsonOrNull(), isNull);
    for (final t in SkillTier.values) {
      expect(fresh.ratioOf(t), 1);
    }
  });

  test('two markets stepped alike are identical (determinism)', () {
    String run() {
      final m = LabourMarket();
      for (var d = 0; d < 90; d++) {
        labourDay(m, 700 + d.toDouble(), {
          SkillTier.engineering: 120,
          SkillTier.skilled: 90,
        }, coverage: d / 90);
      }
      return jsonEncode(m.toJsonOrNull());
    }

    expect(run(), run());
  });
}
