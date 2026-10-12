// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';

import 'package:acro_space_simulator/domain/colony/city/factory/factory_colony_port.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_floor.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_sim_api.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_templates.dart';
import 'package:flutter_test/flutter_test.dart';

/// A colony save holds every floor's full runtime state (§3
/// "Persistence"). Saving mid-run — items mid-belt, arms mid-swing,
/// workers mid-trip, a part-run sub-step in the carry — and loading must
/// continue exactly as if the game had never stopped, bit for bit, or a
/// reload would quietly change what a plant produces.
void main() {
  test('save → load → step equals an uninterrupted run', () {
    final a = FactoryFloor.fromBlueprint(factoryTemplateFor('steelmill')!);
    final pa = InfiniteColonyPort();
    a.step(137.3, pa); // leaves 0.05 s in the sub-step carry

    final saved = jsonEncode(a.toJson());
    final snap = jsonDecode(saved) as Map<String, Object?>;
    expect(snap['cr'], isNot(0.0), reason: 'the remainder is part of it');
    expect(a.beltItems, isNotEmpty);
    expect(a.handlers.any((h) => h.state != HandlerState.idle), isTrue,
        reason: 'the save catches a worker mid-trip');

    final b = FactoryFloor.fromJson(snap);
    expect(jsonEncode(b.toJson()), saved, reason: 'load is lossless');

    final pb = InfiniteColonyPort();
    for (var i = 0; i < 4; i++) {
      a.step(50.1, pa);
      b.step(50.1, pb);
    }
    expect(jsonEncode(b.toJson()), jsonEncode(a.toJson()));
    expect(pb.given, isNotEmpty);
  });
}
