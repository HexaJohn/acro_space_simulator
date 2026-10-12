// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/factory/factory_colony_port.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_floor.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_sim_api.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_templates.dart';
import 'package:flutter_test/flutter_test.dart';

import 'factory_test_support.dart';

/// The Steel Mill template is the regression test of the whole feature
/// (docs/plans/factory-floors.md §3 "Templates"): opening a plant's floor
/// must not change what the colony gets from it. The spec's flat rate is
/// 2 ore → 1.5 steel + 0.4 tubes per second with 35 jobs; the template's
/// MEASURED steady state has to land within 5% of each, and ship nothing
/// but steel and tubes (slag is pressed into tubes in place).
void main() {
  test('template steady state is the spec rate within 5%', () {
    final floor = FactoryFloor.fromBlueprint(factoryTemplateFor('steelmill')!);
    final port = InfiniteColonyPort();
    final r = measure(floor, port, warmupS: 300, windowS: 1200);

    expect(r.inPerS.keys, ['ore']);
    expect(r.inPerS['ore']!, closeTo(2.0, 0.1));
    expect(r.outPerS.keys.toSet(), {'steel', 'tubes'},
        reason: 'the mill ships nothing but steel and tubes');
    expect(r.outPerS['steel']!, closeTo(1.5, 0.075));
    expect(r.outPerS['tubes']!, closeTo(0.4, 0.02));
    expect(r.jobs, closeTo(35, 2));
  });

  test('template is a realistic, valid hall', () {
    final bp = factoryTemplateFor('steelmill')!;
    expect(bp.validate(), isEmpty);
    expect(bp.hall.widthM, inInclusiveRange(40, 250));
    expect(bp.hall.depthM, inInclusiveRange(40, 250));
    expect(factoryTemplateFor('i-low'), isNull,
        reason: 'zoned industry never gets a floor');
    expect(factoryTemplateFor('refinery'), isNull);
    expect(identical(factoryTemplateFor('steelmill'),
        factoryTemplateFor('steelmill')), isFalse,
        reason: 'each call is a fresh blueprint the caller may edit');
  });

  test('every station works and the walkers carry the tubes', () {
    final floor = FactoryFloor.fromBlueprint(factoryTemplateFor('steelmill')!);
    final port = InfiniteColonyPort();
    floor.step(300, port);
    floor.takeLedger();
    floor.step(300, port);
    final l = floor.takeLedger();
    expect(l.itemMetres, greaterThan(0),
        reason: 'workers on foot really move freight in the template');
    for (final p in floor.blueprint.placements) {
      if (p.recipe == null) continue;
      expect(floor.statusOf(p.id), isNot(MachineStatus.unstaffed));
      expect(floor.statusOf(p.id), isNot(MachineStatus.blocked),
          reason: 'nothing in the template backs up (${p.recipe})');
    }
  });
}
