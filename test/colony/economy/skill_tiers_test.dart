// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Which skill every job needs (docs/plans/dynamic-markets.md phase 3,
/// `skill_tiers.dart`): flat buildings by type, factory floors by role.
library;

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/economy_contracts.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/skill_tiers.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_catalog.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_recipe.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_templates.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUpAll(ensureFactoryCatalog);

  test('the documented tier of each kind of plant', () {
    expect(tierOfType('rocketfactory'), SkillTier.engineering);
    expect(tierOfType('electronics'), SkillTier.engineering);
    expect(tierOfType('missilefactory'), SkillTier.engineering);
    expect(tierOfType('refinery'), SkillTier.technical);
    expect(tierOfType('steelmill'), SkillTier.skilled);
    expect(tierOfType('mine'), SkillTier.unskilled);
    expect(tierOfType('farm'), SkillTier.unskilled);
    // Anything unlisted needs no training.
    expect(tierOfType('c-low'), SkillTier.unskilled);
    expect(tierOfType('no-such-building'), SkillTier.unskilled);
    // Every tier pays at least the cost of living, more for more skill.
    var last = 0.0;
    for (final t in SkillTier.values) {
      expect(skillMultipleOf(t), greaterThan(last));
      last = skillMultipleOf(t);
    }
    expect(skillMultipleOf(SkillTier.unskilled), 1);
  });

  test('every catalogue job has a tier, every tier a wage', () {
    for (final s in kUtilCatalog) {
      if (s.jobs <= 0) continue;
      final shares = labourSharesOf(s.type);
      var sum = 0.0;
      for (final v in shares.values) {
        sum += v;
      }
      expect(sum, closeTo(1, 1e-12), reason: s.type);
      expect(wageMultipleOf(shares), greaterThanOrEqualTo(1), reason: s.type);
    }
  });

  // Floors: a station's crew needs its recipe's tier (packers unskilled,
  // machine tending at most technical, assembly the plant's own tier),
  // handlers are skilled, maintenance technicians technical.
  test(
    'floor stations use the recipe tier; handlers and technicians theirs',
    () {
      FactoryRecipe r(String id) => FactoryRecipes.byId(id)!;
      expect(tierOfRecipe(r('rocketfactory:assemble')), SkillTier.engineering);
      expect(
        tierOfRecipe(r('rocketfactory:wireAvionics')),
        SkillTier.engineering,
      );
      expect(
        tierOfRecipe(r('missilefactory:cutTubes')),
        SkillTier.technical,
        reason: 'a press in the missile plant tends a machine',
      );
      expect(tierOfRecipe(r('electronics:pack')), SkillTier.unskilled);
      expect(tierOfRecipe(r('steel:smelt')), SkillTier.skilled);
      expect(tierOfRecipe(r('refinery:synthesise')), SkillTier.technical);
      expect(kHandlerTier, SkillTier.skilled);
      expect(kMaintenanceTier, SkillTier.technical);

      // The Missile Plant's template: 12 assembler jobs are engineering, its
      // 8 press jobs and its automated motor caster's quarter technician
      // technical, its 38 handler operators skilled. The tiers add up to the
      // jobs the floor posts.
      final bp = factoryTemplateFor('missilefactory')!;
      final jobs = labourProfileOf(bp);
      expect(jobs[SkillTier.engineering], 12);
      expect(jobs[SkillTier.technical], 8.25);
      expect(jobs[SkillTier.skilled], 38);
      var total = 0.0;
      for (final v in jobs.values) {
        total += v;
      }
      // Templates ship with their crew HIRED (factory-floors §10 item 20):
      // whole technicians, so the floor posts up to one job more than the
      // profile's fractional technician share.
      final spare = bp.jobDemand - total;
      expect(spare, inInclusiveRange(-1e-9, 1 - 1e-9));
    },
  );
}
