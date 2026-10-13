// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';

import 'package:acro_space_simulator/domain/colony/city/factory/factory_colony_port.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_floor.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_handling.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_sim_api.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_templates.dart';
import 'package:flutter_test/flutter_test.dart';

/// Floors are measured headless and re-run after load (§3 "Off-screen",
/// "Persistence"), so vehicles must be as deterministic as walkers: two
/// identical mixed fleets print identical JSON, and a save taken with a
/// forklift on charge, another mid-trip and a crane mid-lift continues
/// bit for bit as if the game had never stopped.
void main() {
  /// The template plus a jack and an AGV: every kind on one floor.
  FactoryFloor mixed() {
    final f = FactoryFloor.fromBlueprint(factoryTemplateFor('steelmill')!);
    expect(f.hire(HandlerKind.palletJack, 1).ok, isTrue);
    expect(f.hire(HandlerKind.agv, 1).ok, isTrue);
    return f;
  }

  test('two identical mixed fleets stay identical', () {
    final a = mixed(), b = mixed();
    final pa = InfiniteColonyPort(), pb = InfiniteColonyPort();
    for (var t = 0; t < 8; t++) {
      a.step(40, pa);
      b.step(40, pb);
      expect(
        jsonEncode(a.toJson()),
        jsonEncode(b.toJson()),
        reason: 'diverged by ${(t + 1) * 40} s',
      );
    }
    expect({for (final h in a.handlers) h.kind}, HandlerKind.values.toSet());
  });

  test('save mid-charge, mid-trip and mid-lift → identical continuation', () {
    final f0 = mixed();
    final port = InfiniteColonyPort();
    f0.step(200, port);
    // Run the first forklift nearly flat so it charges soon.
    final j = f0.toJson();
    final forklift = (j['h'] as List).cast<Map<String, Object?>>().firstWhere(
      (h) => h['k'] == HandlerKind.forklift.name,
    );
    forklift['bt'] = 80.0;
    final a = FactoryFloor.fromJson(
      jsonDecode(jsonEncode(j)) as Map<String, Object?>,
    );

    bool caught() {
      final hs = a.handlers.toList();
      final charging = hs.any((h) => h.state == HandlerState.charging);
      final lifting = hs.any(
        (h) => h.kind == HandlerKind.crane && h.state == HandlerState.carrying,
      );
      final driving = hs.any(
        (h) =>
            (h.kind == HandlerKind.forklift || h.kind == HandlerKind.agv) &&
            h.state != HandlerState.idle &&
            h.state != HandlerState.charging,
      );
      return charging && lifting && driving;
    }

    while (!caught()) {
      a.step(kFactoryStepS, port);
      expect(a.simSeconds, lessThan(600), reason: 'never caught all three');
    }
    a.step(0.1, port); // and a part-run sub-step in the carry
    final saved = jsonEncode(a.toJson());
    final b = FactoryFloor.fromJson(jsonDecode(saved) as Map<String, Object?>);
    expect(jsonEncode(b.toJson()), saved, reason: 'load is lossless');
    final pb = InfiniteColonyPort();
    for (var i = 0; i < 6; i++) {
      a.step(33.3, port);
      b.step(33.3, pb);
      expect(
        jsonEncode(b.toJson()),
        jsonEncode(a.toJson()),
        reason: 'diverged ${(i + 1) * 33.3} s after the load',
      );
    }
  });
}
