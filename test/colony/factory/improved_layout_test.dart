// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/factory/factory_colony_port.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_entities.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_floor.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_handling.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_templates.dart';
import 'package:flutter_test/flutter_test.dart';

import 'factory_test_support.dart';

/// Engagement is optional but REWARDED (§3 "Reward", user decision
/// 2026-10-12): the template must leave room for a better design. Here a
/// designer re-crews the template — one operator per station instead of a
/// manual pair, and one walker fewer — and gets the same steel and tubes
/// for far fewer jobs (the labour lever). The 1.5× cap is the colony's to
/// enforce at integration, not the floor's.
void main() {
  test('a re-crewed template matches its output with fewer jobs', () {
    final base = FactoryFloor.fromBlueprint(factoryTemplateFor('steelmill')!);
    final r0 = measure(base, InfiniteColonyPort(), warmupS: 300, windowS: 900);

    final bp = factoryTemplateFor('steelmill')!;
    for (var i = 0; i < bp.placements.length; i++) {
      final p = bp.placements[i];
      if (p.kind != EntityKind.machine) continue;
      bp.placements[i] = p.copyWith(mode: MachineMode.assisted);
    }
    bp.roster[HandlerKind.onFoot] = 8;
    final better = FactoryFloor.fromBlueprint(bp);
    final r1 = measure(better, InfiniteColonyPort(), warmupS: 300, windowS: 900);

    expect(r1.jobs, lessThan(r0.jobs * 0.7),
        reason: '${r1.jobs} jobs against the template\'s ${r0.jobs}');
    for (final c in ['steel', 'tubes']) {
      expect(r1.outPerS[c]!, greaterThanOrEqualTo(r0.outPerS[c]! * 0.98),
          reason: '$c: ${r1.outPerS[c]} vs ${r0.outPerS[c]}');
    }
  });
}
