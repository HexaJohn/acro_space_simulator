// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';
import 'dart:isolate';

import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_colony_port.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_floor.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/templates/refinery_template.dart';
import 'package:flutter_test/flutter_test.dart';

import '../factory_test_support.dart';

void main() {
  /// A save is loaded in a fresh process, where nothing has called
  /// `refineryTemplate()` and so nothing has registered the Refinery's
  /// recipes — only `ensureFactoryCatalog()` runs (inside `fromJson`).
  /// If the catalog forgets the chain, every station's recipe id resolves
  /// to nothing and the plant goes dead after a save/load. A spawned
  /// isolate has fresh registries, so it stands in for that new process.
  test('a saved Refinery floor loads and runs in a fresh process', () async {
    final spec = kUtilCatalog.firstWhere((s) => s.type == kRefineryType);
    final floor = FactoryFloor.fromBlueprint(refineryTemplate());
    // 400 s: mid-run, with belts, tanks and totes all holding stock.
    floor.step(400, InfiniteColonyPort());
    final saved = jsonEncode(floor.toJson());

    final rates = await Isolate.run(() {
      final f = FactoryFloor.fromJson(
          (jsonDecode(saved) as Map).cast<String, Object?>());
      // The template test's window: 300 s settle, 1200 s measured.
      final r = measure(f, InfiniteColonyPort(), warmupS: 300, windowS: 1200);
      return Map<String, double>.of(r.outPerS);
    });

    spec.outputs.forEach((c, want) => expect(rates[c] ?? 0,
        closeTo(want, want * 0.05), reason: '$c out after load: $rates'));
  });
}
